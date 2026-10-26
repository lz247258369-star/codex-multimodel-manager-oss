#requires -Version 7
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Initialize", "Enable", "Disable", "Status", "Doctor", "SelectModel", "Launch")]
    [string]$Action = "",

    [Parameter(Mandatory = $false)]
    [string]$Model = "",

    [Parameter(Mandatory = $false)]
    [ValidateSet("low", "medium", "high", "xhigh", "max")]
    [string]$ReasoningEffort = "",

    [Parameter(Mandatory = $false)]
    [string]$ProjectPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$CheckOnly,

    [Parameter(Mandatory = $false)]
    [switch]$Ping
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

$script:Lr12SchemaVersion = 1
$script:Lr12ProviderId = "mm_local_router"
$script:Lr12TokenEnv = "CODEX_LOCAL_ROUTER_TOKEN"
$script:Lr12DefaultHost = "127.0.0.1"
$script:Lr12DefaultPort = 47821
$script:Lr12ProfileId = "mm_local_router"
$script:Lr12UpstreamSecretEnvNames = @(
    "OPENROUTER_API_KEY",
    "CODEX_DASHSCOPE_API_KEY",
    "CODEX_OPENAI_API_KEY",
    "MIMO_API_KEY",
    "DEEPSEEK_API_KEY"
)
$script:Lr12RouterEligibleProviders = @(
    "mm_openai_api",
    "mm_modelstudio",
    "mm_openrouter",
    "mm_mimo",
    "deepseek"
)
# Schema-level provider identity set: every Router-capable provider plus the
# Direct-only chatgpt identity. It is derived from the single eligible-provider
# table above so the schema validator never carries a second copy of the truth.
$script:Lr12SchemaProviderIds = @("chatgpt") + @($script:Lr12RouterEligibleProviders)
$script:Lr12OpenAiApiCapabilityGap = "MM_OPENAI_API_CATALOG_CAPABILITY_GAP"
$script:Lr12CatalogProviderMap = [ordered]@{
    "modelstudio" = "mm_modelstudio"
    "openrouter" = "mm_openrouter"
    "mimo" = "mm_mimo"
    "deepseek" = "deepseek"
}
$script:Lr12UserEnvLookup = $null

$script:Lr12BaseBeginMarker = "# >>> CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN"
$script:Lr12BaseEndMarker = "# <<< CODEX MULTIMODEL MANAGER ROUTER CLI END"
$script:Lr12ProfileBeginMarker = "# >>> CODEX MULTIMODEL MANAGER ROUTER CLI PROFILE BEGIN"
$script:Lr12ProfileEndMarker = "# <<< CODEX MULTIMODEL MANAGER ROUTER CLI PROFILE END"

function Get-RouterCliStatePath {
    $codexHome = Get-CodexHome
    $dir = Join-Path $codexHome "multimodel-manager"
    Ensure-Directory $dir
    return (Join-Path $dir "router-cli-state.json")
}

function Get-RouterCliProfilePath {
    $codexHome = Get-CodexHome
    return (Join-Path $codexHome ($script:Lr12ProfileId + ".config.toml"))
}

function Get-CatalogPath {
    $installerRoot = Split-Path -Parent $PSScriptRoot
    return (Join-Path $installerRoot "model-catalog.json")
}

function Get-ApprovedModelsPath {
    $codexHome = Get-CodexHome
    return (Join-Path $codexHome "multimodel-manager/approved-models.json")
}

function Get-RouterCliUserEnvironmentValue([string]$Name) {
    # Injectable seam: production reads the real User-scope environment. Tests
    # override $script:Lr12UserEnvLookup so a validator never writes real
    # User-scope variables.
    if ($null -ne $script:Lr12UserEnvLookup -and $script:Lr12UserEnvLookup.ContainsKey($Name)) {
        return [string]$script:Lr12UserEnvLookup[$Name]
    }
    return [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::User)
}

function Read-CatalogRecords {
    $catalogPath = Get-CatalogPath
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        throw "Canonical model catalog is missing: $catalogPath"
    }
    $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
    if ($null -eq $catalog.providers -or [int]$catalog.version -ne 3) {
        throw "Canonical model catalog schema is not the expected v3: $catalogPath"
    }
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($provider in @($catalog.providers)) {
        $catalogProviderId = [string]$provider.id
        if (-not $script:Lr12CatalogProviderMap.Contains($catalogProviderId)) {
            continue
        }
        $managerId = $script:Lr12CatalogProviderMap[$catalogProviderId]
        foreach ($model in @($provider.models)) {
            $levels = @()
            if ($null -ne $model.performance_levels) {
                $levels = @($model.performance_levels | ForEach-Object { [string]$_ })
            }
            $records.Add([pscustomobject]@{
                catalog_provider_id = $catalogProviderId
                provider_id = $managerId
                model_id = [string]$model.id
                performance_levels = $levels
                status = [string]$model.status
            })
        }
    }
    return @($records.ToArray())
}

function Get-ApprovedModelRecords {
    $approvedPath = Get-ApprovedModelsPath
    if (-not (Test-Path -LiteralPath $approvedPath -PathType Leaf)) {
        return @()
    }
    try {
        $approved = Get-Content -Raw -LiteralPath $approvedPath | ConvertFrom-Json
        return @($approved | ForEach-Object {
            [pscustomobject]@{
                provider_id = [string]$_.provider_id
                model_id = [string]$_.model_id
            }
        })
    }
    catch {
        return @()
    }
}

function Get-RouterCollectionCount($Value) {
    # Null-safe collection count for the route projections.
    #
    # ConvertFrom-Json yields $null for a route array that is absent, JSON null,
    # or empty, and PowerShell counts @($null) as one element. Counting the
    # route arrays directly therefore reported a zero-route router.config.json
    # as 1/1/1 in the Doctor bootstrap ladder. This helper is the single place
    # that maps null/empty to 0 and otherwise returns the exact element count.
    if ($null -eq $Value) { return 0 }
    return @($Value).Count
}

function Get-RouterRouteConfig([hashtable]$Failures) {
    $result = [pscustomobject]@{
        Valid = $true
        ProviderRoutes = @()
        ModelRoutes = @()
        Routes = @()
        Error = ""
    }
    $configPath = Get-RouterCliConfigPath
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $result.Valid = $false
        $result.Error = "Router config is missing."
        return $result
    }
    try {
        $cfg = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        $result.ProviderRoutes = if ($null -eq $cfg.provider_routes) { @() } else { @($cfg.provider_routes) }
        $result.ModelRoutes = if ($null -eq $cfg.model_routes) { @() } else { @($cfg.model_routes) }
        $result.Routes = if ($null -eq $cfg.routes) { @() } else { @($cfg.routes) }
        return $result
    }
    catch {
        $result.Valid = $false
        $result.Error = $_.Exception.Message
        return $result
    }
}

function Test-RouterModelCandidate([string]$ModelId) {
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($ModelId)) {
        $errors.Add("A Router model is required.")
        return [pscustomobject]@{
            Valid = $false
            ModelId = $ModelId
            Errors = @($errors.ToArray())
            Warnings = @($warnings.ToArray())
            CatalogRecord = $null
            EnabledModelRoutes = @()
        }
    }

    $routeConfig = Get-RouterRouteConfig
    if (-not $routeConfig.Valid) {
        $errors.Add("Router route config could not be read: $($routeConfig.Error)")
    }

    $enabledProviderIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $enabledProviderRouteIdsByProvider = [ordered]@{}
    foreach ($providerRoute in @($routeConfig.ProviderRoutes)) {
        $enabled = $false
        if ($null -ne $providerRoute.enabled) { $enabled = [bool]$providerRoute.enabled }
        $providerId = [string]$providerRoute.provider_id
        if ($enabled -and $providerId -in $script:Lr12RouterEligibleProviders) {
            [void]$enabledProviderIds.Add($providerId)
            if (-not $enabledProviderRouteIdsByProvider.Contains($providerId)) {
                $enabledProviderRouteIdsByProvider[$providerId] = New-Object System.Collections.Generic.List[string]
            }
            $providerRouteId = [string]$providerRoute.provider_route_id
            if (-not [string]::IsNullOrWhiteSpace($providerRouteId)) {
                $enabledProviderRouteIdsByProvider[$providerId].Add($providerRouteId)
            }
        }
    }

    $matchingEnabled = New-Object System.Collections.Generic.List[object]
    foreach ($modelRoute in @($routeConfig.ModelRoutes)) {
        $enabled = $false
        if ($null -ne $modelRoute.enabled) { $enabled = [bool]$modelRoute.enabled }
        $clientModel = [string]$modelRoute.client_model_id
        $providerId = [string]$modelRoute.provider_id
        if (-not $enabled) { continue }
        # DSR2: a client-facing request matches a route by client_model_id exact
        # OR by one of that route's explicit aliases. Aliases are never inferred
        # from substrings, and an alias collision still fails closed below.
        $routeAliases = @()
        if ($null -ne $modelRoute.aliases) { $routeAliases = @($modelRoute.aliases | ForEach-Object { [string]$_ }) }
        if ($clientModel -ne $ModelId -and -not ($routeAliases -contains $ModelId)) { continue }
        if ($providerId -notin $script:Lr12RouterEligibleProviders) {
            $errors.Add("Router route provider is not Router-eligible for model $ModelId : $providerId")
            continue
        }
        if (-not $enabledProviderIds.Contains($providerId)) {
            $warnings.Add("No enabled provider route for provider $providerId ; model $ModelId is not routable.")
            continue
        }
        $modelRouteId = [string]$modelRoute.model_route_id
        $canonicalModelId = [string]$modelRoute.model_id
        if ([string]::IsNullOrWhiteSpace($canonicalModelId)) { $canonicalModelId = $clientModel }
        $upstreamModelId = [string]$modelRoute.upstream_model_id
        if ([string]::IsNullOrWhiteSpace($upstreamModelId)) { $upstreamModelId = [string]$modelRoute.model_id }

        $fullRouteEnabled = $true
        if (@($routeConfig.Routes).Count -gt 0) {
            $allowedProviderRouteIds = @()
            if ($enabledProviderRouteIdsByProvider.Contains($providerId)) {
                $allowedProviderRouteIds = @($enabledProviderRouteIdsByProvider[$providerId])
            }
            $linked = @($routeConfig.Routes | Where-Object {
                $enabledFlag = $false
                if ($null -ne $_.enabled) { $enabledFlag = [bool]$_.enabled }
                $enabledFlag -and
                    [string]$_.model_route_id -eq $modelRouteId -and
                    [string]$_.provider_route_id -in $allowedProviderRouteIds
            })
            $fullRouteEnabled = $linked.Count -gt 0
        }
        if (-not $fullRouteEnabled) {
            $warnings.Add("Enabled model route $modelRouteId for $ModelId has no enabled full route.")
            continue
        }

        $matchingEnabled.Add([pscustomobject]@{
            model_route_id = $modelRouteId
            provider_id = $providerId
            client_model_id = $clientModel
            canonical_model_id = $canonicalModelId
            upstream_model_id = $upstreamModelId
        })
        if ($providerId -eq "mm_openai_api") {
            $gapCode = $script:Lr12OpenAiApiCapabilityGap
            $errors.Add(($gapCode + ": no canonical catalog or versioned capability source exists for mm_openai_api reasoning/effort metadata in LR-12. Model $ModelId is not Codex-selectable until a separate prerequisite PR provides that source. ChatGPT identity is DIRECT_ONLY and is never mapped to mm_openai_api."))
        }
    }

    # DSR2 architecture decision D: catalog identity is provider-scoped, so the
    # canonical catalog record is resolved with the (provider_id, canonical
    # model_id) pair of the single owning route. A globally duplicate model id in
    # another, inactive provider is never treated as a conflict.
    $catalogRecord = $null
    $catalogError = ""
    if ($matchingEnabled.Count -eq 1) {
        $resolvedProviderId = [string]$matchingEnabled[0].provider_id
        $resolvedModelId = [string]$matchingEnabled[0].canonical_model_id
        try {
            $records = @(Read-CatalogRecords | Where-Object {
                    [string]$_.provider_id -eq $resolvedProviderId -and [string]$_.model_id -eq $resolvedModelId
                })
            if ($records.Count -eq 0) {
                $catalogError = "Model $resolvedModelId is not present in the canonical model catalog for provider $resolvedProviderId."
            }
            elseif ($records.Count -gt 1) {
                $catalogError = "Model $resolvedModelId is ambiguous inside provider $resolvedProviderId."
            }
            else {
                $catalogRecord = $records[0]
            }
        }
        catch {
            $catalogError = "Canonical model catalog could not be read: $($_.Exception.Message)"
        }
    }

    if ($matchingEnabled.Count -eq 0) {
        $errors.Add("Model $ModelId has no enabled approved Router route (unknown, disabled, or unapproved route).")
    }
    elseif ($matchingEnabled.Count -gt 1) {
        $ids = @($matchingEnabled | ForEach-Object { $_.model_route_id } | Sort-Object -Unique) -join ", "
        $errors.Add("ACTIVE_CLIENT_SLUG_AMBIGUOUS: client-facing model slug $ModelId is claimed by more than one enabled Router route ($ids). Exactly one active owner per client slug is required; disable one route or give it a distinct client-facing slug.")
    }
    elseif (-not [string]::IsNullOrWhiteSpace($catalogError)) {
        $errors.Add($catalogError)
    }

    return [pscustomobject]@{
        Valid = ($errors.Count -eq 0)
        ModelId = $ModelId
        Errors = @($errors.ToArray())
        Warnings = @($warnings.ToArray())
        CatalogRecord = $catalogRecord
        EnabledModelRoutes = @($matchingEnabled.ToArray())
    }
}

function Assert-RouterModelValid([string]$ModelId) {
    $candidate = Test-RouterModelCandidate $ModelId
    if ($candidate.Valid) { return $candidate }
    throw ("Invalid Router model `"$ModelId`": " + ($candidate.Errors -join " "))
}

function Assert-RouterEffortSupported([string]$ModelId, [string]$Effort) {
    if ([string]::IsNullOrWhiteSpace($Effort)) {
        throw "A reasoning effort is required."
    }
    $candidate = Test-RouterModelCandidate $ModelId
    if (-not $candidate.Valid) {
        throw ("Invalid Router model `"$ModelId`": " + ($candidate.Errors -join " "))
    }
    if ($null -eq $candidate.CatalogRecord) {
        throw "Reasoning effort for model $ModelId cannot be validated because the canonical catalog has no capability record for it. Failing closed instead of guessing."
    }
    $supported = @($candidate.CatalogRecord.performance_levels | ForEach-Object { [string]$_ })
    if ($supported.Count -eq 0) {
        throw "Model $ModelId has no declared reasoning performance levels in the canonical catalog. Failing closed."
    }
    if ($Effort -notin $supported) {
        throw ("Reasoning effort `"$Effort`" is not supported by model $ModelId. Supported: " + ($supported -join ", "))
    }
}

function Get-RouterCliChildEnvSnapshot {
    $names = @($script:Lr12UpstreamSecretEnvNames + @($script:Lr12TokenEnv) | Sort-Object -Unique)
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        $entries.Add([pscustomobject]@{
            name = $name
            existed = ($null -ne $value)
            value = $value
            imported = $false
        })
    }
    return $entries
}

function Set-RouterCliChildEnv($Snapshot) {
    foreach ($entry in $Snapshot) {
        $name = [string]$entry.name
        if ($name -in $script:Lr12UpstreamSecretEnvNames) {
            if ([bool]$entry.existed) {
                Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
            }
            continue
        }
        if ($name -eq $script:Lr12TokenEnv -and -not [bool]$entry.existed) {
            $userValue = Get-RouterCliUserEnvironmentValue $name
            if (-not [string]::IsNullOrWhiteSpace($userValue)) {
                Set-Item -Path "Env:$name" -Value $userValue
                $entry.imported = $true
            }
        }
    }
}

function Restore-RouterCliChildEnv($Snapshot) {
    foreach ($entry in $Snapshot) {
        $name = [string]$entry.name
        if ([bool]$entry.existed) {
            Set-Item -Path "Env:$name" -Value ([string]$entry.value) -ErrorAction SilentlyContinue
        }
        else {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        }
        $entry.imported = $false
    }
}

function Get-RouterProviderOwnersPath {
    $codexHome = Get-CodexHome
    $dir = Join-Path $codexHome "multimodel-manager"
    Ensure-Directory $dir
    return (Join-Path $dir "router-provider-owners.json")
}

function Get-RouterProviderBaselineDir {
    $codexHome = Get-CodexHome
    $dir = Join-Path $codexHome "multimodel-manager/router-provider-baseline"
    Ensure-Directory $dir
    return $dir
}

function Read-RouterProviderOwners {
    $path = Get-RouterProviderOwnersPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            schema_version = 1
            provider_id = $script:Lr12ProviderId
            baseline_dir = ""
            config_existed = $false
            desktop_registered_ever = $false
            owners = @()
        }
    }
    try {
        $registry = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        if ($null -eq $registry.owners) { $registry | Add-Member -NotePropertyName "owners" -NotePropertyValue @() -Force }
        if ($null -eq $registry.baseline_dir) { $registry | Add-Member -NotePropertyName "baseline_dir" -NotePropertyValue "" -Force }
        if ($null -eq $registry.config_existed) { $registry | Add-Member -NotePropertyName "config_existed" -NotePropertyValue $false -Force }
        if ($null -eq $registry.desktop_registered_ever) { $registry | Add-Member -NotePropertyName "desktop_registered_ever" -NotePropertyValue $false -Force }
        return $registry
    }
    catch {
        throw "Router provider ownership registry is corrupt: $path ($($_.Exception.Message))"
    }
}

function Save-RouterProviderOwners($Registry) {
    $Registry | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Get-RouterProviderOwnersPath) -Encoding UTF8
}

function Register-RouterProviderOwner([string]$ClientId) {
    if ([string]::IsNullOrWhiteSpace($ClientId)) { throw "A Router provider owner client id is required." }
    $ownersPath = Get-RouterProviderOwnersPath
    if (-not (Test-Path -LiteralPath $ownersPath -PathType Leaf)) {
        $baselineDir = Get-RouterProviderBaselineDir
        $configPath = Get-CodexConfigPath
        $configExisted = Test-Path -LiteralPath $configPath -PathType Leaf
        if ($configExisted) {
            Copy-Item -LiteralPath $configPath -Destination (Join-Path $baselineDir "config.toml") -Force
        }
        $registry = [pscustomobject]@{
            schema_version = 1
            provider_id = $script:Lr12ProviderId
            baseline_dir = $baselineDir
            config_existed = $configExisted
            desktop_registered_ever = $false
            owners = @()
        }
        Save-RouterProviderOwners $registry
    }
    else {
        $registry = Read-RouterProviderOwners
    }
    $existing = @($registry.owners | Where-Object { [string]$_.client_id -eq $ClientId })
    if ($existing.Count -eq 0) {
        $owners = New-Object System.Collections.Generic.List[object]
        foreach ($owner in @($registry.owners)) { $owners.Add($owner) }
        $owners.Add([pscustomobject]@{
            client_id = $ClientId
            registered_at = (Get-Date).ToUniversalTime().ToString("o")
        })
        $registry.owners = @($owners.ToArray())
        if ($null -eq $registry.baseline_dir -or [string]::IsNullOrWhiteSpace([string]$registry.baseline_dir)) {
            $registry.baseline_dir = Get-RouterProviderBaselineDir
        }
        if ($ClientId -eq "client.codex_desktop") {
            $registry.desktop_registered_ever = $true
        }
        Save-RouterProviderOwners $registry
    }
    return (Read-RouterProviderOwners)
}

function Unregister-RouterProviderOwner([string]$ClientId) {
    $registry = Read-RouterProviderOwners
    $before = @($registry.owners | Where-Object { [string]$_.client_id -ne $ClientId })
    $wasRegistered = (@($registry.owners).Count -ne $before.Count)
    $desktopEver = if ($null -eq $registry.desktop_registered_ever) { $false } else { [bool]$registry.desktop_registered_ever }
    $registry.owners = @($before)
    if ($registry.owners.Count -eq 0) {
        # Owners file is removed by the last-owner cleanup after the baseline
        # config has been restored; the result carries the baseline location.
    }
    else {
        Save-RouterProviderOwners $registry
    }
    return [pscustomobject]@{
        WasRegistered = $wasRegistered
        WasLast = ($wasRegistered -and $before.Count -eq 0)
        RemainingOwners = $before.Count
        BaselineDir = if ([string]::IsNullOrWhiteSpace([string]$registry.baseline_dir)) { "" } else { [string]$registry.baseline_dir }
        ConfigExisted = if ($null -eq $registry.config_existed) { $false } else { [bool]$registry.config_existed }
        DesktopRegisteredEver = $desktopEver
    }
}

function Restore-RouterProviderBaselineConfig($UnregisterResult) {
    if (-not $UnregisterResult.WasLast) { return }
    $configPath = Get-CodexConfigPath
    $baselineConfig = Join-Path ([string]$UnregisterResult.BaselineDir) "config.toml"
    if ([bool]$UnregisterResult.ConfigExisted) {
        if (-not (Test-Path -LiteralPath $baselineConfig -PathType Leaf)) {
            throw "Router provider baseline config is missing: $baselineConfig"
        }
        Write-ExactBytes $baselineConfig $configPath
    }
    else {
        Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath ([string]$UnregisterResult.BaselineDir) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Get-RouterProviderOwnersPath) -Force -ErrorAction SilentlyContinue
}

function Remove-RouterProviderOwnershipFiles {
    Remove-Item -LiteralPath (Get-RouterProviderBaselineDir) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Get-RouterProviderOwnersPath) -Force -ErrorAction SilentlyContinue
}

function Remove-RouterCliSharedLastOwnerArtifacts([string]$ConfigPath, [string]$ProfilePath) {
    # Last Router owner leaving while Router was ever shared with Desktop:
    # remove ONLY the Router-owned provider block and the CLI-owned profile.
    # Never restore a whole old config because the current Desktop route and
    # unrelated user configuration must survive.
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $text = Get-Content -Raw -LiteralPath $ConfigPath
        $cleaned = Remove-RouterProviderBlockFromConfig $text
        Write-Utf8NoBom $ConfigPath $cleaned
    }
    if (Test-ProfileOwned $ProfilePath) {
        Remove-Item -LiteralPath $ProfilePath -Force
    }
    Remove-RouterProviderOwnershipFiles
}

function Set-RouterProviderBaselineFromConfig([string]$ConfigSourcePath, [bool]$ConfigExisted) {
    $registry = Read-RouterProviderOwners
    if ($registry.owners.Count -ne 1) {
        # Only the very first Router client owner may seed the shared baseline.
        return
    }
    $baselineDir = [string]$registry.baseline_dir
    if ([string]::IsNullOrWhiteSpace($baselineDir)) { return }
    $baselineConfig = Join-Path $baselineDir "config.toml"
    if ($ConfigExisted) {
        if (-not (Test-Path -LiteralPath $ConfigSourcePath -PathType Leaf)) {
            throw "Router provider baseline source config is missing: $ConfigSourcePath"
        }
        Copy-Item -LiteralPath $ConfigSourcePath -Destination $baselineConfig -Force
    }
    else {
        Remove-Item -LiteralPath $baselineConfig -Force -ErrorAction SilentlyContinue
    }
    $registry.config_existed = $ConfigExisted
    Save-RouterProviderOwners $registry
}

function Get-RouterCliAvailableModels {
    $available = New-Object System.Collections.Generic.List[object]
    $routeConfig = Get-RouterRouteConfig
    foreach ($modelRoute in @($routeConfig.ModelRoutes)) {
        $enabled = $false
        if ($null -ne $modelRoute.enabled) { $enabled = [bool]$modelRoute.enabled }
        if (-not $enabled) { continue }
        $clientModel = [string]$modelRoute.client_model_id
        if ([string]::IsNullOrWhiteSpace($clientModel)) { continue }
        $candidate = Test-RouterModelCandidate $clientModel
        if ($candidate.Valid -and -not (@($available | Where-Object { $_.model_id -eq $clientModel }).Count -gt 0)) {
            $available.Add([pscustomobject]@{
                model_id = $clientModel
                provider_id = [string]$modelRoute.provider_id
            })
        }
    }
    return @($available | Sort-Object model_id)
}

function Read-RouterModelInteractive {
    $available = @(Get-RouterCliAvailableModels)
    if ($available.Count -eq 0) {
        Write-Host ""
        Write-Host "No enabled Router route currently resolves to a canonical catalog model." -ForegroundColor Yellow
        Write-Host "Add an enabled provider_route + model_route (+ route) in router.config.json first," -ForegroundColor Yellow
        Write-Host "then enable the Router CLI again. Example model: qwen3-coder-plus / deepseek-v4-pro." -ForegroundColor Yellow
        throw "No Router model can be selected because no approved Router route exists."
    }

    Write-Host ""
    Write-Host "Router models available through enabled routes:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $available.Count; $i++) {
        Write-Host ("  {0}. {1}  (provider {2})" -f ($i + 1), $available[$i].model_id, $available[$i].provider_id) -ForegroundColor White
    }
    $defaultModel = [string]$available[0].model_id
    $choice = Read-Host ("Enter Router model ID [" + $defaultModel + "]")
    if ([string]::IsNullOrWhiteSpace($choice)) {
        $choice = $defaultModel
    }
    $choice = $choice.Trim()
    if (-not (@($available | Where-Object { $_.model_id -eq $choice }).Count -gt 0)) {
        throw "Selected model `"$choice`" is not in the enabled Router route set."
    }
    return $choice
}

function Get-RouterCliConfigPath {
    $codexHome = Get-CodexHome
    return (Join-Path $codexHome "multimodel-manager/local-router/router.config.json")
}

function Get-RouterCliBackupRoot {
    $codexHome = Get-CodexHome
    return (Join-Path $codexHome "backups/router-cli")
}

function Get-RouterCliReceiptRoot {
    $codexHome = Get-CodexHome
    return (Join-Path $codexHome "multimodel-manager/router-cli-backups")
}

function Get-FileSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $sha.ComputeHash($stream)
            return ([System.BitConverter]::ToString($bytes)).Replace("-", "").ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Write-ExactBytes([string]$Source, [string]$Destination) {
    [System.IO.File]::WriteAllBytes($Destination, [System.IO.File]::ReadAllBytes($Source))
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Read-RouterUserConfig {
    $configPath = Get-RouterCliConfigPath
    $defaults = [pscustomobject]@{
        Path = $configPath
        Exists = $false
        Valid = $false
        Error = ""
        Mode = "direct"
        Enabled = $false
        Host = $script:Lr12DefaultHost
        Port = $script:Lr12DefaultPort
    }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return $defaults
    }
    $defaults.Exists = $true
    try {
        $raw = Get-Content -Raw -LiteralPath $configPath
        $cfg = $raw | ConvertFrom-Json
        $mode = [string]$cfg.mode
        if ([string]::IsNullOrWhiteSpace($mode)) { $mode = "direct" }

        $enabled = $false
        $hostValue = $script:Lr12DefaultHost
        $portValue = $script:Lr12DefaultPort
        if ($null -ne $cfg.local_router) {
            if ($null -ne $cfg.local_router.enabled) { $enabled = [bool]$cfg.local_router.enabled }
            if ($null -ne $cfg.local_router.host) { $hostValue = [string]$cfg.local_router.host }
            if ($null -ne $cfg.local_router.port) { $portValue = [int]$cfg.local_router.port }
        }
        if ([string]::IsNullOrWhiteSpace($hostValue)) { $hostValue = $script:Lr12DefaultHost }
        if ($portValue -lt 1 -or $portValue -gt 65535) {
            throw "Invalid router port: $portValue"
        }
        if ($hostValue -ne "127.0.0.1" -and $hostValue -ne "localhost" -and $hostValue -ne "::1") {
            throw "Router host must stay loopback: $hostValue"
        }
        if ($hostValue -eq "::1") { $hostValue = "127.0.0.1" }

        $defaults.Valid = $true
        $defaults.Mode = $mode
        $defaults.Enabled = ($mode -eq "router" -and $enabled)
        $defaults.Host = $hostValue
        $defaults.Port = $portValue
        return $defaults
    }
    catch {
        $defaults.Valid = $false
        $defaults.Error = $_.Exception.Message
        return $defaults
    }
}

function Get-RouterCliState {
    $path = Get-RouterCliStatePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
            if ($null -eq $state.schema_version) { $state | Add-Member -NotePropertyName "schema_version" -NotePropertyValue $script:Lr12SchemaVersion -Force }
            if ($null -eq $state.mode) { $state | Add-Member -NotePropertyName "mode" -NotePropertyValue "direct" -Force }
            if ($null -eq $state.generation) { $state | Add-Member -NotePropertyName "generation" -NotePropertyValue 0 -Force }
            if ($null -eq $state.selected_model) { $state | Add-Member -NotePropertyName "selected_model" -NotePropertyValue "" -Force }
            if ($null -eq $state.reasoning_effort) { $state | Add-Member -NotePropertyName "reasoning_effort" -NotePropertyValue "medium" -Force }
            if ($null -eq $state.host) { $state | Add-Member -NotePropertyName "host" -NotePropertyValue $script:Lr12DefaultHost -Force }
            if ($null -eq $state.port) { $state | Add-Member -NotePropertyName "port" -NotePropertyValue $script:Lr12DefaultPort -Force }
            if ($null -eq $state.provider_id) { $state | Add-Member -NotePropertyName "provider_id" -NotePropertyValue $script:Lr12ProviderId -Force }
            if ($null -eq $state.token_env) { $state | Add-Member -NotePropertyName "token_env" -NotePropertyValue $script:Lr12TokenEnv -Force }
            if ($null -eq $state.backup_receipt) { $state | Add-Member -NotePropertyName "backup_receipt" -NotePropertyValue "" -Force }
            if ($null -eq $state.first_backup_receipt) { $state | Add-Member -NotePropertyName "first_backup_receipt" -NotePropertyValue "" -Force }
            if ($null -eq $state.enabled_at) { $state | Add-Member -NotePropertyName "enabled_at" -NotePropertyValue $null -Force }
            if ($null -eq $state.updated_at) { $state | Add-Member -NotePropertyName "updated_at" -NotePropertyValue $null -Force }
            return $state
        }
        catch {
            throw "Router CLI state is corrupt: $path ($($_.Exception.Message))"
        }
    }
    return [pscustomobject]@{
        schema_version = $script:Lr12SchemaVersion
        mode = "direct"
        generation = 0
        selected_model = ""
        reasoning_effort = "medium"
        host = $script:Lr12DefaultHost
        port = $script:Lr12DefaultPort
        provider_id = $script:Lr12ProviderId
        token_env = $script:Lr12TokenEnv
        enabled_at = $null
        backup_receipt = ""
        first_backup_receipt = ""
        updated_at = $null
    }
}

function Save-RouterCliState($State) {
    $path = Get-RouterCliStatePath
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-RouterProviderBlock([int]$Port) {
    $lines = @(
        $script:Lr12BaseBeginMarker
        "# Owned by Codex Multi-Model Manager LR-12 (router-codex-cli.ps1). Schema version $script:Lr12SchemaVersion."
        "# Codex connects only to the Local Router. Upstream provider secrets never enter this block."
        ""
        "[model_providers.$script:Lr12ProviderId]"
        'name = "Codex Multi-Model Local Router"'
        ('base_url = "http://{0}:{1}/v1"' -f $script:Lr12DefaultHost, $Port)
        'env_key = "CODEX_LOCAL_ROUTER_TOKEN"'
        'wire_api = "responses"'
        "requires_openai_auth = false"
        "supports_websockets = false"
        ""
        $script:Lr12BaseEndMarker
    )
    return ($lines -join "`r`n")
}

function Get-RouterProfileBody([string]$Model, [string]$Effort) {
    $modelLine = if ([string]::IsNullOrWhiteSpace($Model)) { "" } else { ('model = "{0}"' -f (Escape-TomlString $Model)) }
    $effortLine = ('model_reasoning_effort = "{0}"' -f $Effort)
    $lines = @(
        $script:Lr12ProfileBeginMarker
        "# Owned by Codex Multi-Model Manager LR-12 (router-codex-cli.ps1). Schema version $script:Lr12SchemaVersion."
        "# This profile references the Router-owned provider and contains no upstream secret."
        ""
        ('model_provider = "{0}"' -f $script:Lr12ProviderId)
        $modelLine
        $effortLine
        "request_max_retries = 0"
        "stream_max_retries = 0"
        ""
        $script:Lr12ProfileEndMarker
    )
    return (($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`r`n")
}

function Set-RouterProviderBlockInConfig([string]$ConfigText, [int]$Port) {
    $block = Get-RouterProviderBlock $Port
    $pattern = '(?s)# >>> CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN.*?# <<< CODEX MULTIMODEL MANAGER ROUTER CLI END'
    if ([regex]::IsMatch($ConfigText, $pattern)) {
        return [regex]::Replace($ConfigText, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 1)
    }
    $prefix = $ConfigText
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        return $block
    }
    # Deterministic separator: exactly one CRLF before the Router-owned block.
    # The original text is never rewritten, so exact disable/restore is provable.
    return ($prefix + "`r`n" + $block)
}

function Remove-RouterProviderBlockFromConfig([string]$ConfigText) {
    $beginMarker = "# >>> CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN"
    $endMarker = "# <<< CODEX MULTIMODEL MANAGER ROUTER CLI END"
    $beginIndex = $ConfigText.IndexOf($beginMarker)
    if ($beginIndex -lt 0) { return $ConfigText }
    $endIndex = $ConfigText.IndexOf($endMarker, $beginIndex)
    if ($endIndex -lt 0) { return $ConfigText }
    $endIndex += $endMarker.Length
    $prefix = $ConfigText.Substring(0, $beginIndex)
    if ($prefix.EndsWith("`r`n")) { $prefix = $prefix.Substring(0, $prefix.Length - 2) }
    elseif ($prefix.EndsWith("`n")) { $prefix = $prefix.Substring(0, $prefix.Length - 1) }
    $suffix = $ConfigText.Substring($endIndex)
    if ($suffix.StartsWith("`r`n")) { $suffix = $suffix.Substring(2) }
    elseif ($suffix.StartsWith("`n")) { $suffix = $suffix.Substring(1) }
    $result = $prefix + $suffix
    if (-not [string]::IsNullOrWhiteSpace($prefix) -and -not [string]::IsNullOrWhiteSpace($suffix) -and -not $prefix.EndsWith("`n")) {
        $result = $prefix + "`r`n" + $suffix
    }
    return $result
}

function Get-CodexConfigPath {
    $codexHome = Get-CodexHome
    return (Join-Path $codexHome "config.toml")
}

function Read-CurrentProviderPort([string]$ConfigText) {
    $match = [regex]::Match($ConfigText, '(?s)# >>> CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN.*?base_url\s*=\s*"http://127\.0\.0\.1:(\d+)/v1".*?# <<< CODEX MULTIMODEL MANAGER ROUTER CLI END')
    if (-not $match.Success) { return $null }
    return [int]$match.Groups[1].Value
}

function Test-ProfileOwned([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $text = Get-Content -Raw -LiteralPath $Path
    return ($text.Contains($script:Lr12ProfileBeginMarker) -and $text.Contains($script:Lr12ProfileEndMarker))
}

function Test-ProfileMatches([string]$Path, [string]$Model, [string]$Effort) {
    if (-not (Test-ProfileOwned $Path)) { return $false }
    $text = Get-Content -Raw -LiteralPath $Path
    if (-not $text.Contains(('model_provider = "{0}"' -f $script:Lr12ProviderId))) { return $false }
    if (-not $text.Contains(('model = "{0}"' -f (Escape-TomlString $Model)))) { return $false }
    if (-not $text.Contains(('model_reasoning_effort = "{0}"' -f $Effort))) { return $false }
    if (-not $text.Contains("request_max_retries = 0")) { return $false }
    if (-not $text.Contains("stream_max_retries = 0")) { return $false }
    return $true
}

function New-RouterCliBackupReceipt([int]$Generation) {
    $receiptId = ("router-cli-" + [guid]::NewGuid().ToString("N"))
    $receiptRoot = Get-RouterCliReceiptRoot
    $backupRoot = Get-RouterCliBackupRoot
    Ensure-Directory $receiptRoot
    Ensure-Directory $backupRoot

    $backupDir = Join-Path $backupRoot $receiptId
    Ensure-Directory $backupDir

    $entries = New-Object System.Collections.Generic.List[object]
    $candidates = @(
        @{ Kind = "codex_config"; Path = (Get-CodexConfigPath) }
        @{ Kind = "router_profile"; Path = (Get-RouterCliProfilePath) }
        @{ Kind = "router_config"; Path = (Get-RouterCliConfigPath) }
    )
    foreach ($candidate in $candidates) {
        $source = $candidate.Path
        $existed = Test-Path -LiteralPath $source -PathType Leaf
        $fileName = [System.IO.Path]::GetFileName($source)
        $backupPath = Join-Path $backupDir $fileName
        if ($existed) {
            Copy-Item -LiteralPath $source -Destination $backupPath -Force
        }
        $entries.Add([pscustomobject]@{
            kind = $candidate.Kind
            source = $source
            backup_path = $backupPath
            existed = $existed
            before_sha256 = if ($existed) { Get-FileSha256 $source } else { $null }
            after_sha256 = $null
        })
    }

    $receipt = [pscustomobject]@{
        schema_version = $script:Lr12SchemaVersion
        receipt_id = $receiptId
        operation = "enable"
        created_at = (Get-Date).ToUniversalTime().ToString("o")
        generation = $Generation
        files = @($entries.ToArray())
    }
    $receiptPath = Join-Path $receiptRoot ($receiptId + ".json")
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    return [pscustomobject]@{ Id = $receiptId; Path = $receiptPath; Receipt = $receipt }
}

function Update-RouterCliReceiptAfterHashes([string]$ReceiptId) {
    $receiptRoot = Get-RouterCliReceiptRoot
    $receiptPath = Join-Path $receiptRoot ($ReceiptId + ".json")
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { return }
    $receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
    foreach ($entry in @($receipt.files)) {
        $source = [string]$entry.source
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $entry.after_sha256 = Get-FileSha256 $source
        }
        else {
            $entry.after_sha256 = $null
        }
    }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
}

function Update-RouterCliReceiptEntryAfterHash([string]$ReceiptId, [string]$Kind, [string]$AfterSha) {
    $receiptRoot = Get-RouterCliReceiptRoot
    $receiptPath = Join-Path $receiptRoot ($ReceiptId + ".json")
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { return }
    $receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
    foreach ($entry in @($receipt.files)) {
        if ([string]$entry.kind -eq $Kind) {
            $entry.after_sha256 = $AfterSha
        }
    }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
}

function Get-RouterCliReceipt([string]$ReceiptId) {
    if ([string]::IsNullOrWhiteSpace($ReceiptId)) { return $null }
    $receiptRoot = Get-RouterCliReceiptRoot
    $receiptPath = Join-Path $receiptRoot ($ReceiptId + ".json")
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { return $null }
    try {
        return (Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Restore-RouterCliFiles($Receipt, [switch]$Force) {
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Receipt.files)) {
        $kind = [string]$entry.kind
        $source = [string]$entry.source
        $backupPath = [string]$entry.backup_path
        $existed = [bool]$entry.existed

        if ($kind -eq "router_config") {
            continue
        }

        if ($kind -eq "codex_config") {
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                continue
            }
            $text = Get-Content -Raw -LiteralPath $source
            $originalText = $null
            if ($existed -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                $originalText = Get-Content -Raw -LiteralPath $backupPath
            }

            $blockMatch = [regex]::Match($text, '(?s)# >>> CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN.*?# <<< CODEX MULTIMODEL MANAGER ROUTER CLI END')
            $currentBlock = if ($blockMatch.Success) { $blockMatch.Value } else { "" }
            if ($blockMatch.Success -and $null -ne $originalText) {
                $expected = $originalText + "`r`n" + $currentBlock
                if ($text -eq $expected) {
                    Write-ExactBytes $backupPath $source
                    continue
                }
            }
            if (-not $existed -and $blockMatch.Success) {
                $expected = $currentBlock
                if ($text -eq $expected -or $text -eq ($expected + "`r`n")) {
                    Remove-Item -LiteralPath $source -Force
                    continue
                }
            }
            $stripped = Remove-RouterProviderBlockFromConfig $text
            if ($Force) {
                if ($stripped -ne $text) {
                    Write-Utf8NoBom $source $stripped
                    $warnings.Add("Codex config changed while Router CLI was enabled; Router-owned block removed without full byte restore: $source")
                    continue
                }
            }
            throw "Refusing to overwrite externally changed Codex config while restoring Router CLI: $source"
        }

        if ($kind -eq "router_profile") {
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                continue
            }
            $text = Get-Content -Raw -LiteralPath $source
            $stripped = [regex]::Replace($text, '(?s)^\s*# >>> CODEX MULTIMODEL MANAGER ROUTER CLI PROFILE BEGIN.*?# <<< CODEX MULTIMODEL MANAGER ROUTER CLI PROFILE END\s*\r?\n?', "")
            $originalText = $null
            if ($existed -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                $originalText = Get-Content -Raw -LiteralPath $backupPath
            }
            if ($existed -and $null -ne $originalText -and $stripped -eq $originalText) {
                Write-ExactBytes $backupPath $source
                continue
            }
            if (-not $existed -and [string]::IsNullOrWhiteSpace($stripped)) {
                Remove-Item -LiteralPath $source -Force
                continue
            }
            throw "Refusing to overwrite externally changed Router profile while restoring Router CLI: $source"
        }
    }
    return @($warnings.ToArray())
}

# ---------------------------------------------------------------------------
# HS1B-RB1 - Local Router bootstrap (Initialize)
# ---------------------------------------------------------------------------
# Everything below is additive: it prepares the Router user config, the local
# client token, and the route topology so the existing explicit Enable action
# stops failing on a missing router.config.json. It never starts Codex, never
# performs a provider request, and never modifies config.toml.
#
# The declarative tables below mirror the canonical C# sources:
#   adapter id/version  -> Router.ProviderAdapters.*.ProviderAdapter constants
#   base_url_ref        -> Router.Execution.RouterExecutionEndpoints
#   upstream secret env -> Router.Secrets.EnvironmentSecretAllowlist
#   catalog provider id -> $script:Lr12CatalogProviderMap (model-catalog v3)
# tests/validate-local-router-bootstrap.ps1 asserts every entry against those
# sources, so a bootstrap can never invent a provider, endpoint, or secret name.
$script:Lr12BootstrapProviderTable = [ordered]@{
    "mm_modelstudio" = [ordered]@{
        ShortId = "modelstudio"
        AdapterId = "adapter.provider.mm_modelstudio.responses.v1"
        AdapterVersion = "1.0"
        BaseUrlRef = "provider-config:mm_modelstudio.base_url"
        SecretEnv = "CODEX_DASHSCOPE_API_KEY"
    }
    "mm_openrouter" = [ordered]@{
        ShortId = "openrouter"
        AdapterId = "adapter.provider.mm_openrouter.responses.v1"
        AdapterVersion = "1.0"
        BaseUrlRef = "provider-config:mm_openrouter.base_url"
        SecretEnv = "OPENROUTER_API_KEY"
    }
    "mm_mimo" = [ordered]@{
        ShortId = "mimo"
        AdapterId = "adapter.provider.mm_mimo.responses.v1"
        AdapterVersion = "1.0"
        BaseUrlRef = "provider-config:mm_mimo.base_url"
        SecretEnv = "MIMO_API_KEY"
    }
    "mm_openai_api" = [ordered]@{
        ShortId = "openai-api"
        AdapterId = "adapter.provider.mm_openai_api.responses.v1"
        AdapterVersion = "1.0"
        BaseUrlRef = "provider-config:mm_openai_api.base_url"
        SecretEnv = "CODEX_OPENAI_API_KEY"
    }
    "deepseek" = [ordered]@{
        ShortId = "deepseek"
        AdapterId = "adapter.provider.deepseek.responses.v1"
        AdapterVersion = "1.0"
        BaseUrlRef = "provider-config:deepseek.base_url"
        SecretEnv = "DEEPSEEK_API_KEY"
    }
}

# DSR2 explicit, versioned canonical-model alias table.
#
# Key   = "<provider_id>::<canonical upstream model id>"
# Value = the legacy client slugs that must resolve to that canonical model.
#
# Aliases belong to the routing/model-route layer only: they are never inferred
# from substrings such as "flash", "vision" or "pro", and a provider adapter
# never applies an alias of its own.
$script:Lr12BootstrapModelAliases = [ordered]@{
    "deepseek::deepseek-flash" = @("deepseek-v4-flash", "deepseek-v4-flash-vision-exp")
}

function Get-RouterBootstrapModelAliases([string]$ProviderId, [string]$ModelId) {
    $key = $ProviderId + "::" + $ModelId
    if ($script:Lr12BootstrapModelAliases.Contains($key)) {
        return @($script:Lr12BootstrapModelAliases[$key])
    }
    return @()
}

$script:Lr12BootstrapClientId = "client.codex_cli"
$script:Lr12BootstrapClientAdapterId = "adapter.client.codex_cli.responses.v1"
$script:Lr12BootstrapClientAuthScope = "responses:invoke"
$script:Lr12BootstrapClientCapabilities = @("text", "streaming", "reasoning", "tools", "usage", "cancellation")
# DSR7-B-FIX1: the Router Control Plane (/v1/router/control-plane/*) requires the
# "router:control-plane" scope, and ClientScopeRegistry resolves a required scope
# by looking for exactly one enabled client with that auth_scope (there is no
# caller-identity transport). The bootstrap therefore generates a dedicated
# control-plane client next to the execution client. Its shape mirrors the
# verified Router.Ingress fixture (ControlPlaneEndpointsTests) exactly: no
# capabilities are invented, and it never participates in a model route.
$script:Lr12ControlPlaneClientId = "client.control_plane"
$script:Lr12ControlPlaneClientAdapterId = "adapter.client.control_plane.responses.v1"
$script:Lr12ControlPlaneClientAuthScope = "router:control-plane"
$script:Lr12BootstrapProtocolRouteId = "protocol-route.responses-pass-through"
$script:Lr12BootstrapProtocolId = "protocol.openai.responses.v1"
$script:Lr12BootstrapProtocolAdapterId = "adapter.protocol.responses-compatible.v1"
$script:Lr12BootstrapProtocolAdapterVersion = "1.0"
$script:Lr12BootstrapFullCapabilities = @("responses", "text", "streaming", "reasoning", "tools", "usage", "cancellation")
$script:Lr12BootstrapModelCapabilities = @("text", "streaming", "reasoning", "tools", "usage")
$script:Lr12BootstrapTimeoutPolicyId = "policy.timeout-default"
$script:Lr12BootstrapRetryPolicyId = "policy.retry-safe-default"
$script:Lr12BootstrapFailoverPolicyId = "policy.failover-off"
$script:Lr12BootstrapUnknownProviderPrefix = "PROVIDER_NOT_ROUTER_SUPPORTED"

# Injectable seam: production writes the real User-scope environment through the
# .NET setter (the established Manager convention). Validators replace the
# hashtable so a bootstrap test never mutates real User scope.
$script:Lr12UserEnvWriter = $null

function Write-RouterCliUserEnvironmentValue([string]$Name, [string]$Value) {
    if ($null -ne $script:Lr12UserEnvWriter) {
        $script:Lr12UserEnvWriter[$Name] = $Value
        return
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, [EnvironmentVariableTarget]::User)
    [Environment]::SetEnvironmentVariable($Name, $Value, [EnvironmentVariableTarget]::Process)
}

function Get-RouterCliUpstreamSecretEnvironmentValue([string]$Name) {
    $processValue = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($processValue)) { return [string]$processValue }
    $userValue = Get-RouterCliUserEnvironmentValue $Name
    if (-not [string]::IsNullOrWhiteSpace($userValue)) { return [string]$userValue }
    return ""
}

function New-RouterCliSecureLocalClientToken {
    # 32 cryptographically secure random bytes == 256 bits of entropy, encoded as
    # base64url so the value is environment- and shell-safe. The value is only
    # ever handed to the user/process environment store; it is never written to
    # a file, receipt, log, or console line.
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $encoded = [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_')
    return $encoded.TrimEnd('=')
}

function Initialize-RouterCliLocalClientToken {
    if (Test-TokenEnvPresent) {
        return [pscustomobject]@{ Present = $true; Created = $false; Store = "existing" }
    }
    $token = New-RouterCliSecureLocalClientToken
    $weak = [string]::IsNullOrWhiteSpace($token) -or $token.Length -lt 43
    if ($weak) {
        $token = $null
        throw "Local client token generation failed the entropy/length check; no token was stored."
    }
    Write-RouterCliUserEnvironmentValue $script:Lr12TokenEnv $token
    $token = $null
    return [pscustomobject]@{ Present = $true; Created = $true; Store = "Windows User environment" }
}

function Get-RouterBootstrapDefaultsPath {
    $installerRoot = Split-Path -Parent $PSScriptRoot
    $repositoryRoot = Split-Path -Parent $installerRoot
    $candidates = @(
        (Join-Path $repositoryRoot "local-router/config/router.defaults.json"),
        (Join-Path $installerRoot "config/router.defaults.json")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw ("Canonical Router defaults document is missing; checked: " + ($candidates -join "; "))
}

function ConvertTo-RouterBootstrapSlug([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $lowered = $Value.ToLowerInvariant()
    $replaced = [regex]::Replace($lowered, '[^a-z0-9]+', '-')
    return $replaced.Trim('-')
}

function Get-RouterBootstrapCatalogProviderId([string]$ProviderId) {
    foreach ($catalogProviderId in $script:Lr12CatalogProviderMap.Keys) {
        if ([string]$script:Lr12CatalogProviderMap[$catalogProviderId] -eq $ProviderId) {
            return [string]$catalogProviderId
        }
    }
    return ""
}

function Read-RouterBootstrapJsonObject([string]$Path, [string]$Label) {
    $raw = Get-Content -Raw -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Router $Label document is empty: $Path"
    }
    try {
        $parsed = $raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "Router $Label document is not valid JSON: $Path ($($_.Exception.Message))"
    }
    if (-not ($parsed -is [System.Collections.IDictionary])) {
        throw "Router $Label document must be a JSON object: $Path"
    }
    return $parsed
}

function Get-RouterBootstrapSchemaVersion { return 1 }

# ConvertFrom-Json materializes RFC 3339 strings as [datetime]; the canonical
# document always carries the wire-shaped UTC string so the written file, the
# idempotency comparison, and the golden fixture stay byte-stable.
function ConvertTo-RouterBootstrapTimestampString($Value) {
    if ($null -eq $Value) { return "" }
    if ($Value -is [datetime]) {
        return ([datetime]$Value).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    $text = [string]$Value
    if (Test-RouterBootstrapPattern $text '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}') { return $text }
    return ""
}

# -- HS1B-RB1 bootstrap: effective document merge ----------------------------

# The effective-document merge mirrors Router.Configuration.RouterConfigMerger:
# objects merge field by field, arrays and scalars replace, and any key outside
# the schema whitelist is a security violation that fails the bootstrap closed.
function Merge-RouterBootstrapEffectiveDocument($Defaults, $User) {
    $topLevel = @(
        "schema_version", "version", "mode", "local_router", "clients",
        "protocol_routes", "provider_routes", "endpoints", "model_routes",
        "routes", "policies", "updated_at"
    )
    $merged = [ordered]@{}
    foreach ($key in $Defaults.Keys) { $merged[$key] = $Defaults[$key] }
    if ($null -eq $User) { return $merged }
    foreach ($key in $User.Keys) {
        if ($key -notin $topLevel) { throw "Router user config field is not part of schema v1: $key" }
        if ($key -eq "local_router") {
            $merged["local_router"] = Merge-RouterBootstrapLocalRouter $Defaults["local_router"] $User[$key]
            continue
        }
        $merged[$key] = $User[$key]
    }
    return $merged
}

function Merge-RouterBootstrapLocalRouter($DefaultLocal, $UserLocal) {
    if (-not ($UserLocal -is [System.Collections.IDictionary])) {
        throw "Router user config field local_router must be a JSON object."
    }
    $allowed = @("enabled", "host", "port", "client_auth", "limits", "thread_selection")
    # Optional schema-v1 fields that the canonical defaults deliberately omit, so
    # their absence keeps the default (HS-1C: quota_failover_enabled -> false).
    # Only these exact names are admitted; every other unknown key still fails.
    $optionalNested = @{ thread_selection = @("quota_failover_enabled") }
    $merged = [ordered]@{}
    foreach ($key in $DefaultLocal.Keys) { $merged[$key] = $DefaultLocal[$key] }
    foreach ($key in $UserLocal.Keys) {
        if ($key -notin $allowed) { throw "Router user config field is not part of schema v1: local_router.$key" }
        if ($key -in @("client_auth", "limits", "thread_selection")) {
            $nested = $UserLocal[$key]
            if (-not ($nested -is [System.Collections.IDictionary])) {
                throw "Router user config field local_router.$key must be a JSON object."
            }
            $base = [ordered]@{}
            foreach ($nestedKey in $DefaultLocal[$key].Keys) { $base[$nestedKey] = $DefaultLocal[$key][$nestedKey] }
            $optional = if ($optionalNested.ContainsKey($key)) { @($optionalNested[$key]) } else { @() }
            foreach ($nestedKey in $nested.Keys) {
                if (-not $base.Contains($nestedKey) -and $nestedKey -cnotin $optional) {
                    throw "Router user config field is not part of schema v1: local_router.$key.$nestedKey"
                }
                $base[$nestedKey] = $nested[$nestedKey]
            }
            $merged[$key] = $base
            continue
        }
        $merged[$key] = $UserLocal[$key]
    }
    return $merged
}

function Test-RouterBootstrapInteger($Value) {
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $false }
    if ($Value -is [string]) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $false }
    if ($Value -is [System.Collections.IEnumerable]) { return $false }
    try { $asDecimal = [decimal]$Value } catch { return $false }
    return ($asDecimal -eq [decimal]::Truncate($asDecimal))
}

function Test-RouterBootstrapIntegerInRange($Value, [decimal]$Minimum, [decimal]$Maximum) {
    if (-not (Test-RouterBootstrapInteger $Value)) { return $false }
    $asDecimal = [decimal]$Value
    return ($asDecimal -ge $Minimum -and $asDecimal -le $Maximum)
}

function Test-RouterBootstrapBoolean($Value) { return ($Value -is [bool]) }

function Test-RouterBootstrapArray($Value) {
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $false }
    return ($Value -is [System.Collections.IEnumerable])
}

function Test-RouterBootstrapPattern([string]$Value, [string]$Pattern) {
    if ($null -eq $Value) { return $false }
    return [regex]::IsMatch([string]$Value, $Pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Test-RouterBootstrapStringList($Value, [string]$Pattern, [bool]$RequireNonEmpty) {
    if (-not (Test-RouterBootstrapArray $Value)) { return $false }
    $items = @($Value)
    if ($RequireNonEmpty -and $items.Count -eq 0) { return $false }
    foreach ($item in $items) {
        if (-not ($item -is [string])) { return $false }
        $text = [string]$item
        if ([string]::IsNullOrEmpty($text) -or $text.Length -gt 128) { return $false }
        if (-not [string]::IsNullOrWhiteSpace($Pattern) -and -not (Test-RouterBootstrapPattern $text $Pattern)) { return $false }
    }
    return $true
}

function Get-RouterBootstrapUnknownFields($Object, [string[]]$Allowed, [string]$Path, $Errors) {
    foreach ($key in $Object.Keys) {
        if ($key -notin $Allowed) { $Errors.Add("Unknown field: $Path.$key") }
    }
}

# -- HS1B-RB1 bootstrap: schema validation ------------------------------------

function Get-RouterBootstrapCapabilityNames {
    return @("text", "streaming", "reasoning", "tools", "usage", "cancellation", "responses")
}

function Test-RouterBootstrapCapabilities($Value, [bool]$RequireNonEmpty) {
    if (-not (Test-RouterBootstrapStringList $Value "" $RequireNonEmpty)) { return $false }
    $known = Get-RouterBootstrapCapabilityNames
    foreach ($item in @($Value)) {
        if ([string]$item -notin $known) { return $false }
    }
    return $true
}

function Get-RouterBootstrapEntityArray($Document, [string]$Name, $Errors) {
    $value = $Document[$Name]
    if ($null -eq $value) { return @() }
    if (-not (Test-RouterBootstrapArray $value)) {
        $Errors.Add("$Name must be an array.")
        return @()
    }
    return @($value)
}

function Test-RouterBootstrapEntityFields($Entity, [string[]]$Allowed, [string[]]$Required, [string]$Path, $Errors) {
    Get-RouterBootstrapUnknownFields $Entity $Allowed $Path $Errors
    $complete = $true
    foreach ($field in $Required) {
        if (-not $Entity.Contains($field)) {
            $Errors.Add("Missing required field: $Path.$field")
            $complete = $false
        }
    }
    return $complete
}

# Mirrors Router.Configuration.RouterConfigValidator for the effective document.
# Unknown schemas, security invariant violations, duplicate ids, unknown enums,
# invalid limits, ambiguous model mappings and invalid secret references all
# fail closed.
function Get-RouterBootstrapDocumentErrors($Document) {
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not ($Document -is [System.Collections.IDictionary])) {
        $errors.Add("Router config document must be a JSON object.")
        return @($errors.ToArray())
    }

    $topLevel = @(
        "schema_version", "version", "mode", "local_router", "clients",
        "protocol_routes", "provider_routes", "endpoints", "model_routes",
        "routes", "policies", "updated_at"
    )
    $requiredTopLevel = @(
        "schema_version", "version", "mode", "local_router", "clients",
        "protocol_routes", "provider_routes", "model_routes", "routes",
        "policies", "updated_at"
    )
    Get-RouterBootstrapUnknownFields $Document $topLevel "config" $errors
    $missing = @($requiredTopLevel | Where-Object { -not $Document.Contains($_) })
    foreach ($field in $missing) { $errors.Add("Missing required field: $field") }
    if ($missing.Count -gt 0) { return @($errors.ToArray()) }

    if (-not (Test-RouterBootstrapInteger $Document["schema_version"]) -or [int]$Document["schema_version"] -ne (Get-RouterBootstrapSchemaVersion)) {
        $errors.Add("Router config schema_version must be 1.")
    }
    if (-not (Test-RouterBootstrapIntegerInRange $Document["version"] 1 2147483647)) {
        $errors.Add("Router config version must be an integer >= 1.")
    }
    $mode = [string]$Document["mode"]
    if ($mode -notin @("direct", "router")) { $errors.Add("Router config mode must be direct or router.") }
    if ([string]::IsNullOrWhiteSpace((ConvertTo-RouterBootstrapTimestampString $Document["updated_at"]))) {
        $errors.Add("Router config updated_at must be an RFC 3339 timestamp.")
    }

    $local = $Document["local_router"]
    if (-not ($local -is [System.Collections.IDictionary])) {
        $errors.Add("local_router must be a JSON object.")
        return @($errors.ToArray())
    }
    $localComplete = Test-RouterBootstrapEntityFields $local `
        @("enabled", "host", "port", "client_auth", "limits", "thread_selection") `
        @("enabled", "host", "port", "client_auth", "limits", "thread_selection") "local_router" $errors
    if (-not $localComplete) { return @($errors.ToArray()) }

    if (-not (Test-RouterBootstrapBoolean $local["enabled"])) { $errors.Add("local_router.enabled must be a boolean.") }
    elseif ($mode -eq "router" -and -not [bool]$local["enabled"]) { $errors.Add("mode=router requires local_router.enabled=true.") }
    if ([string]$local["host"] -ne "127.0.0.1") { $errors.Add("local_router.host must stay loopback: 127.0.0.1") }
    if (-not (Test-RouterBootstrapIntegerInRange $local["port"] 1 65535)) { $errors.Add("local_router.port must be 1..65535.") }

    $clientAuth = $local["client_auth"]
    if (-not ($clientAuth -is [System.Collections.IDictionary])) {
        $errors.Add("local_router.client_auth must be a JSON object.")
    }
    elseif (Test-RouterBootstrapEntityFields $clientAuth @("mode", "token_ref") @("mode", "token_ref") "local_router.client_auth" $errors) {
        if ([string]$clientAuth["mode"] -ne "bearer_env_ref") { $errors.Add("local_router.client_auth.mode must be bearer_env_ref.") }
        if ([string]$clientAuth["token_ref"] -ne $script:Lr12TokenEnv) {
            $errors.Add("local_router.client_auth.token_ref must be $script:Lr12TokenEnv.")
        }
    }

    $limits = $local["limits"]
    if (-not ($limits -is [System.Collections.IDictionary])) {
        $errors.Add("local_router.limits must be a JSON object.")
    }
    elseif (Test-RouterBootstrapEntityFields $limits `
        @("max_request_bytes", "max_header_bytes", "max_connections", "shutdown_grace_ms") `
        @("max_request_bytes", "max_header_bytes", "max_connections", "shutdown_grace_ms") "local_router.limits" $errors) {
        if (-not (Test-RouterBootstrapIntegerInRange $limits["max_request_bytes"] 1 268435456)) { $errors.Add("local_router.limits.max_request_bytes is out of range.") }
        if (-not (Test-RouterBootstrapIntegerInRange $limits["max_header_bytes"] 1 1048576)) { $errors.Add("local_router.limits.max_header_bytes is out of range.") }
        if (-not (Test-RouterBootstrapIntegerInRange $limits["max_connections"] 1 1024)) { $errors.Add("local_router.limits.max_connections is out of range.") }
        if (-not (Test-RouterBootstrapIntegerInRange $limits["shutdown_grace_ms"] 1 120000)) { $errors.Add("local_router.limits.shutdown_grace_ms is out of range.") }
    }

    $threadSelection = $local["thread_selection"]
    if (-not ($threadSelection -is [System.Collections.IDictionary])) {
        $errors.Add("local_router.thread_selection must be a JSON object.")
    }
    elseif (Test-RouterBootstrapEntityFields $threadSelection `
        @("enabled", "pending_ttl_ms", "active_idle_ttl_ms", "quota_failover_enabled") `
        @("enabled", "pending_ttl_ms", "active_idle_ttl_ms") "local_router.thread_selection" $errors) {
        if (-not (Test-RouterBootstrapBoolean $threadSelection["enabled"])) { $errors.Add("local_router.thread_selection.enabled must be a boolean.") }
        if (-not (Test-RouterBootstrapIntegerInRange $threadSelection["pending_ttl_ms"] 30000 1800000)) { $errors.Add("local_router.thread_selection.pending_ttl_ms is out of range.") }
        if (-not (Test-RouterBootstrapIntegerInRange $threadSelection["active_idle_ttl_ms"] 3600000 604800000)) { $errors.Add("local_router.thread_selection.active_idle_ttl_ms is out of range.") }
        # HS-1C (mirrors RouterConfigValidator.ValidateThreadSelection): optional,
        # absent means false; when present it must be a JSON boolean (never a
        # string, number, null, array or object), and true requires
        # thread_selection.enabled=true.
        if ($threadSelection.Contains("quota_failover_enabled")) {
            $quotaFailover = $threadSelection["quota_failover_enabled"]
            if (-not (Test-RouterBootstrapBoolean $quotaFailover)) {
                $errors.Add("local_router.thread_selection.quota_failover_enabled must be a boolean.")
            }
            elseif ($quotaFailover -and -not ($threadSelection["enabled"] -is [bool] -and $threadSelection["enabled"])) {
                $errors.Add("local_router.thread_selection.quota_failover_enabled=true requires local_router.thread_selection.enabled=true.")
            }
        }
    }

    Get-RouterBootstrapClientErrors $Document $errors
    Get-RouterBootstrapProtocolRouteErrors $Document $errors
    Get-RouterBootstrapEndpointErrors $Document $errors
    Get-RouterBootstrapProviderRouteErrors $Document $errors
    Get-RouterBootstrapModelRouteErrors $Document $errors
    Get-RouterBootstrapRouteErrors $Document $errors
    Get-RouterBootstrapPolicyErrors $Document $errors
    return @($errors.ToArray())
}

function Get-RouterBootstrapClientErrors($Document, $Errors) {
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($client in (Get-RouterBootstrapEntityArray $Document "clients" $Errors)) {
        if (-not ($client -is [System.Collections.IDictionary])) { $Errors.Add("clients entries must be JSON objects."); continue }
        if (-not (Test-RouterBootstrapEntityFields $client `
            @("client_id", "adapter_id", "enabled", "auth_scope", "allowed_route_ids", "capabilities", "version") `
            @("client_id", "adapter_id", "enabled", "auth_scope", "version") "clients" $Errors)) { continue }
        $clientId = [string]$client["client_id"]
        if (-not (Test-RouterBootstrapPattern $clientId '^client\.[a-z0-9_]+$') -or -not $seen.Add($clientId)) {
            $Errors.Add("clients.client_id is invalid or duplicated: $clientId")
        }
        if (-not (Test-RouterBootstrapIntegerInRange $client["version"] 1 2147483647)) { $Errors.Add("clients.version must be an integer >= 1.") }
        if (-not (Test-RouterBootstrapBoolean $client["enabled"])) { $Errors.Add("clients.enabled must be a boolean.") }
        if (-not (Test-RouterBootstrapPattern ([string]$client["adapter_id"]) '^adapter\.[a-z0-9_.-]+$')) { $Errors.Add("clients.adapter_id is invalid.") }
        if ([string]::IsNullOrWhiteSpace([string]$client["auth_scope"])) { $Errors.Add("clients.auth_scope must not be empty.") }
        if ($client.Contains("allowed_route_ids") -and -not (Test-RouterBootstrapStringList $client["allowed_route_ids"] '^route\.[a-z0-9-]+$' $false)) {
            $Errors.Add("clients.allowed_route_ids is invalid.")
        }
        if ($client.Contains("capabilities") -and -not (Test-RouterBootstrapCapabilities $client["capabilities"] $true)) {
            $Errors.Add("clients.capabilities must be a non-empty known capability list.")
        }
    }
}

function Get-RouterBootstrapProtocolRouteErrors($Document, $Errors) {
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($route in (Get-RouterBootstrapEntityArray $Document "protocol_routes" $Errors)) {
        if (-not ($route -is [System.Collections.IDictionary])) { $Errors.Add("protocol_routes entries must be JSON objects."); continue }
        if (-not (Test-RouterBootstrapEntityFields $route `
            @("protocol_route_id", "ingress_protocol", "upstream_protocol", "adapter_id", "adapter_version", "capabilities", "loss_policy", "version") `
            @("protocol_route_id", "ingress_protocol", "upstream_protocol", "adapter_id", "adapter_version", "loss_policy", "version") "protocol_routes" $Errors)) { continue }
        $routeId = [string]$route["protocol_route_id"]
        if (-not (Test-RouterBootstrapPattern $routeId '^protocol-route\.[a-z0-9-]+$') -or -not $seen.Add($routeId)) {
            $Errors.Add("protocol_routes.protocol_route_id is invalid or duplicated: $routeId")
        }
        if (-not (Test-RouterBootstrapIntegerInRange $route["version"] 1 2147483647)) { $Errors.Add("protocol_routes.version must be an integer >= 1.") }
        if (-not (Test-RouterBootstrapPattern ([string]$route["ingress_protocol"]) '^[a-z0-9._-]+$') -or
            -not (Test-RouterBootstrapPattern ([string]$route["upstream_protocol"]) '^[a-z0-9._-]+$')) {
            $Errors.Add("protocol_routes protocol names are invalid.")
        }
        if (-not (Test-RouterBootstrapPattern ([string]$route["adapter_id"]) '^adapter\.[a-z0-9_.-]+$')) { $Errors.Add("protocol_routes.adapter_id is invalid.") }
        if ([string]::IsNullOrEmpty([string]$route["adapter_version"]) -or ([string]$route["adapter_version"]).Length -gt 32) { $Errors.Add("protocol_routes.adapter_version is invalid.") }
        if ([string]$route["loss_policy"] -ne "fail_closed") { $Errors.Add("protocol_routes.loss_policy must be fail_closed.") }
        if ($route.Contains("capabilities") -and -not (Test-RouterBootstrapCapabilities $route["capabilities"] $true)) {
            $Errors.Add("protocol_routes.capabilities must be a non-empty known capability list.")
        }
    }
}

function Get-RouterBootstrapEndpointErrors($Document, $Errors) {
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($endpoint in (Get-RouterBootstrapEntityArray $Document "endpoints" $Errors)) {
        if (-not ($endpoint -is [System.Collections.IDictionary])) { $Errors.Add("endpoints entries must be JSON objects."); continue }
        if (-not (Test-RouterBootstrapEntityFields $endpoint `
            @("endpoint_id", "base_url_ref", "enabled", "data_boundary", "tls_required", "priority", "weight", "version") `
            @("endpoint_id", "base_url_ref", "enabled", "data_boundary", "tls_required", "priority", "weight", "version") "endpoints" $Errors)) { continue }
        $endpointId = [string]$endpoint["endpoint_id"]
        if (-not (Test-RouterBootstrapPattern $endpointId '^endpoint\.[a-z0-9-]+$') -or -not $seen.Add($endpointId)) {
            $Errors.Add("endpoints.endpoint_id is invalid or duplicated: $endpointId")
        }
        if (-not (Test-RouterBootstrapIntegerInRange $endpoint["version"] 1 2147483647)) { $Errors.Add("endpoints.version must be an integer >= 1.") }
        if ([string]::IsNullOrWhiteSpace([string]$endpoint["base_url_ref"]) -or ([string]$endpoint["base_url_ref"]).Length -gt 256) { $Errors.Add("endpoints.base_url_ref is invalid.") }
        if (-not (Test-RouterBootstrapBoolean $endpoint["enabled"])) { $Errors.Add("endpoints.enabled must be a boolean.") }
        if (-not (Test-RouterBootstrapBoolean $endpoint["tls_required"])) { $Errors.Add("endpoints.tls_required must be a boolean.") }
        if ([string]$endpoint["data_boundary"] -notin @("provider-default", "residency-required", "no-store")) { $Errors.Add("endpoints.data_boundary is invalid.") }
        if (-not (Test-RouterBootstrapIntegerInRange $endpoint["priority"] 0 2147483647) -or
            -not (Test-RouterBootstrapIntegerInRange $endpoint["weight"] 0 2147483647)) {
            $Errors.Add("endpoints.priority/weight must be integers >= 0.")
        }
    }
}

function Get-RouterBootstrapProviderRouteErrors($Document, $Errors) {
    $knownProviders = @($script:Lr12SchemaProviderIds)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($route in (Get-RouterBootstrapEntityArray $Document "provider_routes" $Errors)) {
        if (-not ($route -is [System.Collections.IDictionary])) { $Errors.Add("provider_routes entries must be JSON objects."); continue }
        if (-not (Test-RouterBootstrapEntityFields $route `
            @("provider_route_id", "provider_id", "adapter_id", "adapter_version", "endpoint_ids", "secret_ref", "base_url_ref", "enabled", "capabilities", "version") `
            @("provider_route_id", "provider_id", "adapter_id", "adapter_version", "enabled", "version") "provider_routes" $Errors)) { continue }
        $routeId = [string]$route["provider_route_id"]
        if (-not (Test-RouterBootstrapPattern $routeId '^provider-route\.[a-z0-9-]+$') -or -not $seen.Add($routeId)) {
            $Errors.Add("provider_routes.provider_route_id is invalid or duplicated: $routeId")
        }
        if (-not (Test-RouterBootstrapIntegerInRange $route["version"] 1 2147483647)) { $Errors.Add("provider_routes.version must be an integer >= 1.") }
        $providerId = [string]$route["provider_id"]
        if ($providerId -notin $knownProviders) { $Errors.Add("provider_routes.provider_id is unknown: $providerId") }
        if (-not (Test-RouterBootstrapPattern ([string]$route["adapter_id"]) '^adapter\.[a-z0-9_.-]+$')) { $Errors.Add("provider_routes.adapter_id is invalid.") }
        if ([string]::IsNullOrEmpty([string]$route["adapter_version"]) -or ([string]$route["adapter_version"]).Length -gt 32) { $Errors.Add("provider_routes.adapter_version is invalid.") }
        if (-not (Test-RouterBootstrapBoolean $route["enabled"])) { $Errors.Add("provider_routes.enabled must be a boolean.") }
        if ($route.Contains("endpoint_ids") -and -not (Test-RouterBootstrapStringList $route["endpoint_ids"] '^endpoint\.[a-z0-9-]+$' $false)) {
            $Errors.Add("provider_routes.endpoint_ids is invalid.")
        }
        if ($route.Contains("base_url_ref") -and ([string]$route["base_url_ref"]).Length -gt 256) { $Errors.Add("provider_routes.base_url_ref is too long.") }
        if ($route.Contains("capabilities") -and -not (Test-RouterBootstrapCapabilities $route["capabilities"] $true)) {
            $Errors.Add("provider_routes.capabilities must be a non-empty known capability list.")
        }
        if ($route.Contains("secret_ref")) { Get-RouterBootstrapSecretReferenceErrors $route["secret_ref"] $providerId $Errors }
    }
}

function Get-RouterBootstrapSecretReferenceErrors($SecretRef, [string]$ProviderId, $Errors) {
    if (-not ($SecretRef -is [System.Collections.IDictionary])) { $Errors.Add("provider_routes.secret_ref must be a JSON object."); return }
    if (-not (Test-RouterBootstrapEntityFields $SecretRef `
        @("resolver", "name", "scope", "allowed_provider_ids", "version") `
        @("resolver", "name", "scope", "allowed_provider_ids", "version") "provider_routes.secret_ref" $Errors)) { return }
    if ([string]$SecretRef["resolver"] -ne "environment") { $Errors.Add("provider_routes.secret_ref.resolver must be environment.") }
    $name = [string]$SecretRef["name"]
    if (-not (Test-RouterBootstrapPattern $name '^[A-Z][A-Z0-9_]{2,127}$')) { $Errors.Add("provider_routes.secret_ref.name is invalid.") }
    if ([string]$SecretRef["scope"] -notin @("process", "user", "user_or_process")) { $Errors.Add("provider_routes.secret_ref.scope is invalid.") }
    if (-not (Test-RouterBootstrapStringList $SecretRef["allowed_provider_ids"] '^[a-z][a-z0-9_]*$' $true)) { $Errors.Add("provider_routes.secret_ref.allowed_provider_ids is invalid.") }
    if (-not (Test-RouterBootstrapIntegerInRange $SecretRef["version"] 1 2147483647)) { $Errors.Add("provider_routes.secret_ref.version must be an integer >= 1.") }
    $expectedEnv = ""
    if ($script:Lr12BootstrapProviderTable.Contains($ProviderId)) { $expectedEnv = [string]$script:Lr12BootstrapProviderTable[$ProviderId].SecretEnv }
    if (-not [string]::IsNullOrWhiteSpace($expectedEnv) -and $name -ne $expectedEnv) {
        $Errors.Add("provider_routes.secret_ref.name must be $expectedEnv for provider $ProviderId.")
    }
    foreach ($allowedProvider in @($SecretRef["allowed_provider_ids"])) {
        if ([string]$allowedProvider -ne $ProviderId) { $Errors.Add("provider_routes.secret_ref.allowed_provider_ids must contain only $ProviderId.") }
    }
}

function Get-RouterBootstrapModelRouteErrors($Document, $Errors) {
    $knownProviders = @($script:Lr12SchemaProviderIds)
    $modelPattern = '^[a-zA-Z0-9._/: -]+$'
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $scoped = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    # DSR2 client-slug ownership map: slug -> claiming enabled routes.
    $slugOwners = [ordered]@{}
    foreach ($route in (Get-RouterBootstrapEntityArray $Document "model_routes" $Errors)) {
        if (-not ($route -is [System.Collections.IDictionary])) { $Errors.Add("model_routes entries must be JSON objects."); continue }
        if (-not (Test-RouterBootstrapEntityFields $route `
            @("model_route_id", "provider_id", "client_model_id", "model_id", "upstream_model_id", "aliases", "capabilities", "pricing_ref", "identity_verification", "enabled", "version") `
            @("model_route_id", "provider_id", "client_model_id", "model_id", "upstream_model_id", "identity_verification", "enabled", "version") "model_routes" $Errors)) { continue }
        $routeId = [string]$route["model_route_id"]
        if (-not (Test-RouterBootstrapPattern $routeId '^model-route\.[a-z0-9-]+$') -or -not $seen.Add($routeId)) {
            $Errors.Add("model_routes.model_route_id is invalid or duplicated: $routeId")
        }
        if (-not (Test-RouterBootstrapIntegerInRange $route["version"] 1 2147483647)) { $Errors.Add("model_routes.version must be an integer >= 1.") }
        $providerId = [string]$route["provider_id"]
        if ($providerId -notin $knownProviders) { $Errors.Add("model_routes.provider_id is unknown: $providerId") }
        foreach ($field in @("client_model_id", "model_id", "upstream_model_id")) {
            if (-not (Test-RouterBootstrapPattern ([string]$route[$field]) $modelPattern)) { $Errors.Add("model_routes.$field is invalid: $($route[$field])") }
        }
        if (-not (Test-RouterBootstrapBoolean $route["enabled"])) { $Errors.Add("model_routes.enabled must be a boolean.") }
        if ([string]$route["identity_verification"] -ne "explicit_config") { $Errors.Add("model_routes.identity_verification must be explicit_config.") }
        if ($route.Contains("aliases") -and -not (Test-RouterBootstrapStringList $route["aliases"] "" $false)) { $Errors.Add("model_routes.aliases is invalid.") }
        if ($route.Contains("capabilities") -and -not (Test-RouterBootstrapCapabilities $route["capabilities"] $true)) {
            $Errors.Add("model_routes.capabilities must be a non-empty known capability list.")
        }
        $clientModelId = [string]$route["client_model_id"]
        $scopedKey = $providerId + "|" + $clientModelId
        if (-not $scoped.Add($scopedKey)) { $Errors.Add("model_routes maps $clientModelId twice for provider $providerId.") }

        # Catalog identity is provider-scoped, but a client-facing slug
        # (client_model_id or an explicit alias) may have exactly one enabled
        # owner: the Codex picker only sends the slug. Collisions fail closed.
        $routeEnabled = $true
        if ($null -ne $route["enabled"]) { $routeEnabled = [bool]$route["enabled"] }
        if ($routeEnabled) {
            $claimSlugs = @($clientModelId)
            if ($null -ne $route["aliases"]) {
                $claimSlugs += @($route["aliases"] | ForEach-Object { [string]$_ })
            }

            foreach ($claimSlug in $claimSlugs) {
                if ([string]::IsNullOrWhiteSpace($claimSlug)) { continue }
                if (-not $slugOwners.Contains($claimSlug)) { $slugOwners[$claimSlug] = New-Object System.Collections.Generic.List[string] }
                $slugOwners[$claimSlug].Add($providerId + ":" + [string]$route["model_route_id"])
            }
        }
    }
    foreach ($claimSlug in $slugOwners.Keys) {
        if ($slugOwners[$claimSlug].Count -gt 1) {
            $Errors.Add("CLIENT_MODEL_SLUG_COLLISION: client-facing model slug $claimSlug is claimed by more than one enabled route ($($slugOwners[$claimSlug] -join ', ')). Exactly one active owner per client slug is required.")
        }
    }
}

function Get-RouterBootstrapRouteErrors($Document, $Errors) {
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($route in (Get-RouterBootstrapEntityArray $Document "routes" $Errors)) {
        if (-not ($route -is [System.Collections.IDictionary])) { $Errors.Add("routes entries must be JSON objects."); continue }
        if (-not (Test-RouterBootstrapEntityFields $route `
            @("route_id", "client_ids", "provider_route_id", "protocol_route_id", "model_route_id", "enabled", "priority", "weight", "health_state", "timeout_policy_id", "retry_policy_id", "failover_policy_id", "fallback_route_ids", "created_at", "updated_at", "version") `
            @("route_id", "provider_route_id", "protocol_route_id", "model_route_id", "enabled", "priority", "weight", "health_state", "timeout_policy_id", "retry_policy_id", "failover_policy_id", "created_at", "updated_at", "version") "routes" $Errors)) { continue }
        $routeId = [string]$route["route_id"]
        if (-not (Test-RouterBootstrapPattern $routeId '^route\.[a-z0-9-]+$') -or -not $seen.Add($routeId)) {
            $Errors.Add("routes.route_id is invalid or duplicated: $routeId")
        }
        if (-not (Test-RouterBootstrapIntegerInRange $route["version"] 1 2147483647)) { $Errors.Add("routes.version must be an integer >= 1.") }
        if (-not (Test-RouterBootstrapBoolean $route["enabled"])) { $Errors.Add("routes.enabled must be a boolean.") }
        if (-not (Test-RouterBootstrapIntegerInRange $route["priority"] 0 2147483647) -or
            -not (Test-RouterBootstrapIntegerInRange $route["weight"] 0 2147483647)) {
            $Errors.Add("routes.priority/weight must be integers >= 0.")
        }
        if ([string]$route["health_state"] -notin @("UNKNOWN", "HEALTHY", "DEGRADED", "UNHEALTHY", "DISABLED")) { $Errors.Add("routes.health_state is invalid.") }
        if ($route.Contains("client_ids") -and -not (Test-RouterBootstrapStringList $route["client_ids"] '^client\.[a-z0-9_]+$' $false)) { $Errors.Add("routes.client_ids is invalid.") }
        if (-not (Test-RouterBootstrapPattern ([string]$route["provider_route_id"]) '^provider-route\.[a-z0-9-]+$')) { $Errors.Add("routes.provider_route_id is invalid.") }
        if (-not (Test-RouterBootstrapPattern ([string]$route["protocol_route_id"]) '^protocol-route\.[a-z0-9-]+$')) { $Errors.Add("routes.protocol_route_id is invalid.") }
        if (-not (Test-RouterBootstrapPattern ([string]$route["model_route_id"]) '^model-route\.[a-z0-9-]+$')) { $Errors.Add("routes.model_route_id is invalid.") }
        foreach ($field in @("timeout_policy_id", "retry_policy_id", "failover_policy_id")) {
            if (-not (Test-RouterBootstrapPattern ([string]$route[$field]) '^policy\.[a-z0-9-]+$')) { $Errors.Add("routes.$field is invalid.") }
        }
        foreach ($field in @("created_at", "updated_at")) {
            if ([string]::IsNullOrWhiteSpace((ConvertTo-RouterBootstrapTimestampString $route[$field]))) {
                $Errors.Add("routes.$field must be an RFC 3339 timestamp.")
            }
        }
        if ($route.Contains("fallback_route_ids") -and -not (Test-RouterBootstrapStringList $route["fallback_route_ids"] '^route\.[a-z0-9-]+$' $false)) {
            $Errors.Add("routes.fallback_route_ids is invalid.")
        }
    }
}

function Get-RouterBootstrapPolicyErrors($Document, $Errors) {
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($policy in (Get-RouterBootstrapEntityArray $Document "policies" $Errors)) {
        if (-not ($policy -is [System.Collections.IDictionary])) { $Errors.Add("policies entries must be JSON objects."); continue }
        if (-not (Test-RouterBootstrapEntityFields $policy @("policy_id", "version", "retry", "timeout", "failover") @("policy_id", "version") "policies" $Errors)) { continue }
        $policyId = [string]$policy["policy_id"]
        if (-not (Test-RouterBootstrapPattern $policyId '^policy\.[a-z0-9-]+$') -or -not $seen.Add($policyId)) {
            $Errors.Add("policies.policy_id is invalid or duplicated: $policyId")
        }
        if (-not (Test-RouterBootstrapIntegerInRange $policy["version"] 1 2147483647)) { $Errors.Add("policies.version must be an integer >= 1.") }
        if ($policy.Contains("retry")) {
            $retry = $policy["retry"]
            if (-not ($retry -is [System.Collections.IDictionary])) { $Errors.Add("policies.retry must be a JSON object.") }
            elseif (Test-RouterBootstrapEntityFields $retry `
                @("schema_version", "max_attempts", "base_delay_ms", "max_delay_ms", "jitter", "respect_retry_after", "max_retry_after_ms") `
                @("schema_version", "max_attempts", "base_delay_ms", "max_delay_ms", "jitter", "respect_retry_after", "max_retry_after_ms") "policies.retry" $Errors) {
                if (-not (Test-RouterBootstrapIntegerInRange $retry["schema_version"] 1 1) -or
                    -not (Test-RouterBootstrapIntegerInRange $retry["max_attempts"] 1 10) -or
                    -not (Test-RouterBootstrapIntegerInRange $retry["base_delay_ms"] 1 86400000) -or
                    -not (Test-RouterBootstrapIntegerInRange $retry["max_delay_ms"] 1 86400000) -or
                    -not (Test-RouterBootstrapIntegerInRange $retry["max_retry_after_ms"] 1 86400000) -or
                    [decimal]$retry["max_delay_ms"] -lt [decimal]$retry["base_delay_ms"]) {
                    $Errors.Add("policies.retry is out of range.")
                }
                if (-not (Test-RouterBootstrapBoolean $retry["respect_retry_after"])) { $Errors.Add("policies.retry.respect_retry_after must be a boolean.") }
            }
        }
        if ($policy.Contains("timeout")) {
            $timeout = $policy["timeout"]
            if (-not ($timeout -is [System.Collections.IDictionary])) { $Errors.Add("policies.timeout must be a JSON object.") }
            elseif (Test-RouterBootstrapEntityFields $timeout `
                @("schema_version", "connect_timeout_ms", "first_byte_timeout_ms", "idle_timeout_ms", "attempt_timeout_ms", "total_timeout_ms") `
                @("schema_version", "connect_timeout_ms", "first_byte_timeout_ms", "idle_timeout_ms", "attempt_timeout_ms", "total_timeout_ms") "policies.timeout" $Errors) {
                foreach ($field in @("connect_timeout_ms", "first_byte_timeout_ms", "idle_timeout_ms", "attempt_timeout_ms", "total_timeout_ms")) {
                    if (-not (Test-RouterBootstrapIntegerInRange $timeout[$field] 1 86400000)) { $Errors.Add("policies.timeout.$field is out of range.") }
                }
            }
        }
        if ($policy.Contains("failover")) {
            $failover = $policy["failover"]
            if (-not ($failover -is [System.Collections.IDictionary])) { $Errors.Add("policies.failover must be a JSON object.") }
            elseif (Test-RouterBootstrapEntityFields $failover `
                @("schema_version", "allow_same_model_alternate_endpoint", "allow_same_model_alternate_provider") `
                @("schema_version", "allow_same_model_alternate_endpoint", "allow_same_model_alternate_provider") "policies.failover" $Errors) {
                if (-not (Test-RouterBootstrapIntegerInRange $failover["schema_version"] 1 1)) { $Errors.Add("policies.failover.schema_version must be 1.") }
            }
        }
    }
}

# -- HS1B-RB1 bootstrap: route plan ------------------------------------------

# Builds the route topology from the canonical catalog, the canonical approval
# registry, and the production adapter table. Only a provider that has a
# production adapter, a canonical catalog mapping, an approved canonical model,
# and a present upstream secret reference produces a route.
function New-RouterBootstrapRoutePlan {
    $supported = New-Object System.Collections.Generic.List[string]
    $providerPlans = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $gaps = New-Object System.Collections.Generic.List[string]
    $claims = [ordered]@{}

    $catalogRecords = @(Read-CatalogRecords)
    $approvedRecords = @(Get-ApprovedModelRecords)

    foreach ($providerId in @($script:Lr12BootstrapProviderTable.Keys)) {
        $descriptor = $script:Lr12BootstrapProviderTable[$providerId]
        $catalogProviderId = Get-RouterBootstrapCatalogProviderId $providerId
        if ([string]::IsNullOrWhiteSpace($catalogProviderId)) {
            if ($providerId -eq "mm_openai_api") {
                $gaps.Add($script:Lr12OpenAiApiCapabilityGap + ": mm_openai_api has a production provider adapter but no canonical catalog provider entry, so no mm_openai_api route is bootstrapped. ChatGPT identity stays DIRECT_ONLY.")
            }
            else {
                $gaps.Add("ROUTER_PROVIDER_CATALOG_GAP: $providerId has no canonical catalog provider mapping.")
            }
            continue
        }

        $secretValue = Get-RouterCliUpstreamSecretEnvironmentValue ([string]$descriptor.SecretEnv)
        if ([string]::IsNullOrWhiteSpace($secretValue)) {
            $secretValue = $null
            $skipped.Add([pscustomobject]@{
                    provider_id = $providerId
                    secret_env = [string]$descriptor.SecretEnv
                    reason = "UPSTREAM_SECRET_REFERENCE_MISSING"
                })
            continue
        }
        $secretValue = $null

        $modelIds = New-Object System.Collections.Generic.List[string]
        foreach ($record in $catalogRecords) {
            if ([string]$record.provider_id -ne $providerId) { continue }
            if ([string]$record.catalog_provider_id -ne $catalogProviderId) { continue }
            $modelId = [string]$record.model_id
            if ([string]::IsNullOrWhiteSpace($modelId)) { continue }
            $approvedMatch = @($approvedRecords | Where-Object {
                    [string]$_.provider_id -eq $providerId -and [string]$_.model_id -eq $modelId
                })
            if ($approvedMatch.Count -eq 0) { continue }
            if (-not $modelIds.Contains($modelId)) { $modelIds.Add($modelId) }
        }

        if ($modelIds.Count -eq 0) {
            $skipped.Add([pscustomobject]@{
                    provider_id = $providerId
                    secret_env = [string]$descriptor.SecretEnv
                    reason = "NO_APPROVED_CANONICAL_MODEL"
                })
            continue
        }

        foreach ($modelId in $modelIds) {
            if (-not $claims.Contains($modelId)) { $claims[$modelId] = New-Object System.Collections.Generic.List[string] }
            if (-not $claims[$modelId].Contains($providerId)) { $claims[$modelId].Add($providerId) }
        }

        $supported.Add($providerId)
        $providerPlans.Add([pscustomobject]@{
                provider_id = $providerId
                short_id = [string]$descriptor.ShortId
                adapter_id = [string]$descriptor.AdapterId
                adapter_version = [string]$descriptor.AdapterVersion
                base_url_ref = [string]$descriptor.BaseUrlRef
                secret_env = [string]$descriptor.SecretEnv
                catalog_provider_id = $catalogProviderId
                model_ids = @($modelIds.ToArray() | Sort-Object)
            })
    }

    # DSR2 architecture decision D - client-slug ownership gate.
    #
    # Catalog identity is provider-scoped, so the same model_id may legitimately
    # exist under several providers. A *client-facing* slug (client_model_id or an
    # explicit alias) is different: the Codex picker only sends the slug, so
    # exactly one enabled route may own it. Any slug claimed by more than one
    # would-be active route fails closed here - never first/last wins, never
    # priority/weight/random selection.
    $slugOwners = [ordered]@{}
    foreach ($providerPlan in $providerPlans) {
        foreach ($modelId in @($providerPlan.model_ids)) {
            $slug = ConvertTo-RouterBootstrapSlug $modelId
            $routeKey = [string]$providerPlan.short_id + "-" + $slug
            foreach ($claim in (@($modelId) + @(Get-RouterBootstrapModelAliases $providerPlan.provider_id $modelId))) {
                if (-not $slugOwners.Contains($claim)) {
                    $slugOwners[$claim] = New-Object System.Collections.Generic.List[string]
                }

                $slugOwners[$claim].Add([string]$providerPlan.provider_id + " (" + $routeKey + ")")
            }
        }
    }

    $slugCollisions = New-Object System.Collections.Generic.List[string]
    foreach ($claim in $slugOwners.Keys) {
        if ($slugOwners[$claim].Count -gt 1) {
            $slugCollisions.Add($claim + " -> " + ($slugOwners[$claim] -join ", "))
        }
    }

    if ($slugCollisions.Count -gt 0) {
        throw ("Router route bootstrap fails closed: CLIENT_MODEL_SLUG_COLLISION. A client-facing model slug may have exactly one active owner, but these slugs are claimed by more than one enabled route: " + ($slugCollisions -join " | ") + ". Disable one provider's approval/route, or give that provider a distinct client-facing slug, before initializing.")
    }

    $generatedIds = New-Object System.Collections.Generic.List[string]
    foreach ($providerPlan in $providerPlans) {
        foreach ($modelId in @($providerPlan.model_ids)) {
            $slug = ConvertTo-RouterBootstrapSlug $modelId
            if ([string]::IsNullOrWhiteSpace($slug)) {
                throw "Router route bootstrap fails closed: model $modelId cannot be mapped to a legal Router id."
            }
            $generatedIds.Add("model-route." + $providerPlan.short_id + "-" + $slug)
            $generatedIds.Add("route." + $providerPlan.short_id + "-" + $slug)
        }
    }
    $collisions = @($generatedIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($collisions.Count -gt 0) {
        throw ("Router route bootstrap fails closed: model ids collide after canonicalization: " + ($collisions -join ", "))
    }

    # Honest provider gap report. A provider identity that only exists in Direct
    # Mode is never promoted into the Router by this bootstrap.
    $observed = New-Object System.Collections.Generic.List[string]
    foreach ($record in $approvedRecords) {
        $approvedProviderId = [string]$record.provider_id
        if ([string]::IsNullOrWhiteSpace($approvedProviderId)) { continue }
        if ($approvedProviderId -in @($script:Lr12BootstrapProviderTable.Keys)) { continue }
        if (-not $observed.Contains($approvedProviderId)) { $observed.Add($approvedProviderId) }
    }
    $codexConfigPath = Get-CodexConfigPath
    if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) {
        $configText = Get-Content -Raw -LiteralPath $codexConfigPath
        $topLevelProvider = [regex]::Match($configText, '(?im)^\s*model_provider\s*=\s*"([^"]+)"')
        if ($topLevelProvider.Success) {
            $directProviderId = [string]$topLevelProvider.Groups[1].Value
            if ($directProviderId -notin @($script:Lr12BootstrapProviderTable.Keys) -and -not $observed.Contains($directProviderId)) {
                $observed.Add($directProviderId)
            }
        }
    }
    foreach ($observedProviderId in $observed) {
        # DSR2: the direct DeepSeek identity is a supported Router provider, so
        # every remaining unknown provider is reported generically. Provider
        # identity is never inferred from a substring such as "deepseek".
        $gaps.Add($script:Lr12BootstrapUnknownProviderPrefix + ": provider `"" + $observedProviderId + "`" has no production Router provider adapter, no canonical catalog provider mapping, and therefore no provider_route/model_route/route mapping. Its Direct Mode configuration is never promoted into the Router by this bootstrap.")
    }

    $routableModels = New-Object System.Collections.Generic.List[string]
    foreach ($providerPlan in $providerPlans) {
        foreach ($modelId in @($providerPlan.model_ids)) {
            if (-not $routableModels.Contains($modelId)) { $routableModels.Add($modelId) }
        }
    }

    return [pscustomobject]@{
        SupportedProviders = @($supported.ToArray())
        ProviderPlans = @($providerPlans.ToArray())
        Skipped = @($skipped.ToArray())
        Gaps = @($gaps.ToArray())
        RoutableModels = @($routableModels.ToArray() | Sort-Object)
    }
}

function Get-RouterBootstrapReferenceErrors($Document) {
    $errors = New-Object System.Collections.Generic.List[string]
    $endpointIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($endpoint in @($Document["endpoints"])) {
        if ($null -ne $endpoint) { [void]$endpointIds.Add([string]$endpoint["endpoint_id"]) }
    }
    $clientIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($client in @($Document["clients"])) {
        if ($null -ne $client) { [void]$clientIds.Add([string]$client["client_id"]) }
    }
    $protocolRouteIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($route in @($Document["protocol_routes"])) {
        if ($null -ne $route) { [void]$protocolRouteIds.Add([string]$route["protocol_route_id"]) }
    }
    $policyIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($policy in @($Document["policies"])) {
        if ($null -ne $policy) { [void]$policyIds.Add([string]$policy["policy_id"]) }
    }
    $providerRoutes = @{}
    foreach ($route in @($Document["provider_routes"])) {
        if ($null -eq $route) { continue }
        $providerRoutes[[string]$route["provider_route_id"]] = $route
        foreach ($endpointId in @($route["endpoint_ids"])) {
            if (-not $endpointIds.Contains([string]$endpointId)) {
                $errors.Add("provider_route $($route["provider_route_id"]) references unknown endpoint $endpointId")
            }
        }
    }
    $modelRoutes = @{}
    foreach ($route in @($Document["model_routes"])) {
        if ($null -ne $route) { $modelRoutes[[string]$route["model_route_id"]] = $route }
    }
    foreach ($route in @($Document["routes"])) {
        if ($null -eq $route) { continue }
        $routeId = [string]$route["route_id"]
        foreach ($clientId in @($route["client_ids"])) {
            if (-not $clientIds.Contains([string]$clientId)) { $errors.Add("route $routeId references unknown client $clientId") }
        }
        $providerRoute = $providerRoutes[[string]$route["provider_route_id"]]
        if ($null -eq $providerRoute) {
            $errors.Add("route $routeId references unknown provider_route $($route["provider_route_id"])")
            continue
        }
        $modelRoute = $modelRoutes[[string]$route["model_route_id"]]
        if ($null -eq $modelRoute) {
            $errors.Add("route $routeId references unknown model_route $($route["model_route_id"])")
            continue
        }
        if (-not $protocolRouteIds.Contains([string]$route["protocol_route_id"])) {
            $errors.Add("route $routeId references unknown protocol_route $($route["protocol_route_id"])")
        }
        foreach ($field in @("timeout_policy_id", "retry_policy_id", "failover_policy_id")) {
            if (-not $policyIds.Contains([string]$route[$field])) { $errors.Add("route $routeId references unknown policy $($route[$field])") }
        }
        if ([string]$providerRoute["provider_id"] -ne [string]$modelRoute["provider_id"]) {
            $errors.Add("route $routeId links a provider_route and model_route of different providers.")
        }
    }
    return @($errors.ToArray())
}

# -- HS1B-RB1 bootstrap: entity builders and Initialize ----------------------

function New-RouterBootstrapClientEntry {
    return [ordered]@{
        client_id = $script:Lr12BootstrapClientId
        adapter_id = $script:Lr12BootstrapClientAdapterId
        enabled = $true
        auth_scope = $script:Lr12BootstrapClientAuthScope
        capabilities = @($script:Lr12BootstrapClientCapabilities)
        version = 1
    }
}

# DSR7-B-FIX1: the control-plane client is generated additively next to the
# execution client. Identity separation is carried by auth_scope alone (the
# Control Plane authorizes with ScopeRegistry.TryResolve("router:control-plane")),
# so this client never receives route ownership and never gets a second
# credential. The capabilities list reuses the already-declared bootstrap
# vocabulary because the production config validator requires every client to
# declare at least one known capability.
function New-RouterBootstrapControlPlaneClientEntry {
    return [ordered]@{
        client_id = $script:Lr12ControlPlaneClientId
        adapter_id = $script:Lr12ControlPlaneClientAdapterId
        enabled = $true
        auth_scope = $script:Lr12ControlPlaneClientAuthScope
        capabilities = @($script:Lr12BootstrapClientCapabilities)
        version = 1
    }
}

function New-RouterBootstrapProtocolRouteEntry {
    return [ordered]@{
        protocol_route_id = $script:Lr12BootstrapProtocolRouteId
        ingress_protocol = $script:Lr12BootstrapProtocolId
        upstream_protocol = $script:Lr12BootstrapProtocolId
        adapter_id = $script:Lr12BootstrapProtocolAdapterId
        adapter_version = $script:Lr12BootstrapProtocolAdapterVersion
        capabilities = @($script:Lr12BootstrapFullCapabilities)
        loss_policy = "fail_closed"
        version = 1
    }
}

function New-RouterBootstrapPolicyEntries {
    return @(
        [ordered]@{ policy_id = $script:Lr12BootstrapTimeoutPolicyId; version = 1 },
        [ordered]@{ policy_id = $script:Lr12BootstrapRetryPolicyId; version = 1 },
        [ordered]@{ policy_id = $script:Lr12BootstrapFailoverPolicyId; version = 1 }
    )
}

function New-RouterBootstrapEndpointEntry($ProviderPlan) {
    return [ordered]@{
        endpoint_id = "endpoint." + $ProviderPlan.short_id
        base_url_ref = $ProviderPlan.base_url_ref
        enabled = $true
        data_boundary = "provider-default"
        tls_required = $true
        priority = 100
        weight = 100
        version = 1
    }
}

function New-RouterBootstrapProviderRouteEntry($ProviderPlan) {
    return [ordered]@{
        provider_route_id = "provider-route." + $ProviderPlan.short_id
        provider_id = $ProviderPlan.provider_id
        adapter_id = $ProviderPlan.adapter_id
        adapter_version = $ProviderPlan.adapter_version
        endpoint_ids = @("endpoint." + $ProviderPlan.short_id)
        secret_ref = [ordered]@{
            resolver = "environment"
            name = $ProviderPlan.secret_env
            scope = "user_or_process"
            allowed_provider_ids = @($ProviderPlan.provider_id)
            version = 1
        }
        base_url_ref = $ProviderPlan.base_url_ref
        enabled = $true
        capabilities = @($script:Lr12BootstrapFullCapabilities)
        version = 1
    }
}

function New-RouterBootstrapModelRouteEntry($ProviderPlan, [string]$ModelId) {
    $slug = ConvertTo-RouterBootstrapSlug $ModelId
    return [ordered]@{
        model_route_id = "model-route." + $ProviderPlan.short_id + "-" + $slug
        provider_id = $ProviderPlan.provider_id
        client_model_id = $ModelId
        model_id = $ModelId
        upstream_model_id = $ModelId
        aliases = @(Get-RouterBootstrapModelAliases $ProviderPlan.provider_id $ModelId)
        capabilities = @($script:Lr12BootstrapModelCapabilities)
        pricing_ref = "pricing." + $ProviderPlan.provider_id + "." + $slug
        identity_verification = "explicit_config"
        enabled = $true
        version = 1
    }
}

function New-RouterBootstrapRouteEntry($ProviderPlan, [string]$ModelId, [string]$Timestamp) {
    $slug = ConvertTo-RouterBootstrapSlug $ModelId
    return [ordered]@{
        route_id = "route." + $ProviderPlan.short_id + "-" + $slug
        client_ids = @($script:Lr12BootstrapClientId)
        provider_route_id = "provider-route." + $ProviderPlan.short_id
        protocol_route_id = $script:Lr12BootstrapProtocolRouteId
        model_route_id = "model-route." + $ProviderPlan.short_id + "-" + $slug
        enabled = $true
        priority = 100
        weight = 100
        health_state = "UNKNOWN"
        timeout_policy_id = $script:Lr12BootstrapTimeoutPolicyId
        retry_policy_id = $script:Lr12BootstrapRetryPolicyId
        failover_policy_id = $script:Lr12BootstrapFailoverPolicyId
        fallback_route_ids = @()
        created_at = $Timestamp
        updated_at = $Timestamp
        version = 1
    }
}

function New-RouterBootstrapEntities($Plan, [string]$Timestamp) {
    $clients = New-Object System.Collections.Generic.List[object]
    $protocolRoutes = New-Object System.Collections.Generic.List[object]
    $providerRoutes = New-Object System.Collections.Generic.List[object]
    $endpoints = New-Object System.Collections.Generic.List[object]
    $modelRoutes = New-Object System.Collections.Generic.List[object]
    $routes = New-Object System.Collections.Generic.List[object]

    if (@($Plan.ProviderPlans).Count -gt 0) {
        $clients.Add((New-RouterBootstrapClientEntry))
        $clients.Add((New-RouterBootstrapControlPlaneClientEntry))
        $protocolRoutes.Add((New-RouterBootstrapProtocolRouteEntry))
    }

    # Every generated client owns a distinct auth_scope: ClientScopeRegistry
    # resolves a required scope by auth_scope alone, so two generated clients
    # sharing one scope would create an ambiguous identity boundary.
    $generatedScopes = @($clients | ForEach-Object { [string]$_["auth_scope"] })
    if (@($generatedScopes | Select-Object -Unique).Count -ne $generatedScopes.Count) {
        throw "Router bootstrap would generate duplicate client auth scopes."
    }
    foreach ($providerPlan in @($Plan.ProviderPlans)) {
        $endpoints.Add((New-RouterBootstrapEndpointEntry $providerPlan))
        $providerRoutes.Add((New-RouterBootstrapProviderRouteEntry $providerPlan))
        foreach ($modelId in @($providerPlan.model_ids)) {
            $modelRoutes.Add((New-RouterBootstrapModelRouteEntry $providerPlan $modelId))
            $routes.Add((New-RouterBootstrapRouteEntry $providerPlan $modelId $Timestamp))
        }
    }

    return [pscustomobject]@{
        Clients = @($clients.ToArray())
        ProtocolRoutes = @($protocolRoutes.ToArray())
        ProviderRoutes = @($providerRoutes.ToArray())
        Endpoints = @($endpoints.ToArray())
        ModelRoutes = @($modelRoutes.ToArray())
        Routes = @($routes.ToArray())
        Policies = @(New-RouterBootstrapPolicyEntries)
    }
}

# Additive merge: an entity that already exists keeps its exact definition; only
# missing ids are added. Nothing is ever removed or overwritten.
function Merge-RouterBootstrapEntityArray($Existing, $Generated, [string]$IdKey) {
    $result = New-Object System.Collections.Generic.List[object]
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($entity in @($Existing)) {
        if ($null -eq $entity) { continue }
        [void]$seen.Add([string]$entity[$IdKey])
        $result.Add($entity)
    }
    foreach ($entity in @($Generated)) {
        if ($null -eq $entity) { continue }
        if ($seen.Add([string]$entity[$IdKey])) { $result.Add($entity) }
    }
    return @($result.ToArray())
}

function New-RouterBootstrapTargetDocument($Effective, $Plan, [int]$Port, [string]$Timestamp) {
    $generated = New-RouterBootstrapEntities $Plan $Timestamp
    $local = $Effective["local_router"]
    $target = [ordered]@{}
    $target["schema_version"] = [int]$Effective["schema_version"]
    $target["version"] = [int]$Effective["version"]
    $target["mode"] = "router"
    $target["local_router"] = [ordered]@{
        enabled = $true
        host = "127.0.0.1"
        port = $Port
        client_auth = [ordered]@{
            mode = [string]$local["client_auth"]["mode"]
            token_ref = [string]$local["client_auth"]["token_ref"]
        }
        limits = [ordered]@{
            max_request_bytes = [int]$local["limits"]["max_request_bytes"]
            max_header_bytes = [int]$local["limits"]["max_header_bytes"]
            max_connections = [int]$local["limits"]["max_connections"]
            shutdown_grace_ms = [int]$local["limits"]["shutdown_grace_ms"]
        }
        thread_selection = [ordered]@{
            enabled = [bool]$local["thread_selection"]["enabled"]
            pending_ttl_ms = [int]$local["thread_selection"]["pending_ttl_ms"]
            active_idle_ttl_ms = [int]$local["thread_selection"]["active_idle_ttl_ms"]
        }
    }
    Copy-RouterBootstrapQuotaFailoverSetting $local["thread_selection"] $target["local_router"]["thread_selection"]
    $target["clients"] = @(Merge-RouterBootstrapEntityArray $Effective["clients"] $generated.Clients "client_id")
    $target["protocol_routes"] = @(Merge-RouterBootstrapEntityArray $Effective["protocol_routes"] $generated.ProtocolRoutes "protocol_route_id")
    $target["provider_routes"] = @(Merge-RouterBootstrapEntityArray $Effective["provider_routes"] $generated.ProviderRoutes "provider_route_id")
    $target["endpoints"] = @(Merge-RouterBootstrapEntityArray $Effective["endpoints"] $generated.Endpoints "endpoint_id")
    $target["model_routes"] = @(Merge-RouterBootstrapEntityArray $Effective["model_routes"] $generated.ModelRoutes "model_route_id")
    $target["routes"] = @(Merge-RouterBootstrapEntityArray $Effective["routes"] $generated.Routes "route_id")
    $target["policies"] = @(Merge-RouterBootstrapEntityArray $Effective["policies"] $generated.Policies "policy_id")
    $target["updated_at"] = $Timestamp
    return $target
}

# HS-1C: an explicit quota_failover_enabled setting survives regeneration and
# canonicalization exactly as the user wrote it. The raw value is copied without
# a [bool] cast, so an invalid type is never masked and is rejected by
# Get-RouterBootstrapDocumentErrors on the generated document. An absent setting
# stays absent (default false): Initialize never adds or enables it.
function Copy-RouterBootstrapQuotaFailoverSetting($SourceThreadSelection, $TargetThreadSelection) {
    if ($SourceThreadSelection -is [System.Collections.IDictionary] -and $SourceThreadSelection.Contains("quota_failover_enabled")) {
        $TargetThreadSelection["quota_failover_enabled"] = $SourceThreadSelection["quota_failover_enabled"]
    }
}

# Canonical field order for every entity kind, mirroring the schema documents.
function ConvertTo-RouterBootstrapCanonicalDocument($Document) {
    $local = $Document["local_router"]
    $canonical = [ordered]@{}
    $canonical["schema_version"] = [int]$Document["schema_version"]
    $canonical["version"] = [int]$Document["version"]
    $canonical["mode"] = [string]$Document["mode"]
    $canonical["local_router"] = [ordered]@{
        enabled = [bool]$local["enabled"]
        host = [string]$local["host"]
        port = [int]$local["port"]
        client_auth = [ordered]@{
            mode = [string]$local["client_auth"]["mode"]
            token_ref = [string]$local["client_auth"]["token_ref"]
        }
        limits = [ordered]@{
            max_request_bytes = [int]$local["limits"]["max_request_bytes"]
            max_header_bytes = [int]$local["limits"]["max_header_bytes"]
            max_connections = [int]$local["limits"]["max_connections"]
            shutdown_grace_ms = [int]$local["limits"]["shutdown_grace_ms"]
        }
        thread_selection = [ordered]@{
            enabled = [bool]$local["thread_selection"]["enabled"]
            pending_ttl_ms = [int]$local["thread_selection"]["pending_ttl_ms"]
            active_idle_ttl_ms = [int]$local["thread_selection"]["active_idle_ttl_ms"]
        }
    }
    Copy-RouterBootstrapQuotaFailoverSetting $local["thread_selection"] $canonical["local_router"]["thread_selection"]
    $canonical["clients"] = @(ConvertTo-RouterBootstrapCanonicalEntities $Document["clients"] "client_id" @(
            "client_id", "adapter_id", "enabled", "auth_scope", "allowed_route_ids", "capabilities", "version"
        ))
    $canonical["protocol_routes"] = @(ConvertTo-RouterBootstrapCanonicalEntities $Document["protocol_routes"] "protocol_route_id" @(
            "protocol_route_id", "ingress_protocol", "upstream_protocol", "adapter_id", "adapter_version", "capabilities", "loss_policy", "version"
        ))
    $canonical["provider_routes"] = @(ConvertTo-RouterBootstrapCanonicalEntities $Document["provider_routes"] "provider_route_id" @(
            "provider_route_id", "provider_id", "adapter_id", "adapter_version", "endpoint_ids", "secret_ref", "base_url_ref", "enabled", "capabilities", "version"
        ))
    $canonical["endpoints"] = @(ConvertTo-RouterBootstrapCanonicalEntities $Document["endpoints"] "endpoint_id" @(
            "endpoint_id", "base_url_ref", "enabled", "data_boundary", "tls_required", "priority", "weight", "version"
        ))
    $canonical["model_routes"] = @(ConvertTo-RouterBootstrapCanonicalEntities $Document["model_routes"] "model_route_id" @(
            "model_route_id", "provider_id", "client_model_id", "model_id", "upstream_model_id", "aliases", "capabilities", "pricing_ref", "identity_verification", "enabled", "version"
        ))
    $canonical["routes"] = @(ConvertTo-RouterBootstrapCanonicalEntities $Document["routes"] "route_id" @(
            "route_id", "client_ids", "provider_route_id", "protocol_route_id", "model_route_id", "enabled", "priority", "weight", "health_state", "timeout_policy_id", "retry_policy_id", "failover_policy_id", "fallback_route_ids", "created_at", "updated_at", "version"
        ))
    $canonical["policies"] = @(ConvertTo-RouterBootstrapCanonicalEntities $Document["policies"] "policy_id" @(
            "policy_id", "version", "retry", "timeout", "failover"
        ))
    $canonical["updated_at"] = ConvertTo-RouterBootstrapTimestampString $Document["updated_at"]
    return $canonical
}

function ConvertTo-RouterBootstrapCanonicalEntities($Entities, [string]$IdKey, [string[]]$FieldOrder) {
    $byId = [ordered]@{}
    foreach ($entity in @($Entities)) {
        if ($null -eq $entity) { continue }
        $byId[[string]$entity[$IdKey]] = $entity
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($id in @($byId.Keys | Sort-Object)) {
        $entity = $byId[$id]
        $entry = [ordered]@{}
        foreach ($field in $FieldOrder) {
            if (-not $entity.Contains($field)) { continue }
            if ($field -in @("created_at", "updated_at")) {
                $entry[$field] = ConvertTo-RouterBootstrapTimestampString $entity[$field]
                continue
            }
            $entry[$field] = $entity[$field]
        }
        $list.Add($entry)
    }
    return @($list.ToArray())
}

function Get-RouterBootstrapComparableJson($CanonicalDocument) {
    # Timestamps are the only non-deterministic fields, so they are excluded from
    # the idempotency comparison (RouterConfigNormalizer's generation input also
    # drops updated_at).
    $copy = [ordered]@{}
    foreach ($key in $CanonicalDocument.Keys) {
        if ($key -eq "updated_at") { continue }
        if ($key -eq "routes") {
            $routes = New-Object System.Collections.Generic.List[object]
            foreach ($route in @($CanonicalDocument[$key])) {
                $stripped = [ordered]@{}
                foreach ($routeKey in $route.Keys) {
                    if ($routeKey -in @("created_at", "updated_at")) { continue }
                    $stripped[$routeKey] = $route[$routeKey]
                }
                $routes.Add($stripped)
            }
            $copy[$key] = @($routes.ToArray())
            continue
        }
        $copy[$key] = $CanonicalDocument[$key]
    }
    return ($copy | ConvertTo-Json -Depth 20 -Compress)
}

function New-RouterBootstrapBackup([string]$SourcePath) {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { return $null }
    $receiptId = "router-bootstrap-" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss") + "-" + ([guid]::NewGuid().ToString("N").Substring(0, 8))
    $codexHome = Get-CodexHome
    $backupDir = Join-Path $codexHome ("backups/router-cli-bootstrap/" + $receiptId)
    Ensure-Directory $backupDir
    $backupPath = Join-Path $backupDir "router.config.json"
    Copy-Item -LiteralPath $SourcePath -Destination $backupPath -Force
    $beforeSha = Get-FileSha256 $SourcePath
    $receipt = [ordered]@{
        schema_version = $script:Lr12SchemaVersion
        receipt_id = $receiptId
        operation = "initialize"
        created_at = (Get-Date).ToUniversalTime().ToString("o")
        source = $SourcePath
        backup_path = $backupPath
        before_sha256 = $beforeSha
    }
    $receiptRoot = Join-Path $codexHome "multimodel-manager/router-bootstrap-receipts"
    Ensure-Directory $receiptRoot
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $receiptRoot ($receiptId + ".json")) -Encoding UTF8
    return [pscustomobject]@{ Id = $receiptId; BackupPath = $backupPath; BeforeSha256 = [string]$beforeSha }
}

# Router bootstrap state ladder used by Initialize and Doctor. Every field is
# derived from local files/loopback health only; no provider request is made.
function Get-RouterBootstrapInventory([switch]$Ping) {
    $configPath = Get-RouterCliConfigPath
    $router = Read-RouterUserConfig
    $state = $null
    $stateError = ""
    try { $state = Get-RouterCliState } catch { $stateError = $_.Exception.Message }
    $codexConfigPath = Get-CodexConfigPath
    $providerBlockPresent = $false
    if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) {
        $providerBlockPresent = (Get-Content -Raw -LiteralPath $codexConfigPath).Contains($script:Lr12BaseBeginMarker)
    }
    $profilePresent = Test-ProfileOwned (Get-RouterCliProfilePath)
    $tokenPresent = Test-TokenEnvPresent
    $routeConfig = Get-RouterRouteConfig @{}
    $available = @()
    try { $available = @(Get-RouterCliAvailableModels) } catch { $available = @() }
    $runtimeReachable = $null
    if ($Ping -and $router.Valid -and $router.Enabled) {
        $healthUrl = ("http://{0}:{1}/health" -f $router.Host, $router.Port)
        try {
            $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 3
            $payload = $response.Content | ConvertFrom-Json
            $runtimeReachable = ($null -ne $payload.ready -and [bool]$payload.ready)
        }
        catch {
            $runtimeReachable = $false
        }
    }

    $routerEnabled = ($null -ne $state -and [string]$state.mode -eq "router" -and $providerBlockPresent)
    $bootstrapState = "NOT_INITIALIZED"
    if ($router.Exists -and $router.Valid -and $tokenPresent) {
        $bootstrapState = "INITIALIZED"
        if ($routerEnabled) { $bootstrapState = "ROUTER_ENABLED" }
        if ($routerEnabled -and $runtimeReachable -eq $true) { $bootstrapState = "ROUTER_READY" }
    }

    return [pscustomobject]@{
        State = $bootstrapState
        ConfigPath = $configPath
        ConfigExists = $router.Exists
        ConfigValid = $router.Valid
        ConfigError = $router.Error
        RouterDeclaredEnabled = $router.Enabled
        Host = $router.Host
        Port = $router.Port
        TokenPresent = $tokenPresent
        # Count through the null-safe helper: a config with no routes must
        # report 0, never the PowerShell @($null).Count == 1 artifact.
        ProviderRouteCount = Get-RouterCollectionCount $routeConfig.ProviderRoutes
        ModelRouteCount = Get-RouterCollectionCount $routeConfig.ModelRoutes
        RouteCount = Get-RouterCollectionCount $routeConfig.Routes
        RoutableModelCount = @($available).Count
        ProviderBlockPresent = $providerBlockPresent
        ProfilePresent = $profilePresent
        RuntimeReachable = $runtimeReachable
        CodexConfigPath = $codexConfigPath
        StateError = $stateError
    }
}

function Initialize-RouterCli {
    param([switch]$Force)

    $configPath = Get-RouterCliConfigPath
    $defaultsPath = Get-RouterBootstrapDefaultsPath
    $codexConfigPath = Get-CodexConfigPath
    $directConfigBefore = if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) { Get-Content -Raw -LiteralPath $codexConfigPath } else { $null }

    $defaultsDocument = Read-RouterBootstrapJsonObject $defaultsPath "defaults"
    $defaultsErrors = @(Get-RouterBootstrapDocumentErrors $defaultsDocument)
    if ($defaultsErrors.Count -gt 0) {
        throw ("Canonical Router defaults are not schema-v1 valid: " + ($defaultsErrors -join " | "))
    }

    $configExists = Test-Path -LiteralPath $configPath -PathType Leaf
    if ($configExists) {
        $userDocument = Read-RouterBootstrapJsonObject $configPath "user config"
        $effective = Merge-RouterBootstrapEffectiveDocument $defaultsDocument $userDocument
        $userErrors = @(Get-RouterBootstrapDocumentErrors $effective)
        if ($userErrors.Count -gt 0) {
            throw ("Router user config is not schema-v1 valid; refusing to modify it: " + ($userErrors -join " | "))
        }
    }
    else {
        $effective = Merge-RouterBootstrapEffectiveDocument $defaultsDocument $null
    }

    $port = [int]$effective["local_router"]["port"]
    $plan = New-RouterBootstrapRoutePlan

    $timestamp = (Get-Date).ToUniversalTime().ToString("o")
    $target = New-RouterBootstrapTargetDocument $effective $plan $port $timestamp
    $targetCanonical = ConvertTo-RouterBootstrapCanonicalDocument $target
    $targetErrors = @(Get-RouterBootstrapDocumentErrors $targetCanonical)
    if ($targetErrors.Count -gt 0) {
        throw ("Generated Router config failed schema validation; nothing was written: " + ($targetErrors -join " | "))
    }
    $referenceErrors = @(Get-RouterBootstrapReferenceErrors $targetCanonical)
    if ($referenceErrors.Count -gt 0) {
        throw ("Generated Router config failed reference validation; nothing was written: " + ($referenceErrors -join " | "))
    }

    $changed = $true
    $existingCanonical = $null
    if ($configExists) {
        $existingCanonical = ConvertTo-RouterBootstrapCanonicalDocument $effective
        $changed = ((Get-RouterBootstrapComparableJson $targetCanonical) -ne (Get-RouterBootstrapComparableJson $existingCanonical))
    }

    $tokenResult = Initialize-RouterCliLocalClientToken

    $backup = $null
    if ($changed) {
        if ($configExists) { $backup = New-RouterBootstrapBackup $configPath }
        Ensure-Directory (Split-Path -Parent $configPath)
        $json = $targetCanonical | ConvertTo-Json -Depth 20
        Write-Utf8NoBom $configPath ($json + "`r`n")
    }

    # Direct Mode projection must be byte-identical; Initialize never writes it.
    $directConfigAfter = if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) { Get-Content -Raw -LiteralPath $codexConfigPath } else { $null }
    if ($directConfigBefore -ne $directConfigAfter) {
        throw "Router bootstrap unexpectedly modified the Codex config.toml; Direct Mode projection is no longer byte-identical."
    }

    $writeLabel = if (-not $changed) { "unchanged (idempotent)" } elseif ($configExists) { "updated (existing config preserved)" } else { "created" }
    Write-Host ""
    Write-Host "Codex Multi-Model Manager - Local Router bootstrap" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor DarkGray
    Write-Host ("Router user config   : {0}" -f $configPath) -ForegroundColor White
    Write-Host ("Config write         : {0}" -f $writeLabel) -ForegroundColor Green
    Write-Host ("Backup               : {0}" -f $(if ($null -eq $backup) { "-" } else { $backup.BackupPath })) -ForegroundColor White
    Write-Host "Router schema        : schema-v1 VALID" -ForegroundColor Green
    Write-Host ("Router mode          : {0} (local_router.enabled={1})" -f $targetCanonical["mode"], $targetCanonical["local_router"]["enabled"]) -ForegroundColor White
    Write-Host ("Router host/port     : {0}:{1}" -f $targetCanonical["local_router"]["host"], $targetCanonical["local_router"]["port"]) -ForegroundColor White
    Write-Host ("Codex config.toml    : untouched ({0})" -f $codexConfigPath) -ForegroundColor White
    Write-Host ("Local client token   : {0} = PRESENT ({1})" -f $script:Lr12TokenEnv, $(if ($tokenResult.Created) { "created" } else { "reused" })) -ForegroundColor Green
    Write-Host ("Token store          : {0}" -f $tokenResult.Store) -ForegroundColor White
    Write-Host ("Router-supported     : {0}" -f (@($script:Lr12BootstrapProviderTable.Keys) -join ", ")) -ForegroundColor White
    Write-Host ("Routable providers   : {0}" -f $(if (@($plan.SupportedProviders).Count -eq 0) { "none" } else { (@($plan.SupportedProviders) -join ", ") })) -ForegroundColor White
    Write-Host ("Provider routes      : {0}" -f @($targetCanonical["provider_routes"]).Count) -ForegroundColor White
    Write-Host ("Model routes         : {0}" -f @($targetCanonical["model_routes"]).Count) -ForegroundColor White
    Write-Host ("Full routes          : {0}" -f @($targetCanonical["routes"]).Count) -ForegroundColor White
    Write-Host ("Routable models      : {0} ({1})" -f @($plan.RoutableModels).Count, $(if (@($plan.RoutableModels).Count -eq 0) { "-" } else { (@($plan.RoutableModels) -join ", ") })) -ForegroundColor White
    foreach ($skip in @($plan.Skipped)) {
        Write-Host ("Skipped provider     : {0} requires {1} [{2}]" -f $skip.provider_id, $skip.secret_env, $skip.reason) -ForegroundColor Yellow
    }
    foreach ($gap in @($plan.Gaps)) {
        Write-Host ("Gap                  : {0}" -f $gap) -ForegroundColor Yellow
    }

    if (@($plan.RoutableModels).Count -eq 0) {
        Write-Host "Route bootstrap      : STOPPED - no approved Router-supported model with a present upstream secret reference. No route was fabricated." -ForegroundColor Yellow
    }
    Write-Host "Router ready         : NO (declaration only; the Router runtime is not started and Codex still uses Direct Mode)" -ForegroundColor Yellow
    Write-Host ("Next step            : {0} -Action Enable -Model <model>" -f (Join-Path $PSScriptRoot "router-codex-cli.ps1")) -ForegroundColor White
    Write-Host ""
}

function Enable-RouterCli {
    param(
        [string]$Model = "",
        [string]$Effort = "",
        [switch]$Force
    )

    $router = Read-RouterUserConfig
    if (-not $router.Valid) {
        throw "Local Router user config is invalid or corrupt: $($router.Path) ($($router.Error))"
    }
    if (-not $router.Enabled) {
        throw "Local Router is not enabled. Set router.config.json mode='router' and local_router.enabled=true before enabling Router CLI."
    }

    $state = Get-RouterCliState
    $effectiveModel = if ([string]::IsNullOrWhiteSpace($Model)) { [string]$state.selected_model } else { $Model }
    if ([string]::IsNullOrWhiteSpace($effectiveModel)) {
        if ($Force) {
            $available = @(Get-RouterCliAvailableModels)
            if ($available.Count -gt 0) {
                $hint = "Use -Model <id>, for example -Model " + $available[0].model_id
            }
            else {
                $hint = "no approved Router route is configured yet"
            }
            throw "A Router model is required. $hint"
        }
        $effectiveModel = Read-RouterModelInteractive
    }
    $effectiveEffort = if ([string]::IsNullOrWhiteSpace($Effort)) { if ([string]::IsNullOrWhiteSpace([string]$state.reasoning_effort)) { "medium" } else { [string]$state.reasoning_effort } } else { $Effort }
    if ([string]::IsNullOrWhiteSpace($effectiveEffort)) { $effectiveEffort = "medium" }

    [void](Assert-RouterModelValid $effectiveModel)
    Assert-RouterEffortSupported $effectiveModel $effectiveEffort
    $earlyProfilePath = Get-RouterCliProfilePath
    if ((Test-Path -LiteralPath $earlyProfilePath -PathType Leaf) -and -not (Test-ProfileOwned $earlyProfilePath)) {
        throw "Refusing to overwrite existing non-Router profile file: $earlyProfilePath"
    }
    [void](Register-RouterProviderOwner "client.codex_cli")

    $configPath = Get-CodexConfigPath
    $profilePath = Get-RouterCliProfilePath
    $codexHome = Get-CodexHome
    Ensure-Directory $codexHome
    Ensure-Directory (Split-Path -Parent $configPath)
    Ensure-Directory (Split-Path -Parent $profilePath)
    if ((Test-Path -LiteralPath $profilePath -PathType Leaf) -and -not (Test-ProfileOwned $profilePath)) {
        throw "Refusing to overwrite existing non-Router profile file: $profilePath"
    }

    $alreadyMatches = ($state.mode -eq "router" -and [int]$state.port -eq $router.Port -and [string]$state.host -eq $router.Host)
    $profileMatches = Test-ProfileMatches $profilePath $effectiveModel $effectiveEffort
    $configPort = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $configPort = Read-CurrentProviderPort (Get-Content -Raw -LiteralPath $configPath)
    }
    if ($alreadyMatches -and $profileMatches -and $configPort -eq $router.Port) {
        Write-Host "Router CLI is already enabled (generation $($state.generation)). No changes made." -ForegroundColor Green
        return
    }

    if (-not $Force) {
        $ok = Read-YesNo "Enable Codex CLI Router Mode (backup first, then point Codex only at the Local Router)?" $false
        if (-not $ok) {
            Write-Host "Cancelled. Router CLI remains disabled." -ForegroundColor Yellow
            return
        }
    }

    $nextGeneration = [int]$state.generation + 1
    $receiptInfo = New-RouterCliBackupReceipt $nextGeneration

    $configText = if (Test-Path -LiteralPath $configPath -PathType Leaf) { Get-Content -Raw -LiteralPath $configPath } else { "" }
    $newConfigText = Set-RouterProviderBlockInConfig $configText $router.Port
    Write-Utf8NoBom $configPath $newConfigText

    $profileBody = Get-RouterProfileBody $effectiveModel $effectiveEffort
    Write-Utf8NoBom $profilePath ($profileBody + "`r`n")

    Update-RouterCliReceiptAfterHashes $receiptInfo.Id

    $state.mode = "router"
    $state.generation = $nextGeneration
    $state.selected_model = $effectiveModel
    $state.reasoning_effort = $effectiveEffort
    $state.host = $router.Host
    $state.port = $router.Port
    $state.provider_id = $script:Lr12ProviderId
    $state.token_env = $script:Lr12TokenEnv
    $state.enabled_at = (Get-Date).ToUniversalTime().ToString("o")
    $state.backup_receipt = $receiptInfo.Id
    if ([string]::IsNullOrWhiteSpace([string]$state.first_backup_receipt)) {
        $state.first_backup_receipt = $receiptInfo.Id
    }
    $state.updated_at = (Get-Date).ToUniversalTime().ToString("o")
    Save-RouterCliState $state

    Write-Host "Router CLI enabled." -ForegroundColor Green
    Write-Host ("Provider     : {0}" -f $script:Lr12ProviderId) -ForegroundColor White
    Write-Host ("Base URL     : http://{0}:{1}/v1" -f $router.Host, $router.Port) -ForegroundColor White
    Write-Host ("Profile      : {0}" -f $profilePath) -ForegroundColor White
    Write-Host ("Model        : {0}" -f $effectiveModel) -ForegroundColor White
    Write-Host ("Token env    : {0}" -f $script:Lr12TokenEnv) -ForegroundColor White
    Write-Host ("Generation    : {0}" -f $nextGeneration) -ForegroundColor White
    Write-Host ("Backup       : {0}" -f $receiptInfo.Id) -ForegroundColor White
}

function Disable-RouterCli {
    param([switch]$Force)

    $state = Get-RouterCliState
    $configPath = Get-CodexConfigPath
    $profilePath = Get-RouterCliProfilePath
    $profilePresent = Test-Path -LiteralPath $profilePath -PathType Leaf
    $blockPresent = $false
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $blockPresent = (Get-Content -Raw -LiteralPath $configPath).Contains($script:Lr12BaseBeginMarker)
    }

    if ($state.mode -ne "router" -and -not $profilePresent -and -not $blockPresent) {
        Write-Host "Router CLI is already disabled. No changes made." -ForegroundColor Green
        return
    }

    if (-not $Force) {
        $ok = Read-YesNo "Disable Codex CLI Router Mode and restore Direct Mode (exact backup restore)?" $false
        if (-not $ok) {
            Write-Host "Cancelled. Router CLI stays enabled." -ForegroundColor Yellow
            return
        }
    }

    $unregisterResult = Unregister-RouterProviderOwner "client.codex_cli"
    $warnings = @()
    $otherOwnerRemains = $unregisterResult.WasRegistered -and -not $unregisterResult.WasLast

    if ($otherOwnerRemains) {
        # A Desktop Router owner still needs the shared mm_local_router block.
        # Restore only CLI-owned artifacts and leave the provider block intact.
        if (Test-ProfileOwned $profilePath) {
            Remove-Item -LiteralPath $profilePath -Force
        }
        Write-Host "Router CLI disabled. Shared mm_local_router block preserved for the remaining Router client owner." -ForegroundColor Green
    }
    else {
        if ($unregisterResult.DesktopRegisteredEver) {
            Remove-RouterCliSharedLastOwnerArtifacts $configPath $profilePath
        }
        else {
            $receipt = Get-RouterCliReceipt ([string]$state.first_backup_receipt)
            if ($null -eq $receipt) {
                $receipt = Get-RouterCliReceipt ([string]$state.backup_receipt)
            }
            if ($null -eq $receipt) {
                throw "Router CLI backup receipt is missing. Refusing destructive cleanup without a receipt."
            }
            $warnings = @(Restore-RouterCliFiles $receipt -Force:$Force)
            Remove-Item -LiteralPath ([string]$unregisterResult.BaselineDir) -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Get-RouterProviderOwnersPath) -Force -ErrorAction SilentlyContinue
        }
        if (Test-ProfileOwned $profilePath) {
            Remove-Item -LiteralPath $profilePath -Force
        }
        Write-Host "Router CLI disabled. Direct Mode is the active launch path." -ForegroundColor Green
    }

    $state.mode = "direct"
    $state.generation = [int]$state.generation + 1
    $state.enabled_at = $null
    $state.first_backup_receipt = ""
    $state.updated_at = (Get-Date).ToUniversalTime().ToString("o")
    Save-RouterCliState $state

    foreach ($warning in $warnings) {
        Write-Host "WARN $warning" -ForegroundColor Yellow
    }
}

function Select-RouterCliModel {
    param(
        [string]$Model,
        [string]$Effort = ""
    )
    $state = Get-RouterCliState
    if ($state.mode -ne "router") {
        throw "Router CLI is not enabled. Enable it before selecting a Router model."
    }
    if ([string]::IsNullOrWhiteSpace($Model)) {
        throw "A model ID is required."
    }
    [void](Assert-RouterModelValid $Model)
    $effectiveEffort = if ([string]::IsNullOrWhiteSpace($Effort)) { [string]$state.reasoning_effort } else { $Effort }
    if ([string]::IsNullOrWhiteSpace($effectiveEffort)) { $effectiveEffort = "medium" }
    Assert-RouterEffortSupported $Model $effectiveEffort

    $profilePath = Get-RouterCliProfilePath
    if (-not (Test-ProfileOwned $profilePath)) {
        throw "Router profile is missing or not Router-owned: $profilePath"
    }
    $body = Get-RouterProfileBody $Model $effectiveEffort
    Write-Utf8NoBom $profilePath ($body + "`r`n")

    $state.selected_model = $Model
    $state.reasoning_effort = $effectiveEffort
    $state.generation = [int]$state.generation + 1
    $state.updated_at = (Get-Date).ToUniversalTime().ToString("o")
    Save-RouterCliState $state
    Update-RouterCliReceiptEntryAfterHash ([string]$state.backup_receipt) "router_profile" (Get-FileSha256 $profilePath)

    Write-Host ("Router model selected: {0} (reasoning {1})" -f $Model, $effectiveEffort) -ForegroundColor Green
}

function Get-RouterCliStatusText {
    $state = Get-RouterCliState
    $router = Read-RouterUserConfig
    $configPath = Get-CodexConfigPath
    $profilePath = Get-RouterCliProfilePath
    $profilePresent = Test-ProfileOwned $profilePath
    $configPort = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $configPort = Read-CurrentProviderPort (Get-Content -Raw -LiteralPath $configPath)
    }
    $tokenPresent = $false
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($script:Lr12TokenEnv, [EnvironmentVariableTarget]::Process)) -or
        -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($script:Lr12TokenEnv, [EnvironmentVariableTarget]::User))) {
        $tokenPresent = $true
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("Mode                  : {0}" -f $state.mode))
    $lines.Add(("Generation            : {0}" -f $state.generation))
    $lines.Add(("Provider              : {0}" -f $script:Lr12ProviderId))
    $lines.Add(("Token env ref         : {0}" -f $script:Lr12TokenEnv))
    $lines.Add(("Token env present     : {0}" -f $(if ($tokenPresent) { "yes" } else { "no" })))
    $lines.Add(("Selected model        : {0}" -f $state.selected_model))
    $lines.Add(("Reasoning effort      : {0}" -f $state.reasoning_effort))
    $lines.Add(("Profile path          : {0}" -f $profilePath))
    $lines.Add(("Profile owned         : {0}" -f $(if ($profilePresent) { "yes" } else { "no" })))
    if ($null -eq $configPort) {
        $lines.Add("Provider base block   : missing")
    }
    else {
        $lines.Add(("Provider base URL     : http://127.0.0.1:{0}/v1" -f $configPort))
    }
    $lines.Add(("Router config         : {0}" -f $(if (-not $router.Valid) { "corrupt" } elseif ($router.Enabled) { "enabled" } else { "disabled" })))
    $lines.Add(("Router host/port      : {0}:{1}" -f $router.Host, $router.Port))
    $lines.Add(("Backup receipt        : {0}" -f $(if ([string]::IsNullOrWhiteSpace([string]$state.backup_receipt)) { "-" } else { $state.backup_receipt })))
    return ($lines -join "`r`n")
}

function Show-RouterCliStatus {
    Write-Host ""
    Write-Host "Codex Multi-Model Manager - Local Router CLI status" -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor DarkGray
    Get-RouterCliStatusText | Write-Host
    Write-Host ""
}

function Test-TokenEnvPresent {
    $processValue = [Environment]::GetEnvironmentVariable($script:Lr12TokenEnv, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($processValue)) { return $true }
    $userValue = Get-RouterCliUserEnvironmentValue $script:Lr12TokenEnv
    if (-not [string]::IsNullOrWhiteSpace($userValue)) { return $true }
    return $false
}

function Get-LaunchGateFailures([switch]$IncludePing, [string]$Model = "", [string]$Effort = "") {
    $failures = New-Object System.Collections.Generic.List[string]
    $state = Get-RouterCliState
    $router = Read-RouterUserConfig

    if ($state.mode -ne "router") {
        $failures.Add("Router CLI is not enabled (mode=$($state.mode)). Run Enable first.")
    }
    if (-not $router.Valid) {
        $failures.Add("Router user config is corrupt or invalid.")
    }
    elseif (-not $router.Enabled) {
        $failures.Add("Local Router is not enabled in router.config.json.")
    }

    $modelId = if ([string]::IsNullOrWhiteSpace($Model)) { [string]$state.selected_model } else { $Model }
    $effortId = if ([string]::IsNullOrWhiteSpace($Effort)) { [string]$state.reasoning_effort } else { $Effort }
    if ([string]::IsNullOrWhiteSpace($effortId)) { $effortId = "medium" }
    if ([string]::IsNullOrWhiteSpace($modelId)) {
        $failures.Add("No Router model selected. Run SelectModel or pass -Model to Launch.")
    }
    else {
        $candidate = Test-RouterModelCandidate $modelId
        if (-not $candidate.Valid) {
            foreach ($error in $candidate.Errors) {
                $failures.Add("Router model gate: $error")
            }
        }
        if ($candidate.Valid) {
            try {
                Assert-RouterEffortSupported $modelId $effortId
            }
            catch {
                $failures.Add("Router reasoning gate: $($_.Exception.Message)")
            }
        }
    }
    if (-not (Test-TokenEnvPresent)) {
        $failures.Add(("Client token env var {0} is missing. Codex will fail closed instead of using another provider." -f $script:Lr12TokenEnv))
    }

    $profilePath = Get-RouterCliProfilePath
    if (-not (Test-ProfileOwned $profilePath)) {
        $failures.Add("Router-owned profile file is missing: $profilePath")
    }
    else {
        $profileText = Get-Content -Raw -LiteralPath $profilePath
        if (-not $profileText.Contains(('model_provider = "{0}"' -f $script:Lr12ProviderId))) {
            $failures.Add("Router profile does not reference $script:Lr12ProviderId.")
        }
        if (-not $profileText.Contains("request_max_retries = 0")) { $failures.Add("Router profile must disable Codex request retries (request_max_retries=0).") }
        if (-not $profileText.Contains("stream_max_retries = 0")) { $failures.Add("Router profile must disable Codex stream retries (stream_max_retries=0).") }
    }

    $configPath = Get-CodexConfigPath
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $configText = Get-Content -Raw -LiteralPath $configPath
        $blockMatch = [regex]::Match($configText, '(?s)# >>> CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN.*?# <<< CODEX MULTIMODEL MANAGER ROUTER CLI END')
        if (-not $blockMatch.Success) {
            $failures.Add("Router-owned mm_local_router block is missing from config.toml.")
        }
        else {
            $block = $blockMatch.Value
            if (-not $block.Contains('wire_api = "responses"')) {
                $failures.Add("Router-owned block must use wire_api responses only.")
            }
            $envKeyMatches = [regex]::Matches($block, '(?im)^\s*env_key\s*=\s*"([^"]+)"')
            $envKeys = @($envKeyMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            if ($envKeys.Count -eq 0 -or ($envKeys.Count -eq 1 -and $envKeys[0] -ne $script:Lr12TokenEnv)) {
                $failures.Add("Router-owned block must reference exactly CODEX_LOCAL_ROUTER_TOKEN via env_key.")
            }
            elseif ($envKeys.Count -gt 1) {
                $failures.Add("Router-owned block references multiple env_key values; only CODEX_LOCAL_ROUTER_TOKEN is allowed.")
            }
            if ($block -match 'OPENROUTER_API_KEY|CODEX_DASHSCOPE_API_KEY|CODEX_OPENAI_API_KEY|MIMO_API_KEY') {
                $failures.Add("Router-owned block exposes an upstream provider key reference. Direct provider blocks are ignored by this gate.")
            }
            $urlMatch = [regex]::Match($block, 'base_url\s*=\s*"http://([^:]+):(\d+)/v1"')
            if (-not $urlMatch.Success) {
                $failures.Add("Router-owned block base_url is not a valid loopback URL.")
            }
            elseif ([string]$urlMatch.Groups[2].Value -ne [string]$router.Port) {
                $failures.Add("Router-owned block base_url port does not match router.config.json port.")
            }
        }
    }
    else {
        $failures.Add("Base Codex config.toml is missing the Router provider block.")
    }

    if ($IncludePing -and $router.Valid -and $router.Enabled) {
        $healthUrl = ("http://{0}:{1}/health" -f $router.Host, $router.Port)
        try {
            $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 3
            $payload = $response.Content | ConvertFrom-Json
            if ($null -eq $payload.ready -or -not [bool]$payload.ready) {
                $failures.Add("Local Router is not ready at $healthUrl (lifecycle=$($payload.lifecycle)).")
            }
        }
        catch {
            $failures.Add("Local Router is not reachable at $healthUrl. Codex will not fall back to another provider.")
        }
    }
    return @($failures.ToArray())
}

function Test-RouterCliLaunchGate([switch]$IncludePing) {
    $failures = @(Get-LaunchGateFailures -IncludePing:$IncludePing)
    if ($failures.Count -eq 0) { return $true }
    Write-Host ""
    Write-Host " Router Mode is NOT ready to launch Codex" -ForegroundColor Red
    Write-Host "-------------------------------------------------" -ForegroundColor DarkGray
    foreach ($failure in $failures) {
        Write-Host (" - " + $failure) -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Direct Mode remains available. Launch Codex Direct Mode through launch-controller-model.ps1." -ForegroundColor Green
    return $false
}

function Invoke-RouterCliLaunch {
    param(
        [string]$Model = "",
        [string]$Effort = "",
        [string]$ProjectPath = "",
        [switch]$CheckOnly,
        [switch]$Ping
    )

    $state = Get-RouterCliState
    $effectiveModel = if ([string]::IsNullOrWhiteSpace($Model)) { [string]$state.selected_model } else { $Model }
    $effectiveEffort = if ([string]::IsNullOrWhiteSpace($Effort)) { [string]$state.reasoning_effort } else { $Effort }
    if ([string]::IsNullOrWhiteSpace($effectiveEffort)) { $effectiveEffort = "medium" }

    $gateFailures = @(Get-LaunchGateFailures -IncludePing:$Ping -Model $effectiveModel -Effort $effectiveEffort)
    if ($gateFailures.Count -gt 0) {
        Write-Host ""
        Write-Host " Router Mode is NOT ready to launch Codex" -ForegroundColor Red
        Write-Host "-------------------------------------------------" -ForegroundColor DarkGray
        foreach ($failure in $gateFailures) {
            Write-Host (" - " + $failure) -ForegroundColor Yellow
        }
        if (-not $CheckOnly) {
            Write-Host "Codex was NOT started because the Router Mode gate failed." -ForegroundColor Red
        }
        return $false
    }
    if ($CheckOnly) {
        Write-Host "Router Mode launch gate PASSED." -ForegroundColor Green
        return $true
    }
    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $codexCommand) {
        throw "codex command was not found on PATH."
    }

    $workspace = ""
    if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
        $workspace = (Resolve-Path -LiteralPath $ProjectPath).Path
        Set-Location -LiteralPath $workspace
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host " Codex Multi-Model Manager -> Local Router -> Codex CLI" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host ("Workspace : {0}" -f $(if ($workspace) { $workspace } else { "(current)" })) -ForegroundColor White
    Write-Host ("Provider  : {0}" -f $script:Lr12ProviderId) -ForegroundColor White
    Write-Host ("Model     : {0}" -f $effectiveModel) -ForegroundColor White
    Write-Host ("Reasoning : {0}" -f $effectiveEffort) -ForegroundColor White
    Write-Host "Retries   : Codex retries disabled (Local Router owns retry)" -ForegroundColor White
    Write-Host "Secrets   : Upstream provider key values isolated from Codex child" -ForegroundColor White
    Write-Host ""
    Write-Host "Starting Codex CLI via Local Router..." -ForegroundColor Cyan
    Write-Host ""

    $envSnapshot = Get-RouterCliChildEnvSnapshot
    $exitCode = 0
    try {
        Set-RouterCliChildEnv $envSnapshot
        $effortConfig = 'model_reasoning_effort="{0}"' -f $effectiveEffort
        & codex --profile $script:Lr12ProfileId -m $effectiveModel -c $effortConfig
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    }
    finally {
        Restore-RouterCliChildEnv $envSnapshot
    }
    if ($exitCode -ne 0) {
        throw "Codex CLI exited with code $exitCode."
    }
    return $true
}

function Invoke-RouterCliDoctor([switch]$Ping) {
    $issues = New-Object System.Collections.Generic.List[string]
    Write-Host ""
    Write-Host "Codex Multi-Model Manager - Local Router CLI doctor" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor DarkGray

    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $codex) {
        $issues.Add("codex command not found on PATH.")
        Write-Host "FAIL  Codex CLI: not found" -ForegroundColor Red
    }
    else {
        try {
            $version = (& codex --version 2>&1 | Select-Object -First 1)
            Write-Host "PASS  Codex CLI: $version" -ForegroundColor Green
        }
        catch {
            $issues.Add("codex --version failed.")
            Write-Host "FAIL  Codex CLI version query failed" -ForegroundColor Red
        }
    }

    $state = Get-RouterCliState
    $router = Read-RouterUserConfig
    if (-not $router.Valid) {
        $issues.Add("Router user config is corrupt.")
        Write-Host "FAIL  Router user config: corrupt ($($router.Error))" -ForegroundColor Red
    }
    else {
        Write-Host ("PASS  Router user config: mode={0} enabled={1} host={2} port={3}" -f $router.Mode, $router.Enabled, $router.Host, $router.Port) -ForegroundColor Green
        if (-not $router.Enabled) { $issues.Add("Local Router is not enabled.") }
    }

    $profilePath = Get-RouterCliProfilePath
    if (-not (Test-ProfileOwned $profilePath)) {
        $issues.Add("Router profile is missing or not Router-owned.")
        Write-Host "FAIL  Router profile: $profilePath" -ForegroundColor Red
    }
    else {
        $profileText = Get-Content -Raw -LiteralPath $profilePath
        if ($profileText -match '(?im)OPENROUTER_API_KEY|CODEX_DASHSCOPE_API_KEY|MIMO_API_KEY|CODEX_OPENAI_API_KEY|Bearer\s+[A-Za-z0-9]') {
            $issues.Add("Router profile contains an upstream key reference.")
            Write-Host "FAIL  Router profile secret boundary: upstream key reference found" -ForegroundColor Red
        }
        else {
            Write-Host "PASS  Router profile secret boundary: no upstream key reference" -ForegroundColor Green
        }
        if ($profileText.Contains("request_max_retries = 0") -and $profileText.Contains("stream_max_retries = 0")) {
            Write-Host "PASS  Retry ownership: Codex retries disabled" -ForegroundColor Green
        }
        else {
            $issues.Add("Router profile must disable Codex-side retries.")
            Write-Host "FAIL  Retry ownership: Codex retries not disabled" -ForegroundColor Red
        }
    }

    if (Test-TokenEnvPresent) {
        Write-Host "PASS  Client token env: $script:Lr12TokenEnv present (value not shown)" -ForegroundColor Green
    }
    else {
        $issues.Add("Client token env var is missing.")
        Write-Host "FAIL  Client token env: $script:Lr12TokenEnv missing" -ForegroundColor Red
    }

    $configPath = Get-CodexConfigPath
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $configText = Get-Content -Raw -LiteralPath $configPath
        $blockMatch = [regex]::Match($configText, '(?s)# >>> CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN.*?# <<< CODEX MULTIMODEL MANAGER ROUTER CLI END')
        if ($blockMatch.Success) {
            $block = $blockMatch.Value
            $envKeys = @([regex]::Matches($block, '(?im)^\s*env_key\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $blockClean = ($block -notmatch 'OPENROUTER_API_KEY|CODEX_DASHSCOPE_API_KEY|CODEX_OPENAI_API_KEY|MIMO_API_KEY')
            if ($envKeys.Count -eq 1 -and $envKeys[0] -eq $script:Lr12TokenEnv -and $block.Contains('wire_api = "responses"') -and $blockClean) {
                Write-Host "PASS  Router-owned block: responses + local token env ref only (Direct provider blocks ignored)" -ForegroundColor Green
            }
            else {
                $issues.Add("Router-owned block is missing required fields or references an upstream key.")
                Write-Host "FAIL  Router-owned block: invalid secret/wire projection" -ForegroundColor Red
            }
        }
        else {
            $issues.Add("Router-owned mm_local_router block is missing.")
            Write-Host "FAIL  Router-owned block: missing" -ForegroundColor Red
        }
    }
    else {
        $issues.Add("Base Codex config.toml is missing.")
        Write-Host "FAIL  Codex config: $configPath missing" -ForegroundColor Red
    }

    $receipt = Get-RouterCliReceipt ([string]$state.backup_receipt)
    if ($null -eq $receipt) {
        Write-Host "INFO  Backup receipt: none (Router CLI never enabled or receipt missing)" -ForegroundColor DarkGray
    }
    else {
        $receiptOk = $true
        foreach ($entry in @($receipt.files)) {
            if ([bool]$entry.existed -and -not (Test-Path -LiteralPath ([string]$entry.backup_path) -PathType Leaf)) {
                $receiptOk = $false
            }
        }
        if ($receiptOk) {
            Write-Host ("PASS  Backup receipt: {0} intact" -f $receipt.receipt_id) -ForegroundColor Green
        }
        else {
            $issues.Add("Backup receipt files are missing.")
            Write-Host "FAIL  Backup receipt files missing" -ForegroundColor Red
        }
    }

    $directScript = Join-Path $PSScriptRoot "launch-controller-model.ps1"
    if (Test-Path -LiteralPath $directScript -PathType Leaf) {
        Write-Host "PASS  Direct Mode launcher present: $directScript" -ForegroundColor Green
    }
    else {
        $issues.Add("Direct Mode launcher is missing.")
        Write-Host "FAIL  Direct Mode launcher missing" -ForegroundColor Red
    }

    if ($Ping -and $router.Valid -and $router.Enabled) {
        $healthUrl = ("http://{0}:{1}/health" -f $router.Host, $router.Port)
        try {
            $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 3
            $payload = $response.Content | ConvertFrom-Json
            Write-Host ("PASS  Loopback health: {0} lifecycle={1} ready={2}" -f $healthUrl, $payload.lifecycle, $payload.ready) -ForegroundColor Green
        }
        catch {
            $issues.Add("Local Router not reachable.")
            Write-Host "FAIL  Loopback health: $healthUrl unreachable" -ForegroundColor Red
        }
    }

    Write-Host ""
    # HS1B-RB1 bootstrap ladder: NOT_INITIALIZED -> INITIALIZED -> ROUTER_ENABLED
    # -> ROUTER_READY. Every value is read from local files or loopback health;
    # no secret value is ever printed.
    $inventory = Get-RouterBootstrapInventory -Ping:$Ping
    Write-Host ("Router state          : {0}" -f $inventory.State) -ForegroundColor White
    Write-Host ("  Router user config  : {0} ({1})" -f $inventory.ConfigPath, $(if ($inventory.ConfigExists) { "present" } else { "missing" })) -ForegroundColor White
    Write-Host ("  Router schema       : {0}" -f $(if ($inventory.ConfigValid) { "VALID" } else { "INVALID (" + $inventory.ConfigError + ")" })) -ForegroundColor $(if ($inventory.ConfigValid) { "Green" } else { "Red" })
    Write-Host ("  Router enabled      : {0}" -f $inventory.RouterDeclaredEnabled) -ForegroundColor White
    Write-Host ("  Router host/port    : {0}:{1}" -f $inventory.Host, $inventory.Port) -ForegroundColor White
    Write-Host ("  Local client token  : {0} = {1}" -f $script:Lr12TokenEnv, $(if ($inventory.TokenPresent) { "PRESENT" } else { "MISSING" })) -ForegroundColor $(if ($inventory.TokenPresent) { "Green" } else { "Red" })
    Write-Host ("  Provider routes     : {0}" -f $inventory.ProviderRouteCount) -ForegroundColor White
    Write-Host ("  Model routes        : {0}" -f $inventory.ModelRouteCount) -ForegroundColor White
    Write-Host ("  Full routes         : {0}" -f $inventory.RouteCount) -ForegroundColor White
    Write-Host ("  Approved routable   : {0}" -f $inventory.RoutableModelCount) -ForegroundColor White
    Write-Host ("  mm_local_router blk : {0}" -f $(if ($inventory.ProviderBlockPresent) { "present" } else { "missing" })) -ForegroundColor White
    Write-Host ("  Router profile      : {0}" -f $(if ($inventory.ProfilePresent) { "present" } else { "missing" })) -ForegroundColor White
    Write-Host ("  Router runtime      : {0}" -f $(if ($null -eq $inventory.RuntimeReachable) { "not checked (use -Ping)" } elseif ($inventory.RuntimeReachable) { "reachable" } else { "unreachable" })) -ForegroundColor White
    if ($inventory.State -eq "NOT_INITIALIZED") {
        $issues.Add("Local Router is not initialized. Run -Action Initialize before enabling Router Mode.")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$inventory.StateError)) {
        $issues.Add("Router CLI state could not be read: $($inventory.StateError)")
    }

    Write-Host ""
    Write-Host ("Generation: {0}  Mode: {1}  Model: {2}" -f $state.generation, $state.mode, $state.selected_model) -ForegroundColor White
    if ($issues.Count -gt 0) {
        Write-Host "Doctor found issues; Router Mode launch gate will fail closed. Direct Mode remains available." -ForegroundColor Red
        return $false
    }
    Write-Host "Doctor checks passed." -ForegroundColor Green
    return $true
}

if (-not [string]::IsNullOrWhiteSpace($Action)) {
    switch ($Action) {
        "Initialize" {
            Initialize-RouterCli -Force:$Force
        }
        "Enable" {
            Enable-RouterCli -Model $Model -Effort $ReasoningEffort -Force:$Force
        }
        "Disable" {
            Disable-RouterCli -Force:$Force
        }
        "Status" {
            Show-RouterCliStatus
        }
        "Doctor" {
            $ok = Invoke-RouterCliDoctor -Ping:$Ping
            if (-not $ok) { exit 1 }
        }
        "SelectModel" {
            Select-RouterCliModel -Model $Model -Effort $ReasoningEffort
        }
        "Launch" {
            $ok = Invoke-RouterCliLaunch -Model $Model -Effort $ReasoningEffort -ProjectPath $ProjectPath -CheckOnly:$CheckOnly -Ping:$Ping
            if (-not $ok) { exit 1 }
        }
    }
}
