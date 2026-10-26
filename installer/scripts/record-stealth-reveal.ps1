param(
    [Parameter(Mandatory = $true)][string]$Alias,
    [Parameter(Mandatory = $true)][string]$NewModelId,
    [string]$OfficialName = ""
)

. (Join-Path $PSScriptRoot "_registry.ps1")

$registryPath = Get-RegistryPath "stealth-models.json"
$historyPath = Get-RegistryPath "stealth-model-history.jsonl"
$syncScript = Join-Path $PSScriptRoot "sync-stealth-registry.ps1"

if (Test-Path $syncScript) {
    & $syncScript -Quiet
}

if (-not (Test-Path $registryPath)) {
    throw "Stealth registry 尚未初始化。先运行 sync-stealth-registry.ps1。"
}

$records = @(Load-JsonFile $registryPath @())
$record = $records | Where-Object {
    $_.key -eq $Alias -or $_.alias -eq $Alias -or (@($_.aliases) -contains $Alias)
} | Select-Object -First 1

if ($null -eq $record) {
    throw "没有找到 stealth alias：$Alias"
}

$headers = @{}
$key = Get-UserEnv "OPENROUTER_API_KEY"
if (-not [string]::IsNullOrWhiteSpace($key)) {
    $headers["Authorization"] = "Bearer $key"
}

Write-Host "验证 OpenRouter 正式/替代模型 ID：$NewModelId" -ForegroundColor Cyan
try {
    $catalog = Invoke-RestMethod -Method Get -Uri "https://openrouter.ai/api/v1/models" -Headers $headers -TimeoutSec 30
    $newModel = @($catalog.data | Where-Object { $_.id -eq $NewModelId }) | Select-Object -First 1
}
catch {
    throw "无法验证 OpenRouter 模型目录：$($_.Exception.Message)"
}

if ($null -eq $newModel) {
    throw "OpenRouter 当前模型目录中没有：$NewModelId。不会记录迁移。"
}

$oldCurrent = [string]$record.current_id
$oldReplacement = [string]$record.replacement_id
$displayOfficial = if (-not [string]::IsNullOrWhiteSpace($OfficialName)) {
    $OfficialName
} elseif ($null -ne $newModel.PSObject.Properties["name"] -and -not [string]::IsNullOrWhiteSpace([string]$newModel.name)) {
    [string]$newModel.name
} else {
    $NewModelId
}

Write-Host ""
Write-Host "准备记录匿名模型揭晓/迁移：" -ForegroundColor Yellow
Write-Host "Alias:          $($record.alias)"
Write-Host "原匿名 ID:      $oldCurrent"
Write-Host "新模型 ID:      $NewModelId"
Write-Host "正式名称:        $displayOfficial"
Write-Host ""
Write-Host "这不会删除旧 ID，也不会替换 GPT-5.6 或修改项目代码。" -ForegroundColor Yellow
Write-Host "以后通过该 alias 启动时，会优先解析到已确认的新模型 ID。" -ForegroundColor Yellow
$confirm = Read-Host "确认记录迁移请输入 MIGRATE"
if ($confirm -cne "MIGRATE") {
    Write-Host "已取消。" -ForegroundColor DarkGray
    exit 0
}

$now = Get-Date -Format "o"
$record | Add-Member -NotePropertyName replacement_id -NotePropertyValue $NewModelId -Force
$record | Add-Member -NotePropertyName official_name -NotePropertyValue $displayOfficial -Force
$record | Add-Member -NotePropertyName revealed_at -NotePropertyValue $now -Force
$record | Add-Member -NotePropertyName status -NotePropertyValue "REVEAL_RECORDED" -Force
$record | Add-Member -NotePropertyName resolved_id -NotePropertyValue $NewModelId -Force

Save-JsonFile $registryPath $records

$event = [pscustomobject][ordered]@{
    at = $now
    event = "reveal_recorded"
    key = $record.key
    alias = $record.alias
    old_current_id = $oldCurrent
    previous_replacement_id = $oldReplacement
    replacement_id = $NewModelId
    official_name = $displayOfficial
}
Add-Content -Path $historyPath -Value ($event | ConvertTo-Json -Compress)

if (Test-Path $syncScript) {
    & $syncScript -Quiet
}

Write-Host "MIGRATION RECORDED" -ForegroundColor Green
Write-Host "$($record.alias): $oldCurrent -> $NewModelId"
Write-Host "旧匿名 ID 作为历史信息保留；不会自动删除。"
exit 0
