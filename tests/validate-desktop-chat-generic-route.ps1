param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
$scriptPath = Join-Path $RepositoryRoot "installer/scripts/desktop-chat-route.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing generic Desktop route script: $scriptPath" }

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors) | Out-Null
if (@($errors).Count -gt 0) { throw "Generic Desktop route parse failed: $($errors[0].Message)" }

$text = Get-Content -Raw -LiteralPath $scriptPath
foreach ($marker in @(
    'ValidateSet("activate", "restore", "status")',
    '"modelstudio"',
    'CodexProvider="mm_modelstudio"',
    '"openrouter"',
    'CodexProvider="mm_openrouter"',
    '"mimo"',
    'CodexProvider="mm_mimo"',
    'managed_env_keys',
    'Backup-CodexConfig',
    'Set-DesktopRouteBlock'
)) {
    if (-not $text.Contains($marker)) { throw "Missing generic Desktop route marker: $marker" }
}

$tempRoot = Join-Path $env:TEMP ("mm-generic-desktop-{0}" -f ([Guid]::NewGuid().ToString("N")))
$oldCodexHome = $env:CODEX_HOME
$oldDash = $env:CODEX_DASHSCOPE_API_KEY
$oldOpenRouter = $env:OPENROUTER_API_KEY
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $env:CODEX_HOME = $tempRoot
    $env:CODEX_DASHSCOPE_API_KEY = "test-dashscope-key"
    $env:OPENROUTER_API_KEY = "test-openrouter-key"

    $managerHome = Join-Path $tempRoot "multimodel-manager"
    New-Item -ItemType Directory -Path $managerHome -Force | Out-Null
    @{
        aliyun_enabled = $true
        aliyun_base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        openrouter_enabled = $true
        mimo_enabled = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $managerHome "state.json") -Encoding utf8

    $configPath = Join-Path $tempRoot "config.toml"
    $originalConfig = "# ORIGINAL CHATGPT CONFIG`r`nmodel_reasoning_effort = `"medium`"`r`n"
    Set-Content -LiteralPath $configPath -Value $originalConfig -NoNewline -Encoding utf8

    & $scriptPath -Mode activate -ProviderId modelstudio -ModelId deepseek-v4-flash -Label "DeepSeek V4 Flash" -Effort high
    $routeStatePath = Join-Path $managerHome "desktop-route-state.json"
    $state1 = Get-Content -Raw -LiteralPath $routeStatePath | ConvertFrom-Json
    if (-not [bool]$state1.active) { throw "DeepSeek route was not activated." }
    if ([string]$state1.provider -ne "mm_modelstudio") { throw "DeepSeek route provider mismatch: $($state1.provider)" }
    if ([string]$state1.model -ne "deepseek-v4-flash") { throw "DeepSeek route model mismatch." }
    $originalBackup = [string]$state1.backup_dir
    if (-not (Test-Path -LiteralPath $originalBackup)) { throw "Original rollback backup missing." }
    $configAfterDeepSeek = Get-Content -Raw -LiteralPath $configPath
    if ($configAfterDeepSeek -notmatch 'model\s*=\s*"deepseek-v4-flash"') { throw "DeepSeek route not written to config." }
    if ($configAfterDeepSeek -notmatch 'model_provider\s*=\s*"mm_modelstudio"') { throw "DeepSeek provider not written to config." }

    & $scriptPath -Mode activate -ProviderId openrouter -ModelId stealth/ox-alpha -Label "Ox Alpha" -Effort high -ConfirmationCode OX
    $state2 = Get-Content -Raw -LiteralPath $routeStatePath | ConvertFrom-Json
    if ([string]$state2.provider -ne "mm_openrouter") { throw "OX route provider mismatch." }
    if ([string]$state2.model -ne "stealth/ox-alpha") { throw "OX route model mismatch." }
    if ([string]$state2.backup_dir -ne $originalBackup) { throw "Direct custom-route switch replaced the original ChatGPT backup." }
    $managedKeys = @($state2.managed_env_keys)
    if ("CODEX_DASHSCOPE_API_KEY" -notin $managedKeys -or "OPENROUTER_API_KEY" -notin $managedKeys) { throw "Managed env key union was not preserved across route switches." }

    & $scriptPath -Mode restore
    $restored = Get-Content -Raw -LiteralPath $configPath
    if ($restored -ne $originalConfig) { throw "Restore did not return config.toml to the exact original content." }
    if (Test-Path -LiteralPath (Join-Path $tempRoot ".env")) { throw "Manager-created .env should be removed after restore when no original .env existed." }
    $state3 = Get-Content -Raw -LiteralPath $routeStatePath | ConvertFrom-Json
    if ([bool]$state3.active) { throw "Route state remained active after restore." }

    Write-Host "Generic Desktop route activate/switch/restore PASS" -ForegroundColor Green
}
finally {
    $env:CODEX_HOME = $oldCodexHome
    $env:CODEX_DASHSCOPE_API_KEY = $oldDash
    $env:OPENROUTER_API_KEY = $oldOpenRouter
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
