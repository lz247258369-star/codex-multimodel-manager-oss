param(
    [Parameter(Mandatory=$true)][string]$ProviderId,
    [Parameter(Mandatory=$true)][string]$ModelId,
    [string]$DisplayName = "",
    # DSR5: registry-only approval.
    #
    # The legacy approval path also projects the approval into Codex config
    # (legacy AUTO MODELS block -> Profile V2 migration -> dedicated profile
    # files). That projection is the right default for a normal interactive
    # approval, but it is the wrong tool when the caller only needs the formal
    # approved-model registry record and must not touch Codex config at all
    # (e.g. the Local Router bootstrap, whose routes are generated from the
    # registry by router-codex-cli.ps1 -Action Initialize).
    #
    # RegistryOnly keeps every admission check and every registry write, and
    # skips only the config/profile side effects. Default stays $false so the
    # historical behaviour of this script is unchanged for existing callers.
    [switch]$RegistryOnly
)

. (Join-Path $PSScriptRoot "_registry.ps1")

$providers = Get-ProviderMap
if (-not $providers.Contains($ProviderId)) {
    throw "Provider 未配置：$ProviderId"
}

$candidatesPath = Get-RegistryPath "candidates.json"
$candidates = @(Load-JsonFile $candidatesPath @())
$c = $candidates | Where-Object {$_.provider_id -eq $ProviderId -and $_.model_id -eq $ModelId} | Select-Object -First 1
if ($null -eq $c) {
    throw "未找到候选模型：$ProviderId / $ModelId"
}

if ($c.basic_probe -ne "PASS") {
    throw "该模型还没有通过基本 Responses 测试。请先运行 probe-model.ps1。"
}

$approvedPath = Get-RegistryPath "approved-models.json"
$approved = @(Load-JsonFile $approvedPath @())

if (-not ($approved | Where-Object {$_.provider_id -eq $ProviderId -and $_.model_id -eq $ModelId})) {
    $profileId = Sanitize-ProfileId $ProviderId $ModelId
    $approved += [pscustomobject]@{
        provider_id = $ProviderId
        provider_name = $providers[$ProviderId].name
        model_id = $ModelId
        display_name = $(if ($DisplayName) {$DisplayName} elseif ($c.name) {$c.name} else {$ModelId})
        profile_id = $profileId
        approved_at = (Get-Date -Format "o")
        basic_probe = $c.basic_probe
        tool_probe = $c.tool_probe
    }
    Save-JsonFile $approvedPath $approved
}

foreach ($x in $candidates) {
    if ($x.provider_id -eq $ProviderId -and $x.model_id -eq $ModelId) {
        $x.approved = $true
        $x.status = "APPROVED"
    }
}
Save-JsonFile $candidatesPath $candidates

if ($RegistryOnly) {
    # Registry-only approval: the admission checks above and the two registry
    # writes are the whole contract. Codex config, the legacy AUTO MODELS
    # block, Profile V2 migration, profile files and profile-v2-files.json are
    # deliberately left untouched.
    Write-Host "Approval mode: REGISTRY_ONLY" -ForegroundColor Cyan
    Write-Host "APPROVED" -ForegroundColor Green
    Write-Host "Model: $ModelId"
    Write-Host "Provider: $ProviderId"
    Write-Host "Registry: $approvedPath"
    Write-Host "Codex config: NOT_MODIFIED (registry-only approval)"
    return
}

Write-Host "Approval mode: LEGACY_PROFILE" -ForegroundColor Cyan

# Build the legacy AUTO MODELS block first, then immediately migrate it to
# Codex Profile V2 dedicated files. This keeps older state compatible while
# ensuring current Codex never sees [profiles.*] in the base config.
$codexHome = Get-CodexHome
$config = Join-Path $codexHome "config.toml"
if (-not (Test-Path $config)) {
    New-Item -ItemType File -Force -Path $config | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $codexHome "backups\auto-models-$stamp"
Ensure-Dir $backupDir
Copy-Item $config (Join-Path $backupDir "config.toml") -Force

$text = Get-Content -Raw $config
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# >>> CODEX AUTO MODELS BEGIN")
$lines.Add("# 临时兼容块；会立即迁移到 Codex Profile V2 独立文件。")
$lines.Add("")

foreach ($a in ($approved | Sort-Object provider_id, model_id)) {
    # NOTE: this local must not be named $pid - $PID is a read-only automatic
    # variable in PowerShell, so assigning to it aborts the legacy projection.
    $profileKey = $a.profile_id
    $mid = ([string]$a.model_id).Replace('\','\\').Replace('"','\"')
    $prov = ([string]$a.provider_id).Replace('\','\\').Replace('"','\"')
    $lines.Add("[profiles.$profileKey]")
    $lines.Add('model = "' + $mid + '"')
    $lines.Add('model_provider = "' + $prov + '"')
    $lines.Add("")
}
$lines.Add("# <<< CODEX AUTO MODELS END")
$block = $lines -join "`r`n"

$pattern = '(?s)# >>> CODEX AUTO MODELS BEGIN.*?# <<< CODEX AUTO MODELS END'
if ([regex]::IsMatch($text, $pattern)) {
    $newText = [regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 1)
} else {
    if (-not [string]::IsNullOrWhiteSpace($text) -and -not $text.EndsWith("`n")) { $text += "`r`n" }
    $newText = $text + "`r`n" + $block + "`r`n"
}
Set-Content -Path $config -Value $newText -Encoding UTF8

$migrationScript = Join-Path $PSScriptRoot "migrate-profile-v2.ps1"
if (Test-Path $migrationScript) {
    & $migrationScript -SkipBackup -Quiet
}

Write-Host "APPROVED" -ForegroundColor Green
Write-Host "Model: $ModelId"
Write-Host "Provider: $ProviderId"
Write-Host "Profile: $(Sanitize-ProfileId $ProviderId $ModelId)"
Write-Host "Config backup: $backupDir"
