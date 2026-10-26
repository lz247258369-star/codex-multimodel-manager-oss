#requires -Version 7
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("activate", "restore", "status", "doctor")]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [string]$ModelId = "",

    [Parameter(Mandatory = $false)]
    [ValidateSet("low", "medium", "high", "xhigh", "max")]
    [string]$Effort = "high",

    [Parameter(Mandatory = $false)]
    [string]$ConfirmationCode = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_common.ps1")
. (Join-Path $PSScriptRoot "router-codex-cli.ps1")

$script:DesktopRouterRouteKind = "router"
$script:DesktopRouterProvider = "mm_local_router"
$script:DesktopRouterClientId = "client.codex_desktop"

# DSR7-A: upstream provider secrets that must never reach a Router-owned block.
# Direct DeepSeek is now a first-class Router provider, so DEEPSEEK_API_KEY
# belongs in this list next to the other providers; the Router block may only
# carry the local client token as an env reference.
$script:DesktopForbiddenUpstreamSecrets = @(
    "DEEPSEEK_API_KEY",
    "OPENROUTER_API_KEY",
    "CODEX_DASHSCOPE_API_KEY",
    "CODEX_OPENAI_API_KEY",
    "MIMO_API_KEY",
    "experimental_bearer_token"
)

function Get-DesktopRouterForbiddenSecret([string]$BlockText) {
    if ([string]::IsNullOrEmpty($BlockText)) { return $null }
    foreach ($name in $script:DesktopForbiddenUpstreamSecrets) {
        if ($BlockText -match [regex]::Escape($name)) { return $name }
    }
    return $null
}

function Get-DesktopManagerHome {
    $path = Join-Path (Get-CodexHome) "multimodel-manager"
    Ensure-Directory $path
    return $path
}

function Get-DesktopRouteStatePath {
    return (Join-Path (Get-DesktopManagerHome) "desktop-route-state.json")
}

function Get-DesktopRouteState {
    $path = Get-DesktopRouteStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json) }
    catch { return $null }
}

function Test-DesktopRouteActive($RouteState) {
    if ($null -eq $RouteState) { return $false }
    if (-not $RouteState.PSObject.Properties["active"]) { return $false }
    return [bool]$RouteState.active
}

function Get-ManagedEnvKeys($RouteState) {
    $keys = New-Object System.Collections.Generic.List[string]
    if ($null -ne $RouteState -and $RouteState.PSObject.Properties["managed_env_keys"]) {
        foreach ($key in @($RouteState.managed_env_keys)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$key)) { $keys.Add([string]$key) }
        }
    }
    return @($keys | Select-Object -Unique)
}

function Remove-DotEnvEntries([string]$Path, [string[]]$Names) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
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

function Restore-EnvToFirstBackup($RouteState, [string]$EnvPath) {
    $backupDir = [string]$RouteState.backup_dir
    $backupEnv = Join-Path $backupDir ".env"
    if ([bool]$RouteState.env_existed) {
        if (-not (Test-Path -LiteralPath $backupEnv -PathType Leaf)) {
            throw "Expected .env first backup is missing: $backupEnv"
        }
        Copy-Item -LiteralPath $backupEnv -Destination $EnvPath -Force
        return
    }
    Remove-DotEnvEntries -Path $EnvPath -Names @(Get-ManagedEnvKeys $RouteState)
}

function Remove-DesktopRouteBlockFromConfig([string]$ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return }
    $text = Get-Content -Raw -LiteralPath $ConfigPath
    $managedPattern = '(?ms)^# >>> CODEX MULTIMODEL MANAGER DESKTOP ROUTE BEGIN\r?\n.*?^# <<< CODEX MULTIMODEL MANAGER DESKTOP ROUTE END\r?\n?'
    $text = [regex]::Replace($text, $managedPattern, "")
    foreach ($name in @("model", "model_provider", "model_reasoning_effort")) {
        $linePattern = '(?m)^\s*' + [regex]::Escape($name) + '\s*=.*(?:\r?\n|$)'
        $text = [regex]::Replace($text, $linePattern, "", 1)
    }
    Write-Utf8NoBom $ConfigPath $text
}

function Restore-DesktopTopLevelPrior([string]$ConfigPath, $RouteState) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return }
    $text = Get-Content -Raw -LiteralPath $ConfigPath
    $priorModel = if ($RouteState.PSObject.Properties["prior_model"]) { [string]$RouteState.prior_model } else { "" }
    $priorProvider = if ($RouteState.PSObject.Properties["prior_provider"]) { [string]$RouteState.prior_provider } else { "" }
    $priorEffort = if ($RouteState.PSObject.Properties["prior_effort"]) { [string]$RouteState.prior_effort } else { "" }

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

    $priorLines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($priorModel)) { $priorLines.Add(('model = "{0}"' -f (Escape-TomlString $priorModel))) }
    if (-not [string]::IsNullOrWhiteSpace($priorProvider)) { $priorLines.Add(('model_provider = "{0}"' -f (Escape-TomlString $priorProvider))) }
    if (-not [string]::IsNullOrWhiteSpace($priorEffort)) { $priorLines.Add(('model_reasoning_effort = "{0}"' -f (Escape-TomlString $priorEffort))) }

    $parts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($prefix)) { $parts.Add($prefix) }
    foreach ($line in $priorLines) { $parts.Add($line) }
    if (-not [string]::IsNullOrWhiteSpace($tables)) { $parts.Add($tables.TrimStart()) }
    Write-Utf8NoBom $ConfigPath (($parts -join "`r`n`r`n") + "`r`n")
}

function Get-UserTableHeadersOutsideManaged([string]$Text) {
    $markerPairs = @(
        @("CODEX MULTIMODEL MANAGER DESKTOP ROUTE BEGIN", "CODEX MULTIMODEL MANAGER DESKTOP ROUTE END"),
        @("CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN", "CODEX MULTIMODEL MANAGER ROUTER CLI END"),
        @("CODEX MULTIMODEL MANAGER BEGIN", "CODEX MULTIMODEL MANAGER END"),
        @("CODEX AUTO MODELS BEGIN", "CODEX AUTO MODELS END")
    )
    $ranges = New-Object System.Collections.Generic.List[object]
    foreach ($pair in $markerPairs) {
        $beginMarker = "# >>> " + $pair[0]
        $endMarker = "# <<< " + $pair[1]
        $beginIndex = $Text.IndexOf($beginMarker)
        while ($beginIndex -ge 0) {
            $endIndex = $Text.IndexOf($endMarker, $beginIndex)
            if ($endIndex -lt 0) { break }
            $ranges.Add([pscustomobject]@{ Start = $beginIndex; End = ($endIndex + $endMarker.Length) })
            $beginIndex = $Text.IndexOf($beginMarker, ($endIndex + $endMarker.Length))
        }
    }
    $headers = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($Text, '(?m)^\s*(\[[^\r\n]+\])\s*$')) {
        $inside = $false
        foreach ($range in $ranges) {
            if ($match.Index -ge $range.Start -and $match.Index -le $range.End) { $inside = $true; break }
        }
        if (-not $inside) { $headers.Add($match.Groups[1].Value.Trim()) }
    }
    return @($headers | Sort-Object -Unique)
}

function Test-DesktopLastOwnerHasExternalUserChange([string]$CurrentText, [string]$BackupText) {
    $currentUser = @(Get-UserTableHeadersOutsideManaged $CurrentText)
    $backupUser = @(Get-UserTableHeadersOutsideManaged $BackupText)
    $extra = @($currentUser | Where-Object { $_ -notin $backupUser })
    return ($extra.Count -gt 0)
}

function Set-DesktopRouterRouteBlock([string]$ConfigPath, [string]$Model, [string]$Effort) {
    $text = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) { Get-Content -Raw -LiteralPath $ConfigPath } else { "" }
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
        "# Codex Desktop -> Local Router route managed by Codex Multi-Model Manager.",
        ('model = "{0}"' -f (Escape-TomlString $Model)),
        ('model_provider = "{0}"' -f $script:DesktopRouterProvider),
        ('model_reasoning_effort = "{0}"' -f (Escape-TomlString $Effort)),
        "# <<< CODEX MULTIMODEL MANAGER DESKTOP ROUTE END"
    ) -join "`r`n"

    $parts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($prefix)) { $parts.Add($prefix) }
    $parts.Add($routeBlock)
    if (-not [string]::IsNullOrWhiteSpace($tables)) { $parts.Add($tables.TrimStart()) }
    Write-Utf8NoBom $ConfigPath (($parts -join "`r`n`r`n") + "`r`n")
}

function Get-RouterRuntimeStatePath {
    $codexHome = Get-CodexHome
    return (Join-Path $codexHome "multimodel-manager/local-router/runtime/router.state.json")
}

function Test-DesktopRouterRuntimeReady {
    $runtimePath = Get-RouterRuntimeStatePath
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) { return $false }
    try {
        $runtime = Get-Content -Raw -LiteralPath $runtimePath | ConvertFrom-Json
        return ([string]$runtime.lifecycle -eq "READY")
    }
    catch {
        return $false
    }
}

function Test-DesktopRouterTokenAvailable {
    $processValue = [Environment]::GetEnvironmentVariable($script:Lr12TokenEnv, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($processValue)) { return $true }
    $userValue = Get-RouterCliUserEnvironmentValue $script:Lr12TokenEnv
    return (-not [string]::IsNullOrWhiteSpace($userValue))
}

function Get-DesktopRouterReadinessFailures {
    $failures = New-Object System.Collections.Generic.List[string]
    $router = Read-RouterUserConfig
    if (-not $router.Valid) {
        $failures.Add("Router user config is corrupt or invalid.")
    }
    elseif (-not $router.Enabled) {
        $failures.Add("Local Router is not enabled (mode=router, local_router.enabled=true required).")
    }
    if (-not (Test-DesktopRouterRuntimeReady)) {
        $failures.Add("Router runtime lifecycle is not READY.")
    }
    if (-not (Test-DesktopRouterTokenAvailable)) {
        $failures.Add("CODEX_LOCAL_ROUTER_TOKEN is not available.")
    }
    return @($failures.ToArray())
}

function Save-DesktopRouteStateObject($StateObject) {
    $StateObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Get-DesktopRouteStatePath) -Encoding UTF8
}

function Activate-DesktopRouterRoute {
    $router = Read-RouterUserConfig
    $readinessFailures = @(Get-DesktopRouterReadinessFailures)
    if ($readinessFailures.Count -gt 0) {
        throw ("Desktop Router readiness gate failed: " + ($readinessFailures -join " "))
    }

    $existing = Get-DesktopRouteState
    $alreadyRouter = (Test-DesktopRouteActive $existing) -and
        [string]$existing.route_kind -eq $script:DesktopRouterRouteKind -and
        [string]$existing.provider -eq $script:DesktopRouterProvider
    if ($alreadyRouter -and [string]$existing.model -eq $ModelId -and [string]$existing.effort -eq $Effort) {
        Write-Host "Desktop Router route already active: $ModelId -> mm_local_router (no changes made)." -ForegroundColor Green
        Write-Host "Restart Codex Desktop completely and create a new conversation to apply it." -ForegroundColor Cyan
        return
    }

    if ([string]::IsNullOrWhiteSpace($ModelId)) {
        Write-Host ""
        Write-Host "Select the model Codex Desktop should send to the Local Router:" -ForegroundColor Cyan
        $available = @(Get-RouterCliAvailableModels)
        if ($available.Count -eq 0) {
            throw "No enabled Router model route is available. Add an enabled provider_route/model_route/route first."
        }
        for ($i = 0; $i -lt $available.Count; $i++) {
            Write-Host ("  {0}. {1} (provider {2})" -f ($i + 1), $available[$i].model_id, $available[$i].provider_id) -ForegroundColor White
        }
        $defaultModel = [string]$available[0].model_id
        $choice = Read-Host ("Enter Router model ID [" + $defaultModel + "]")
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = $defaultModel }
        $ModelId = $choice.Trim()
    }

    [void](Assert-RouterModelValid $ModelId)
    Assert-RouterEffortSupported $ModelId $Effort

    $code = $ConfirmationCode
    if ([string]::IsNullOrWhiteSpace($code)) {
        Write-Host ""
        Write-Host "Activating the Codex Desktop Router route will:" -ForegroundColor Yellow
        Write-Host "  - change the Desktop default route to mm_local_router only" -ForegroundColor White
        Write-Host "  - connect Desktop Responses traffic only to the loopback Local Router" -ForegroundColor White
        Write-Host "  - NOT modify the Codex Desktop program" -ForegroundColor White
        Write-Host "  - require a full Codex Desktop restart (provider activation boundary)" -ForegroundColor White
        Write-Host "  - after that restart: reopen the SAME existing conversation for the NPG1-B same-thread picker test" -ForegroundColor White
        Write-Host "  - same-thread native-picker switching is NOT YET VERIFIED; do not create a new conversation for the acceptance experiment" -ForegroundColor White
        Write-Host "  - remain exactly restorable to the first Manager baseline" -ForegroundColor White
        $code = Read-Host "Type ROUTER to continue"
    }
    if ($code.Trim().ToUpperInvariant() -ne "ROUTER") {
        throw "Confirmation failed. Type ROUTER to activate the Desktop Router route."
    }

    $codexHome = Get-CodexHome
    Ensure-Directory $codexHome
    $configPath = Get-CodexConfigPath
    $envPath = Join-Path $codexHome ".env"

    $alreadyActive = Test-DesktopRouteActive $existing
    $activatedAt = if ($alreadyActive -and $existing.PSObject.Properties["activated_at"]) { [string]$existing.activated_at } else { (Get-Date -Format "o") }

    $priorModel = $null
    $priorProvider = $null
    $priorEffort = $null
    if ($alreadyActive -and [string]$existing.route_kind -ne $script:DesktopRouterRouteKind) {
        if ($existing.PSObject.Properties["model"]) { $priorModel = [string]$existing.model }
        if ($existing.PSObject.Properties["provider"]) { $priorProvider = [string]$existing.provider }
        if ($existing.PSObject.Properties["effort"]) { $priorEffort = [string]$existing.effort }
    }
    elseif (-not $alreadyActive -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $priorConfigText = Get-Content -Raw -LiteralPath $configPath
        $firstTableIndex = [regex]::Match($priorConfigText, '(?m)^\s*\[')
        $rootLength = if ($firstTableIndex.Success) { $firstTableIndex.Index } else { $priorConfigText.Length }
        $priorRoot = $priorConfigText.Substring(0, $rootLength)
        $priorMatch = [regex]::Match($priorRoot, '(?m)^model\s*=\s*"([^"]+)"')
        if ($priorMatch.Success) { $priorModel = $priorMatch.Groups[1].Value }
        $priorMatch = [regex]::Match($priorRoot, '(?m)^model_provider\s*=\s*"([^"]+)"')
        if ($priorMatch.Success) { $priorProvider = $priorMatch.Groups[1].Value }
        $priorMatch = [regex]::Match($priorRoot, '(?m)^model_reasoning_effort\s*=\s*"([^"]+)"')
        if ($priorMatch.Success) { $priorEffort = $priorMatch.Groups[1].Value }
    }

    if ($alreadyActive) {
        $backupDir = [string]$existing.backup_dir
        $envExisted = [bool]$existing.env_existed
        if ([string]$existing.route_kind -ne $script:DesktopRouterRouteKind) {
            # Switching a Manager Direct Desktop route to Router: rebuild .env
            # from the first backup so Manager-injected upstream secrets are not
            # left for the Router route. User-owned baseline values are kept.
            Restore-EnvToFirstBackup $existing $envPath
        }
    }
    else {
        $backupDir = Backup-CodexConfig
        $envExisted = Test-Path -LiteralPath $envPath -PathType Leaf
        if ($envExisted) { Copy-Item -LiteralPath $envPath -Destination (Join-Path $backupDir ".env") -Force }
    }

    $ownersBefore = Read-RouterProviderOwners
    [void](Register-RouterProviderOwner $script:DesktopRouterClientId)
    if ($alreadyActive -and $ownersBefore.owners.Count -eq 0) {
        # The Desktop route may already be a Manager Direct route whose first
        # backup holds the true pre-Manager baseline. Seed the shared Router
        # baseline from that first backup so the final restore is exact.
        $firstBackupConfig = Join-Path $backupDir "config.toml"
        $firstBackupConfigExisted = Test-Path -LiteralPath $firstBackupConfig -PathType Leaf
        Set-RouterProviderBaselineFromConfig $firstBackupConfig $firstBackupConfigExisted
    }

    $configText = if (Test-Path -LiteralPath $configPath -PathType Leaf) { Get-Content -Raw -LiteralPath $configPath } else { "" }
    $newConfigText = Set-RouterProviderBlockInConfig $configText $router.Port
    Write-Utf8NoBom $configPath $newConfigText
    Set-DesktopRouterRouteBlock -ConfigPath $configPath -Model $ModelId -Effort $Effort

    Save-DesktopRouteStateObject ([ordered]@{
        schema_version = 1
        active = $true
        route_kind = $script:DesktopRouterRouteKind
        source_provider = "router"
        provider = $script:DesktopRouterProvider
        model = $ModelId
        label = ("Router: " + $ModelId)
        effort = $Effort
        backup_dir = $backupDir
        config_path = $configPath
        env_path = $envPath
        env_existed = $envExisted
        managed_env_keys = @()
        token_in_env = $false
        router_port = $router.Port
        prior_model = $priorModel
        prior_provider = $priorProvider
        prior_effort = $priorEffort
        activated_at = $activatedAt
        updated_at = (Get-Date -Format "o")
    })

    Write-Host ""
    Write-Host "Desktop Router route prepared: $ModelId -> mm_local_router -> http://127.0.0.1:$($router.Port)/v1" -ForegroundColor Green
    Write-Host "Router adapter added upstream provider secrets: NO" -ForegroundColor Green
    Write-Host ""
    Write-Host "IMPORTANT: fully exit Codex Desktop and restart it (required for the provider activation boundary)." -ForegroundColor Cyan
    Write-Host "After the restart, reopen the SAME existing conversation. Do NOT create a new conversation:" -ForegroundColor Cyan
    Write-Host "the NPG1-B acceptance experiment is a same-thread test." -ForegroundColor Cyan
    Write-Host "Same-thread native-picker switching is NOT YET VERIFIED (PENDING NPG1-B)." -ForegroundColor Yellow
    Write-Host "The official model picker may not display Router models; the Desktop route is applied by Manager configuration." -ForegroundColor Yellow
}

function Restore-DesktopRouterRoute {
    $routeState = Get-DesktopRouteState
    if ($null -eq $routeState) {
        throw "No Desktop route backup state found. Nothing to restore."
    }
    if (-not (Test-DesktopRouteActive $routeState)) {
        Write-Host "Desktop route is already restored; no active Manager override remains." -ForegroundColor Green
        return
    }
    $isRouterState = ([string]$routeState.route_kind -eq $script:DesktopRouterRouteKind -or
        [string]$routeState.provider -eq $script:DesktopRouterProvider)
    if (-not $isRouterState) {
        throw "The active Desktop route is not a Router route. Restore it through desktop-chat-route.ps1 instead."
    }

    $envPath = [string]$routeState.env_path
    Restore-EnvToFirstBackup $routeState $envPath

    $unregisterResult = Unregister-RouterProviderOwner $script:DesktopRouterClientId
    if (-not $unregisterResult.WasRegistered) {
        throw "Router provider ownership registry is missing while a Desktop Router route is active. Refusing unsafe cleanup."
    }
    $configPath = [string]$routeState.config_path
    if ($unregisterResult.WasRegistered -and -not $unregisterResult.WasLast) {
        # Another Router client (for example the Codex CLI) still owns the
        # shared mm_local_router block. Remove the Desktop overlay and restore
        # the exact top-level values that existed before Desktop Router.
        $currentRaw = if (Test-Path -LiteralPath $configPath -PathType Leaf) { Get-Content -Raw -LiteralPath $configPath } else { "" }
        $baselineConfig = Join-Path ([string]$unregisterResult.BaselineDir) "config.toml"
        $baselineRaw = if (Test-Path -LiteralPath $baselineConfig -PathType Leaf) { Get-Content -Raw -LiteralPath $baselineConfig } else { "" }
        $externalChange = Test-DesktopLastOwnerHasExternalUserChange $currentRaw $baselineRaw
        Remove-DesktopRouteBlockFromConfig $configPath
        if (-not $externalChange -and (Test-Path -LiteralPath $baselineConfig -PathType Leaf)) {
            # Rebuild the exact shared state expected by the remaining CLI
            # owner: original baseline bytes + the single Router provider block.
            $afterOverlay = Get-Content -Raw -LiteralPath $configPath
            $blockMatch = [regex]::Match($afterOverlay, '(?s)# >>> CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN.*?# <<< CODEX MULTIMODEL MANAGER ROUTER CLI END')
            $expectedBlock = if ($blockMatch.Success) { $blockMatch.Value } else { "" }
            Write-Utf8NoBom $configPath ($baselineRaw + "`r`n" + $expectedBlock)
        }
        else {
            Restore-DesktopTopLevelPrior $configPath $routeState
        }
        Write-Host "Desktop Router route restored. Shared mm_local_router block preserved for the remaining Router client owner." -ForegroundColor Green
    }
    else {
        $backupConfig = Join-Path ([string]$routeState.backup_dir) "config.toml"
        $currentText = if (Test-Path -LiteralPath $configPath -PathType Leaf) { Get-Content -Raw -LiteralPath $configPath } else { "" }
        $backupText = if (Test-Path -LiteralPath $backupConfig -PathType Leaf) { Get-Content -Raw -LiteralPath $backupConfig } else { "" }
        $externalChange = Test-DesktopLastOwnerHasExternalUserChange $currentText $backupText
        if ($externalChange) {
            # Prefer preserving unrelated user configuration: remove only the
            # Desktop Router overlay and the Router-owned provider block.
            Remove-DesktopRouteBlockFromConfig $configPath
            $cleanedText = Get-Content -Raw -LiteralPath $configPath
            Write-Utf8NoBom $configPath (Remove-RouterProviderBlockFromConfig $cleanedText)
            Restore-DesktopTopLevelPrior $configPath $routeState
            Remove-RouterProviderOwnershipFiles
            Write-Host "WARN Unrelated user configuration changed during Desktop Router route; overlay removed without full byte restore." -ForegroundColor Yellow
        }
        elseif (Test-Path -LiteralPath $backupConfig -PathType Leaf) {
            Copy-Item -LiteralPath $backupConfig -Destination $configPath -Force
            $copiedText = Get-Content -Raw -LiteralPath $configPath
            Write-Utf8NoBom $configPath (Remove-RouterProviderBlockFromConfig $copiedText)
            Remove-RouterProviderOwnershipFiles
            Write-Host "Codex Desktop Router configuration restored from the Desktop first backup." -ForegroundColor Green
        }
        else {
            Remove-DesktopRouteBlockFromConfig $configPath
            Remove-RouterProviderOwnershipFiles
            Write-Host "Codex Desktop Router configuration restored (no original config backup existed)." -ForegroundColor Green
        }
    }

    Save-DesktopRouteStateObject ([ordered]@{
        schema_version = 1
        active = $false
        route_kind = $script:DesktopRouterRouteKind
        restored_from = [string]$routeState.backup_dir
        restored_at = (Get-Date -Format "o")
    })
}

function Show-DesktopRouterStatus {
    $routeState = Get-DesktopRouteState
    $active = Test-DesktopRouteActive $routeState
    $isRouter = $active -and [string]$routeState.route_kind -eq $script:DesktopRouterRouteKind
    $routerFailures = @(Get-DesktopRouterReadinessFailures)
    Write-Host ""
    Write-Host "Codex Desktop Router integration status" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor DarkGray
    Write-Host ("Desktop mode      : {0}" -f $(if ($isRouter) { "ROUTER" } else { "DIRECT" })) -ForegroundColor White
    Write-Host ("Router status     : {0}" -f $(if ($routerFailures.Count -eq 0) { "READY" } else { "NOT READY" })) -ForegroundColor White
    if ($routerFailures.Count -gt 0) {
        foreach ($failure in $routerFailures) { Write-Host ("  - " + $failure) -ForegroundColor Yellow }
    }
    if ($isRouter) {
        Write-Host ("Selected model    : {0}" -f $routeState.model) -ForegroundColor White
        Write-Host ("Reasoning effort  : {0}" -f $routeState.effort) -ForegroundColor White
        Write-Host ("Provider          : {0}" -f $script:DesktopRouterProvider) -ForegroundColor White
        Write-Host "Restart required     : YES" -ForegroundColor White
        Write-Host "Existing conversation: REOPEN SAME THREAD AFTER RESTART" -ForegroundColor White
        Write-Host "Same-thread picker   : PENDING NPG1-B" -ForegroundColor White
        Write-Host ("Rollback backup   : {0}" -f $routeState.backup_dir) -ForegroundColor White
    }
    else {
        Write-Host "Desktop mode      : DIRECT (ChatGPT/OpenAI default or Manager Direct route)" -ForegroundColor White
    }
    Write-Host ""
}

function Invoke-DesktopRouterDoctor {
    $routeState = Get-DesktopRouteState
    $issues = New-Object System.Collections.Generic.List[string]
    Show-DesktopRouterStatus | Out-Null
    $router = Read-RouterUserConfig
    if (-not $router.Valid) { $issues.Add("Router user config corrupt.") }
    elseif (-not $router.Enabled) { $issues.Add("Local Router not enabled.") }
    if (-not (Test-DesktopRouterRuntimeReady)) { $issues.Add("Router runtime lifecycle not READY.") }
    if (-not (Test-DesktopRouterTokenAvailable)) { $issues.Add("CODEX_LOCAL_ROUTER_TOKEN unavailable.") }

    $configPath = Get-CodexConfigPath
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $configText = Get-Content -Raw -LiteralPath $configPath
        $blockMatch = [regex]::Match($configText, '(?s)# >>> CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN.*?# <<< CODEX MULTIMODEL MANAGER ROUTER CLI END')
        if (-not $blockMatch.Success) { $issues.Add("mm_local_router provider block missing.") }
        else {
            $forbiddenSecret = Get-DesktopRouterForbiddenSecret $blockMatch.Value
            if ($null -ne $forbiddenSecret) {
                $issues.Add("mm_local_router block references an upstream secret reference: $forbiddenSecret")
            }
        }
    }
    else {
        $issues.Add("Codex config.toml missing.")
    }

    if ($issues.Count -gt 0) {
        Write-Host "Desktop Router doctor found issues; activation would fail closed." -ForegroundColor Red
        return $false
    }
    Write-Host "Desktop Router doctor checks passed." -ForegroundColor Green
    return $true
}

switch ($Mode) {
    "activate" { Activate-DesktopRouterRoute }
    "restore" { Restore-DesktopRouterRoute }
    "status" { Show-DesktopRouterStatus }
    "doctor" {
        $ok = Invoke-DesktopRouterDoctor
        if (-not $ok) { exit 1 }
    }
}
