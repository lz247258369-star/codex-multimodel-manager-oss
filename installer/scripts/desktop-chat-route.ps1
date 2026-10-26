param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("activate", "restore", "status")]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [string]$ProviderId = "",

    [Parameter(Mandatory = $false)]
    [string]$ModelId = "",

    [Parameter(Mandatory = $false)]
    [string]$Label = "",

    [Parameter(Mandatory = $false)]
    [ValidateSet("low", "medium", "high", "xhigh")]
    [string]$Effort = "high",

    [Parameter(Mandatory = $false)]
    [string]$ConfirmationCode = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_common.ps1")
. (Join-Path $PSScriptRoot "router-codex-cli.ps1")

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
    return ($null -ne $RouteState -and $RouteState.PSObject.Properties["active"] -and [bool]$RouteState.active)
}

function Leave-DesktopRouterOwnerForDirect([string]$ConfigPath) {
    $routeState = Get-DesktopRouteState
    if (-not (Test-DesktopRouteActive $routeState)) { return }
    $isRouterRoute = ([string]$routeState.route_kind -eq "router" -or
        [string]$routeState.provider -eq "mm_local_router")
    if (-not $isRouterRoute) { return }

    $result = Unregister-RouterProviderOwner "client.codex_desktop"
    if (-not $result.WasRegistered) { return }
    if ($result.WasLast) {
        $text = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) { Get-Content -Raw -LiteralPath $ConfigPath } else { "" }
        $cleaned = Remove-RouterProviderBlockFromConfig $text
        Write-Utf8NoBom $ConfigPath $cleaned
        Remove-RouterProviderOwnershipFiles
    }
}

function Remove-StaleRouterBlockAfterDesktopRestore([string]$ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return }
    $text = Get-Content -Raw -LiteralPath $ConfigPath
    if (-not $text.Contains("# >>> CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN")) { return }
    $owners = Read-RouterProviderOwners
    if (@($owners.owners).Count -gt 0) { return }
    $cleaned = Remove-RouterProviderBlockFromConfig $text
    Write-Utf8NoBom $ConfigPath $cleaned
    Remove-RouterProviderOwnershipFiles
}

function Get-UserOrProcessEnv([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    return [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::User)
}

function Set-DotEnvEntry([string]$Path, [string]$Name, [string]$Value) {
    $lines = @()
    if (Test-Path -LiteralPath $Path) { $lines = @(Get-Content -LiteralPath $Path) }
    $pattern = '^\s*' + [regex]::Escape($Name) + '\s*='
    $next = New-Object System.Collections.Generic.List[string]
    $replaced = $false
    foreach ($line in $lines) {
        if ($line -match $pattern) {
            if (-not $replaced) { $next.Add("$Name=$Value"); $replaced = $true }
            continue
        }
        $next.Add([string]$line)
    }
    if (-not $replaced) {
        if ($next.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$next[$next.Count - 1])) { $next.Add("") }
        $next.Add("$Name=$Value")
    }
    Set-Content -LiteralPath $Path -Value $next.ToArray() -Encoding UTF8
}

function Remove-DotEnvEntries([string]$Path, [string[]]$Names) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $names = @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    if ($names.Count -eq 0) { return }
    $patterns = @($names | ForEach-Object { '^\s*' + [regex]::Escape([string]$_) + '\s*=' })
    $remaining = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        $managed = $false
        foreach ($pattern in $patterns) {
            if ($line -match $pattern) { $managed = $true; break }
        }
        if (-not $managed) { $remaining.Add([string]$line) }
    }
    if ($remaining.Count -eq 0 -or (($remaining -join "").Trim().Length -eq 0)) {
        Remove-Item -LiteralPath $Path -Force
    }
    else {
        Set-Content -LiteralPath $Path -Value $remaining.ToArray() -Encoding UTF8
    }
}

function Set-DesktopRouteBlock([string]$ConfigPath, [string]$Model, [string]$Provider, [string]$ReasoningEffort) {
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
        "# Experimental custom Desktop route managed by Codex Multi-Model Manager.",
        ('model = "{0}"' -f (Escape-TomlString $Model)),
        ('model_provider = "{0}"' -f (Escape-TomlString $Provider)),
        ('model_reasoning_effort = "{0}"' -f (Escape-TomlString $ReasoningEffort)),
        "# <<< CODEX MULTIMODEL MANAGER DESKTOP ROUTE END"
    ) -join "`r`n"

    $parts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($prefix)) { $parts.Add($prefix) }
    $parts.Add($routeBlock)
    if (-not [string]::IsNullOrWhiteSpace($tables)) { $parts.Add($tables.TrimStart()) }
    Set-Content -LiteralPath $ConfigPath -Value (($parts -join "`r`n`r`n") + "`r`n") -Encoding UTF8
}

function Get-DesktopProviderSpec([string]$Id) {
    switch ($Id) {
        "modelstudio" {
            return [pscustomobject]@{ CodexProvider="mm_modelstudio"; EnvKey="CODEX_DASHSCOPE_API_KEY"; StateFlag="aliyun_enabled"; Label="阿里云百炼" }
        }
        "openrouter" {
            return [pscustomobject]@{ CodexProvider="mm_openrouter"; EnvKey="OPENROUTER_API_KEY"; StateFlag="openrouter_enabled"; Label="OpenRouter" }
        }
        "mimo" {
            return [pscustomobject]@{ CodexProvider="mm_mimo"; EnvKey="MIMO_API_KEY"; StateFlag="mimo_enabled"; Label="Xiaomi MiMo" }
        }
        default { return $null }
    }
}

function Get-ManagedEnvKeys($RouteState) {
    $keys = New-Object System.Collections.Generic.List[string]
    if ($null -ne $RouteState -and $RouteState.PSObject.Properties["managed_env_keys"]) {
        foreach ($key in @($RouteState.managed_env_keys)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$key)) { $keys.Add([string]$key) }
        }
    }
    if ($keys.Count -eq 0 -and $null -ne $RouteState -and $RouteState.PSObject.Properties["provider"]) {
        switch ([string]$RouteState.provider) {
            "mm_openrouter" { $keys.Add("OPENROUTER_API_KEY") }
            "mm_modelstudio" { $keys.Add("CODEX_DASHSCOPE_API_KEY") }
            "mm_mimo" { $keys.Add("MIMO_API_KEY") }
        }
    }
    return @($keys | Select-Object -Unique)
}

function Save-DesktopRouteState($StateObject) {
    $StateObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Get-DesktopRouteStatePath) -Encoding UTF8
}

function Activate-DesktopRoute {
    if ([string]::IsNullOrWhiteSpace($ProviderId) -or [string]::IsNullOrWhiteSpace($ModelId)) {
        throw "ProviderId and ModelId are required for activate mode."
    }

    $spec = Get-DesktopProviderSpec $ProviderId
    if ($null -eq $spec) { throw "Provider '$ProviderId' is not supported for Codex Desktop custom routing." }

    if ($ModelId -eq "stealth/ox-alpha") {
        $code = $ConfirmationCode
        if ([string]::IsNullOrWhiteSpace($code)) {
            Write-Host "Ox Alpha is an anonymous experimental model. Type OX to continue." -ForegroundColor Yellow
            $code = Read-Host "Confirmation"
        }
        if ($code.Trim().ToUpperInvariant() -ne "OX") { throw "Confirmation failed. Type OX to activate Ox Alpha." }
    }

    $apiKey = Get-UserOrProcessEnv ([string]$spec.EnvKey)
    if ([string]::IsNullOrWhiteSpace($apiKey)) { throw "Missing $($spec.EnvKey). Configure the Provider first." }

    $managerState = Load-State
    if (-not (Get-StateValue $managerState ([string]$spec.StateFlag) $false)) {
        throw "$($spec.Label) is not enabled in Multi-Model Manager state. Configure the Provider first."
    }

    Leave-DesktopRouterOwnerForDirect (Get-CodexConfigPath)

    $codexHome = Get-CodexHome
    Ensure-Directory $codexHome
    $configPath = Join-Path $codexHome "config.toml"
    $envPath = Join-Path $codexHome ".env"
    $existing = Get-DesktopRouteState
    $alreadyActive = Test-DesktopRouteActive $existing

    if ($alreadyActive -and [string]$existing.model -eq $ModelId -and [string]$existing.provider -eq [string]$spec.CodexProvider) {
        Write-Host "Desktop route already active: $ModelId -> $($spec.CodexProvider)" -ForegroundColor Green
        return
    }

    if ($alreadyActive) {
        $backupDir = [string]$existing.backup_dir
        $envExisted = [bool]$existing.env_existed
        $managedKeys = New-Object System.Collections.Generic.List[string]
        foreach ($key in @(Get-ManagedEnvKeys $existing)) { $managedKeys.Add([string]$key) }
    }
    else {
        $backupDir = Backup-CodexConfig
        $envExisted = Test-Path -LiteralPath $envPath
        if ($envExisted) { Copy-Item -LiteralPath $envPath -Destination (Join-Path $backupDir ".env") -Force }
        $managedKeys = New-Object System.Collections.Generic.List[string]
    }

    if (-not $managedKeys.Contains([string]$spec.EnvKey)) { $managedKeys.Add([string]$spec.EnvKey) }

    $configText = if (Test-Path -LiteralPath $configPath) { Get-Content -Raw -LiteralPath $configPath } else { "" }
    $providerPattern = '(?m)^\s*\[model_providers\.' + [regex]::Escape([string]$spec.CodexProvider) + '\]\s*$'
    if ($configText -notmatch $providerPattern) { Apply-ManagedConfig $managerState }

    Set-DotEnvEntry -Path $envPath -Name ([string]$spec.EnvKey) -Value $apiKey
    Set-DesktopRouteBlock -ConfigPath $configPath -Model $ModelId -Provider ([string]$spec.CodexProvider) -ReasoningEffort $Effort

    $routeLabel = if ([string]::IsNullOrWhiteSpace($Label)) { $ModelId } else { $Label }
    Save-DesktopRouteState ([ordered]@{
        schema_version = 1
        active = $true
        route_kind = "direct"
        source_provider = $ProviderId
        provider = [string]$spec.CodexProvider
        model = $ModelId
        label = $routeLabel
        effort = $Effort
        backup_dir = $backupDir
        config_path = $configPath
        env_path = $envPath
        env_existed = $envExisted
        managed_env_keys = $managedKeys.ToArray()
        activated_at = if ($alreadyActive -and $existing.PSObject.Properties["activated_at"]) { [string]$existing.activated_at } else { (Get-Date -Format "o") }
        updated_at = (Get-Date -Format "o")
    })

    Write-Host "Desktop route prepared: $routeLabel -> $($spec.CodexProvider)" -ForegroundColor Green
    Write-Host "Restart Codex Desktop completely and create a new conversation." -ForegroundColor Cyan
}

function Restore-DesktopRoute {
    $routeState = Get-DesktopRouteState
    if ($null -eq $routeState) { throw "No Desktop route backup state found. Nothing to restore." }
    if (-not (Test-DesktopRouteActive $routeState)) {
        Write-Host "Desktop route is already restored." -ForegroundColor Green
        return
    }

    $backupDir = [string]$routeState.backup_dir
    $configPath = [string]$routeState.config_path
    $envPath = [string]$routeState.env_path
    if ([string]::IsNullOrWhiteSpace($backupDir) -or -not (Test-Path -LiteralPath $backupDir)) {
        throw "Desktop route backup directory is missing: $backupDir"
    }

    $backupConfig = Join-Path $backupDir "config.toml"
    if (Test-Path -LiteralPath $backupConfig) { Copy-Item -LiteralPath $backupConfig -Destination $configPath -Force }
    elseif (Test-Path -LiteralPath $configPath) { Remove-Item -LiteralPath $configPath -Force }

    $backupEnv = Join-Path $backupDir ".env"
    if ([bool]$routeState.env_existed) {
        if (-not (Test-Path -LiteralPath $backupEnv)) { throw "Expected .env backup is missing: $backupEnv" }
        Copy-Item -LiteralPath $backupEnv -Destination $envPath -Force
    }
    else {
        Remove-DotEnvEntries -Path $envPath -Names @(Get-ManagedEnvKeys $routeState)
    }

    Remove-StaleRouterBlockAfterDesktopRestore $configPath

    Save-DesktopRouteState ([ordered]@{
        active = $false
        restored_from = $backupDir
        restored_at = (Get-Date -Format "o")
    })
    Write-Host "Codex Desktop configuration restored from backup." -ForegroundColor Green
}

function Show-DesktopRouteStatus {
    $routeState = Get-DesktopRouteState
    if (-not (Test-DesktopRouteActive $routeState)) {
        Write-Host "Desktop route: ChatGPT/OpenAI default." -ForegroundColor Green
        return
    }
    $label = if ($routeState.PSObject.Properties["label"] -and -not [string]::IsNullOrWhiteSpace([string]$routeState.label)) { [string]$routeState.label } else { [string]$routeState.model }
    Write-Host "Desktop route ACTIVE: $label · $([string]$routeState.model) -> $([string]$routeState.provider)" -ForegroundColor Cyan
}

switch ($Mode) {
    "activate" { Activate-DesktopRoute }
    "restore" { Restore-DesktopRoute }
    "status" { Show-DesktopRouteStatus }
}
