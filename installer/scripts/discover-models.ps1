param(
    [switch]$Scheduled,
    [switch]$ForceRebaseline
)

. (Join-Path $PSScriptRoot "_registry.ps1")

$managerHome = Get-ManagerHome
$baselinePath = Get-RegistryPath "discovery-baseline.json"
$latestPath = Get-RegistryPath "discovered-models.json"
$candidatesPath = Get-RegistryPath "candidates.json"
$historyPath = Get-RegistryPath "model-history.jsonl"
$reportDir = Join-Path $managerHome "reports"
Ensure-Dir $reportDir

$providers = Get-ProviderMap
if ($providers.Count -eq 0) {
    Write-Host "还没有配置可扫描的 API Provider。先运行 ONE_CLICK_SETUP.cmd。" -ForegroundColor Yellow
    exit 1
}

$all = New-Object System.Collections.Generic.List[object]

foreach ($kv in $providers.GetEnumerator()) {
    $p = $kv.Value
    if ([string]$p.discovery -eq "none") {
        Write-Host "跳过：$($p.name)（该 provider 不参与自动发现）" -ForegroundColor DarkGray
        continue
    }
    Write-Host "检查：$($p.name)" -ForegroundColor Cyan
    $models = Invoke-ModelsEndpoint $p
    foreach ($m in $models) {
        if (-not (Is-CodingCandidate $p.id $m)) { continue }

        $name = if ($m.PSObject.Properties["name"]) { [string]$m.name } else { [string]$m.id }
        $created = if ($m.PSObject.Properties["created"]) { $m.created } else { $null }

        $all.Add([pscustomobject]@{
            key = ($p.id + "::" + [string]$m.id)
            provider_id = $p.id
            provider_name = $p.name
            model_id = [string]$m.id
            name = $name
            created = $created
            responses_provider = [bool]$p.responses
            gateway = [bool]$p.gateway
            discovered_at = (Get-Date -Format "o")
        })
    }
}

$all = @($all | Sort-Object key -Unique)
Save-JsonFile $latestPath $all

# Stealth lifecycle tracking is read-only with respect to provider catalogs and Codex config.
$stealthSync = Join-Path $PSScriptRoot "sync-stealth-registry.ps1"
if (Test-Path $stealthSync) {
    & $stealthSync -Quiet
}

$baseline = @()
if (Test-Path $baselinePath) {
    $baseline = @(Load-JsonFile $baselinePath @())
}

if ($ForceRebaseline -or $baseline.Count -eq 0) {
    Save-JsonFile $baselinePath $all
    Save-JsonFile $candidatesPath @()
    $msg = "已建立模型发现基线：$($all.Count) 个当前模型。以后新出现的模型才会被标记为候选。"
    Write-Host $msg -ForegroundColor Green
    Add-Content -Path $historyPath -Value (([pscustomobject]@{
        at=(Get-Date -Format "o"); event="baseline"; count=$all.Count
    }) | ConvertTo-Json -Compress)
    exit 0
}

$knownKeys = @{}
foreach ($b in $baseline) { $knownKeys[[string]$b.key] = $true }

$existingCandidates = @()
if (Test-Path $candidatesPath) {
    $existingCandidates = @(Load-JsonFile $candidatesPath @())
}
$candidateMap = @{}
foreach ($c in $existingCandidates) { $candidateMap[[string]$c.key] = $c }

$newCount = 0
foreach ($m in $all) {
    if (-not $knownKeys.ContainsKey([string]$m.key)) {
        if (-not $candidateMap.ContainsKey([string]$m.key)) {
            $candidateMap[[string]$m.key] = [pscustomobject]@{
                key=$m.key
                provider_id=$m.provider_id
                provider_name=$m.provider_name
                model_id=$m.model_id
                name=$m.name
                first_seen=(Get-Date -Format "o")
                status="NEW"
                basic_probe="NOT_RUN"
                tool_probe="NOT_RUN"
                approved=$false
                notes=""
            }
            $newCount++
        }
    }
}

$candidates = @($candidateMap.Values | Sort-Object first_seen -Descending)
Save-JsonFile $candidatesPath $candidates

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $reportDir "model-scan-$stamp.md"

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Codex Multi-Model Model Scan")
$lines.Add("")
$lines.Add("扫描时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$lines.Add("")
$lines.Add("已扫描模型：$($all.Count)")
$lines.Add("本次新增候选：$newCount")
$lines.Add("候选总数：$($candidates.Count)")
$lines.Add("")
$lines.Add("## 新模型候选")
$lines.Add("")
if ($newCount -eq 0) {
    $lines.Add("没有发现新的候选模型。")
} else {
    foreach ($c in ($candidates | Where-Object {$_.status -eq "NEW"} | Select-Object -First 100)) {
        $lines.Add("- $($c.provider_name) :: ``$($c.model_id)``")
    }
}
$lines.Add("")
$lines.Add("> 自动发现不等于 Codex 兼容。只有经过 Responses/工具测试并经用户确认后，才会注册为可用模型。")
Set-Content -Path $reportPath -Value ($lines -join "`r`n") -Encoding UTF8

Add-Content -Path $historyPath -Value (([pscustomobject]@{
    at=(Get-Date -Format "o"); event="scan"; total=$all.Count; new=$newCount; report=$reportPath
}) | ConvertTo-Json -Compress)

if ($newCount -gt 0) {
    Write-Host ""
    Write-Host "发现 $newCount 个新模型候选。" -ForegroundColor Green
    Write-Host "报告：$reportPath"
    Write-Host "运行 MODEL_UPDATE_CENTER.cmd 可测试和批准。" -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "没有发现新模型。" -ForegroundColor Green
    Write-Host "报告：$reportPath"
}

if ($Scheduled -and $newCount -gt 0) {
    $notice = Join-Path $managerHome "NEW_MODELS_FOUND.txt"
    Set-Content -Path $notice -Value "发现 $newCount 个新模型候选。运行 MODEL_UPDATE_CENTER.cmd 审核。`r`n报告：$reportPath" -Encoding UTF8
}
