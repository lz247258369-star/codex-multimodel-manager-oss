param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR2 validation - direct DeepSeek Router bootstrap + provider-scoped identity.
#
# Architecture decision D: catalog identity and approval identity are
# provider-scoped ((provider_id, model_id)), while a client-facing model slug
# (client_model_id or an explicit ModelRoute alias) may have exactly one active
# owner in the generated route set. Catalog duplicates are allowed; active
# client-slug collisions fail closed.
#
# Everything here is offline: isolated temp CODEX_HOME sandboxes, no provider
# request, no user runtime mutation.

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }
function Assert-True([bool]$Condition, [string]$Message) { if ($Condition) { Pass $Message } else { Fail $Message } }

function Read-FileText([string]$RelativePath) {
    $path = Join-Path $RepositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Fail "Missing required file: $RelativePath"
        return ""
    }
    return (Get-Content -Raw -LiteralPath $path)
}

$modulePath = Join-Path $RepositoryRoot "installer/scripts/router-codex-cli.ps1"
$moduleText = Read-FileText "installer/scripts/router-codex-cli.ps1"
$catalogText = Read-FileText "installer/model-catalog.json"
$controllerCatalogText = Read-FileText "installer/scripts/controller-catalog.ps1"
$reasoningText = Read-FileText "local-router/src/Router.ClientAdapters.Responses/Reasoning.cs"
$catalog = $catalogText | ConvertFrom-Json

# --- Catalog identity --------------------------------------------------------
$deepSeekProvider = @($catalog.providers | Where-Object { [string]$_.id -eq "deepseek" })
Assert-True ($deepSeekProvider.Count -eq 1) "Canonical catalog declares exactly one direct deepseek provider"
Assert-True ([string]$deepSeekProvider[0].label -eq "DeepSeek Official") "Catalog provider label is DeepSeek Official"
Assert-True ([string]$deepSeekProvider[0].env_key -eq "DEEPSEEK_API_KEY") "Catalog provider env_key is DEEPSEEK_API_KEY"

$flashModel = @($deepSeekProvider[0].models | Where-Object { [string]$_.id -eq "deepseek-flash" })
$proModel = @($deepSeekProvider[0].models | Where-Object { [string]$_.id -eq "deepseek-v4-pro" })
Assert-True ($flashModel.Count -eq 1) "Direct DeepSeek canonical flash model is deepseek-flash"
Assert-True ([string]$flashModel[0].label -eq "DeepSeek V4.1 Flash") "Direct flash label is DeepSeek V4.1 Flash"
Assert-True ($proModel.Count -eq 1) "Direct DeepSeek canonical pro model is deepseek-v4-pro"
foreach ($entry in @($flashModel[0], $proModel[0])) {
    Assert-True ([string]$entry.status -eq "official") "Direct DeepSeek catalog status is official ($($entry.id))"
    Assert-True ((@($entry.performance_levels) -join ",") -eq "low,high,max") "Direct DeepSeek performance levels are low/high/max ($($entry.id))"
    Assert-True ($null -eq $entry.price_input -and $null -eq $entry.price_output) "Direct DeepSeek price is not guessed ($($entry.id))"
}
$modelStudioProvider = @($catalog.providers | Where-Object { [string]$_.id -eq "modelstudio" })
Assert-True (@($modelStudioProvider[0].models | Where-Object { [string]$_.id -eq "deepseek-v4-pro" }).Count -eq 1) "Model Studio historical deepseek-v4-pro catalog record is preserved"
Assert-True (@($modelStudioProvider[0].models | Where-Object { [string]$_.id -eq "deepseek-v4-flash" }).Count -eq 1) "Model Studio historical deepseek-v4-flash catalog record is preserved"
Assert-True (@($modelStudioProvider[0].models | Where-Object { @($_.performance_levels) -contains "medium" }).Count -gt 0) "Model Studio performance levels are unchanged (medium still present)"

# --- Controller provider mapping --------------------------------------------
Assert-True ($controllerCatalogText.Contains('"deepseek" { return "deepseek" }')) "Controller provider mapping maps deepseek to itself"
foreach ($pair in @('"mm_mimo" { return "mimo" }', '"mm_openrouter" { return "openrouter" }', '"mm_modelstudio" { return "modelstudio" }')) {
    Assert-True ($controllerCatalogText.Contains($pair)) "Existing controller provider mapping preserved: $pair"
}

# --- Router scope ------------------------------------------------------------
Assert-True ($moduleText.Contains('"deepseek"')) "Router eligible provider set includes deepseek"
Assert-True ($moduleText.Contains('"deepseek" = [ordered]@{')) "Bootstrap provider table declares the direct DeepSeek provider"
Assert-True ($moduleText.Contains('AdapterId = "adapter.provider.deepseek.responses.v1"')) "Bootstrap adapter id matches DSR1"
Assert-True ($moduleText.Contains('BaseUrlRef = "provider-config:deepseek.base_url"')) "Bootstrap base URL reference matches DSR1"
Assert-True ($moduleText.Contains('SecretEnv = "DEEPSEEK_API_KEY"')) "Bootstrap secret env matches DSR1/EnvironmentSecretAllowlist"
Assert-True ($moduleText.Contains('DEEPSEEK_API_KEY')) "Upstream secret env list contains DEEPSEEK_API_KEY"
Assert-True (-not $moduleText.Contains("DEEPSEEK_ROUTER_GAP")) "The active DeepSeek Router gap code is retired"
Assert-True ($moduleText.Contains('"deepseek::deepseek-flash" = @("deepseek-v4-flash", "deepseek-v4-flash-vision-exp")')) "The explicit flash alias table is exact"
Assert-True ($moduleText.Contains('if ($script:Lr12BootstrapModelAliases.Contains($key))')) "Alias resolution is an explicit table lookup, never substring matching"

# --- Decision D wiring -------------------------------------------------------
Assert-True ($moduleText.Contains("CLIENT_MODEL_SLUG_COLLISION")) "Client-slug collision gate exists"
Assert-True ($moduleText.Contains("Exactly one active owner per client slug is required")) "The single-owner rule is stated in the failure message"
Assert-True ($moduleText.Contains("ACTIVE_CLIENT_SLUG_AMBIGUOUS")) "The CLI candidate check reports ACTIVE_CLIENT_SLUG_AMBIGUOUS"
Assert-True ($moduleText.Contains('$routeAliases -contains $ModelId')) "The CLI candidate check resolves explicit route aliases"
Assert-True ($moduleText.Contains('$_.provider_id -eq $resolvedProviderId') -and $moduleText.Contains('$_.model_id -eq $resolvedModelId')) "The CLI catalog lookup is provider-scoped"
Assert-True (-not ($moduleText -match 'Model \$ModelId is ambiguous across catalog providers')) "The global model-id-only ambiguity message is gone"
Assert-True (-not ($moduleText -match 'would be ambiguous')) "The global cross-provider claim error is gone"

# --- Reasoning max (DSR2 protocol item) -------------------------------------
Assert-True ($reasoningText.Contains("Max = 3")) "ReasoningEffort.Max exists"
Assert-True ($reasoningText.Contains('case "max":')) "Reasoning effort parsing accepts max"
Assert-True ($reasoningText.Contains('ReasoningEffort.Max => "max"')) "Reasoning effort serialization keeps max"
Assert-True ($moduleText.Contains('[ValidateSet("low", "medium", "high", "xhigh", "max")]')) "Router CLI effort ValidateSet offers max and keeps xhigh"
Assert-True ((Read-FileText "installer/scripts/desktop-router-route.ps1").Contains('[ValidateSet("low", "medium", "high", "xhigh", "max")]')) "Desktop Router effort ValidateSet offers max and keeps xhigh"

# --- No live-provider / no user-runtime escape hatch ------------------------
Assert-True (-not $moduleText.Contains("experimental_bearer_token")) "Router CLI never reads the inline direct-mode bearer token"
Assert-True (-not ($moduleText -match 'models\.json[^\r\n]*(Set-Content|Add-Content|WriteAllText|WriteAllLines)')) "Router CLI never writes the native picker catalog"
Assert-True ((Read-FileText "installer/scripts/intake-model-candidate.ps1").Contains('throw "Provider is not configured or not enabled, refusing candidate intake: $ProviderId"')) "Candidate intake still fails closed for unconfigured providers"

# --- Picker compatibility phase + future NMP1 contract ----------------------
$readmeText = Read-FileText "local-router/README.md"
Assert-True ($readmeText.Contains("DSR2 compatibility phase")) "The picker compatibility phase is documented"
Assert-True ($readmeText.Contains("CLIENT_MODEL_SLUG_COLLISION")) "The documented contract states the single-active-owner collision rule"
Assert-True ($readmeText.Contains("NMP1")) "The future native picker catalog promotion (NMP1) contract is documented"
Assert-True (-not ($readmeText -match '(?m)^```sh[\s\S]*models\.json[\s\S]*^```$')) "The documentation never asks the reader to hand-edit models.json"

# --- Sandbox scenarios: provider-scoped identity, single active slug owner ---
function New-Dsr2Sandbox([string[]]$ApprovedModels) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-dsr2-" + [guid]::NewGuid().ToString("N"))
    $codexHome = Join-Path $root "codex-home"
    New-Item -ItemType Directory -Force -Path (Join-Path $codexHome "multimodel-manager") | Out-Null
    $records = @($ApprovedModels | ForEach-Object {
            $parts = $_ -split "::"
            [pscustomobject]@{ provider_id = $parts[0]; model_id = $parts[1] }
        })
    $records | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $codexHome "multimodel-manager/approved-models.json") -Encoding UTF8
    return [pscustomobject]@{ Root = $root; CodexHome = $codexHome }
}

function Invoke-Dsr2Bootstrap($Sandbox) {
    $env:CODEX_HOME = $Sandbox.CodexHome
    $configPath = Join-Path $Sandbox.CodexHome "multimodel-manager/local-router/router.config.json"
    if (Test-Path -LiteralPath $configPath -PathType Leaf) { Remove-Item -LiteralPath $configPath -Force }
    $output = (& { Initialize-RouterCli } *>&1 | Out-String)
    return [pscustomobject]@{ Output = $output; ConfigPath = $configPath }
}

function Get-Dsr2Routes([string]$ConfigPath, [string]$ProviderId) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return @() }
    $doc = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    return @($doc.model_routes | Where-Object { [string]$_.provider_id -eq $ProviderId })
}

$envBefore = $env:CODEX_HOME
$sandboxes = New-Object System.Collections.Generic.List[object]
try {
    . $modulePath
    $envTable = (Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "tests/fixtures/local-router/v1/bootstrap/env.references.json") | ConvertFrom-Json).references

    function Set-Dsr2Seams([hashtable]$ExtraSecrets) {
        $script:Lr12UserEnvWriter = @{}
        $script:Lr12UserEnvLookup = $script:Lr12UserEnvWriter
        foreach ($p in $envTable.PSObject.Properties) { $script:Lr12UserEnvLookup[$p.Name] = [string]$p.Value }
        foreach ($p in $ExtraSecrets.GetEnumerator()) { $script:Lr12UserEnvLookup[$p.Key] = [string]$p.Value }
        $script:Lr12UserEnvLookup["CODEX_LOCAL_ROUTER_TOKEN"] = "fixture-existing-router-token-value"
    }

    # CASE A: only the direct DeepSeek pro approval is active.
    $caseA = New-Dsr2Sandbox @("deepseek::deepseek-v4-pro")
    $sandboxes.Add($caseA)
    Set-Dsr2Seams @{}
    $resultA = Invoke-Dsr2Bootstrap $caseA
    $routesA = @(Get-Dsr2Routes $resultA.ConfigPath "deepseek")
    Assert-True ($routesA.Count -eq 1) "CASE A: direct deepseek pro route is generated while Model Studio stays inactive"
    Assert-True (@($routesA | Where-Object { [string]$_.client_model_id -eq "deepseek-v4-pro" -and [string]$_.upstream_model_id -eq "deepseek-v4-pro" }).Count -eq 1) "CASE A: canonical and upstream id are deepseek-v4-pro"
    Assert-True (@($routesA | Where-Object { @($_.aliases).Count -eq 0 }).Count -eq 1) "CASE A: direct pro declares no aliases"
    Assert-True (@(Get-Dsr2Routes $resultA.ConfigPath "mm_modelstudio").Count -eq 0) "CASE A: the paused Model Studio provider stays out of the route set"

    # CASE B: only the Model Studio approval is active.
    $caseB = New-Dsr2Sandbox @("mm_modelstudio::deepseek-v4-pro")
    $sandboxes.Add($caseB)
    Set-Dsr2Seams @{}
    $resultB = Invoke-Dsr2Bootstrap $caseB
    $routesB = @(Get-Dsr2Routes $resultB.ConfigPath "mm_modelstudio")
    Assert-True ($routesB.Count -eq 1) "CASE B: the Model Studio pro route is generated when it is the only owner"
    Assert-True (@(Get-Dsr2Routes $resultB.ConfigPath "deepseek").Count -eq 0) "CASE B: no direct DeepSeek route is fabricated"

    # CASE C: the catalog contains both duplicate model ids but only direct is active.
    Assert-True (@($catalog.providers | Where-Object { [string]$_.id -in @("deepseek", "modelstudio") }).Count -eq 2) "CASE C: both catalog providers exist (provider-scoped duplicate model id allowed)"
    Assert-True ($routesA.Count -eq 1 -and $routesB.Count -eq 1) "CASE C: the same model id resolves independently per provider"

    # CASE D: two active routes claim the same client-facing slug.
    $caseD = New-Dsr2Sandbox @("deepseek::deepseek-v4-pro", "mm_modelstudio::deepseek-v4-pro")
    $sandboxes.Add($caseD)
    Set-Dsr2Seams @{}
    $threwD = $false
    $messageD = ""
    try { [void](Invoke-Dsr2Bootstrap $caseD) } catch { $threwD = $true; $messageD = $_.Exception.Message }
    Assert-True $threwD "CASE D: two active routes claiming one client slug fail closed"
    Assert-True ($messageD -match "CLIENT_MODEL_SLUG_COLLISION") "CASE D: the failure carries the explicit collision code"
    Assert-True ($messageD -match "deepseek-v4-pro") "CASE D: the failure names the colliding slug"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $caseD.CodexHome "multimodel-manager/local-router/router.config.json"))) "CASE D: no router config is written on collision"

    # CASE E: distinct client-facing slugs may coexist (documented future rule).
    Assert-True ($moduleText.Contains("give that provider a distinct client-facing slug")) "CASE E: the failure message documents the distinct-slug remedy"

    # CLI alias resolution for the legacy picker slugs.
    $caseFlash = New-Dsr2Sandbox @("deepseek::deepseek-flash")
    $sandboxes.Add($caseFlash)
    Set-Dsr2Seams @{}
    $resultFlash = Invoke-Dsr2Bootstrap $caseFlash
    $routesFlash = @(Get-Dsr2Routes $resultFlash.ConfigPath "deepseek")
    Assert-True ($routesFlash.Count -eq 1) "Flash route generated for the alias scenario"
    Assert-True ((@($routesFlash[0].aliases) -join ",") -eq "deepseek-v4-flash,deepseek-v4-flash-vision-exp") "Flash aliases are explicit and exact"
    foreach ($slug in @("deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp")) {
        $candidate = Test-RouterModelCandidate $slug
        Assert-True ($candidate.Valid) "CLI candidate check accepts $slug through the alias"
        Assert-True ([string]$candidate.CatalogRecord.provider_id -eq "deepseek") "CLI catalog lookup for $slug is provider-scoped to deepseek"
        Assert-True ([string]$candidate.CatalogRecord.model_id -eq "deepseek-flash") "CLI catalog lookup for $slug resolves canonical deepseek-flash"
    }
    $effortOk = $true
    try { Assert-RouterEffortSupported "deepseek-v4-flash" "max" } catch { $effortOk = $false }
    Assert-True $effortOk "Provider-scoped effort lookup accepts max for the direct flash model through its alias"
    $mediumOk = $true
    try { Assert-RouterEffortSupported "deepseek-flash" "medium" } catch { $mediumOk = $false }
    Assert-True (-not $mediumOk) "Direct DeepSeek flash does not silently accept the Model Studio 'medium' level"

    # Unknown DeepSeek-like names never route.
    $unknown = Test-RouterModelCandidate "deepseek-super-future-model"
    Assert-True (-not $unknown.Valid) "An unknown DeepSeek-like model name fails closed (no brand inference)"
}
catch {
    Fail "DSR2 sandbox validation failed: $($_.Exception.Message)"
}
finally {
    $env:CODEX_HOME = $envBefore
    foreach ($sandbox in $sandboxes) {
        Remove-Item -LiteralPath $sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- DSR2 late registration: installer/scripts/_registry.ps1 ------------------
# The DSR2 delta also gated the direct DeepSeek provider inside the shared
# Manager registry helper, but the file was shipped without an authorization
# entry. The entry is now registered in tests/shared/protected-file-scope.ps1;
# the exact reviewed markers (state-gated, discovery disabled, no credential
# value) are asserted here, together with a mutation proof that the constraints
# and the delta-exact pin are both load bearing.
function Get-RegistryDeepSeekDeltaErrors([string]$Text) {
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $Text.Contains('$state.PSObject.Properties["deepseek_enabled"]')) { $errors.Add("missing the deepseek_enabled state gate") }
    if (-not $Text.Contains('$state.deepseek_enabled')) { $errors.Add("missing the deepseek_enabled boolean check") }
    if (-not $Text.Contains('$map["deepseek"]')) { $errors.Add("missing the deepseek provider map entry") }
    if (-not $Text.Contains('env_key="DEEPSEEK_API_KEY"')) { $errors.Add("missing the DeepSeek env key reference") }
    if (-not $Text.Contains('discovery="none"')) { $errors.Add("DeepSeek discovery is not explicitly disabled") }
    if ($Text -match 'experimental_bearer_token') { $errors.Add("an inline credential key leaked into the registry helper") }

    $gateIndex = $Text.IndexOf('if ($state.PSObject.Properties["deepseek_enabled"]')
    $entryIndex = $Text.IndexOf('$map["deepseek"]')
    if ($gateIndex -lt 0 -or $entryIndex -lt 0 -or $gateIndex -gt $entryIndex) {
        $errors.Add("the deepseek entry is not declared inside its state gate")
    }
    return $errors.ToArray()
}

$registryText = Read-FileText "installer/scripts/_registry.ps1"
$registryErrors = @(Get-RegistryDeepSeekDeltaErrors $registryText)
if ($registryErrors.Count -eq 0) {
    Pass "DSR2: the reviewed _registry.ps1 DeepSeek gate is state-gated and discovery-free"
}
else {
    foreach ($registryError in $registryErrors) { Fail "DSR2 _registry.ps1: $registryError" }
}

. (Join-Path $RepositoryRoot "tests/shared/protected-file-scope.ps1")
"installer/scripts/_registry.ps1" | ForEach-Object {
    if (Test-Lr13ProtectedFileChangeAuthorized $RepositoryRoot $_) {
        Pass "Protected-file policy authorizes the registered _registry.ps1 DSR2 delta"
    }
    else {
        Fail "Protected-file policy rejected the registered _registry.ps1 DSR2 delta"
    }
}

$registryTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("dsr2-registry-scope-" + [guid]::NewGuid().ToString("N"))
try {
    $tempScriptDir = Join-Path $registryTemp "installer/scripts"
    $tempValidatorDir = Join-Path $registryTemp "tests"
    New-Item -ItemType Directory -Force -Path $tempScriptDir, $tempValidatorDir | Out-Null
    $tempRegistry = Join-Path $tempScriptDir "_registry.ps1"
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot "installer/scripts/_registry.ps1") -Destination $tempRegistry
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot "tests/validate-deepseek-router-bootstrap.ps1") -Destination (Join-Path $tempValidatorDir "validate-deepseek-router-bootstrap.ps1")

    if (Test-Lr13ProtectedFileChangeAuthorized $registryTemp "installer/scripts/_registry.ps1") {
        Pass "The registered _registry.ps1 delta is authorized once its scope validator is present"
    }
    else {
        Fail "The registered _registry.ps1 delta was rejected although the scope validator is present"
    }

    $registryOriginal = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "installer/scripts/_registry.ps1")
    [System.IO.File]::WriteAllText(
        $tempRegistry,
        ($registryOriginal + "`n# UNAUTHORIZED DSR2 REGISTRY MUTATION MARKER`n"),
        [System.Text.UTF8Encoding]::new($false))
    if (-not (Test-Lr13ProtectedFileChangeAuthorized $registryTemp "installer/scripts/_registry.ps1")) {
        Pass "An unauthorized future _registry.ps1 mutation fails the delta-exact gate"
    }
    else {
        Fail "An unauthorized future _registry.ps1 mutation was not detected"
    }

    [System.IO.File]::WriteAllText(
        $tempRegistry,
        $registryOriginal.Replace('discovery="none"', 'discovery="auto"'),
        [System.Text.UTF8Encoding]::new($false))
    if (@(Get-RegistryDeepSeekDeltaErrors (Get-Content -Raw -LiteralPath $tempRegistry)).Count -gt 0) {
        Pass "The DSR2 _registry.ps1 content constraints reject a discovery-enabled variant"
    }
    else {
        Fail "The DSR2 _registry.ps1 content constraints accepted a discovery-enabled variant"
    }
}
finally {
    $tempBase = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
    if ($registryTemp.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $registryTemp).StartsWith("dsr2-registry-scope-", [System.StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $registryTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "DeepSeek direct router bootstrap validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}
Write-Host "DeepSeek direct router bootstrap validation PASSED" -ForegroundColor Green
exit 0
