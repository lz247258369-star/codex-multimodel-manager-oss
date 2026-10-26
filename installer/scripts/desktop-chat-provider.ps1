param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("activate-ox", "restore", "status")]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [string]$ConfirmationCode = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_common.ps1")

function Get-ManagerHome {
    $path = Join-Path (Get-CodexHome) "multimodel-manager"
    Ensure-Directory $path
    return $path
}

function Get-DesktopRouteStatePath {
    return (Join-Path (Get-ManagerHome) "desktop-route-state.json")
}

function Get-DesktopRouteState {
    $path = Get-DesktopRouteStatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json) }
    catch { return $null }
}

function Test-DesktopRouteActive($RouteState) {
    if ($null -eq $RouteState) { return $false }
    if (-not $RouteState.PSObject.Properties["active"]) { return $false }
    return [bool]$RouteState.active
}

function Get-UserOrProcessEnv([string]$Name) {
    $processValue = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($processValue)) { return $processValue }
    return [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::User)
}

function Set-DotEnvEntry([string]$Path, [string]$Name, [string]$Value) {
    $lines = @()
    if (Test-Path -LiteralPath $Path) {
        $lines = @(Get-Content -LiteralPath $Path)
    }

    $pattern = '^\s*' + [regex]::Escape($Name) + '\s*='
    $newLines = New-Object System.Collections.Generic.List[string]
    $replaced = $false

    foreach ($line in $lines) {
        if ($line -match $pattern) {
            if (-not $replaced) {
                $newLines.Add("$Name=$Value")
                $replaced = $true
            }
            continue
        }
        $newLines.Add([string]$line)
    }

    if (-not $replaced) {
        if ($newLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$newLines[$newLines.Count - 1])) {
            $newLines.Add("")
        }
        $newLines.Add("$Name=$Value")
    }

    Set-Content -LiteralPath $Path -Value @($newLines) -Encoding UTF8
}

function Set-DesktopRouteBlock(
    [string]$ConfigPath,
    [string]$Model,
    [string]$Provider,
    [string]$Effort
) {
    $text = if (Test-Path -LiteralPath $ConfigPath) { Get-Content -Raw -LiteralPath $ConfigPath } else { "" }

    $managedPattern = '(?ms)^# >>> CODEX MULTIMODEL MANAGER DESKTOP ROUTE BEGIN\r?\n.*?^# <<< CODEX MULTIMODEL MANAGER DESKTOP ROUTE END\r?\n?'
    $text = [regex]::Replace($text, $managedPattern, "")

    $tableMatch = [regex]::Match($text, '(?m)^\s*\[')
    if ($tableMatch.Success) {
        $prefix = $text.Substring(0, $tableMatch.Index)
        $tables = $text.Substring($tableMatch.Index)
    }
    else {
        $prefix = $text
        $tables = ""
    }

    foreach ($name in @("model", "model_provider", "model_reasoning_effort")) {
        $linePattern = '(?m)^\s*' + [regex]::Escape($name) + '\s*=.*(?:\r?\n|$)'
        $prefix = [regex]::Replace($prefix, $linePattern, "")
    }

    $prefix = $prefix.TrimEnd()
    $routeBlock = @(
        "# >>> CODEX MULTIMODEL MANAGER DESKTOP ROUTE BEGIN",
        "# Experimental Desktop route. Remove with RESTORE_CHATGPT_DESKTOP.cmd.",
        ('model = "{0}"' -f (Escape-TomlString $Model)),
        ('model_provider = "{0}"' -f (Escape-TomlString $Provider)),
        ('model_reasoning_effort = "{0}"' -f (Escape-TomlString $Effort)),
        "# <<< CODEX MULTIMODEL MANAGER DESKTOP ROUTE END"
    ) -join "`r`n"

    $parts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($prefix)) { $parts.Add($prefix) }
    $parts.Add($routeBlock)
    if (-not [string]::IsNullOrWhiteSpace($tables)) { $parts.Add($tables.TrimStart()) }

    Set-Content -LiteralPath $ConfigPath -Value (($parts -join "`r`n`r`n") + "`r`n") -Encoding UTF8
}

function Save-DesktopRouteState(
    [string]$BackupDir,
    [bool]$EnvExisted,
    [string]$ConfigPath,
    [string]$EnvPath
) {
    [ordered]@{
        active = $true
        provider = "mm_openrouter"
        model = "stealth/ox-alpha"
        backup_dir = $BackupDir
        config_path = $ConfigPath
        env_path = $EnvPath
        env_existed = $EnvExisted
        activated_at = (Get-Date -Format "o")
    } | ConvertTo-Json | Set-Content -LiteralPath (Get-DesktopRouteStatePath) -Encoding UTF8
}

function Show-DesktopRouteStatus {
    $routeState = Get-DesktopRouteState
    if (-not (Test-DesktopRouteActive $routeState)) {
        Write-Host "Desktop route: ChatGPT/OpenAI default or no active Manager override." -ForegroundColor Green
        return
    }

    $provider = if ($routeState.PSObject.Properties["provider"]) { [string]$routeState.provider } else { "unknown" }
    $model = if ($routeState.PSObject.Properties["model"]) { [string]$routeState.model } else { "unknown" }
    Write-Host "Desktop route ACTIVE: $model -> $provider" -ForegroundColor Cyan
    if ($routeState.PSObject.Properties["backup_dir"]) {
        Write-Host "Rollback backup: $([string]$routeState.backup_dir)" -ForegroundColor DarkGray
    }
}

function Activate-OxDesktop {
    $existingRoute = Get-DesktopRouteState
    if (Test-DesktopRouteActive $existingRoute) {
        $existingModel = if ($existingRoute.PSObject.Properties["model"]) { [string]$existingRoute.model } else { "" }
        $existingProvider = if ($existingRoute.PSObject.Properties["provider"]) { [string]$existingRoute.provider } else { "" }
        if ($existingModel -eq "stealth/ox-alpha" -and $existingProvider -eq "mm_openrouter") {
            Write-Host "Desktop route already active: Ox Alpha -> mm_openrouter" -ForegroundColor Green
            Write-Host "Original rollback backup is preserved; no new backup was created." -ForegroundColor DarkGray
            Write-Host "如刚修改过应用状态，请彻底退出 Codex Desktop、重新打开，并新建会话。" -ForegroundColor Cyan
            return
        }
        throw "A different Manager Desktop route is already active. Restore it before activating Ox Alpha."
    }

    $code = $ConfirmationCode
    if ([string]::IsNullOrWhiteSpace($code)) {
        Write-Host "Ox Alpha 是匿名实验模型。此操作会修改 ~/.codex/config.toml 的默认 Desktop 路由，并在 ~/.codex/.env 中写入 OPENROUTER_API_KEY 的本地副本。" -ForegroundColor Yellow
        Write-Host "不会修改 Codex Desktop 程序本体，也不会把第三方模型注入官方模型下拉框。" -ForegroundColor DarkGray
        $code = Read-Host "如仍要继续，请输入 OX"
    }
    if ($code.Trim().ToUpperInvariant() -ne "OX") {
        throw "Confirmation failed. Type OX to activate the experimental Desktop route."
    }

    $openRouterKey = Get-UserOrProcessEnv "OPENROUTER_API_KEY"
    if ([string]::IsNullOrWhiteSpace($openRouterKey)) {
        throw "Missing OPENROUTER_API_KEY. Run ONE_CLICK_SETUP.cmd first."
    }

    $state = Load-State
    if (-not (Get-StateValue $state "openrouter_enabled" $false)) {
        throw "OpenRouter is not enabled in Multi-Model Manager state. Run ONE_CLICK_SETUP.cmd first."
    }

    $codexHome = Get-CodexHome
    Ensure-Directory $codexHome
    $configPath = Join-Path $codexHome "config.toml"
    $envPath = Join-Path $codexHome ".env"

    $backupDir = Backup-CodexConfig
    $envExisted = Test-Path -LiteralPath $envPath
    if ($envExisted) {
        Copy-Item -LiteralPath $envPath -Destination (Join-Path $backupDir ".env") -Force
    }

    $configText = if (Test-Path -LiteralPath $configPath) { Get-Content -Raw -LiteralPath $configPath } else { "" }
    if ($configText -notmatch '(?m)^\s*\[model_providers\.mm_openrouter\]\s*$') {
        Apply-ManagedConfig $state
    }

    Set-DotEnvEntry -Path $envPath -Name "OPENROUTER_API_KEY" -Value $openRouterKey
    Set-DesktopRouteBlock -ConfigPath $configPath -Model "stealth/ox-alpha" -Provider "mm_openrouter" -Effort "high"
    Save-DesktopRouteState -BackupDir $backupDir -EnvExisted $envExisted -ConfigPath $configPath -EnvPath $envPath

    Write-Host ""
    Write-Host "Desktop route prepared: Ox Alpha -> mm_openrouter" -ForegroundColor Green
    Write-Host "Config: $configPath" -ForegroundColor DarkGray
    Write-Host "Key copied locally to ~/.codex/.env without printing the value." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "下一步：彻底退出 Codex Desktop，再重新打开，并新建一个会话。" -ForegroundColor Cyan
    Write-Host "注意：官方模型下拉框可能仍不会显示 Ox Alpha；后台会显示为自定义 Provider/Model 路由。" -ForegroundColor Yellow
    Write-Host "如果桌面端报错或仍走 OpenAI，请运行 RESTORE_CHATGPT_DESKTOP.cmd 立即恢复。" -ForegroundColor Yellow
}

function Restore-DesktopRoute {
    $statePath = Get-DesktopRouteStatePath
    $routeState = Get-DesktopRouteState
    if ($null -eq $routeState) {
        throw "No Desktop route backup state found. Nothing to restore."
    }
    if (-not (Test-DesktopRouteActive $routeState)) {
        Write-Host "Desktop route is already restored; no active Manager override remains." -ForegroundColor Green
        return
    }

    $backupDir = [string]$routeState.backup_dir
    $configPath = [string]$routeState.config_path
    $envPath = [string]$routeState.env_path

    if ([string]::IsNullOrWhiteSpace($backupDir) -or -not (Test-Path -LiteralPath $backupDir)) {
        throw "Desktop route backup directory is missing: $backupDir"
    }

    $backupConfig = Join-Path $backupDir "config.toml"
    if (Test-Path -LiteralPath $backupConfig) {
        Copy-Item -LiteralPath $backupConfig -Destination $configPath -Force
    }
    elseif (Test-Path -LiteralPath $configPath) {
        Remove-Item -LiteralPath $configPath -Force
    }

    $backupEnv = Join-Path $backupDir ".env"
    if ([bool]$routeState.env_existed) {
        if (-not (Test-Path -LiteralPath $backupEnv)) {
            throw "Expected .env backup is missing: $backupEnv"
        }
        Copy-Item -LiteralPath $backupEnv -Destination $envPath -Force
    }
    elseif (Test-Path -LiteralPath $envPath) {
        $remaining = @(Get-Content -LiteralPath $envPath | Where-Object { $_ -notmatch '^\s*OPENROUTER_API_KEY\s*=' })
        if ($remaining.Count -eq 0 -or (($remaining -join "").Trim().Length -eq 0)) {
            Remove-Item -LiteralPath $envPath -Force
        }
        else {
            Set-Content -LiteralPath $envPath -Value $remaining -Encoding UTF8
        }
    }

    [ordered]@{
        active = $false
        restored_from = $backupDir
        restored_at = (Get-Date -Format "o")
    } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

    Write-Host "Codex Desktop configuration restored from backup." -ForegroundColor Green
    Write-Host "下一步：彻底退出 Codex Desktop，再重新打开，并新建一个会话。" -ForegroundColor Cyan
}

switch ($Mode) {
    "activate-ox" { Activate-OxDesktop }
    "restore" { Restore-DesktopRoute }
    "status" { Show-DesktopRouteStatus }
    default { throw "Unsupported mode: $Mode" }
}
