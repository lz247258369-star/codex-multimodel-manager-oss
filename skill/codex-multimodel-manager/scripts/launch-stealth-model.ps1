param(
    [string]$Alias = "Ox Alpha",
    [string]$ConfirmationCode = "STEALTH",
    [Parameter(Mandatory = $false)]
    [ValidateSet("low","medium","high","xhigh")]
    [string]$ReasoningEffort = "high"
)

. (Join-Path $PSScriptRoot "_registry.ps1")

$registryPath = Get-RegistryPath "stealth-models.json"
$syncScript = Join-Path $PSScriptRoot "sync-stealth-registry.ps1"

if (Test-Path $syncScript) {
    & $syncScript -Quiet
}

if (-not (Test-Path $registryPath)) {
    Write-Host "Stealth Registry 尚未初始化。" -ForegroundColor Yellow
    exit 1
}

$records = @(Load-JsonFile $registryPath @())
$record = $records | Where-Object {
    $_.key -eq $Alias -or $_.alias -eq $Alias -or (@($_.aliases) -contains $Alias)
} | Select-Object -First 1

if ($null -eq $record) {
    Write-Host "没有找到 stealth alias：$Alias" -ForegroundColor Yellow
    exit 1
}

$key = Get-UserEnv "OPENROUTER_API_KEY"
if ([string]::IsNullOrWhiteSpace($key)) {
    Write-Host "缺少 OPENROUTER_API_KEY。请先运行 ONE_CLICK_SETUP.cmd 配置 OpenRouter。" -ForegroundColor Yellow
    exit 1
}
# A Windows user-scoped environment variable is not retroactively inherited by
# an already-open terminal. Codex reads env_key from its process environment,
# so hydrate the current launcher process without printing or persisting the key.
Set-Item -Path "Env:OPENROUTER_API_KEY" -Value $key

$codexHome = Get-CodexHome
$configPath = Join-Path $codexHome "config.toml"
if (-not (Test-Path $configPath)) {
    Write-Host "未找到 Codex config.toml。请先运行 ONE_CLICK_SETUP.cmd。" -ForegroundColor Yellow
    exit 1
}

$configText = Get-Content -Raw -Path $configPath
if ($configText -notmatch '(?m)^\[model_providers\.mm_openrouter\]\s*$') {
    Write-Host "Codex 尚未配置 mm_openrouter Provider。请先运行 ONE_CLICK_SETUP.cmd -> OpenRouter。" -ForegroundColor Yellow
    exit 1
}

$headers = @{ Authorization = "Bearer $key" }
try {
    $catalog = Invoke-RestMethod -Method Get -Uri "https://openrouter.ai/api/v1/models" -Headers $headers -TimeoutSec 30
    $models = @($catalog.data)
}
catch {
    Write-Host "无法读取 OpenRouter 模型目录：$($_.Exception.Message)" -ForegroundColor Yellow
    exit 2
}

$replacementId = [string]$record.replacement_id
$currentId = [string]$record.current_id
$resolvedId = ""

if (-not [string]::IsNullOrWhiteSpace($replacementId) -and @($models | Where-Object { $_.id -eq $replacementId }).Count -gt 0) {
    $resolvedId = $replacementId
}
elseif (-not [string]::IsNullOrWhiteSpace($currentId) -and @($models | Where-Object { $_.id -eq $currentId }).Count -gt 0) {
    $resolvedId = $currentId
}

if ([string]::IsNullOrWhiteSpace($resolvedId)) {
    Write-Host "该 alias 当前没有可用的 OpenRouter 模型 ID。" -ForegroundColor Yellow
    Write-Host "Alias: $($record.alias)"
    Write-Host "Current: $currentId"
    Write-Host "Replacement: $replacementId"
    Write-Host "请先运行 STEALTH_MODEL_REGISTRY.cmd 检查或记录揭晓后的新 ID。" -ForegroundColor Yellow
    exit 2
}

Write-Host ""
Write-Host "Stealth / Alias launch" -ForegroundColor Cyan
Write-Host "Alias:       $($record.alias)"
Write-Host "Status:      $($record.status)"
Write-Host "Original ID: $($record.original_id)"
Write-Host "Resolved ID: $resolvedId"
Write-Host "Performance: $ReasoningEffort"
if (-not [string]::IsNullOrWhiteSpace([string]$record.official_name)) {
    Write-Host "Official:    $($record.official_name)"
}
Write-Host ""
Write-Host "匿名/stealth 模型的身份、路由、可用性和数据处理政策可能变化。" -ForegroundColor Yellow
Write-Host "不会把该模型设为默认主力，也不会自动替换 GPT-5.6。" -ForegroundColor Yellow
Write-Host "对私有核心代码、商业机密、凭据等敏感内容，请先确认当前数据政策。" -ForegroundColor Yellow
Write-Host ""
$confirm = Read-Host "如仍要启动，请输入 $ConfirmationCode"
if ($confirm -cne $ConfirmationCode) {
    Write-Host "已取消。" -ForegroundColor DarkGray
    exit 0
}

$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -ne $git) {
    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) {
        $handoff = Join-Path $PSScriptRoot "collect-handoff.ps1"
        if (Test-Path $handoff) {
            & $handoff -TargetModel "$($record.alias) ($resolvedId)"
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Git handoff 失败，本次不启动模型。" -ForegroundColor Red
                exit 3
            }
        }
    }
}

$effortConfig = 'model_reasoning_effort="{0}"' -f $ReasoningEffort
Write-Host "启动 Codex：$($record.alias) -> $resolvedId · reasoning=$ReasoningEffort" -ForegroundColor Green
& codex -m $resolvedId -c 'model_provider="mm_openrouter"' -c $effortConfig
exit $LASTEXITCODE
