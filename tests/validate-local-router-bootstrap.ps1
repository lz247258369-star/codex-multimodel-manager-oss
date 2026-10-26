param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# HS1B-RB1 Local Router bootstrap validation.
#
# Everything below is fake/fixture/loopback only: the module under test is loaded
# with an injectable User-environment read seam AND write seam, so no real
# User-scope variable is ever created, and no provider request is ever made. The
# canonical schema-v1 acceptance of the generated document lives in
# local-router/tests/Router.Core.Tests/Configuration/BootstrapConfigFixtureTests.cs,
# which loads the same golden fixture through Router.Configuration.

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Pass $Message } else { Fail $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}

function Assert-ThrowsMatch([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $matched = $false
    try { & $Action | Out-Null } catch { $matched = ($_.Exception.Message -match $Pattern) }
    Assert-True $matched $Message
}

function Save-ProcessEnvSnapshot {
    $names = @(
        "OPENROUTER_API_KEY",
        "CODEX_DASHSCOPE_API_KEY",
        "CODEX_OPENAI_API_KEY",
        "MIMO_API_KEY",
        "CODEX_LOCAL_ROUTER_TOKEN",
        "CODEX_HOME"
    ) | Sort-Object -Unique
    $snapshot = [ordered]@{}
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        $snapshot[$name] = if ($null -eq $value) { $null } else { [string]$value }
    }
    return $snapshot
}

function Restore-ProcessEnvSnapshot($Snapshot) {
    foreach ($entry in $Snapshot.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            Remove-Item -Path ("Env:" + $entry.Key) -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -Path ("Env:" + $entry.Key) -Value ([string]$entry.Value) -ErrorAction SilentlyContinue
        }
    }
}

function Clear-ProcessUpstreamEnv {
    foreach ($name in @("OPENROUTER_API_KEY", "CODEX_DASHSCOPE_API_KEY", "CODEX_OPENAI_API_KEY", "MIMO_API_KEY", "CODEX_LOCAL_ROUTER_TOKEN")) {
        Remove-Item -Path ("Env:" + $name) -ErrorAction SilentlyContinue
    }
}

function Invoke-InitializeCaptured {
    # Captures Write-Host (information stream) plus normal output so the test can
    # prove that no secret value is ever printed.
    return (& { Initialize-RouterCli } *>&1 | Out-String)
}

function Get-ReceiptCount([string]$CodexHome) {
    $dir = Join-Path $CodexHome "multimodel-manager/router-bootstrap-receipts"
    if (-not (Test-Path -LiteralPath $dir -PathType Leaf)) {
        if (-not (Test-Path -LiteralPath $dir)) { return 0 }
    }
    return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue).Count
}

function Get-ConfigText([string]$CodexHome) {
    $path = Join-Path $CodexHome "multimodel-manager/local-router/router.config.json"
    return (Get-Content -Raw -LiteralPath $path)
}

function Get-ManagedConfig([string]$CodexHome) {
    return (Get-Content -Raw -LiteralPath (Join-Path $CodexHome "multimodel-manager/local-router/router.config.json") | ConvertFrom-Json -AsHashtable)
}

function Write-RouterConfigDocument([string]$CodexHome, $Document) {
    $dir = Join-Path $CodexHome "multimodel-manager/local-router"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $dir "router.config.json") -Encoding UTF8
}

$envBefore = Save-ProcessEnvSnapshot
$modulePath = Join-Path $RepositoryRoot "installer/scripts/router-codex-cli.ps1"
$fixtureRoot = Join-Path $RepositoryRoot "tests/fixtures/local-router/v1/bootstrap"
$goldenPath = Join-Path $fixtureRoot "router-config.expected.json"
# NOTE: the fixture cannot be named approved-models.json - the repository
# .gitignore and tests/validate-repo.ps1 both reserve that exact file name for
# untracked user runtime state, so a committed fixture must use another name.
# The sandbox still receives it as approved-models.json, which is the name the
# Router CLI reads from CODEX_HOME.
$approvedFixturePath = Join-Path $fixtureRoot "approved-models.fixture.json"
$envReferenceFixturePath = Join-Path $fixtureRoot "env.references.json"

foreach ($path in @($modulePath, $goldenPath, $approvedFixturePath, $envReferenceFixturePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail "Required bootstrap file missing: $path" }
}
if ($failures.Count -gt 0) {
    Write-Host "Local Router bootstrap validation FAILED (missing files)" -ForegroundColor Red
    exit 1
}

$moduleText = Get-Content -Raw -LiteralPath $modulePath
$validatorText = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "tests/validate-local-router-bootstrap.ps1")
$setEnvApiPattern = "Set" + "EnvironmentVariable"
$userTargetPattern = "EnvironmentVariableTarget]::" + "User"
Assert-True (-not $validatorText.Contains($setEnvApiPattern)) ("Validator never calls " + $setEnvApiPattern + " (no real User-scope writes)")
Assert-True (-not $validatorText.Contains($userTargetPattern)) "Validator never references the real User-scope environment target"

# --- Static contract: the bootstrap entry, its tables, and their C# sources ---
Assert-True $moduleText.Contains('"Initialize"') "Router CLI ValidateSet exposes the Initialize action"
Assert-True $moduleText.Contains("function Initialize-RouterCli") "Router CLI implements Initialize-RouterCli"
Assert-True $moduleText.Contains('"Initialize" {') "Router CLI dispatches the Initialize action"
Assert-True $moduleText.Contains("Initialize-RouterCli -Force:") "Initialize dispatch calls the bootstrap entry"
Assert-True (-not $moduleText.Contains("DEEPSEEK_ROUTER_GAP")) "DSR2: the active DeepSeek Router gap code is retired"
Assert-True ($moduleText.Contains('"deepseek" = [ordered]@{')) "DSR2: the bootstrap provider table declares the direct DeepSeek provider"
Assert-True ($moduleText.Contains('"deepseek" = "deepseek"')) "DSR2: the catalog provider map maps deepseek to itself (never to modelstudio)"
Assert-True ($moduleText.Contains('"deepseek::deepseek-flash" = @("deepseek-v4-flash", "deepseek-v4-flash-vision-exp")')) "DSR2: the explicit versioned DeepSeek flash alias table is declared"
Assert-True ($moduleText.Contains("Get-RouterBootstrapModelAliases")) "DSR2: model routes resolve aliases from the explicit table, never from substrings"
Assert-True ($moduleText.Contains("Lr12SchemaProviderIds")) "DSR2: the schema provider identity set is derived from the single eligible-provider table"
Assert-True $moduleText.Contains("UPSTREAM_SECRET_REFERENCE_MISSING") "Router CLI reports a missing upstream secret reference"
Assert-True $moduleText.Contains("STOPPED - no approved Router-supported model") "Router CLI stops the route bootstrap instead of fabricating a route"
Assert-True $moduleText.Contains("New-RouterCliSecureLocalClientToken") "Router CLI owns a secure local token generator"
Assert-True $moduleText.Contains("RandomNumberGenerator") "Local token uses a cryptographic random source"
Assert-True $moduleText.Contains("Lr12UserEnvWriter") "Token bootstrap exposes an injectable User-scope write seam"
Assert-True $moduleText.Contains('$script:Lr12ProviderId = "mm_local_router"') "Bootstrap reuses the single mm_local_router provider identity"

$adapterSources = [ordered]@{
    "mm_modelstudio" = "local-router/src/Router.ProviderAdapters.ModelStudio/ModelStudioProviderAdapter.cs"
    "mm_openrouter" = "local-router/src/Router.ProviderAdapters.OpenRouter/OpenRouterProviderAdapter.cs"
    "mm_mimo" = "local-router/src/Router.ProviderAdapters.MiMo/MiMoProviderAdapter.cs"
    "mm_openai_api" = "local-router/src/Router.ProviderAdapters.OpenAI/OpenAIProviderAdapter.cs"
}
$endpointSourceText = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Execution/RouterExecutionEndpoints.cs")
$allowlistSourceText = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Secrets/EnvironmentSecretAllowlist.cs")
$catalogText = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "installer/model-catalog.json")

foreach ($providerId in $adapterSources.Keys) {
    $sourceText = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $adapterSources[$providerId])
    $adapterId = [regex]::Match($sourceText, 'public const string AdapterId = "([^"]+)"').Groups[1].Value
    $adapterVersion = [regex]::Match($sourceText, 'public const string AdapterVersion = "([^"]+)"').Groups[1].Value
    $tableMatch = [regex]::Match($moduleText, ('(?s)"' + [regex]::Escape($providerId) + '"\s*=\s*\[ordered\]@\{(?<body>.*?)\n    \}'))
    Assert-True $tableMatch.Success "Bootstrap table declares provider $providerId"
    if ($tableMatch.Success) {
        $body = $tableMatch.Groups["body"].Value
        Assert-True ($body.Contains($adapterId)) "Bootstrap adapter id matches the production adapter for $providerId"
        Assert-True ($body.Contains(('AdapterVersion = "' + $adapterVersion + '"'))) "Bootstrap adapter version matches the production adapter for $providerId"
        Assert-True ($body.Contains("provider-config:" + $providerId + ".base_url")) "Bootstrap base_url_ref matches RouterExecutionEndpoints for $providerId"
    }
    Assert-True $endpointSourceText.Contains('provider-config:' + $providerId + '.base_url') "RouterExecutionEndpoints defines the base_url_ref for $providerId"
}
foreach ($pair in @(
        @("OPENROUTER_API_KEY", "OPENROUTER_API_KEY"),
        @("MIMO_API_KEY", "MIMO_API_KEY"),
        @("CODEX_OPENAI_API_KEY", "CODEX_OPENAI_API_KEY"),
        @("CODEX_DASHSCOPE_API_KEY", "CODEX_DASHSCOPE_API_KEY"),
        @("DEEPSEEK_API_KEY", "DEEPSEEK_API_KEY")
    )) {
    Assert-True $allowlistSourceText.Contains(('"' + $pair[0] + '"')) "EnvironmentSecretAllowlist declares $($pair[1])"
    Assert-True $moduleText.Contains(('SecretEnv = "' + $pair[1] + '"')) "Bootstrap uses the allowlisted secret env name $($pair[1])"
}
Assert-True ($moduleText.Contains("catalog_provider_id") -or $moduleText.Contains("catalog_provider_id =")) "Bootstrap routes carry the canonical catalog provider mapping"

$fixtureApprovals = @(Get-Content -Raw -LiteralPath $approvedFixturePath | ConvertFrom-Json)
$fixtureEnvTable = (Get-Content -Raw -LiteralPath $envReferenceFixturePath | ConvertFrom-Json).references
$expectedProviderRoutes = @("provider-route.deepseek", "provider-route.mimo", "provider-route.modelstudio", "provider-route.openrouter")
$expectedSkippedProvider = "mm_mimo"
$expectedSkippedEnv = "MIMO_API_KEY"

# --- Scenario helper: fresh sandbox with the fixture approval/secret seams ----
function New-BootstrapSandbox {
    param([switch]$WithoutApprovals)

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-mm-rb1-" + [guid]::NewGuid().ToString("N"))
    $codexHome = Join-Path $root "codex-home"
    New-Item -ItemType Directory -Force -Path (Join-Path $codexHome "multimodel-manager") | Out-Null
    if (-not $WithoutApprovals) {
        Copy-Item -LiteralPath $approvedFixturePath -Destination (Join-Path $codexHome "multimodel-manager/approved-models.json")
    }
    return [pscustomobject]@{ Root = $root; CodexHome = $codexHome }
}

# --- HS1B-RB1-FIX1 helper: router config with verbatim route arrays ----------
# The three route arrays are injected as raw JSON so a scenario can distinguish
# JSON null, [], a single entity and many entities.
function Write-RouterConfigWithRouteArrays([string]$CodexHome, [string]$ProviderRoutes, [string]$ModelRoutes, [string]$Routes) {
    $dir = Join-Path $CodexHome "multimodel-manager/local-router"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $document = @"
{
  "schema_version": 1,
  "version": 1,
  "mode": "router",
  "local_router": { "enabled": true, "host": "127.0.0.1", "port": 47821 },
  "clients": [],
  "protocol_routes": [],
  "endpoints": [],
  "provider_routes": $ProviderRoutes,
  "model_routes": $ModelRoutes,
  "routes": $Routes,
  "policies": [],
  "updated_at": "2026-09-17T00:00:00Z"
}
"@
    Set-Content -LiteralPath (Join-Path $dir "router.config.json") -Value $document -Encoding UTF8
}

# A config written before the route arrays existed must be counted the same way
# as one that spells them out as JSON null.
function Write-RouterConfigWithoutRouteKeys([string]$CodexHome) {
    $dir = Join-Path $CodexHome "multimodel-manager/local-router"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $document = @"
{
  "schema_version": 1,
  "version": 1,
  "mode": "router",
  "local_router": { "enabled": true, "host": "127.0.0.1", "port": 47821 },
  "clients": [],
  "protocol_routes": [],
  "endpoints": [],
  "policies": [],
  "updated_at": "2026-09-17T00:00:00Z"
}
"@
    Set-Content -LiteralPath (Join-Path $dir "router.config.json") -Value $document -Encoding UTF8
}

$moduleLoaded = $false
$sandbox = $null
try {
    Clear-ProcessUpstreamEnv
    $sandbox = New-BootstrapSandbox
    $env:CODEX_HOME = $sandbox.CodexHome
    . $modulePath
    $moduleLoaded = $true
    $script:Lr12UserEnvWriter = @{}
    $script:Lr12UserEnvLookup = $script:Lr12UserEnvWriter
    foreach ($property in $fixtureEnvTable.PSObject.Properties) {
        $script:Lr12UserEnvLookup[$property.Name] = [string]$property.Value
    }
    $script:Lr12UserEnvLookup["CODEX_LOCAL_ROUTER_TOKEN"] = $null

    # 1. No router.config.json -> Initialize creates a valid user config.
    $routerConfigPath = Join-Path $sandbox.CodexHome "multimodel-manager/local-router/router.config.json"
    $codexConfigPath = Join-Path $sandbox.CodexHome "config.toml"
    Assert-True (-not (Test-Path -LiteralPath $routerConfigPath -PathType Leaf)) "Scenario 1 starts with no router.config.json"
    $output1 = Invoke-InitializeCaptured
    Assert-True (Test-Path -LiteralPath $routerConfigPath -PathType Leaf) "Scenario 1: Initialize creates the Router user config"
    $doc1 = Get-ManagedConfig $sandbox.CodexHome
    Assert-True ([int]$doc1.schema_version -eq 1) "Scenario 1: generated config is schema v1"
    Assert-True ([string]$doc1.mode -eq "router") "Scenario 1: generated config declares mode=router"
    Assert-True ([bool]$doc1.local_router.enabled) "Scenario 1: generated config enables the Local Router flag"
    Assert-True ([string]$doc1.local_router.host -eq "127.0.0.1") "Scenario 1: generated config stays loopback only"
    Assert-True ([int]$doc1.local_router.port -eq 47821) "Scenario 1: generated config uses the canonical default port"
    Assert-True (-not [bool]$doc1.local_router.thread_selection.enabled) "Scenario 1: thread_selection stays off by default"
    Assert-True (@($doc1.policies | Where-Object { $_.policy_id -eq "policy.failover-off" }).Count -eq 1) "Scenario 1: failover policy is declared without a cross-model body"
    Assert-True ($null -eq $doc1.policies[0].failover) "Scenario 1: no cross-model failover body is written"
    Assert-True $(if ($output1 -match "Config write\s*:\s*created") { $true } else { $false }) "Scenario 1: Initialize reports the config as created"

    # Golden fixture: the generated document must equal the reviewed bootstrap output.
    $goldenDoc = Get-Content -Raw -LiteralPath $goldenPath | ConvertFrom-Json -AsHashtable
    $generatedCanonical = Get-RouterBootstrapComparableJson (ConvertTo-RouterBootstrapCanonicalDocument $doc1)
    $goldenCanonical = Get-RouterBootstrapComparableJson (ConvertTo-RouterBootstrapCanonicalDocument $goldenDoc)
    Assert-True ($generatedCanonical -eq $goldenCanonical) "Golden: generated bootstrap config equals tests/fixtures/local-router/v1/bootstrap/router-config.expected.json"

    $providerRouteIds = @($doc1.provider_routes | ForEach-Object { $_.provider_route_id })
    foreach ($expected in $expectedProviderRoutes) {
        Assert-True ($expected -in $providerRouteIds) "Scenario 1: generated provider route $expected"
    }
    Assert-True (@($doc1.provider_routes).Count -eq 4) "Scenario 1: the five Router-supported providers with a present secret and approval get provider routes"
    Assert-True (@($doc1.model_routes).Count -eq 5) "Scenario 1: every approved canonical model gets a model route"
    Assert-True (@($doc1.routes).Count -eq 5) "Scenario 1: every model route gets a full route"
    $directDeepSeekRoute = @($doc1.provider_routes | Where-Object { $_.provider_id -eq "deepseek" })
    Assert-True ($directDeepSeekRoute.Count -eq 1) "Scenario 1: the direct DeepSeek provider route is generated once"
    Assert-True ($directDeepSeekRoute[0].adapter_id -eq "adapter.provider.deepseek.responses.v1") "Scenario 1: the direct DeepSeek route uses the DSR1 adapter identity"
    Assert-True ($directDeepSeekRoute[0].base_url_ref -eq "provider-config:deepseek.base_url") "Scenario 1: the direct DeepSeek route uses the approved base URL reference"
    $flashRoute = @($doc1.model_routes | Where-Object { $_.provider_id -eq "deepseek" -and $_.client_model_id -eq "deepseek-flash" })
    Assert-True ($flashRoute.Count -eq 1) "Scenario 1: the canonical deepseek-flash model route is generated"
    Assert-True ($flashRoute[0].upstream_model_id -eq "deepseek-flash") "Scenario 1: the canonical upstream model id is deepseek-flash"
    Assert-True ((@($flashRoute[0].aliases) -join ",") -eq "deepseek-v4-flash,deepseek-v4-flash-vision-exp") "Scenario 1: the legacy picker slugs are explicit model-route aliases"
    $proRoute = @($doc1.model_routes | Where-Object { $_.provider_id -eq "deepseek" -and $_.client_model_id -eq "deepseek-v4-pro" })
    Assert-True ($proRoute.Count -eq 1) "DSR2 decision D: direct deepseek-v4-pro is generated despite the Model Studio catalog duplicate"
    Assert-True ($proRoute[0].upstream_model_id -eq "deepseek-v4-pro") "DSR2 decision D: direct pro keeps canonical/upstream deepseek-v4-pro"
    Assert-True (@($proRoute[0].aliases).Count -eq 0) "DSR2 decision D: direct pro declares no aliases"
    Assert-True (@($doc1.model_routes | Where-Object { $_.provider_id -eq "mm_modelstudio" -and $_.client_model_id -eq "deepseek-v4-pro" }).Count -eq 0) "DSR2 decision D: Model Studio remains paused, so no active route claims that slug"
    Assert-True ((@($doc1.model_routes | ForEach-Object { $_.client_model_id }) + @($doc1.model_routes | ForEach-Object { $_.aliases }) | Where-Object { $_ } | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0) "DSR2 decision D: every client-facing slug has exactly one active owner"
    Assert-True (@($doc1.clients | Where-Object { $_.client_id -eq "client.codex_cli" -and $_.auth_scope -eq "responses:invoke" }).Count -eq 1) "Scenario 1: the Codex client identity and scope are declared"
    # DSR7-B-FIX1: the Control Plane needs its own generated client, because
    # ClientScopeRegistry resolves a required scope to exactly one enabled client.
    Assert-True (@($doc1.clients | Where-Object { $_.client_id -eq "client.control_plane" -and $_.auth_scope -eq "router:control-plane" -and [bool]$_.enabled -eq $true }).Count -eq 1) "DSR7-B-FIX1: the control-plane client identity and scope are declared exactly once"
    Assert-True (@($doc1.clients | Where-Object { $_.auth_scope -eq "router:control-plane" }).Count -eq 1) "DSR7-B-FIX1: exactly one generated client grants router:control-plane"
    Assert-True (@($doc1.clients | Where-Object { $_.auth_scope -eq "responses:invoke" }).Count -eq 1) "DSR7-B-FIX1: exactly one generated client grants responses:invoke"
    Assert-True (@($doc1.clients | ForEach-Object { $_.auth_scope } | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0) "DSR7-B-FIX1: generated clients never share an auth_scope"
    Assert-True (@($doc1.routes | Where-Object { @($_.client_ids) -contains "client.control_plane" }).Count -eq 0) "DSR7-B-FIX1: the control-plane client owns no model route"
    Assert-True (@($doc1.protocol_routes | Where-Object { $_.protocol_route_id -eq "protocol-route.responses-pass-through" }).Count -eq 1) "Scenario 1: the Responses protocol route is declared"
    $generatedText1 = Get-ConfigText $sandbox.CodexHome
    Assert-True ($generatedText1.Contains('"wire_api"') -eq $false) "Scenario 1: the Router config never carries a Codex wire_api projection"

    # 2. Second Initialize is idempotent.
    $receiptCountBefore = Get-ReceiptCount $sandbox.CodexHome
    $bytesBefore = Get-ConfigText $sandbox.CodexHome
    $output2 = Invoke-InitializeCaptured
    Assert-True ((Get-ConfigText $sandbox.CodexHome) -eq $bytesBefore) "Scenario 2: repeated Initialize leaves the config bytes unchanged"
    Assert-True ((Get-ReceiptCount $sandbox.CodexHome) -eq $receiptCountBefore) "Scenario 2: repeated Initialize creates no extra backup receipt"
    Assert-True $(if ($output2 -match "unchanged \(idempotent\)") { $true } else { $false }) "Scenario 2: repeated Initialize reports an idempotent no-op"

    # 3. Existing valid user config is preserved and safely updated.
    $partial = @{
        local_router = @{
            port = 50000
            limits = @{ max_connections = 16 }
        }
        policies = @(@{ policy_id = "policy.user-custom"; version = 1 })
    }
    Write-RouterConfigDocument $sandbox.CodexHome $partial
    $userBytesBefore = Get-ConfigText $sandbox.CodexHome
    $output3 = Invoke-InitializeCaptured
    $doc3 = Get-ManagedConfig $sandbox.CodexHome
    Assert-True ([int]$doc3.local_router.port -eq 50000) "Scenario 3: an existing valid port is preserved"
    Assert-True ([int]$doc3.local_router.limits.max_connections -eq 16) "Scenario 3: existing user limits are preserved"
    Assert-True (@($doc3.policies | Where-Object { $_.policy_id -eq "policy.user-custom" }).Count -eq 1) "Scenario 3: an existing user policy is preserved"
    Assert-True (@($doc3.policies).Count -eq 4) "Scenario 3: generated policies are added additively"
    Assert-True (@($doc3.provider_routes).Count -eq 4) "Scenario 3: generated provider routes are added to the existing config"
    Assert-True ((Get-ReceiptCount $sandbox.CodexHome) -gt $receiptCountBefore) "Scenario 3: updating an existing config writes a backup receipt"
    $receiptFiles = @(Get-ChildItem -LiteralPath (Join-Path $sandbox.CodexHome "multimodel-manager/router-bootstrap-receipts") -File)
    $latestReceipt = Get-Content -Raw -LiteralPath $receiptFiles[-1].FullName | ConvertFrom-Json
    Assert-True (Test-Path -LiteralPath ([string]$latestReceipt.backup_path) -PathType Leaf) "Scenario 3: the backup copy of the previous config exists"
    Assert-True ((Get-FileSha256 ([string]$latestReceipt.backup_path)) -eq [string]$latestReceipt.before_sha256) "Scenario 3: the receipt records the exact previous config hash"
    Assert-True ((Get-Content -Raw -LiteralPath ([string]$latestReceipt.backup_path)) -eq $userBytesBefore) "Scenario 3: the backup holds the exact pre-Initialize bytes"

    # 4 + 5. Corrupt / schema-invalid existing config fails closed without writes.
    $corruptText = "{ this is not json"
    Set-Content -LiteralPath $routerConfigPath -Value $corruptText -Encoding UTF8
    $corruptBytesBefore = Get-ConfigText $sandbox.CodexHome
    Assert-ThrowsMatch { Initialize-RouterCli } "not valid JSON" "Scenario 4: corrupt router config fails closed"
    Assert-True ((Get-ConfigText $sandbox.CodexHome) -eq $corruptBytesBefore) "Scenario 4: corrupt config bytes are untouched"

    $invalidDoc = @{
        schema_version = 1
        version = 1
        mode = "router"
        local_router = @{
            enabled = $true
            host = "0.0.0.0"
            port = 47821
            client_auth = @{ mode = "bearer_env_ref"; token_ref = "CODEX_LOCAL_ROUTER_TOKEN" }
            limits = @{ max_request_bytes = 16777216; max_header_bytes = 32768; max_connections = 32; shutdown_grace_ms = 15000 }
            thread_selection = @{ enabled = $false; pending_ttl_ms = 300000; active_idle_ttl_ms = 86400000 }
        }
        clients = @()
        protocol_routes = @()
        provider_routes = @()
        model_routes = @()
        routes = @()
        policies = @()
        updated_at = "2026-09-16T00:00:00Z"
    }
    Write-RouterConfigDocument $sandbox.CodexHome $invalidDoc
    $invalidBytesBefore = Get-ConfigText $sandbox.CodexHome
    Assert-ThrowsMatch { Initialize-RouterCli } "not schema-v1 valid" "Scenario 5: schema-invalid router config fails closed"
    Assert-True ((Get-ConfigText $sandbox.CodexHome) -eq $invalidBytesBefore) "Scenario 5: schema-invalid config bytes are untouched"

    # 11. Ambiguous model mapping in an existing config fails closed.
    $ambiguousDoc = @{
        schema_version = 1
        version = 1
        mode = "router"
        local_router = @{
            enabled = $true
            host = "127.0.0.1"
            port = 47821
            client_auth = @{ mode = "bearer_env_ref"; token_ref = "CODEX_LOCAL_ROUTER_TOKEN" }
            limits = @{ max_request_bytes = 16777216; max_header_bytes = 32768; max_connections = 32; shutdown_grace_ms = 15000 }
            thread_selection = @{ enabled = $false; pending_ttl_ms = 300000; active_idle_ttl_ms = 86400000 }
        }
        clients = @(@{ client_id = "client.codex_cli"; adapter_id = "adapter.client.codex_cli.responses.v1"; enabled = $true; auth_scope = "responses:invoke"; capabilities = @("text"); version = 1 })
        protocol_routes = @()
        provider_routes = @()
        model_routes = @(
            @{ model_route_id = "model-route.modelstudio-deepseek-v4-pro"; provider_id = "mm_modelstudio"; client_model_id = "deepseek-v4-pro"; model_id = "deepseek-v4-pro"; upstream_model_id = "deepseek-v4-pro"; capabilities = @("text"); identity_verification = "explicit_config"; enabled = $true; version = 1 },
            @{ model_route_id = "model-route.mimo-deepseek-v4-pro"; provider_id = "mm_mimo"; client_model_id = "deepseek-v4-pro"; model_id = "mimo-v2.5-pro"; upstream_model_id = "mimo-v2.5-pro"; capabilities = @("text"); identity_verification = "explicit_config"; enabled = $true; version = 1 }
        )
        routes = @()
        policies = @()
        updated_at = "2026-09-16T00:00:00Z"
    }
    Write-RouterConfigDocument $sandbox.CodexHome $ambiguousDoc
    $ambiguousBytesBefore = Get-ConfigText $sandbox.CodexHome
    Assert-ThrowsMatch { Initialize-RouterCli } "CLIENT_MODEL_SLUG_COLLISION" "Scenario 11: a client slug claimed by two enabled routes fails closed with CLIENT_MODEL_SLUG_COLLISION"
    Assert-True ((Get-ConfigText $sandbox.CodexHome) -eq $ambiguousBytesBefore) "Scenario 11: ambiguous config bytes are untouched"
    Assert-True $moduleText.Contains("CLIENT_MODEL_SLUG_COLLISION") "Scenario 11: the generator reports the explicit client-slug collision code"
    Assert-True $moduleText.Contains("Exactly one active owner per client slug is required") "Scenario 11: the collision message states the single-owner rule"
    Assert-True (-not $moduleText.Contains("would be ambiguous")) "DSR2 decision D: the old global model-id ambiguity wording is gone"

    # --- Fresh sandbox for token, route-scope and Enable integration scenarios --
    $sandbox = New-BootstrapSandbox
    $env:CODEX_HOME = $sandbox.CodexHome
    $routerConfigPath = Join-Path $sandbox.CodexHome "multimodel-manager/local-router/router.config.json"
    $codexConfigPath = Join-Path $sandbox.CodexHome "config.toml"

    # 6 + 8. Missing token -> generated through the seam, never printed or stored.
    $script:Lr12UserEnvWriter = @{}
    $script:Lr12UserEnvLookup = $script:Lr12UserEnvWriter
    foreach ($property in $fixtureEnvTable.PSObject.Properties) {
        $script:Lr12UserEnvLookup[$property.Name] = [string]$property.Value
    }
    $script:Lr12UserEnvLookup["CODEX_LOCAL_ROUTER_TOKEN"] = $null
    $output6 = Invoke-InitializeCaptured
    $generatedToken = [string]$script:Lr12UserEnvWriter["CODEX_LOCAL_ROUTER_TOKEN"]
    Assert-True (-not [string]::IsNullOrWhiteSpace($generatedToken)) "Scenario 6: a missing token is generated"
    Assert-True ($generatedToken.Length -ge 43) "Scenario 6: generated token carries at least 256 bits of entropy in base64url form"
    Assert-True ($generatedToken -match '^[A-Za-z0-9_-]+$') "Scenario 6: generated token uses the base64url alphabet"
    Assert-True $moduleText.Contains("RandomNumberGenerator") "Scenario 6: token generation uses a cryptographic random source"
    Assert-True $(if ($output6 -match ([regex]::Escape("CODEX_LOCAL_ROUTER_TOKEN = PRESENT"))) { $true } else { $false }) "Scenario 6: output reports the token as PRESENT"
    Assert-True (-not $output6.Contains($generatedToken)) "Scenario 8: the token value never appears in console output"
    Assert-True (-not (Get-ConfigText $sandbox.CodexHome).Contains($generatedToken)) "Scenario 8: the token value never appears in router.config.json"
    $secretLeak = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $sandbox.CodexHome -Recurse -File)) {
        if ((Get-Content -Raw -LiteralPath $file.FullName).Contains($generatedToken)) { $secretLeak += $file.FullName }
    }
    Assert-True ($secretLeak.Count -eq 0) "Scenario 8: the token value appears in no file under CODEX_HOME (backups/receipts/logs included)"

    # 7. An existing token is reused, never replaced.
    $existingToken = "fixture-existing-router-token-value"
    $script:Lr12UserEnvWriter["CODEX_LOCAL_ROUTER_TOKEN"] = $existingToken
    $output7 = Invoke-InitializeCaptured
    Assert-True ([string]$script:Lr12UserEnvWriter["CODEX_LOCAL_ROUTER_TOKEN"] -eq $existingToken) "Scenario 7: an existing token is never replaced"
    Assert-True $(if ($output7 -match "\(reused\)") { $true } else { $false }) "Scenario 7: output reports the token as reused"
    Assert-True (-not $output7.Contains($existingToken)) "Scenario 7: the reused token value is never printed"

    # 9 + 12. DSR2: the direct DeepSeek provider is a supported Router provider;
    # mm_openai_api still stays an honest gap.
    $doc9 = Get-ManagedConfig $sandbox.CodexHome
    $allProviderIds = @($doc9.provider_routes | ForEach-Object { $_.provider_id } | Sort-Object -Unique)
    Assert-True (@($allProviderIds | Where-Object { $_ -eq "deepseek" }).Count -eq 1) "Scenario 9: the direct DeepSeek provider route is generated from its own approval"
    Assert-True (@($allProviderIds | Where-Object { $_ -eq "mm_modelstudio" }).Count -eq 1) "Scenario 9: the Model Studio provider stays a separate provider scope"
    Assert-True (@($doc9.provider_routes | Where-Object { $_.provider_id -eq "mm_openai_api" }).Count -eq 0) "Scenario 12: no mm_openai_api provider route is fabricated"
    Assert-True (-not $output6.Contains("DEEPSEEK_ROUTER_GAP")) "Scenario 9: Initialize no longer reports DEEPSEEK_ROUTER_GAP"
    Assert-True (-not $output6.Contains("PROVIDER_NOT_ROUTER_SUPPORTED: provider `"deepseek`"")) "Scenario 9: the direct DeepSeek identity never reaches the unknown-provider branch"
    Assert-True ($output6.Contains("MM_OPENAI_API_CATALOG_CAPABILITY_GAP")) "Scenario 12: Initialize reports MM_OPENAI_API_CATALOG_CAPABILITY_GAP"
    Assert-True ($output6 -match "has a production provider adapter but no canonical catalog provider entry") "Scenario 12: the remaining mm_openai_api gap names the missing catalog layer"
    Assert-True (@($fixtureApprovals | Where-Object { $_.provider_id -eq "deepseek" -and $_.model_id -eq "deepseek-flash" }).Count -eq 1) "Scenario 9: the fixture approves the canonical direct DeepSeek flash model"
    Assert-True (@($fixtureApprovals | Where-Object { $_.provider_id -eq "deepseek" -and $_.model_id -eq "deepseek-chat" }).Count -eq 1) "Scenario 9: a non-canonical legacy DeepSeek approval stays routable-free in the fixture"
    Assert-True (@($doc9.model_routes | Where-Object { $_.provider_id -eq "deepseek" -and $_.client_model_id -eq "deepseek-chat" }).Count -eq 0) "Scenario 9: a non-canonical DeepSeek model id never gets a route"

    # 10. An unapproved canonical model never gets a route.
    Assert-True (@($doc9.model_routes | Where-Object { $_.client_model_id -eq "qwen3.8-max" }).Count -eq 0) "Scenario 10: an unapproved canonical model gets no route"
    Assert-True ((Get-Content -Raw -LiteralPath $approvedFixturePath).Contains("qwen3.8-max") -eq $false) "Scenario 10: the unapproved model is absent from the fixture approvals"

    # 13. A missing upstream secret reference leaves that provider unusable.
    $sandboxMissing = New-BootstrapSandbox
    $env:CODEX_HOME = $sandboxMissing.CodexHome
    $script:Lr12UserEnvWriter = @{}
    $script:Lr12UserEnvLookup = $script:Lr12UserEnvWriter
    foreach ($property in $fixtureEnvTable.PSObject.Properties) {
        if ($property.Name -eq $expectedSkippedEnv) { continue }
        $script:Lr12UserEnvLookup[$property.Name] = [string]$property.Value
    }
    $script:Lr12UserEnvLookup[$expectedSkippedEnv] = $null
    $script:Lr12UserEnvLookup["CODEX_LOCAL_ROUTER_TOKEN"] = "fixture-existing-router-token-value"
    $output13 = Invoke-InitializeCaptured
    $doc13 = Get-ManagedConfig $sandboxMissing.CodexHome
    Assert-True (@($doc13.provider_routes | Where-Object { $_.provider_id -eq $expectedSkippedProvider }).Count -eq 0) "Scenario 13: a provider without its upstream secret reference gets no provider route"
    Assert-True (@($doc13.model_routes | Where-Object { $_.provider_id -eq $expectedSkippedProvider }).Count -eq 0) "Scenario 13: no model route for the unusable provider"
    Assert-True (@($doc13.routes).Count -eq 4) "Scenario 13: only the usable providers' routes are enabled"
    Assert-True ($output13.Contains($expectedSkippedEnv)) "Scenario 13: the skipped provider and its required env name are reported"
    Assert-True (-not $output13.Contains("fixture-mimo-reference-value")) "Scenario 13: no secret value is printed"

    # 14 + 15 + 16. Direct Mode is preserved; Initialize satisfies Enable; Disable restores.
    $sandboxEnable = New-BootstrapSandbox
    $env:CODEX_HOME = $sandboxEnable.CodexHome
    $routerConfigPath = Join-Path $sandboxEnable.CodexHome "multimodel-manager/local-router/router.config.json"
    $directConfigPath = Join-Path $sandboxEnable.CodexHome "config.toml"
    Set-Content -LiteralPath $directConfigPath -Encoding UTF8 -Value @'
# Existing user Codex configuration (must be preserved exactly)
model = "deepseek-chat"
model_provider = "deepseek"
approval_policy = "on-request"

[model_providers.deepseek]
name = "DeepSeek (Direct Mode)"
base_url = "https://api.deepseek.com/v1"
env_key = "DEEPSEEK_API_KEY"
wire_api = "responses"
'@
    $directBytesBefore = Get-Content -Raw -LiteralPath $directConfigPath
    $script:Lr12UserEnvWriter = @{}
    $script:Lr12UserEnvLookup = $script:Lr12UserEnvWriter
    foreach ($property in $fixtureEnvTable.PSObject.Properties) {
        $script:Lr12UserEnvLookup[$property.Name] = [string]$property.Value
    }
    $script:Lr12UserEnvLookup["CODEX_LOCAL_ROUTER_TOKEN"] = "fixture-existing-router-token-value"
    $output14 = Invoke-InitializeCaptured
    Assert-True ((Get-Content -Raw -LiteralPath $directConfigPath) -eq $directBytesBefore) "Scenario 14: Initialize leaves config.toml byte-identical"
    Assert-True (-not (Get-Content -Raw -LiteralPath $directConfigPath).Contains("mm_local_router")) "Scenario 14: Initialize adds no mm_local_router provider block"
    Assert-True ((Get-LaunchGateFailures | Where-Object { $_ -match "not enabled" }).Count -gt 0) "Scenario 14: Direct Mode remains the active launch path before Enable"
    Assert-True (-not (Test-ProfileOwned (Get-RouterCliProfilePath))) "Scenario 14: Initialize writes no Router profile"

    $enabledPrecondition = Read-RouterUserConfig
    Assert-True ($enabledPrecondition.Valid -and $enabledPrecondition.Enabled) "Scenario 15: Initialize makes the Enable precondition satisfiable"
    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    Assert-True ((Get-RouterCliState).mode -eq "router") "Scenario 15: Enable succeeds on the bootstrapped route set"
    Assert-True ((Get-Content -Raw -LiteralPath $directConfigPath).Contains("[model_providers.mm_local_router]")) "Scenario 15: Enable adds the single mm_local_router provider block"
    Assert-True ((Get-Content -Raw -LiteralPath $directConfigPath).Contains('base_url = "http://127.0.0.1:47821/v1"')) "Scenario 15: the Router provider block points at the loopback port"
    Assert-True ((Get-LaunchGateFailures).Count -eq 0) "Scenario 15: the Router launch gate passes on the bootstrapped config"

    Disable-RouterCli -Force | Out-Null
    Assert-True ((Get-Content -Raw -LiteralPath $directConfigPath) -eq $directBytesBefore) "Scenario 16: Disable restores the exact original config.toml bytes"
    Assert-True ((Get-RouterCliState).mode -eq "direct") "Scenario 16: Disable returns the ModeSelector to Direct"
    Assert-True (Test-Path -LiteralPath $routerConfigPath -PathType Leaf) "Scenario 16: the bootstrapped Router user config is left in place (init state survives Disable)"

    # Doctor must expose the bootstrap ladder without printing secrets.
    $env:CODEX_HOME = $sandboxEnable.CodexHome
    $doctorOk = Invoke-RouterCliDoctor *>&1 | Out-String
    Assert-True ($doctorOk -match "Router state\s*:") "Doctor reports the Router bootstrap state"
    Assert-True ($doctorOk -match "INITIALIZED|ROUTER_ENABLED|ROUTER_READY|NOT_INITIALIZED") "Doctor reports a bootstrap state value"
    Assert-True ($doctorOk -match "Local client token\s*:\s*CODEX_LOCAL_ROUTER_TOKEN = PRESENT") "Doctor reports the token as PRESENT without a value"
    Assert-True (-not $doctorOk.Contains("fixture-existing-router-token-value")) "Doctor never prints a token value"

    # --- HS1B-RB1-FIX1: the Doctor route projection must be null-safe -------
    # A router.config.json with no routes must project as 0/0/0. Before the fix
    # ConvertFrom-Json returned $null for an absent or empty route array, and
    # PowerShell counts @($null) as one element, so Doctor printed a
    # fabricated 1/1/1 while the document carried no routes at all.
    $fixSandbox = New-BootstrapSandbox -WithoutApprovals
    $env:CODEX_HOME = $fixSandbox.CodexHome

    # A. JSON null for all three arrays.
    Write-RouterConfigWithRouteArrays $fixSandbox.CodexHome "null" "null" "null"
    $invA = Get-RouterBootstrapInventory
    Assert-True ($invA.ProviderRouteCount -eq 0 -and $invA.ModelRouteCount -eq 0 -and $invA.RouteCount -eq 0) `
        ("FIX1 A: JSON null route arrays project as 0/0/0 (actual {0}/{1}/{2})" -f $invA.ProviderRouteCount, $invA.ModelRouteCount, $invA.RouteCount)

    # A2. Route keys absent entirely, as in a config written before they existed.
    Write-RouterConfigWithoutRouteKeys $fixSandbox.CodexHome
    $invA2 = Get-RouterBootstrapInventory
    Assert-True ($invA2.ProviderRouteCount -eq 0 -and $invA2.ModelRouteCount -eq 0 -and $invA2.RouteCount -eq 0) `
        ("FIX1 A2: absent route keys project as 0/0/0 (actual {0}/{1}/{2})" -f $invA2.ProviderRouteCount, $invA2.ModelRouteCount, $invA2.RouteCount)

    # B. Empty arrays for all three.
    Write-RouterConfigWithRouteArrays $fixSandbox.CodexHome "[]" "[]" "[]"
    $invB = Get-RouterBootstrapInventory
    Assert-True ($invB.ProviderRouteCount -eq 0 -and $invB.ModelRouteCount -eq 0 -and $invB.RouteCount -eq 0) `
        ("FIX1 B: empty route arrays project as 0/0/0 (actual {0}/{1}/{2})" -f $invB.ProviderRouteCount, $invB.ModelRouteCount, $invB.RouteCount)

    # C. Exactly one entity in each array.
    $oneProvider = '[{ "provider_route_id": "provider-route.modelstudio", "provider_id": "mm_modelstudio", "enabled": true }]'
    $oneModel = '[{ "model_route_id": "model-route.modelstudio-deepseek-v4-pro", "provider_id": "mm_modelstudio", "client_model_id": "deepseek-v4-pro", "enabled": true }]'
    $oneRoute = '[{ "route_id": "route.modelstudio-deepseek-v4-pro", "model_route_id": "model-route.modelstudio-deepseek-v4-pro", "enabled": true }]'
    Write-RouterConfigWithRouteArrays $fixSandbox.CodexHome $oneProvider $oneModel $oneRoute
    $invC = Get-RouterBootstrapInventory
    Assert-True ($invC.ProviderRouteCount -eq 1 -and $invC.ModelRouteCount -eq 1 -and $invC.RouteCount -eq 1) `
        ("FIX1 C: a single entity per array projects as 1/1/1 (actual {0}/{1}/{2})" -f $invC.ProviderRouteCount, $invC.ModelRouteCount, $invC.RouteCount)

    # D. Multiple entities project the exact count.
    $manyProviders = '[{ "provider_route_id": "provider-route.modelstudio", "provider_id": "mm_modelstudio", "enabled": true }, { "provider_route_id": "provider-route.openrouter", "provider_id": "mm_openrouter", "enabled": true }]'
    $manyModels = '[{ "model_route_id": "model-route.a" }, { "model_route_id": "model-route.b" }, { "model_route_id": "model-route.c" }]'
    $manyRoutes = '[{ "route_id": "route.a" }, { "route_id": "route.b" }, { "route_id": "route.c" }, { "route_id": "route.d" }]'
    Write-RouterConfigWithRouteArrays $fixSandbox.CodexHome $manyProviders $manyModels $manyRoutes
    $invD = Get-RouterBootstrapInventory
    Assert-True ($invD.ProviderRouteCount -eq 2 -and $invD.ModelRouteCount -eq 3 -and $invD.RouteCount -eq 4) `
        ("FIX1 D: multiple entities project the exact count 2/3/4 (actual {0}/{1}/{2})" -f $invD.ProviderRouteCount, $invD.ModelRouteCount, $invD.RouteCount)

    # E. The real "nothing approved" bootstrap that NPG1-A hit: Initialize must
    #    report 0/0/0/0 and Doctor must not print the fabricated 1/1/1.
    $noApprovalSandbox = New-BootstrapSandbox -WithoutApprovals
    $env:CODEX_HOME = $noApprovalSandbox.CodexHome
    $script:Lr12UserEnvWriter = @{}
    $script:Lr12UserEnvLookup = $script:Lr12UserEnvWriter
    foreach ($property in $fixtureEnvTable.PSObject.Properties) {
        $script:Lr12UserEnvLookup[$property.Name] = [string]$property.Value
    }
    $script:Lr12UserEnvLookup["CODEX_LOCAL_ROUTER_TOKEN"] = "fixture-existing-router-token-value"
    $noApprovalConfigPath = Join-Path $noApprovalSandbox.CodexHome "multimodel-manager/local-router/router.config.json"
    $initNoApproval = Invoke-InitializeCaptured
    Assert-True (Test-Path -LiteralPath $noApprovalConfigPath -PathType Leaf) "FIX1 E: Initialize writes the Router user config without approvals"
    Assert-True ($initNoApproval -match "Provider routes\s*:\s*0") "FIX1 E: Initialize reports 0 provider routes"
    Assert-True ($initNoApproval -match "Model routes\s*:\s*0") "FIX1 E: Initialize reports 0 model routes"
    Assert-True ($initNoApproval -match "Full routes\s*:\s*0") "FIX1 E: Initialize reports 0 full routes"
    Assert-True ($initNoApproval -match "Route bootstrap\s*:\s*STOPPED - no approved Router-supported model") "FIX1 E: Initialize stops instead of fabricating a route"

    $invE = Get-RouterBootstrapInventory
    Assert-True ($invE.ProviderRouteCount -eq 0 -and $invE.ModelRouteCount -eq 0 -and $invE.RouteCount -eq 0 -and $invE.RoutableModelCount -eq 0) `
        ("FIX1 E: inventory projects 0/0/0/0 (actual {0}/{1}/{2}/{3})" -f $invE.ProviderRouteCount, $invE.ModelRouteCount, $invE.RouteCount, $invE.RoutableModelCount)

    $doctorNoApproval = Invoke-RouterCliDoctor *>&1 | Out-String
    Assert-True ($doctorNoApproval -match "Provider routes\s*:\s*0") "FIX1 E: Doctor reports Provider routes 0"
    Assert-True ($doctorNoApproval -match "Model routes\s*:\s*0") "FIX1 E: Doctor reports Model routes 0"
    Assert-True ($doctorNoApproval -match "Full routes\s*:\s*0") "FIX1 E: Doctor reports Full routes 0"
    Assert-True (-not ($doctorNoApproval -match "Provider routes\s*:\s*1")) "FIX1 E: Doctor no longer prints a fabricated provider route count"
    Assert-True (-not ($doctorNoApproval -match "Model routes\s*:\s*1")) "FIX1 E: Doctor no longer prints a fabricated model route count"
    Assert-True (-not ($doctorNoApproval -match "Full routes\s*:\s*1")) "FIX1 E: Doctor no longer prints a fabricated full route count"

    Remove-Item -LiteralPath $fixSandbox.Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $noApprovalSandbox.Root -Recurse -Force -ErrorAction SilentlyContinue

    # --- HS1C-CFG: installer support for local_router.thread_selection.quota_failover_enabled ---
    # The setting is optional (absent = false), must be a JSON boolean, needs
    # thread_selection.enabled=true when true, survives Initialize/re-Initialize
    # exactly as written, and Initialize never adds or enables it.
    $goldenText = Get-Content -Raw -LiteralPath $goldenPath
    Assert-True (-not $goldenText.Contains("quota_failover_enabled")) "HS1C-CFG: the reviewed golden fixture carries no quota_failover_enabled (legacy shape unchanged)"
    Assert-True (-not $doc1.local_router.thread_selection.ContainsKey("quota_failover_enabled")) "HS1C-CFG: a fresh Initialize never adds quota_failover_enabled (default stays off)"
    $defaultsText = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/config/router.defaults.json")
    Assert-True (-not $defaultsText.Contains("quota_failover_enabled")) "HS1C-CFG: the canonical Router defaults do not declare quota_failover_enabled"

    $hs1cSandbox = New-BootstrapSandbox
    $env:CODEX_HOME = $hs1cSandbox.CodexHome
    $script:Lr12UserEnvWriter = @{}
    $script:Lr12UserEnvLookup = $script:Lr12UserEnvWriter
    foreach ($property in $fixtureEnvTable.PSObject.Properties) {
        $script:Lr12UserEnvLookup[$property.Name] = [string]$property.Value
    }
    $script:Lr12UserEnvLookup["CODEX_LOCAL_ROUTER_TOKEN"] = "fixture-existing-router-token-value"
    $hs1cConfigPath = Join-Path $hs1cSandbox.CodexHome "multimodel-manager/local-router/router.config.json"

    # A. A legacy user config without the field initializes and stays off.
    Write-RouterConfigDocument $hs1cSandbox.CodexHome @{ local_router = @{ thread_selection = @{ enabled = $true } } }
    Invoke-InitializeCaptured | Out-Null
    $docA = Get-ManagedConfig $hs1cSandbox.CodexHome
    Assert-True ([bool]$docA.local_router.thread_selection.enabled) "HS1C-CFG A: a legacy config keeps its explicit thread_selection.enabled=true"
    Assert-True (-not $docA.local_router.thread_selection.ContainsKey("quota_failover_enabled")) "HS1C-CFG A: a legacy config without quota_failover_enabled stays without it (off)"

    # B. Explicit false is accepted and preserved as false (never flipped to true).
    Write-RouterConfigDocument $hs1cSandbox.CodexHome @{ local_router = @{ thread_selection = @{ enabled = $false; quota_failover_enabled = $false } } }
    Invoke-InitializeCaptured | Out-Null
    $docB = Get-ManagedConfig $hs1cSandbox.CodexHome
    Assert-True ($docB.local_router.thread_selection.ContainsKey("quota_failover_enabled") -and $docB.local_router.thread_selection.quota_failover_enabled -is [bool] -and -not $docB.local_router.thread_selection.quota_failover_enabled) "HS1C-CFG B: explicit quota_failover_enabled=false is preserved as false"

    # C. Explicit true with thread_selection.enabled=true is accepted and preserved;
    #    a second Initialize is a byte-identical no-op that keeps it.
    Write-RouterConfigDocument $hs1cSandbox.CodexHome @{ local_router = @{ thread_selection = @{ enabled = $true; quota_failover_enabled = $true } } }
    Invoke-InitializeCaptured | Out-Null
    $docC = Get-ManagedConfig $hs1cSandbox.CodexHome
    Assert-True ($docC.local_router.thread_selection.quota_failover_enabled -is [bool] -and $docC.local_router.thread_selection.quota_failover_enabled) "HS1C-CFG C: explicit quota_failover_enabled=true with thread_selection.enabled=true is preserved"
    $bytesC = Get-ConfigText $hs1cSandbox.CodexHome
    $receiptsC = Get-ReceiptCount $hs1cSandbox.CodexHome
    $outputC2 = Invoke-InitializeCaptured
    Assert-True ((Get-ConfigText $hs1cSandbox.CodexHome) -eq $bytesC) "HS1C-CFG C: re-Initialize leaves the HS-1C config bytes unchanged"
    Assert-True ((Get-ReceiptCount $hs1cSandbox.CodexHome) -eq $receiptsC) "HS1C-CFG C: re-Initialize writes no extra backup receipt"
    Assert-True $(if ($outputC2 -match "unchanged \(idempotent\)") { $true } else { $false }) "HS1C-CFG C: re-Initialize reports an idempotent no-op"

    # D. A real rewrite of a full config (one generated policy is missing, so
    #    Initialize must add it back and write the file) keeps the setting and
    #    rewrites no provider, endpoint, model route, route, client or auth entry.
    $docFull = Get-ManagedConfig $hs1cSandbox.CodexHome
    $docFull["policies"] = @($docFull["policies"] | Select-Object -Skip 1)
    Write-RouterConfigDocument $hs1cSandbox.CodexHome $docFull
    $docFull = Get-ManagedConfig $hs1cSandbox.CodexHome
    # Route created_at/updated_at are excluded exactly as Get-RouterBootstrapComparableJson
    # excludes them: an existing rewrite re-serializes them at whole-second precision.
    $withoutRouteTimestamps = {
        param($Entities)
        @($Entities | ForEach-Object {
                $copy = [ordered]@{}
                foreach ($key in $_.Keys) { if ($key -notin @("created_at", "updated_at")) { $copy[$key] = $_[$key] } }
                $copy
            }) | ConvertTo-Json -Depth 20 -Compress
    }
    $sectionsBefore = [ordered]@{}
    foreach ($section in @("clients", "protocol_routes", "provider_routes", "endpoints", "model_routes", "routes")) {
        $sectionsBefore[$section] = (& $withoutRouteTimestamps $docFull[$section])
    }
    $clientAuthBefore = ($docFull.local_router.client_auth | ConvertTo-Json -Compress)
    $receiptsD = Get-ReceiptCount $hs1cSandbox.CodexHome
    Invoke-InitializeCaptured | Out-Null
    $docD = Get-ManagedConfig $hs1cSandbox.CodexHome
    Assert-True ((Get-ReceiptCount $hs1cSandbox.CodexHome) -gt $receiptsD) "HS1C-CFG D: Initialize really rewrote the full config (backup receipt written)"
    Assert-True (@($docD["policies"]).Count -eq (@($docFull["policies"]).Count + 1)) "HS1C-CFG D: the missing generated policy is added back additively"
    $rewritten = @($sectionsBefore.Keys | Where-Object { (& $withoutRouteTimestamps $docD[$_]) -ne $sectionsBefore[$_] })
    Assert-True ($rewritten.Count -eq 0) ("HS1C-CFG D: providers, endpoints, model routes, routes and clients are not rewritten (changed: {0})" -f ($rewritten -join ","))
    Assert-True (($docD.local_router.client_auth | ConvertTo-Json -Compress) -eq $clientAuthBefore) "HS1C-CFG D: local_router.client_auth is not rewritten"
    Assert-True ($docD.local_router.thread_selection.quota_failover_enabled -is [bool] -and $docD.local_router.thread_selection.quota_failover_enabled) "HS1C-CFG D: quota_failover_enabled=true survives a real rewrite of a full config"

    # E. Invalid settings fail closed before any write: bytes untouched, no backup.
    $invalidCases = @(
        @{ Name = "true without thread_selection.enabled=true"; ThreadSelection = @{ enabled = $false; quota_failover_enabled = $true }; Pattern = "requires local_router\.thread_selection\.enabled=true" },
        @{ Name = 'the string "true"'; ThreadSelection = @{ enabled = $true; quota_failover_enabled = "true" }; Pattern = "quota_failover_enabled must be a boolean" },
        @{ Name = 'the string "false"'; ThreadSelection = @{ enabled = $true; quota_failover_enabled = "false" }; Pattern = "quota_failover_enabled must be a boolean" },
        @{ Name = "the number 1"; ThreadSelection = @{ enabled = $true; quota_failover_enabled = 1 }; Pattern = "quota_failover_enabled must be a boolean" },
        @{ Name = "the number 0"; ThreadSelection = @{ enabled = $true; quota_failover_enabled = 0 }; Pattern = "quota_failover_enabled must be a boolean" },
        @{ Name = "null"; ThreadSelection = @{ enabled = $true; quota_failover_enabled = $null }; Pattern = "quota_failover_enabled must be a boolean" },
        @{ Name = "an array"; ThreadSelection = @{ enabled = $true; quota_failover_enabled = @($true) }; Pattern = "quota_failover_enabled must be a boolean" },
        @{ Name = "an object"; ThreadSelection = @{ enabled = $true; quota_failover_enabled = @{ value = $true } }; Pattern = "quota_failover_enabled must be a boolean" },
        @{ Name = "an unknown thread_selection field"; ThreadSelection = @{ enabled = $true; quota_failover_mode = $true }; Pattern = "not part of schema v1: local_router\.thread_selection\.quota_failover_mode" },
        @{ Name = "a differently cased field name"; ThreadSelection = @{ enabled = $true; Quota_Failover_Enabled = $true }; Pattern = "not part of schema v1: local_router\.thread_selection\.Quota_Failover_Enabled" }
    )
    foreach ($case in $invalidCases) {
        Write-RouterConfigDocument $hs1cSandbox.CodexHome @{ local_router = @{ thread_selection = $case.ThreadSelection } }
        $invalidBytes = Get-ConfigText $hs1cSandbox.CodexHome
        $invalidReceipts = Get-ReceiptCount $hs1cSandbox.CodexHome
        Assert-ThrowsMatch { Initialize-RouterCli } $case.Pattern "HS1C-CFG E: quota_failover_enabled as $($case.Name) is rejected"
        Assert-True ((Get-ConfigText $hs1cSandbox.CodexHome) -eq $invalidBytes) "HS1C-CFG E: config bytes are untouched after rejecting $($case.Name)"
        Assert-True ((Get-ReceiptCount $hs1cSandbox.CodexHome) -eq $invalidReceipts) "HS1C-CFG E: no backup receipt is written after rejecting $($case.Name)"
    }

    # F. The document validator itself mirrors RouterConfigValidator.
    $schemaDoc = Get-Content -Raw -LiteralPath $goldenPath | ConvertFrom-Json -AsHashtable
    Assert-True (@(Get-RouterBootstrapDocumentErrors $schemaDoc).Count -eq 0) "HS1C-CFG F: the golden document without the field is schema-v1 valid"
    $schemaDoc.local_router.thread_selection["enabled"] = $true
    $schemaDoc.local_router.thread_selection["quota_failover_enabled"] = $true
    Assert-True (@(Get-RouterBootstrapDocumentErrors $schemaDoc).Count -eq 0) "HS1C-CFG F: quota_failover_enabled=true with thread_selection.enabled=true is schema-v1 valid"
    $schemaDoc.local_router.thread_selection["enabled"] = $false
    Assert-True (@(Get-RouterBootstrapDocumentErrors $schemaDoc | Where-Object { $_ -match "requires local_router\.thread_selection\.enabled=true" }).Count -eq 1) "HS1C-CFG F: quota_failover_enabled=true with thread_selection.enabled=false is reported"
    $schemaDoc.local_router.thread_selection["quota_failover_enabled"] = $false
    Assert-True (@(Get-RouterBootstrapDocumentErrors $schemaDoc).Count -eq 0) "HS1C-CFG F: quota_failover_enabled=false with thread_selection.enabled=false is schema-v1 valid"
    Assert-True ($moduleText.Contains('$optionalNested = @{ thread_selection = @("quota_failover_enabled") }')) "HS1C-CFG F: only the exact quota_failover_enabled name is admitted as an optional thread_selection field"

    Remove-Item -LiteralPath $hs1cSandbox.Root -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    Fail "Local Router bootstrap validation failed: $($_.Exception.Message)"
}
finally {
    if ($moduleLoaded) {
        $script:Lr12UserEnvWriter = $null
        $script:Lr12UserEnvLookup = $null
    }
    Restore-ProcessEnvSnapshot $envBefore
    if ($null -ne $sandbox) { Remove-Item -LiteralPath $sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

$envAfter = Save-ProcessEnvSnapshot
$differences = New-Object System.Collections.Generic.List[string]
foreach ($entry in $envBefore.GetEnumerator()) {
    $after = $envAfter[$entry.Key]
    if ($null -eq $entry.Value -and $null -eq $after) { continue }
    if ($null -ne $entry.Value -and $null -ne $after -and $entry.Value -eq $after) { continue }
    $differences.Add($entry.Key)
}
Assert-True ($differences.Count -eq 0) "Validator Process environment snapshot is restored exactly (before == after)"

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Local Router bootstrap validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}
Write-Host "Local Router bootstrap validation PASSED" -ForegroundColor Green
exit 0
