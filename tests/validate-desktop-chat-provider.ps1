param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Fail([string]$Message) {
    $failures.Add($Message)
    Write-Host "FAIL  $Message" -ForegroundColor Red
}

function Pass([string]$Message) {
    Write-Host "PASS  $Message" -ForegroundColor Green
}

$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$scriptPath = Join-Path $RepositoryRoot "installer/scripts/desktop-chat-provider.ps1"
$activateCmd = Join-Path $RepositoryRoot "installer/ACTIVATE_OX_DESKTOP_EXPERIMENTAL.cmd"
$restoreCmd = Join-Path $RepositoryRoot "installer/RESTORE_CHATGPT_DESKTOP.cmd"
$docPath = Join-Path $RepositoryRoot "docs/DESKTOP_CHAT_PROVIDER_EXPERIMENT.md"

foreach ($path in @($scriptPath, $activateCmd, $restoreCmd, $docPath)) {
    if (Test-Path -LiteralPath $path) { Pass "Exists: $($path.Substring($RepositoryRoot.Length + 1))" }
    else { Fail "Missing: $($path.Substring($RepositoryRoot.Length + 1))" }
}

if (Test-Path -LiteralPath $scriptPath) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -eq 0) { Pass "desktop-chat-provider.ps1 parses" }
    else { Fail "desktop-chat-provider.ps1 has PowerShell parse errors" }

    $text = Get-Content -Raw -LiteralPath $scriptPath
    foreach ($required in @(
        'stealth/ox-alpha',
        'mm_openrouter',
        'OPENROUTER_API_KEY',
        'CODEX MULTIMODEL MANAGER DESKTOP ROUTE BEGIN',
        'Backup-CodexConfig',
        'desktop-route-state.json',
        'Test-DesktopRouteActive',
        'Original rollback backup is preserved',
        '"status" { Show-DesktopRouteStatus }'
    )) {
        if ($text -match [regex]::Escape($required)) { Pass "Script contains required guard/route: $required" }
        else { Fail "Script missing required guard/route: $required" }
    }

    foreach ($pattern in @('\bgit\s+reset\b','\bgit\s+clean\b','\bgit\s+stash\b','force push')) {
        if ($text -match $pattern) { Fail "Forbidden destructive Git behavior detected: $pattern" }
    }
}

if (Test-Path -LiteralPath $activateCmd) {
    $text = Get-Content -Raw -LiteralPath $activateCmd
    if ($text -match 'desktop-chat-provider\.ps1' -and $text -match '-Mode activate-ox') { Pass "Activation CMD routes to activate-ox" }
    else { Fail "Activation CMD does not route to activate-ox" }
}

if (Test-Path -LiteralPath $restoreCmd) {
    $text = Get-Content -Raw -LiteralPath $restoreCmd
    if ($text -match 'desktop-chat-provider\.ps1' -and $text -match '-Mode restore') { Pass "Restore CMD routes to restore" }
    else { Fail "Restore CMD does not route to restore" }
}

if ($failures.Count -eq 0 -and (Test-Path -LiteralPath $scriptPath)) {
    $oldCodexHome = $env:CODEX_HOME
    $oldOpenRouter = $env:OPENROUTER_API_KEY
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-desktop-route-test-" + [guid]::NewGuid().ToString("N"))

    try {
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        $env:CODEX_HOME = $tempRoot
        $env:OPENROUTER_API_KEY = "test-secret-not-real"

        $managerHome = Join-Path $tempRoot "multimodel-manager"
        New-Item -ItemType Directory -Force -Path $managerHome | Out-Null
        '{"openrouter_enabled":true}' | Set-Content -LiteralPath (Join-Path $managerHome "state.json") -Encoding UTF8

        $configPath = Join-Path $tempRoot "config.toml"
        $originalConfig = @'
approval_policy = "on-request"
model = "gpt-old"
model_provider = "openai"
model_reasoning_effort = "medium"

[profiles.keep_me]
model = "keep-me"
'@
        Set-Content -LiteralPath $configPath -Value $originalConfig -Encoding UTF8
        $originalConfigOnDisk = Get-Content -Raw -LiteralPath $configPath

        $envPath = Join-Path $tempRoot ".env"
        $originalEnv = "EXISTING_VALUE=keep`r`n"
        Set-Content -LiteralPath $envPath -Value $originalEnv -NoNewline -Encoding UTF8
        $originalEnvOnDisk = Get-Content -Raw -LiteralPath $envPath

        & $scriptPath -Mode activate-ox -ConfirmationCode OX

        $activeConfig = Get-Content -Raw -LiteralPath $configPath
        if ($activeConfig -match '(?m)^model = "stealth/ox-alpha"\r?$' -and
            $activeConfig -match '(?m)^model_provider = "mm_openrouter"\r?$' -and
            $activeConfig -match '(?m)^model_reasoning_effort = "high"\r?$') {
            Pass "Activation writes Ox Alpha Desktop root route"
        }
        else { Fail "Activation did not write the expected Ox Alpha Desktop root route" }

        if ($activeConfig -match '(?m)^\[model_providers\.mm_openrouter\]\r?$') { Pass "Activation preserves/creates mm_openrouter provider definition" }
        else { Fail "Activation missing mm_openrouter provider definition" }

        $activeEnv = Get-Content -Raw -LiteralPath $envPath
        if ($activeEnv -match '(?m)^EXISTING_VALUE=keep\r?$' -and $activeEnv -match '(?m)^OPENROUTER_API_KEY=test-secret-not-real\r?$') {
            Pass "Activation preserves existing .env content and adds local OpenRouter key"
        }
        else { Fail "Activation did not update .env as expected" }

        $routeStatePath = Join-Path $managerHome "desktop-route-state.json"
        $firstRouteState = Get-Content -Raw -LiteralPath $routeStatePath | ConvertFrom-Json
        $firstBackup = [string]$firstRouteState.backup_dir
        $firstActiveConfig = Get-Content -Raw -LiteralPath $configPath

        & $scriptPath -Mode activate-ox -ConfirmationCode OX

        $secondRouteState = Get-Content -Raw -LiteralPath $routeStatePath | ConvertFrom-Json
        $secondActiveConfig = Get-Content -Raw -LiteralPath $configPath
        if ([string]$secondRouteState.backup_dir -eq $firstBackup -and $secondActiveConfig -eq $firstActiveConfig) {
            Pass "Repeated activation is idempotent and preserves the original rollback backup"
        }
        else { Fail "Repeated activation rotated the rollback backup or changed active config" }

        & $scriptPath -Mode status
        Pass "Status mode executes while Ox route is active"

        & $scriptPath -Mode restore

        $restoredConfig = Get-Content -Raw -LiteralPath $configPath
        $restoredEnv = Get-Content -Raw -LiteralPath $envPath
        if ($restoredConfig -eq $originalConfigOnDisk) { Pass "Restore returns config.toml exactly to pre-activation content" }
        else { Fail "Restore did not return config.toml to pre-activation content" }

        if ($restoredEnv -eq $originalEnvOnDisk) { Pass "Restore returns .env exactly to pre-activation content" }
        else { Fail "Restore did not return .env to pre-activation content" }

        & $scriptPath -Mode restore
        Pass "Repeated restore is safe and idempotent"
    }
    catch {
        Fail "Isolated activation/restore runtime test failed: $($_.Exception.Message)"
    }
    finally {
        $env:CODEX_HOME = $oldCodexHome
        $env:OPENROUTER_API_KEY = $oldOpenRouter
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Desktop Chat provider validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "Desktop Chat provider validation PASSED" -ForegroundColor Green
exit 0
