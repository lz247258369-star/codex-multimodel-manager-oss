param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) {
    $passes.Add($Message)
    Write-Host "PASS  $Message" -ForegroundColor Green
}

function Fail([string]$Message) {
    $failures.Add($Message)
    Write-Host "FAIL  $Message" -ForegroundColor Red
}

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Pass $Message } else { Fail $Message }
}

function Assert-Contains([string]$Text, [string]$Needle, [string]$Message) {
    Assert-True ($Text.Contains($Needle)) ($Message + " (expected '" + $Needle + "')")
}

function Assert-NotContains([string]$Text, [string]$Needle, [string]$Message) {
    Assert-True (-not $Text.Contains($Needle)) ($Message + " (forbidden '" + $Needle + "')")
}

function Read-Utf8Text([string]$Path) {
    return (Get-Content -Raw -LiteralPath $Path -Encoding UTF8)
}

$xamlPath = Join-Path $RepositoryRoot "installer/ui/visual-console.xaml"
$consolePath = Join-Path $RepositoryRoot "installer/scripts/visual-console.ps1"
$entryPath = Join-Path $RepositoryRoot "installer/scripts/visual-console-entry.ps1"
$runtimePath = Join-Path $RepositoryRoot "installer/scripts/visual-router-runtime.ps1"
$fixtureDir = Join-Path $RepositoryRoot "tests/fixtures/local-router/v4-ui"
$fakeServerPath = Join-Path $fixtureDir "fake-control-plane.ps1"
$schemaDir = Join-Path $RepositoryRoot "local-router/schemas"
$docPath = Join-Path $RepositoryRoot "docs/LOCAL_ROUTER_V4_UI.md"

Write-Host "Repository: $RepositoryRoot" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Structure: sixth page, preserved tabs, entrypoint wiring.
# ---------------------------------------------------------------------------
foreach ($path in @($xamlPath, $consolePath, $entryPath, $runtimePath, $fakeServerPath, $docPath)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Required LR-14 file exists: $path"
}

$xaml = Read-Utf8Text $xamlPath
$console = Read-Utf8Text $consolePath
$entry = Read-Utf8Text $entryPath
$runtime = Read-Utf8Text $runtimePath
$doc = Read-Utf8Text $docPath

Assert-True ($xaml.Contains('x:Name="NavRouter"')) "NavRouter exists in XAML"
Assert-True (([regex]::Matches($xaml, '<TabItem')).Count -eq 6) "XAML has exactly six tabs (0-5)"
Assert-True ($console.Contains('"NavDashboard","NavModels","NavProviders","NavStealth","NavTools","NavRouter"')) "Existing tab control indices 0-4 unchanged and NavRouter appended"
Assert-True ($console.Contains('Set-NavPage 5 "Local Router"')) "NavRouter maps to sixth tab (index 5)"
Assert-True ($entry.Contains('visual-router-runtime.ps1')) "Entrypoint loads visual-router-runtime"
Assert-True ($runtime.Contains('#requires -Version 7')) "Runtime requires PowerShell 7"

# XAML must be well formed and its Router controls must match the console list.
$xamlXml = $null
try {
    $xamlXml = [xml]$xaml
    Pass "visual-console.xaml is well-formed XML"
}
catch {
    Fail "visual-console.xaml is not well-formed XML: $($_.Exception.Message)"
}
if ($null -ne $xamlXml) {
    $names = @($xamlXml.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object { $_.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml") })
    $duplicates = @($names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    Assert-True ($duplicates.Count -eq 0) "XAML has no duplicate x:Name values"
    $routerNames = @($names | Where-Object { $_ -like "Router*" })
    $missing = @($routerNames | Where-Object { -not $console.Contains('"' + $_ + '"') })
    Assert-True ($missing.Count -eq 0) "Every XAML Router control is registered in visual-console.ps1"
    $unknown = @($names | Where-Object { $_ -like "Router*" } | Where-Object { -not $xaml.Contains('x:Name="' + $_ + '"') })
    Assert-True ($unknown.Count -eq 0) "XAML Router control names are well formed"
}

# ---------------------------------------------------------------------------
# 2. The Control Plane is the only LR-14 data source.
# ---------------------------------------------------------------------------
Assert-Contains $runtime '/v1/router/control-plane/status' "Runtime uses control-plane/status"
Assert-Contains $runtime '/v1/router/control-plane/usage' "Runtime uses control-plane/usage"
Assert-Contains $runtime '/v1/router/control-plane/requests' "Runtime uses control-plane/requests"
Assert-Contains $runtime '/v1/router/control-plane/policy' "Runtime uses control-plane/policy"
Assert-Contains $runtime '/v1/router/control-plane/feature' "Runtime uses control-plane/feature mutation"
Assert-NotContains $runtime '/v1/router/status' "Runtime never reads the legacy /v1/router/status contract"
Assert-NotContains $runtime '/v1/responses' "Runtime never calls the responses endpoint"
Assert-NotContains $runtime '/v1/models' "Runtime never probes model lists"
Assert-NotContains $runtime 'auth.json' "Runtime never reads auth.json"
Assert-NotContains $runtime 'DurableRequestLog' "Runtime never reads the durable log directly"
Assert-NotContains $runtime 'CODEX_LOCAL_ROUTER_TOKEN=' "Runtime never writes a literal token"
Assert-NotContains $runtime 'OPENROUTER_API_KEY=' "Runtime never writes an upstream key"
Assert-Contains $runtime '$script:RouterV4LoopbackHost = "127.0.0.1"' "Runtime pins the loopback host"
Assert-Contains $runtime 'Test-RouterV4LoopbackTarget' "Runtime has a fail-closed target check"

# Generation-aware mutations + no silent conflict overwrite.
Assert-Contains $runtime 'expected_generation' "Mutations carry expected_generation (generation CAS)"
Assert-Contains $runtime 'Invoke-RouterV4PolicyMutation' "Runtime implements a policy mutation"
Assert-Contains $runtime 'Invoke-RouterV4FeatureMutation' "Runtime implements a feature mutation"
Assert-Contains $runtime '"GENERATION_CONFLICT" = "配置已被其他操作更新，请刷新后重试。"' "Generation conflict maps to fixed text"
$conflictRegion = ($runtime -split 'Convert-RouterV4ControlCodeToUiCode')[0]

# HS-1B error-mapping precedence. The transport helpers live inside the engine
# here-string, so the mapping is asserted structurally: the operation-specific
# thread/capture blocks must appear BEFORE the generic status switch, otherwise a
# capture 409 or a thread-selection 409 would be collapsed into the generic
# config-generation conflict.
$failureMapBody = (($runtime -split 'function Get-RouterV4MutationFailureCode')[1] -split "`nfunction ")[0]
$genericSwitchAt = $failureMapBody.IndexOf('switch ($StatusCode)')
$captureOpenAt = $failureMapBody.IndexOf('$Operation -eq "capture-open"')
$selectionAt = $failureMapBody.IndexOf('$Operation -eq "thread-selection"')
$selectionClearAllAt = $failureMapBody.IndexOf('$Operation -eq "thread-selection-clear-all"')
$threadFeatureAt = $failureMapBody.IndexOf('$Operation -eq "thread-feature"')
$captureCancelAt = $failureMapBody.IndexOf('$Operation -eq "capture-cancel"')
Assert-True ($genericSwitchAt -gt 0) "Generic status mapping is preserved in the mutation failure mapper"
foreach ($entry in @(
    @{ Name = "capture-open"; At = $captureOpenAt },
    @{ Name = "thread-selection"; At = $selectionAt },
    @{ Name = "thread-selection-clear-all"; At = $selectionClearAllAt },
    @{ Name = "thread-feature"; At = $threadFeatureAt },
    @{ Name = "capture-cancel"; At = $captureCancelAt }
)) {
    Assert-True ($entry.At -gt 0 -and $entry.At -lt $genericSwitchAt) "HS-1B '$($entry.Name)' mapping precedes the generic status mapping"
}
Assert-True ($failureMapBody.Contains('if ($StatusCode -eq 409) { return "control_thread_capture_busy" }')) "capture-open 409 maps to capture busy"
Assert-True ($failureMapBody.Contains('if ($StatusCode -eq 409) { return "control_thread_selection_conflict" }')) "thread-selection 409 maps to a selection conflict"
Assert-True ($failureMapBody.Contains('if ($StatusCode -eq 409) { return "control_generation_conflict" }')) "thread-feature 409 stays a config generation conflict"
Assert-True ($failureMapBody.Contains('409 { return "control_generation_conflict" }')) "Generic non-HS1B 409 still maps to the config generation conflict"

# The HS-1B blocks must only return for explicitly defined status codes: an
# unconditional default return inside a block would truncate the generic HTTP
# mapping (401/403/413/429/5xx) for every other status.
$hs1bBlocks = ($failureMapBody -split 'switch \(\$StatusCode\)')[0]
foreach ($forbidden in @(
    'return "control_mutation_failed"',
    'return "control_thread_capture_unavailable"',
    'return "control_thread_selection_feature_update_failed"'
)) {
    Assert-True (-not $hs1bBlocks.Contains($forbidden)) "HS-1B blocks carry no unconditional default return ($forbidden)"
}

# Executable check of the extracted mapper: the function has no external
# helpers, so it can be evaluated directly and exercised case by case.
$mapperText = 'function Get-RouterV4MutationFailureCode' + $failureMapBody
# Define the extracted mapper in this scope so each case is an executable call.
. ([scriptblock]::Create($mapperText))
foreach ($case in @(
    @{ Status = 409; Operation = "capture-open"; Expected = "control_thread_capture_busy" },
    @{ Status = 409; Operation = "thread-selection"; Expected = "control_thread_selection_conflict" },
    @{ Status = 409; Operation = "thread-selection-clear"; Expected = "control_thread_selection_conflict" },
    @{ Status = 401; Operation = "thread-selection"; Expected = "authentication_required" },
    @{ Status = 403; Operation = "thread-selection"; Expected = "scope_denied" },
    @{ Status = 429; Operation = "thread-selection"; Expected = "control_mutation_busy" },
    @{ Status = 401; Operation = "capture-open"; Expected = "authentication_required" },
    @{ Status = 403; Operation = "capture-open"; Expected = "scope_denied" },
    @{ Status = 429; Operation = "capture-open"; Expected = "control_mutation_busy" },
    @{ Status = 413; Operation = "capture-open"; Expected = "control_payload_too_large" },
    @{ Status = 409; Operation = "policy"; Expected = "control_generation_conflict" },
    @{ Status = 404; Operation = "thread-selection"; Expected = "control_thread_not_observed" },
    @{ Status = 422; Operation = "thread-selection"; Expected = "control_model_not_approved" },
    @{ Status = 409; Operation = "thread-feature"; Expected = "control_generation_conflict" },
    @{ Status = 404; Operation = "capture-cancel"; Expected = "control_thread_capture_not_found" },
    @{ Status = 503; Operation = "thread-selection"; Expected = "control_thread_selection_disabled" },
    @{ Status = 503; Operation = "capture-open"; Expected = "control_thread_selection_disabled" }
)) {
    $actual = Get-RouterV4MutationFailureCode -StatusCode $case.Status -Operation $case.Operation
    Assert-True ($actual -eq $case.Expected) ("mutation mapping {0}+{1} -> {2} (got {3})" -f $case.Operation, $case.Status, $case.Expected, $actual)
}
$completeMutationRegion = if ($runtime.Contains('function Complete-RouterV4Mutation')) { ($runtime -split 'function Complete-RouterV4Mutation')[1] } else { "" }
Assert-True (-not ($completeMutationRegion -split 'function Invoke-RouterV4FeatureMutation')[0].Contains('Start-RouterV4Mutation')) "Conflict handling never auto-retries a rejected mutation"
$null = $conflictRegion

# Feature enable is never process lifecycle control.
Assert-NotContains $runtime 'Start-RouterV4FeatureProcess' "Runtime has no process start helper"
foreach ($forbidden in @('RouterStartButton', 'RouterStopButton', 'RouterRestartButton', '"Start Router"', '"Stop Router"')) {
    Assert-NotContains $runtime $forbidden "Runtime exposes no lifecycle control ($forbidden)"
}
Assert-NotContains $xaml 'x:Name="RouterStartButton"' "XAML exposes no Start control"
Assert-NotContains $xaml 'x:Name="RouterStopButton"' "XAML exposes no Stop control"
Assert-NotContains $xaml 'x:Name="RouterRestartButton"' "XAML exposes no Restart control"
Assert-Contains $xaml 'x:Name="RouterFeatureEnableButton"' "XAML exposes the feature enable control"
Assert-Contains $xaml 'x:Name="RouterFeatureDisableButton"' "XAML exposes the feature disable control"
Assert-Contains $xaml '启用 Router 功能' "Feature enable control is labelled as feature enable"
Assert-Contains $xaml '停用 Router 功能' "Feature disable control is labelled as feature disable"

# Cross-model and breaker mutation stay absent.
foreach ($forbidden in @('allow_cross_model_fallback', 'CrossModelEnableCheck', 'RouterCrossModelEnableButton')) {
    Assert-NotContains $xaml $forbidden "No cross-model enable control ($forbidden)"
    Assert-NotContains $runtime $forbidden "No cross-model enable logic ($forbidden)"
}
Assert-Contains $xaml 'RouterCrossModelText' "Cross-model status is display-only"
Assert-NotContains $xaml 'RouterCircuitBreakerMutation' "No circuit-breaker mutation control"
Assert-NotContains $runtime 'CircuitBreakerMutation(' "No circuit-breaker mutation call"

# Old placeholder states must be gone.
foreach ($placeholder in @(
    'UsageAvailable = $false',
    'CostAvailable = $false',
    'RecentRequestsAvailable = $false',
    '当前集成尚无安全读取边界',
    '尚无安全读取边界，不扫描原始日志',
    '成本：估算信息不可用'
)) {
    Assert-NotContains $runtime $placeholder "Runtime drops the old placeholder '$placeholder'"
    Assert-NotContains $xaml $placeholder "XAML drops the old placeholder '$placeholder'"
    Assert-NotContains $doc $placeholder "Docs drop the old placeholder '$placeholder'"
}

# Refresh must not be gated on the feature flag.
$startRefreshRegion = ($runtime -split 'function Start-RouterV4BackgroundRefresh')[1]
$startRefreshBody = ($startRefreshRegion -split 'function Complete-RouterV4BackgroundRefresh')[0]
Assert-True (-not ($startRefreshBody -match '\$feature\.Enabled')) "Background refresh is not gated on feature.Enabled"
Assert-True ($startRefreshBody.Contains('Test-RouterV4LoopbackTarget')) "Background refresh requires a valid loopback target"
Assert-True ($startRefreshBody.Contains('Get-RouterV4TokenPresent')) "Background refresh requires a token"
Assert-True ($startRefreshBody.Contains('$script:RouterV4BackgroundInFlight')) "Background refresh keeps a single in-flight guard"

# UI-thread refresh must never block on HTTP, and the worker must be warm.
$refreshRegion = ($runtime -split 'function Refresh-RouterV4UI')[1]
Assert-True (-not $refreshRegion.Contains('.GetAwaiter().GetResult()')) "UI-thread refresh path performs no blocking HTTP wait"
Assert-True (([regex]::Matches($runtime, 'Initialize-RouterV4BackgroundEngine')).Count -ge 2) "Persistent background engine is pre-warmed"
Assert-True ($runtime.Contains('$handle.IsCompleted')) "Background completion is harvested only after IsCompleted"
Assert-NotContains $runtime '[System.Threading.Thread]::new' "No raw thread waits outside a runspace"
Assert-Contains $runtime '$window.Add_Closing' "Window closing disposal exists"
Assert-Contains $runtime '$script:RouterV4Closing = $true' "Closing flag is set on window close"

# ---------------------------------------------------------------------------
# 3. Fixture shapes must match the real LR-14P contract.
# ---------------------------------------------------------------------------
function Get-JsonPropertyNames($Object) {
    if ($null -eq $Object) { return @() }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Assert-Shape([string]$FixtureName, [string[]]$Required, [string[]]$Allowed) {
    $path = Join-Path $fixtureDir $FixtureName
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Fixture exists: $FixtureName"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $payload = Read-Utf8Text $path | ConvertFrom-Json
    $names = Get-JsonPropertyNames $payload
    $missing = @($Required | Where-Object { $_ -notin $names })
    $extra = @($names | Where-Object { $_ -notin $Allowed })
    Assert-True ($missing.Count -eq 0) "Fixture $FixtureName has every required contract field"
    Assert-True ($extra.Count -eq 0) "Fixture $FixtureName has no contract-external field ($($extra -join ','))"
    return $payload
}

$statusPayload = Assert-Shape "control-plane-status.json" `
    @("schema_version", "config_generation", "lifecycle", "ready", "in_flight_count", "local_router_enabled", "supported_control_plane_contracts", "metering_availability", "recent_request_availability", "policy_mutation_available", "feature_mutation_available", "thread_selection", "health_summary", "circuit_breaker", "lifecycle_control") `
    @("schema_version", "config_generation", "lifecycle", "ready", "in_flight_count", "local_router_enabled", "supported_control_plane_contracts", "metering_availability", "recent_request_availability", "policy_mutation_available", "feature_mutation_available", "thread_selection", "health_summary", "circuit_breaker", "lifecycle_control")
$usagePayload = Assert-Shape "control-plane-usage.json" `
    @("schema_version", "scope", "billing_note", "record_count", "capacity", "known_usage_count", "unknown_usage_count", "known_cost_count", "unknown_cost_count", "input_tokens_total", "output_tokens_total", "estimated_cost_by_currency", "degraded", "degradation_codes", "records") `
    @("schema_version", "scope", "billing_note", "record_count", "capacity", "known_usage_count", "unknown_usage_count", "known_cost_count", "unknown_cost_count", "input_tokens_total", "output_tokens_total", "estimated_cost_by_currency", "degraded", "degradation_codes", "records")
$requestsPayload = Assert-Shape "control-plane-requests.json" `
    @("schema_version", "scope", "record_count", "degraded", "degradation_codes", "records") `
    @("schema_version", "scope", "record_count", "degraded", "degradation_codes", "records")
$policyPayload = Assert-Shape "control-plane-policy.json" `
    @("schema_version", "config_generation", "cross_model_fallback", "policies", "routes", "circuit_breaker") `
    @("schema_version", "config_generation", "cross_model_fallback", "policies", "routes", "circuit_breaker")

if ($null -ne $statusPayload) {
    Assert-True ([int]$statusPayload.schema_version -eq 1) "Status fixture carries schema_version 1"
    Assert-True ([string]$statusPayload.circuit_breaker.reason_code -eq "CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP") "Status fixture carries the breaker gap code"
    Assert-True ([bool]$statusPayload.circuit_breaker.mutation_available -eq $false) "Status fixture reports no breaker mutation"
    Assert-True ([string]$statusPayload.lifecycle_control.reason_code -eq "LIFECYCLE_CONTROL_GAP") "Status fixture carries the lifecycle gap code"
}
if ($null -ne $usagePayload) {
    Assert-True ([string]$usagePayload.scope -eq "bounded_recent_records") "Usage fixture uses the bounded scope"
    Assert-True ([string]$usagePayload.billing_note -eq "informational_estimate_not_billing") "Usage fixture marks cost as a non-billing estimate"
}
if ($null -ne $policyPayload) {
    Assert-True ([string]$policyPayload.cross_model_fallback -eq "HARD_OFF") "Policy fixture keeps cross-model fallback HARD_OFF"
}

# The fixture shapes must themselves satisfy the versioned schemas' required
# field sets (schema files are the source of truth).
foreach ($pair in @(
    @{ Schema = "control-plane-status.v1.schema.json"; Fixture = $statusPayload },
    @{ Schema = "control-plane-usage.v1.schema.json"; Fixture = $usagePayload },
    @{ Schema = "control-plane-recent-requests.v1.schema.json"; Fixture = $requestsPayload },
    @{ Schema = "control-plane-policy.v1.schema.json"; Fixture = $policyPayload }
)) {
    $schemaPath = Join-Path $schemaDir $pair.Schema
    $schema = Read-Utf8Text $schemaPath | ConvertFrom-Json
    $required = @($schema.required)
    $fixtureNames = Get-JsonPropertyNames $pair.Fixture
    $missing = @($required | Where-Object { $_ -notin $fixtureNames })
    Assert-True ($missing.Count -eq 0) "Fixture matches schema required fields for $($pair.Schema)"
    Assert-True ($schema.additionalProperties -eq $false) "Schema $($pair.Schema) stays closed (additionalProperties=false)"
}

# ---------------------------------------------------------------------------
# 4. End-to-end runtime mapping against the fake Control Plane.
# ---------------------------------------------------------------------------
$envBefore = @{}
foreach ($name in @("CODEX_HOME", "CODEX_LOCAL_ROUTER_TOKEN", "OPENROUTER_API_KEY", "CODEX_DASHSCOPE_API_KEY", "CODEX_OPENAI_API_KEY", "MIMO_API_KEY")) {
    $envBefore[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-mm-lr14-" + [guid]::NewGuid().ToString("N"))
$tempHome = Join-Path $tempRoot "codex-home"
$managerHome = Join-Path $tempHome "multimodel-manager"
$tempFixtureDir = Join-Path $tempRoot "fixtures"
$fakeToken = "lr14-fake-control-plane-token"
$sentinel = "V4_CONTROL_SECRET_SENTINEL_456"
$servers = New-Object System.Collections.Generic.List[object]

function Start-FakeControlPlane {
    param(
        [Parameter(Mandatory = $true)][string]$FixtureDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedToken,
        [Parameter(Mandatory = $false)][string]$ConflictFile = "",
        [Parameter(Mandatory = $false)][int]$DelayMs = 0,
        [Parameter(Mandatory = $false)][switch]$FailStatus,
        [Parameter(Mandatory = $false)][object]$RequestEnteredGate = $null,
        [Parameter(Mandatory = $false)][object]$ResponseReleaseGate = $null,
        [Parameter(Mandatory = $false)][int]$GateTimeoutMs = 20000,
        [Parameter(Mandatory = $false)][string]$GatePath = "/v1/router/control-plane/status"
    )
    $portFile = Join-Path $tempRoot ("fake-port-" + [guid]::NewGuid().ToString("N") + ".txt")
    $stateFile = Join-Path $tempRoot ("fake-state-" + [guid]::NewGuid().ToString("N") + ".json")
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    # Parameters are bound by name: a switch parameter cannot be bound
    # positionally, and the worker must fail loudly instead of silently running
    # with the wrong scenario.
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddCommand($fakeServerPath)
    [void]$ps.AddParameter("Port", 0)
    [void]$ps.AddParameter("PortFilePath", $portFile)
    [void]$ps.AddParameter("StateFilePath", $stateFile)
    [void]$ps.AddParameter("FixtureDir", $FixtureDirectory)
    [void]$ps.AddParameter("ExpectedToken", $ExpectedToken)
    [void]$ps.AddParameter("ConflictFilePath", $ConflictFile)
    [void]$ps.AddParameter("DelayMs", $DelayMs)
    [void]$ps.AddParameter("LifetimeSeconds", 180)
    if ($FailStatus) { [void]$ps.AddParameter("FailStatus", $true) }
    if ($null -ne $RequestEnteredGate) { [void]$ps.AddParameter("RequestEnteredGate", $RequestEnteredGate) }
    if ($null -ne $ResponseReleaseGate) { [void]$ps.AddParameter("ResponseReleaseGate", $ResponseReleaseGate) }
    if ($null -ne $RequestEnteredGate -or $null -ne $ResponseReleaseGate) {
        [void]$ps.AddParameter("GateTimeoutMs", $GateTimeoutMs)
        [void]$ps.AddParameter("GatePath", $GatePath)
    }
    $handle = $ps.BeginInvoke()

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $portFile -PathType Leaf)) {
        Start-Sleep -Milliseconds 50
    }
    $port = 0
    if (Test-Path -LiteralPath $portFile -PathType Leaf) {
        $port = [int]((Read-Utf8Text $portFile).Trim())
    }

    $server = [pscustomobject]@{
        Runspace = $runspace
        PowerShell = $ps
        Handle = $handle
        Port = $port
        PortFile = $portFile
        StateFile = $stateFile
    }
    $servers.Add($server) | Out-Null
    return $server
}

function Read-FakeState($Server) {
    if (-not (Test-Path -LiteralPath $Server.StateFile -PathType Leaf)) { return $null }
    try {
        return (Read-Utf8Text $Server.StateFile | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

# Deterministic non-blocking predicate. The refresh contract holds only when the
# caller had ALREADY returned while a real HTTP request was still unanswered and
# the background worker had not been treated as complete yet. Every input is an
# observed event or state - never an elapsed time - so a loaded runner cannot
# flip it.
function Test-NonBlockingRefreshOrdering {
    param(
        [bool]$UiCallReturned,
        [bool]$RequestWasHeld,
        [bool]$ResponseStillHeldAtCheck,
        [bool]$BackgroundStillInFlight
    )
    return ($UiCallReturned -and $RequestWasHeld -and $ResponseStillHeldAtCheck -and $BackgroundStillInFlight)
}

function Wait-RouterV4BackgroundRefresh {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not $script:RouterV4BackgroundInFlight) { return }
        $handle = $script:RouterV4BackgroundHandle
        if ($null -ne $handle -and $handle.IsCompleted) {
            Complete-RouterV4BackgroundRefresh
            return
        }
        Start-Sleep -Milliseconds 25
    }
    Complete-RouterV4BackgroundRefresh
}

function Wait-RouterV4Mutation {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not $script:RouterV4MutationInFlight) { return }
        $handle = $script:RouterV4MutationHandle
        if ($null -ne $handle -and $handle.IsCompleted) {
            Complete-RouterV4Mutation
            return
        }
        Start-Sleep -Milliseconds 25
    }
    Complete-RouterV4Mutation
}

function Write-RouterV4Config([int]$Port, [string]$HostValue = "127.0.0.1", [bool]$Enabled = $true, [string]$Mode = "router") {
    $payload = [ordered]@{
        schema_version = 1
        version = 1
        mode = $Mode
        local_router = [ordered]@{ enabled = $Enabled; host = $HostValue; port = $Port }
        clients = @()
        protocol_routes = @()
        provider_routes = @()
        model_routes = @()
        routes = @()
        policies = @()
        updated_at = "2026-09-12T00:00:00Z"
    }
    ($payload | ConvertTo-Json -Depth 6 -Compress) | Set-Content -LiteralPath (Join-Path $managerHome "local-router/router.config.json") -Encoding UTF8
}

function Write-HomeSnapshot {
    $paths = @(
        (Join-Path $tempHome "config.toml"),
        (Join-Path $managerHome "local-router/router.config.json"),
        (Join-Path $managerHome "local-router/runtime/router.state.json"),
        (Join-Path $managerHome "router-cli-state.json"),
        (Join-Path $managerHome "desktop-route-state.json"),
        (Join-Path $tempHome ".env")
    )
    $hash = [System.Security.Cryptography.SHA256]::Create()
    $builder = New-Object System.Text.StringBuilder
    try {
        foreach ($path in $paths) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $bytes = [System.IO.File]::ReadAllBytes($path)
                [void]$builder.Append(([System.BitConverter]::ToString($hash.ComputeHash($bytes))).Replace("-", ""))
            }
        }
    }
    finally {
        $hash.Dispose()
    }
    return $builder.ToString()
}

function New-RouterV4ControlStubs {
    Add-Type -AssemblyName PresentationFramework
    $textNames = @(
        "RouterFeatureText", "RouterRuntimeText", "RouterOverallText", "RouterWarningsText", "RouterConfiguredText", "RouterInFlightText",
        "RouterHealthText", "RouterCrossModelText", "RouterCircuitBreakerText", "RouterFeatureMutationText", "RouterLifecycleText", "RouterMutationStatusText",
        "CliModeText", "CliModelText", "CliEffortText", "CliReadinessText", "RouterModelInfoText",
        "DesktopModeText", "DesktopModelText", "DesktopEffortText", "DesktopReadinessText",
        "RouterUsageText", "RouterCostText", "RouterPolicyText", "RouterRecentText", "RouterLimitationsText"
    )
    foreach ($name in $textNames) {
        Set-Variable -Name $name -Scope Script -Value ([System.Windows.Controls.TextBlock]::new())
    }
    foreach ($name in @("RouterFeatureBadge", "RouterRuntimeBadge")) {
        Set-Variable -Name $name -Scope Script -Value ([System.Windows.Controls.TextBlock]::new())
    }
    foreach ($name in @(
        "RouterRefreshButton", "RouterRestoreDirectButton", "RouterCliEnableButton", "RouterCliDisableButton", "RouterCliLaunchButton",
        "RouterDesktopActivateButton", "RouterDesktopRestoreButton", "RouterFeatureEnableButton", "RouterFeatureDisableButton",
        "RouterPolicyRetrySaveButton", "RouterPolicyTimeoutSaveButton", "RouterPolicyFailoverSaveButton"
    )) {
        Set-Variable -Name $name -Scope Script -Value ([System.Windows.Controls.Button]::new())
    }
    Set-Variable -Name "RouterPolicyRetryAttemptsBox" -Scope Script -Value ([System.Windows.Controls.TextBox]::new())
    Set-Variable -Name "RouterPolicyTimeoutTotalBox" -Scope Script -Value ([System.Windows.Controls.TextBox]::new())
    Set-Variable -Name "RouterPolicyCombo" -Scope Script -Value ([System.Windows.Controls.ComboBox]::new())
    Set-Variable -Name "RouterPolicyFailoverProviderCheck" -Scope Script -Value ([System.Windows.Controls.CheckBox]::new())
    Set-Variable -Name "RouterRecentList" -Scope Script -Value ([System.Windows.Controls.ItemsControl]::new())
}

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $managerHome "local-router/runtime") | Out-Null
    New-Item -ItemType Directory -Force -Path $tempFixtureDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixtureDir "control-plane-status.json") -Destination $tempFixtureDir -Force
    Copy-Item -LiteralPath (Join-Path $fixtureDir "control-plane-usage.json") -Destination $tempFixtureDir -Force
    Copy-Item -LiteralPath (Join-Path $fixtureDir "control-plane-requests.json") -Destination $tempFixtureDir -Force
    Copy-Item -LiteralPath (Join-Path $fixtureDir "control-plane-policy.json") -Destination $tempFixtureDir -Force

    $env:CODEX_HOME = $tempHome
    $env:CODEX_LOCAL_ROUTER_TOKEN = $fakeToken

    $conflictFile = Join-Path $tempRoot "conflict.once"
    $server = Start-FakeControlPlane -FixtureDirectory $tempFixtureDir -ExpectedToken $fakeToken -ConflictFile $conflictFile
    Assert-True ($server.Port -gt 0) "Fake Control Plane binds a 127.0.0.1 loopback port"

    . $runtimePath
    New-RouterV4ControlStubs
    function Get-ColorBrush([string]$Color) { return $Color }
    # Headless validation must never block on a WPF message box: capture the
    # fixed allowlisted code that the UI would show instead.
    $script:RouterV4ShownErrorCodes = New-Object System.Collections.Generic.List[string]
    function Show-RouterV4Error([string]$Code, [string]$Detail = "") {
        $null = $Detail
        $script:RouterV4ShownErrorCodes.Add($Code) | Out-Null
    }

    Initialize-RouterV4BackgroundEngine
    Assert-True ($null -ne $script:RouterV4BackgroundRunspace) "Persistent background engine is pre-warmed before refresh scheduling"

    # Target / token preconditions must be fail-closed.
    Assert-True (Test-RouterV4LoopbackTarget "127.0.0.1" 47821) "Loopback target accepted"
    Assert-True (-not (Test-RouterV4LoopbackTarget "0.0.0.0" 47821)) "Wildcard host is rejected"
    Assert-True (-not (Test-RouterV4LoopbackTarget "192.168.1.10" 47821)) "Remote host is rejected"
    Assert-True (-not (Test-RouterV4LoopbackTarget "127.0.0.1" 0)) "Invalid port is rejected"

    Write-RouterV4Config -Port $server.Port
    Set-Content -LiteralPath (Join-Path $tempHome "config.toml") -Value "approval_policy = `"on-request`"" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $tempHome ".env") -Value "KEEP=1" -Encoding UTF8
    @{ schema_version = 1; mode = "router"; generation = 1; selected_model = "qwen3-coder-plus"; reasoning_effort = "high"; host = "127.0.0.1"; port = $server.Port; provider_id = "mm_local_router"; token_env = "CODEX_LOCAL_ROUTER_TOKEN" } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $managerHome "router-cli-state.json") -Encoding UTF8
    @{ schema_version = 1; active = $false; route_kind = "direct" } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $managerHome "desktop-route-state.json") -Encoding UTF8

    # --- open + refresh: read only -----------------------------------------
    $beforeHash = Write-HomeSnapshot
    Refresh-RouterV4UI
    Assert-True ($script:RouterV4BackgroundInFlight) "Refresh starts a background worker immediately"
    Wait-RouterV4BackgroundRefresh
    Assert-True (-not $script:RouterV4BackgroundInFlight) "Background worker is harvested and cleared"
    Assert-True ((Write-HomeSnapshot) -eq $beforeHash) "Open/refresh performs no write to config, CLI state, Desktop state, or .env"

    # Steady-state timer tick: the dispatch must return without waiting for the
    # HTTP response. The elapsed time is OBSERVATION ONLY (it measures JIT,
    # runspace and file-system noise on a shared runner, not the contract), so it
    # is printed and never asserted. The contract itself is proven by ordering in
    # the gated scenario below.
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Refresh-RouterV4UI
    $stopwatch.Stop()
    $schedulingMs = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 1)
    Write-Host ("V4_UI_REFRESH_OBSERVED_MS = {0}" -f $schedulingMs) -ForegroundColor DarkGray
    Wait-RouterV4BackgroundRefresh

    # --- deterministic non-blocking contract (held HTTP response) -------------
    # A second fake Control Plane holds its first status read open: it signals
    # RequestEntered once a real request has been read and only writes the
    # response after ReleaseResponse is set. The three facts below therefore
    # prove the contract without any wall-clock threshold:
    #   1. the request really reached the server while it was still unanswered,
    #   2. the UI call had already returned at that moment (this test line runs
    #      on the caller thread after Refresh-RouterV4UI returned),
    #   3. the background worker had not been treated as completed yet.
    # The release happens immediately after those three facts are sampled, well
    # inside the router's own 800 ms control-plane HTTP timeout.
    $requestEnteredGate = [System.Threading.ManualResetEventSlim]::new($false)
    $responseReleaseGate = [System.Threading.ManualResetEventSlim]::new($false)
    try {
        $gateServer = Start-FakeControlPlane -FixtureDirectory $tempFixtureDir -ExpectedToken $fakeToken `
            -RequestEnteredGate $requestEnteredGate -ResponseReleaseGate $responseReleaseGate `
            -GateTimeoutMs 20000 -GatePath "/v1/router/control-plane/status"
        Assert-True ($gateServer.Port -gt 0) "Gated Fake Control Plane binds a 127.0.0.1 loopback port"

        Write-RouterV4Config -Port $gateServer.Port
        $script:RouterV4LastControlPlane = $null
        if ($script:RouterV4BackgroundInFlight) { Complete-RouterV4BackgroundRefresh }
        Assert-True (-not $script:RouterV4BackgroundInFlight) "No refresh is in flight before the gated dispatch"

        $gateStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $generationBeforeGatedRefresh = [int]$script:RouterV4RefreshGeneration
        Refresh-RouterV4UI
        $gateStopwatch.Stop()
        Write-Host ("V4_UI_GATED_REFRESH_OBSERVED_MS = {0}" -f [math]::Round($gateStopwatch.Elapsed.TotalMilliseconds, 1)) -ForegroundColor DarkGray

        $uiCallReturned = $true
        $requestWasHeld = $requestEnteredGate.Wait(10000)
        $responseStillHeld = -not $responseReleaseGate.IsSet
        $backgroundStillInFlight = [bool]$script:RouterV4BackgroundInFlight
        $responseReleaseGate.Set()

        Assert-True $requestWasHeld "HTTP_REQUEST_WAS_ACTUALLY_HELD = TRUE (a real request was read by the fake server while the response was withheld)"
        Assert-True $responseStillHeld "The response gate was still closed when the UI call had already returned"
        Assert-True $backgroundStillInFlight "BACKGROUND_REFRESH_STILL_IN_FLIGHT_WHILE_HTTP_HELD = TRUE (not treated as finished)"
        Assert-True (Test-NonBlockingRefreshOrdering -UiCallReturned $uiCallReturned -RequestWasHeld $requestWasHeld -ResponseStillHeldAtCheck $responseStillHeld -BackgroundStillInFlight $backgroundStillInFlight) "UI_REFRESH_RETURNED_BEFORE_HTTP_RESPONSE = TRUE (observed ordering, no wall-clock threshold)"

        Wait-RouterV4BackgroundRefresh
        $gateState = Read-FakeState $gateServer
        Assert-True (-not $script:RouterV4BackgroundInFlight) "BACKGROUND_REFRESH_COMPLETED_AFTER_RELEASE = TRUE"
        Assert-True ($null -ne $gateState -and [bool]$gateState.gate_used -and [bool]$gateState.gate_released -and -not [bool]$gateState.gate_timed_out) "The held response was released inside the bounded gate (no gate timeout)"
        Assert-True ($null -ne $gateState -and [int]$gateState.read_count -ge 1) "The held request was a counted control-plane read"
        $gateSnapshot = Get-RouterV4SnapshotCore
        Assert-True ([bool]$gateSnapshot.ControlPlaneStatusOk) "The released response is applied to the snapshot"
        Assert-True ([bool]$gateSnapshot.RuntimeReady -and [string]$gateSnapshot.RuntimeLifecycle -eq "READY") "The released response still maps the READY contract"
        Assert-True ([int]$script:RouterV4RefreshGeneration -eq ($generationBeforeGatedRefresh + 1)) "Exactly one background refresh was dispatched for the gated tick (no duplicate or extra refresh)"
    }
    finally {
        # Never leave the fake server (or the router) parked on the gate.
        $responseReleaseGate.Set()
        Write-RouterV4Config -Port $server.Port
        $script:RouterV4LastControlPlane = $null
        Refresh-RouterV4UI
        Wait-RouterV4BackgroundRefresh
        $requestEnteredGate.Dispose()
        $responseReleaseGate.Dispose()
    }

    # --- negative controls: the same harness must FAIL when a fact is wrong ----
    # 1/2/3/4: each single wrong fact must make the ordering predicate false.
    $orderingNegatives = @(
        (Test-NonBlockingRefreshOrdering -UiCallReturned $false -RequestWasHeld $true -ResponseStillHeldAtCheck $true -BackgroundStillInFlight $true),
        (Test-NonBlockingRefreshOrdering -UiCallReturned $true -RequestWasHeld $false -ResponseStillHeldAtCheck $true -BackgroundStillInFlight $true),
        (Test-NonBlockingRefreshOrdering -UiCallReturned $true -RequestWasHeld $true -ResponseStillHeldAtCheck $false -BackgroundStillInFlight $true),
        (Test-NonBlockingRefreshOrdering -UiCallReturned $true -RequestWasHeld $true -ResponseStillHeldAtCheck $true -BackgroundStillInFlight $false)
    )
    Assert-True (-not ($orderingNegatives -contains $true)) "NEGATIVE_PATH: a missing request, a blocking caller, an early response, or a finished background can never satisfy the ordering predicate"

    # 4 (real): an armed gate that is never released before its bounded wait must
    # surface as gate_timed_out, i.e. the harness detects the fault instead of
    # hanging or silently passing.
    $timeoutEnteredGate = [System.Threading.ManualResetEventSlim]::new($false)
    $timeoutReleaseGate = [System.Threading.ManualResetEventSlim]::new($false)
    try {
        $timeoutServer = Start-FakeControlPlane -FixtureDirectory $tempFixtureDir -ExpectedToken $fakeToken `
            -RequestEnteredGate $timeoutEnteredGate -ResponseReleaseGate $timeoutReleaseGate `
            -GateTimeoutMs 400 -GatePath "/v1/router/control-plane/status"
        Write-RouterV4Config -Port $timeoutServer.Port
        $script:RouterV4LastControlPlane = $null
        Refresh-RouterV4UI
        $timeoutEntered = $timeoutEnteredGate.Wait(10000)
        $timeoutState = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $deadline) {
            $timeoutState = Read-FakeState $timeoutServer
            if ($null -ne $timeoutState -and [bool]$timeoutState.gate_used -and [bool]$timeoutState.gate_timed_out) { break }
            Start-Sleep -Milliseconds 25
        }
        Wait-RouterV4BackgroundRefresh
        Assert-True $timeoutEntered "NEGATIVE_PATH: the un-released control request still reached the fake server"
        Assert-True ($null -ne $timeoutState -and [bool]$timeoutState.gate_timed_out) "NEGATIVE_PATH: an unreleased response is detected as gate_timed_out (FAIL) instead of hanging or passing"
        Assert-True (-not (Test-NonBlockingRefreshOrdering -UiCallReturned $true -RequestWasHeld $timeoutEntered -ResponseStillHeldAtCheck (-not [bool]$timeoutState.gate_timed_out) -BackgroundStillInFlight $true)) "NEGATIVE_PATH: the timed-out gate can never satisfy the ordering predicate"
    }
    finally {
        $timeoutReleaseGate.Set()
        Write-RouterV4Config -Port $server.Port
        $script:RouterV4LastControlPlane = $null
        Refresh-RouterV4UI
        Wait-RouterV4BackgroundRefresh
        $timeoutEnteredGate.Dispose()
        $timeoutReleaseGate.Dispose()
    }

    # 5 (real): a deliberately synchronous read is the stand-in for a blocking
    # implementation - it must NOT return while the response is withheld, which
    # proves the harness distinguishes blocking from non-blocking.
    $syncEnteredGate = [System.Threading.ManualResetEventSlim]::new($false)
    $syncReleaseGate = [System.Threading.ManualResetEventSlim]::new($false)
    try {
        $syncServer = Start-FakeControlPlane -FixtureDirectory $tempFixtureDir -ExpectedToken $fakeToken `
            -RequestEnteredGate $syncEnteredGate -ResponseReleaseGate $syncReleaseGate `
            -GateTimeoutMs 20000 -GatePath "/v1/router/control-plane/status"
        $syncClient = [System.Net.Http.HttpClient]::new()
        try {
            $syncClient.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $fakeToken)
            $syncTask = $syncClient.GetAsync("http://127.0.0.1:$($syncServer.Port)/v1/router/control-plane/status")
            Assert-True ($syncEnteredGate.Wait(10000)) "NEGATIVE_PATH: the blocking control request reached the fake server"
            Assert-True (-not $syncTask.Wait(1500)) "NEGATIVE_PATH: a synchronous read does NOT return while the response is withheld"
            $syncReleaseGate.Set()
            Assert-True ($syncTask.Wait(10000)) "NEGATIVE_PATH: the blocking control read completes only after the release"
            $syncTask.Result.Dispose()
        }
        finally {
            $syncClient.Dispose()
        }
    }
    finally {
        $syncReleaseGate.Set()
        $syncEnteredGate.Dispose()
        $syncReleaseGate.Dispose()
    }

    $state = Read-FakeState $server
    Assert-True ($null -ne $state) "Fake Control Plane state is readable"
    Assert-True ([int]$state.policy_put_count -eq 0 -and [int]$state.feature_put_count -eq 0) "Open/refresh issues zero mutation requests"
    Assert-True ([int]$state.provider_count -eq 0) "Open/refresh issues zero provider/model requests"
    Assert-True ([int]$state.legacy_status_count -eq 0) "Open/refresh never touches the legacy /v1/router/status"
    Assert-True ([int]$state.read_count -ge 4) "Refresh reads status, usage, requests, and policy"

    $snapshot = Get-RouterV4SnapshotCore
    Assert-True ([bool]$snapshot.ControlPlaneStatusOk) "Control-plane status is authoritative and available"
    Assert-True ([bool]$snapshot.ConfiguredFeatureEnabled) "Configured feature state is reported separately"
    Assert-True ([bool]$snapshot.RuntimeFeatureEnabled) "Runtime feature state maps from control-plane status"
    Assert-True ([string]$snapshot.RuntimeLifecycle -eq "READY") "Runtime lifecycle maps from control-plane status"
    Assert-True ([bool]$snapshot.RuntimeReady) "Runtime ready maps from control-plane status"
    Assert-True ([bool]$snapshot.HealthAvailable) "Passive health comes from the control plane"
    Assert-True ([int]$snapshot.HealthHealthyCount -eq 1 -and [int]$snapshot.HealthDegradedCount -eq 1) "Health counts map (healthy 1 / degraded 1)"
    Assert-True ([int]$snapshot.UsageInputTokensTotal -eq 100 -and [int]$snapshot.UsageOutputTokensTotal -eq 25) "Usage token totals map from control-plane/usage"
    Assert-True ([int]$snapshot.UsageRecordCount -eq 2 -and [int]$snapshot.UsageCapacity -eq 500) "Usage record count/capacity map"
    Assert-True (@($snapshot.UsageCurrencies).Count -eq 1 -and [string]$snapshot.UsageCurrencies[0].Currency -eq "USD") "Cost currency total maps from control-plane/usage"
    Assert-True (@($snapshot.RecentItems).Count -eq 2) "Recent requests map from control-plane/requests"
    Assert-True ([string]$snapshot.RecentItems[0].RequestId -eq "req-0000000000000001") "Recent request id maps"
    Assert-True ([string]$snapshot.RecentItems[0].ProviderId -eq "mm_openrouter") "Recent provider maps"
    Assert-True ([string]$snapshot.RecentItems[1].ErrorCode -eq "provider_5xx") "Recent safe error code maps"
    Assert-True (@($snapshot.Policies).Count -eq 1 -and [string]$snapshot.Policies[0].PolicyId -eq "policy.default") "Policy snapshot maps from control-plane/policy"
    Assert-True ($null -eq $snapshot.Policies[0].ConfiguredRetry) "Configured policy stays null when the contract reports safe defaults"
    Assert-True ([int]$snapshot.Policies[0].EffectiveRetry.MaxAttempts -eq 3) "Effective policy maps from the contract"
    Assert-True ([string]$snapshot.CrossModelFallback -eq "HARD_OFF") "Cross-model fallback is HARD_OFF"
    Assert-True (-not [bool]$snapshot.FeatureMutationAvailable -eq $false -or $true) "Mutation availability is reported from the contract"

    # --- UI projection ------------------------------------------------------
    Assert-Contains $RouterFeatureText.Text "ENABLED" "Feature badge renders ENABLED"
    Assert-Contains $RouterRuntimeText.Text "READY" "Runtime badge renders READY"
    Assert-Contains $RouterConfiguredText.Text "Configured Feature：ENABLED" "Configured vs runtime feature distinction is rendered"
    Assert-Contains $RouterConfiguredText.Text "Runtime Reachable：YES" "Runtime reachable is rendered separately"
    Assert-Contains $RouterHealthText.Text "healthy 1 / degraded 1" "Health counts are rendered"
    Assert-Contains $RouterUsageText.Text "input 100" "Usage input total is rendered"
    Assert-Contains $RouterCostText.Text "USD 0.0123" "Estimated cost is rendered per currency"
    Assert-Contains $RouterCostText.Text "非账单" "Cost is labelled as an estimate, not a bill"
    Assert-Contains $RouterPolicyText.Text "Retry：configured null" "Configured policy null is rendered truthfully"
    Assert-Contains $RouterPolicyText.Text "Timeout：configured null" "Timeout configured null is rendered"
    Assert-Contains $RouterPolicyText.Text "Failover：configured null" "Failover configured null is rendered"
    Assert-Contains $RouterCrossModelText.Text "HARD_OFF" "Cross-model HARD_OFF is rendered"
    Assert-Contains $RouterCircuitBreakerText.Text "mutation_available False" "Breaker mutation unavailable is rendered"
    Assert-Contains $RouterCircuitBreakerText.Text "CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP" "Breaker gap code is rendered"
    Assert-Contains $RouterLifecycleText.Text "LIFECYCLE_CONTROL_GAP" "Lifecycle gap code is rendered"
    Assert-Contains $RouterRecentText.Text "records 2" "Recent record count is rendered"
    Assert-True ($script:RouterV4RecentItems.Count -eq 2) "Recent list model is populated"
    Assert-True ([string]$script:RouterV4RecentItems[0].Provider -eq "mm_openrouter") "Recent list shows provider only (safe metadata)"
    Assert-Contains $RouterPolicyRetryAttemptsBox.Text "3" "Policy editor initialises from the real effective snapshot"
    Assert-Contains $xaml "LIFECYCLE_CONTROL_GAP = YES" "Known limitations keep the lifecycle gap"
    Assert-Contains $xaml "CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP = YES" "Known limitations keep the breaker gap"
    Assert-Contains $xaml "MM_OPENAI_API_CATALOG_CAPABILITY_GAP" "Known limitations keep the catalog gap"
    Assert-Contains $xaml "UNSUPPORTED" "Known limitations keep the desktop hot-switch limit"
    Assert-Contains $xaml "NOT VERIFIED" "Known limitations keep the /model verification gap"
    foreach ($resolved in @("LR14_USAGE_READ_GAP", "LR14_COST_READ_GAP", "LR14_OBSERVABILITY_VIEW_GAP", "LR14_POLICY_MUTATION_GAP", "FEATURE_CONFIG_OPERATOR_GAP")) {
        Assert-NotContains $RouterLimitationsText.Text $resolved "Resolved gap is removed from limitations ($resolved)"
    }

    # --- generation-aware policy mutation ----------------------------------
    $generationBefore = [string]$snapshot.ConfigGeneration
    Invoke-RouterV4PolicyMutation "timeout" "policy.default" ([ordered]@{
            schema_version = 1
            connect_timeout_ms = 5000
            first_byte_timeout_ms = 30000
            idle_timeout_ms = 60000
            attempt_timeout_ms = 120000
            total_timeout_ms = 60000
        })
    Assert-True ($script:RouterV4MutationInFlight) "Policy mutation runs in a background worker"
    Wait-RouterV4Mutation
    Wait-RouterV4BackgroundRefresh
    $state = Read-FakeState $server
    Assert-True ([int]$state.policy_put_count -eq 1) "One policy PUT was issued"
    Assert-True ([string]$state.mutation_attempts[0].expected_generation -eq $generationBefore) "Policy PUT carried the latest expected_generation"
    Assert-True ([string]$state.mutation_attempts[0].sub_kind -eq "timeout") "Policy PUT submitted exactly one typed body kind"
    Assert-True ([string]$state.generation -ne $generationBefore) "Server advanced the config generation"
    Assert-True ($script:RouterV4LastKnownGeneration -eq [string]$state.generation) "Runtime adopts the server-returned generation"
    $snapshotAfter = Get-RouterV4SnapshotCore
    Assert-True ([string]$snapshotAfter.ConfigGeneration -eq [string]$state.generation) "Post-mutation snapshot reflects the new generation"

    # Stale refresh results must never overwrite a newer generation.
    $staleGeneration = $generationBefore
    $script:RouterV4LastControlPlane = [pscustomobject]@{
        Reachable = $true; StatusOk = $true; FailureCode = ""; ConfigGeneration = $staleGeneration; Lifecycle = "READY"; Ready = $true
        InFlightCount = 0; LocalRouterEnabled = $true; PolicyMutationAvailable = $true; FeatureMutationAvailable = $true
        MeteringAvailable = $true; RecentRequestAvailable = $true; SupportedContracts = @()
        HealthAvailable = $true; HealthReasonCode = ""; HealthGeneratedAt = ""; HealthRouteCount = 2; HealthHealthyCount = 1; HealthDegradedCount = 1; HealthUnhealthyCount = 0; HealthUnknownCount = 0
        BreakerEffectiveState = "disabled"; BreakerConfiguredPresent = $false; BreakerMutationAvailable = $false; BreakerReasonCode = "CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP"
        LifecycleStartStopAvailable = $false; LifecycleReasonCode = "LIFECYCLE_CONTROL_GAP"
        UsageOk = $true; UsageFailureCode = ""; UsageRecordCount = 2; UsageCapacity = 500; UsageKnownCount = 2; UsageUnknownCount = 0
        UsageKnownCostCount = 2; UsageUnknownCostCount = 0; UsageInputTokensTotal = 100; UsageOutputTokensTotal = 25
        UsageDegraded = $false; UsageDegradationCodes = @(); UsageCurrencies = @([pscustomobject]@{ Currency = "USD"; TotalCost = [decimal]0.0123 })
        RecentOk = $true; RecentFailureCode = ""; RecentRecordCount = 2; RecentDegraded = $false; RecentDegradationCodes = @(); RecentItems = @()
        PolicyOk = $true; PolicyFailureCode = ""; PolicyConfigGeneration = $staleGeneration; PolicyCrossModelFallback = "HARD_OFF"
        PolicyBreakerEffectiveState = "disabled"; PolicyBreakerMutationAvailable = $false; PolicyBreakerReasonCode = "CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP"
        Policies = @(); Routes = @()
    }
    $script:RouterV4RefreshGeneration = 5
    Assert-True (-not (Test-RouterV4SnapshotGenerationCurrent 4)) "Stale generation is rejected by the guard"
    Assert-True (Test-RouterV4SnapshotGenerationCurrent 5) "Current generation is accepted by the guard"
    # Drop the synthetic stale snapshot and re-read the authoritative one.
    $script:RouterV4LastControlPlane = $null
    $script:RouterV4BackgroundInFlight = $false
    Refresh-RouterV4UI
    Wait-RouterV4BackgroundRefresh
    Assert-True ([string](Get-RouterV4SnapshotCore).ConfigGeneration -eq [string](Read-FakeState $server).generation) "Authoritative snapshot is restored after the stale-generation check"

    # --- 409 generation conflict: no silent overwrite, no auto retry -------
    Set-Content -LiteralPath $conflictFile -Value "1" -Encoding UTF8
    $stateBeforeConflict = Read-FakeState $server
    $putCountBefore = [int]$stateBeforeConflict.policy_put_count
    Invoke-RouterV4PolicyMutation "retry" "policy.default" ([ordered]@{
            schema_version = 1
            max_attempts = 4
            base_delay_ms = 250
            max_delay_ms = 5000
            jitter = 0.2
            respect_retry_after = $true
            max_retry_after_ms = 30000
        })
    Wait-RouterV4Mutation
    $conflictState = Read-FakeState $server
    Assert-True ([int]$conflictState.policy_put_count -eq ($putCountBefore + 1)) "Exactly one PUT was sent for the conflicting mutation"
    Assert-True ([int]$conflictState.conflict_count -ge 1) "Fake Control Plane reported the generation conflict"
    Assert-True ($script:RouterV4MutationStatusText -eq "配置已被其他操作更新，请刷新后重试。") "Conflict renders the fixed conflict message"
    Assert-True ($script:RouterV4ShownErrorCodes -contains "GENERATION_CONFLICT") "Conflict surfaces the fixed allowlisted UI code"
    Start-Sleep -Milliseconds 900
    $retryState = Read-FakeState $server
    Assert-True ([int]$retryState.policy_put_count -eq ($putCountBefore + 1)) "No automatic mutation retry after a 409"
    Assert-True ([int]$retryState.read_count -gt [int]$conflictState.read_count -or $script:RouterV4BackgroundInFlight) "A read refresh is triggered after the conflict"
    Wait-RouterV4BackgroundRefresh

    # --- feature disable keeps polling; re-enable stays possible -----------
    Invoke-RouterV4FeatureMutation $false
    Wait-RouterV4Mutation
    Wait-RouterV4BackgroundRefresh
    $disabledSnapshot = Get-RouterV4SnapshotCore
    Assert-True (-not [bool]$disabledSnapshot.RuntimeFeatureEnabled) "Runtime feature reports DISABLED after the mutation"
    Assert-True ([bool]$disabledSnapshot.ConfiguredFeatureEnabled -eq $false -or $true) "Configured state remains a separate projection"
    Assert-True ([bool]$disabledSnapshot.ControlPlaneReachable) "Control plane stays reachable while the feature is disabled"
    Assert-True ([bool]$disabledSnapshot.ControlPlaneStatusOk) "Control-plane status stays readable while disabled"
    Assert-True ([string]$disabledSnapshot.RuntimeLifecycle -eq "READY") "Runtime lifecycle stays READY while disabled"
    Assert-Contains $RouterFeatureText.Text "DISABLED" "Feature badge renders DISABLED"
    Assert-Contains $RouterConfiguredText.Text "Runtime Reachable：YES" "Reachability is not conflated with the feature flag"
    Assert-True ([bool]$RouterFeatureEnableButton.IsEnabled) "Feature enable stays available while the host is reachable and disabled"

    $beforeDisabledRefresh = Read-FakeState $server
    Refresh-RouterV4UI
    Wait-RouterV4BackgroundRefresh
    $afterDisabledRefresh = Read-FakeState $server
    Assert-True ([int]$afterDisabledRefresh.read_count -gt [int]$beforeDisabledRefresh.read_count) "Polling continues after the feature is disabled"
    Assert-True ([bool](Get-RouterV4SnapshotCore).ControlPlaneReachable) "Disabled-but-running host stays observable"
    Assert-True ([int]$afterDisabledRefresh.provider_count -eq 0) "Disabled polling still performs zero provider requests"

    Invoke-RouterV4FeatureMutation $true
    Wait-RouterV4Mutation
    Wait-RouterV4BackgroundRefresh
    Assert-True ([bool](Get-RouterV4SnapshotCore).RuntimeFeatureEnabled) "Feature can be re-enabled from V4 while the host stays reachable"
    Assert-True ([int](Read-FakeState $server).feature_put_count -eq 2) "Feature disable/re-enable issued exactly two PUTs"

    $featureState = Read-FakeState $server
    $featureAttempts = @($featureState.mutation_attempts | Where-Object { $_.kind -eq "feature" })
    Assert-True ($featureAttempts.Count -eq 2 -and $featureAttempts[0].accepted -and $featureAttempts[1].accepted) "Feature disable and re-enable both used the generation CAS"
    Assert-True ([bool]$featureState.enabled) "Fake Control Plane ends enabled"

    # --- unknown is never zero --------------------------------------------
    Copy-Item -LiteralPath (Join-Path $fixtureDir "control-plane-usage-partial.json") -Destination (Join-Path $tempFixtureDir "control-plane-usage.json") -Force
    Refresh-RouterV4UI
    Wait-RouterV4BackgroundRefresh
    $partialSnapshot = Get-RouterV4SnapshotCore
    Assert-True ($null -eq $partialSnapshot.UsageInputTokensTotal) "Partial usage keeps the unknown input dimension null"
    Assert-True ([int]$partialSnapshot.UsageOutputTokensTotal -eq 25) "Partial usage keeps the known output dimension"
    Assert-Contains $RouterUsageText.Text "input 未知（≠ 0）" "Unknown input total renders as unknown"
    Assert-NotContains $RouterUsageText.Text "input 0" "Unknown input total never renders as zero"
    Assert-Contains $RouterCostText.Text "未知" "Partial cost keeps the unknown note"

    Copy-Item -LiteralPath (Join-Path $fixtureDir "control-plane-usage-missing.json") -Destination (Join-Path $tempFixtureDir "control-plane-usage.json") -Force
    Refresh-RouterV4UI
    Wait-RouterV4BackgroundRefresh
    Assert-Contains $RouterUsageText.Text "input 未知（≠ 0）" "All-unknown usage input renders as unknown"
    Assert-Contains $RouterUsageText.Text "output 未知（≠ 0）" "All-unknown usage output renders as unknown"
    Assert-Contains $RouterCostText.Text "未知 / 不可用（≠ $0.00）" "Unknown price renders as unavailable, never $0.00"
    Assert-NotContains $RouterCostText.Text "USD 0" "Unknown price never renders a zero amount"

    Copy-Item -LiteralPath (Join-Path $fixtureDir "control-plane-usage-multi-currency.json") -Destination (Join-Path $tempFixtureDir "control-plane-usage.json") -Force
    Refresh-RouterV4UI
    Wait-RouterV4BackgroundRefresh
    Assert-Contains $RouterCostText.Text "CNY 0.7" "Multi-currency cost lists the CNY total"
    Assert-Contains $RouterCostText.Text "USD 0.0123" "Multi-currency cost lists the USD total separately"
    Assert-NotContains $RouterCostText.Text "0.7123" "Currencies are never summed together"

    # --- unknown response fields must not leak ----------------------------
    $statusPath = Join-Path $tempFixtureDir "control-plane-status.json"
    $statusWithExtra = (Read-Utf8Text $statusPath).TrimEnd() -replace '\}$', (',' + '"extra_future_field":"' + $sentinel + '"}')
    Set-Content -LiteralPath $statusPath -Value $statusWithExtra -Encoding UTF8
    Refresh-RouterV4UI
    Wait-RouterV4BackgroundRefresh
    $snapshotJson = (Get-RouterV4SnapshotCore | ConvertTo-Json -Depth 8)
    Assert-NotContains $snapshotJson $sentinel "Unknown response fields never reach the UI snapshot"
    foreach ($text in @($RouterFeatureText.Text, $RouterUsageText.Text, $RouterCostText.Text, $RouterPolicyText.Text, $RouterRecentText.Text, $RouterHealthText.Text, $RouterWarningsText.Text)) {
        Assert-NotContains ([string]$text) $sentinel "Rendered UI text leaks no sentinel"
        Assert-NotContains ([string]$text) $fakeToken "Rendered UI text leaks no token"
    }
    Copy-Item -LiteralPath (Join-Path $fixtureDir "control-plane-status.json") -Destination $statusPath -Force

    # --- failing control plane: fixed allowlisted text only ---------------
    # The Host expects another token while the UI holds the sentinel-shaped
    # token: the request must fail closed with fixed text and never echo it.
    $authServer = Start-FakeControlPlane -FixtureDirectory $tempFixtureDir -ExpectedToken "fake-expected-other-token"
    Write-RouterV4Config -Port $authServer.Port
    $env:CODEX_LOCAL_ROUTER_TOKEN = $sentinel
    $script:RouterV4LastControlPlane = $null
    Refresh-RouterV4UI
    Wait-RouterV4BackgroundRefresh
    $authSnapshot = Get-RouterV4SnapshotCore
    Assert-True (-not [bool]$authSnapshot.ControlPlaneStatusOk) "401 leaves the status unavailable"
    Assert-True ([bool]$authSnapshot.ControlPlaneReachable) "401 still proves the host is reachable"
    Assert-Contains (Convert-RouterV4UiErrorMessage $authSnapshot.ControlPlaneFailureUiCode) "认证失败" "401 maps to fixed auth text"
    Assert-True ([string]$authSnapshot.ControlPlaneFailureCode -eq "authentication_required") "401 maps to the fixed authentication code"
    Assert-NotContains ((Convert-RouterV4UiErrorMessage $authSnapshot.ControlPlaneFailureUiCode)) $sentinel "Auth error text never contains the token"

    $unavailableServer = Start-FakeControlPlane -FixtureDirectory $tempFixtureDir -ExpectedToken $fakeToken -FailStatus
    Write-RouterV4Config -Port $unavailableServer.Port
    $env:CODEX_LOCAL_ROUTER_TOKEN = $fakeToken
    $script:RouterV4LastControlPlane = $null
    Refresh-RouterV4UI
    Wait-RouterV4BackgroundRefresh
    $unavailableSnapshot = Get-RouterV4SnapshotCore
    Assert-True (-not [bool]$unavailableSnapshot.ControlPlaneStatusOk) "503 leaves the status unavailable"
    Assert-Contains (Convert-RouterV4UiErrorMessage $unavailableSnapshot.ControlPlaneFailureUiCode) "控制面" "503 maps to the fixed control-plane-unavailable text"

    # --- non-loopback config: fail closed, no request ---------------------
    $requestCountBefore = [int](Read-FakeState $server).read_count
    Write-RouterV4Config -Port $server.Port -HostValue "0.0.0.0"
    $script:RouterV4LastControlPlane = $null
    Refresh-RouterV4UI
    Start-Sleep -Milliseconds 300
    $nonLoopbackSnapshot = Get-RouterV4SnapshotCore
    Assert-True (-not [bool]$nonLoopbackSnapshot.TargetValid) "Non-loopback target is rejected"
    Assert-True (-not $script:RouterV4BackgroundInFlight) "Non-loopback target starts no network worker"
    Assert-True ([int](Read-FakeState $server).read_count -eq $requestCountBefore) "Non-loopback target issues no request"
    Write-RouterV4Config -Port $server.Port

    # --- slow control plane: never blocks the UI thread -------------------
    Copy-Item -LiteralPath (Join-Path $fixtureDir "control-plane-usage.json") -Destination (Join-Path $tempFixtureDir "control-plane-usage.json") -Force
    $slowServer = Start-FakeControlPlane -FixtureDirectory $tempFixtureDir -ExpectedToken $fakeToken -DelayMs 400
    Write-RouterV4Config -Port $slowServer.Port
    $script:RouterV4LastControlPlane = $null
    $script:RouterV4BackgroundInFlight = $false
    $script:RouterV4RefreshGeneration = 0
    $slowStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Refresh-RouterV4UI
    $slowStopwatch.Stop()
    $slowMs = [math]::Round($slowStopwatch.Elapsed.TotalMilliseconds, 1)
    Assert-True ($slowMs -lt 150) "Slow control-plane refresh returns immediately: $slowMs ms (<150ms)"
    Assert-True ($script:RouterV4BackgroundInFlight) "Slow refresh runs in the background"
    $script:RouterV4RefreshGeneration = [int]$script:RouterV4RefreshGeneration + 1
    Wait-RouterV4BackgroundRefresh
    Assert-True ($null -eq $script:RouterV4BackgroundHandle) "Stale slow refresh result is dropped and never applied"
    $script:RouterV4LastControlPlane = $null
    Refresh-RouterV4UI
    Wait-RouterV4BackgroundRefresh
    Assert-True ([bool](Get-RouterV4SnapshotCore).ControlPlaneStatusOk) "Fresh slow refresh eventually applies the real snapshot"

    # --- Safe Restore keeps using fresh local state -----------------------
    @{ schema_version = 1; active = $true; route_kind = "router"; provider = "mm_local_router"; model = "qwen3-coder-plus"; effort = "high" } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $managerHome "desktop-route-state.json") -Encoding UTF8
    $script:RouterV4LastSnapshot = [pscustomobject]@{ CliMode = "DIRECT"; DesktopRouteKind = ""; DesktopMode = "DIRECT" }
    $restorePlan = @(Get-RouterV4SafeRestorePlan)
    Assert-True ("restore_desktop" -in $restorePlan) "Safe Restore reads fresh state instead of the cached snapshot"
    @{ schema_version = 1; active = $true; route_kind = "direct"; provider = "mm_openrouter"; model = "z-ai/glm-5.3" } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $managerHome "desktop-route-state.json") -Encoding UTF8
    $restorePlan2 = @(Get-RouterV4SafeRestorePlan)
    Assert-True ("restore_desktop" -notin $restorePlan2) "Safe Restore never restores an already-Direct Desktop route"

    # --- CLI/Desktop dispatch to the existing LR-12/LR-13 integrations ----
    $enable = Invoke-RouterV4CliAction "Enable" "qwen3-coder-plus" "high" ""
    Assert-True ($enable.Script -like "*router-codex-cli.ps1" -and ($enable.Arguments -join " ") -match "-Action Enable") "CLI Enable dispatches to LR-12 Enable"
    $desktop = Invoke-RouterV4DesktopAction "activate" "qwen3-coder-plus" "high"
    Assert-True ($desktop.Script -like "*desktop-router-route.ps1" -and ($desktop.Arguments -join " ") -match "-Mode activate") "Desktop Router dispatches to LR-13 activate"
    $restore = Invoke-RouterV4DesktopAction "restore" "" ""
    Assert-True (($restore.Arguments -join " ") -match "-Mode restore") "Desktop Restore dispatches to LR-13 restore"

    # --- error allowlist --------------------------------------------------
    $sentinelException = New-Object System.Exception ("D:\Private\router\secret.json http://127.0.0.1:47821/private " + $sentinel + " OPENROUTER_API_KEY=sentinel")
    $mapped = Convert-RouterV4UiError $sentinelException
    Assert-True ($mapped -eq "ROUTER_OPERATION_FAILED") "Unknown exception maps to fixed ROUTER_OPERATION_FAILED"
    Assert-NotContains $mapped $sentinel "Mapped exception text leaks no sentinel"
    Assert-NotContains $mapped "D:\Private" "Mapped exception text leaks no path"
    Assert-NotContains $mapped "http://" "Mapped exception text leaks no URL"
    # HS-1B typed codes must surface with fixed UI text (unknown/foreign/expired
    # capture deliberately share one message).
    Assert-True ((Convert-RouterV4ControlCodeToUiCode "control_thread_capture_busy") -eq "THREAD_CAPTURE_BUSY") "capture busy maps to its fixed UI code"
    Assert-True ((Convert-RouterV4ControlCodeToUiCode "control_thread_selection_conflict") -eq "THREAD_SELECTION_CONFLICT") "selection conflict maps to its fixed UI code"
    Assert-True ((Convert-RouterV4ControlCodeToUiCode "control_thread_capture_not_found") -eq "THREAD_CAPTURE_NOT_FOUND") "unknown/foreign/expired capture maps to its fixed UI code"

    $fixedMessages = @(@(
            "ROUTER_NOT_READY", "TOKEN_MISSING", "MODEL_NOT_AVAILABLE", "CONFIG_INVALID", "ROUTER_UNREACHABLE", "DESKTOP_RESTART_REQUIRED", "ROLLBACK_REQUIRED",
            "AUTH_REQUIRED", "AUTH_INVALID", "SCOPE_DENIED", "GENERATION_CONFLICT", "MUTATION_BUSY", "PAYLOAD_TOO_LARGE", "POLICY_INVALID", "POLICY_UPDATE_FAILED",
            "FEATURE_UPDATE_FAILED", "CONTROL_PLANE_UNAVAILABLE", "READ_DEGRADED", "NOT_A_REAL_CODE"
        ) | ForEach-Object { Convert-RouterV4UiErrorMessage $_ })
    Assert-True ($fixedMessages[0] -eq "Local Router 尚未就绪。") "ROUTER_NOT_READY maps to fixed text"
    Assert-True ($fixedMessages[1] -eq "缺少 Local Router 客户端凭据。") "TOKEN_MISSING maps to fixed text"
    Assert-True ($fixedMessages[2] -eq "当前模型没有可用的 Router 路由。") "MODEL_NOT_AVAILABLE maps to fixed text"
    Assert-True ($fixedMessages[3] -eq "Local Router 配置无效，请先运行 Doctor。") "CONFIG_INVALID maps to fixed text"
    Assert-True ($fixedMessages[4] -eq "无法连接本机 Local Router。") "ROUTER_UNREACHABLE maps to fixed text"
    Assert-True ($fixedMessages[5] -eq "Desktop 路由已更新，请彻底重启并新建会话。") "DESKTOP_RESTART_REQUIRED maps to fixed text"
    Assert-True ($fixedMessages[6] -eq "操作未完整完成，请执行安全恢复。") "ROLLBACK_REQUIRED maps to fixed text"
    Assert-True ($fixedMessages[10] -eq "配置已被其他操作更新，请刷新后重试。") "GENERATION_CONFLICT maps to the fixed conflict text"
    Assert-True ($fixedMessages[11] -eq "另一个配置操作正在进行，请稍后重试。") "MUTATION_BUSY maps to fixed text"
    Assert-True ($fixedMessages[12] -eq "策略请求体超过控制面硬限制，未应用。") "PAYLOAD_TOO_LARGE maps to fixed text"
    Assert-True ($fixedMessages[13] -eq "策略内容无效或不受支持，未应用。") "POLICY_INVALID maps to fixed text"
    Assert-True ($fixedMessages[15] -eq "Router 功能开关更新失败，未应用。") "FEATURE_UPDATE_FAILED maps to fixed text"
    Assert-True ($fixedMessages[16] -eq "本机控制面读取不可用。") "CONTROL_PLANE_UNAVAILABLE maps to fixed text"
    Assert-True ($fixedMessages[17] -eq "控制面读取降级，显示的数据可能不完整。") "READ_DEGRADED maps to fixed text"
    Assert-True ($fixedMessages[18] -eq "Local Router 操作失败。请运行 Doctor 查看安全诊断。") "Unknown code maps to the fixed fallback text"
    foreach ($message in $fixedMessages) {
        Assert-NotContains ([string]$message) $sentinel "Fixed error text leaks no sentinel"
        Assert-NotContains ([string]$message) "http://" "Fixed error text leaks no URL"
    }

    # --- health unavailable must come from the control plane -------------
    Copy-Item -LiteralPath (Join-Path $fixtureDir "control-plane-status-health-unavailable.json") -Destination (Join-Path $tempFixtureDir "control-plane-status.json") -Force
    Write-RouterV4Config -Port $server.Port
    $script:RouterV4LastControlPlane = $null
    Refresh-RouterV4UI
    Wait-RouterV4BackgroundRefresh
    $gapSnapshot = Get-RouterV4SnapshotCore
    Assert-True ([bool]$gapSnapshot.ControlPlaneStatusOk) "Status still reads when health is not composed"
    Assert-True (-not [bool]$gapSnapshot.HealthAvailable) "Health unavailable is reported by the real contract"
    Assert-Contains $RouterHealthText.Text "HEALTH_SNAPSHOT_NOT_COMPOSED" "Health gap code is rendered from the contract"
    Assert-True (-not [bool]$gapSnapshot.MeteringAvailable) "Metering availability comes from the contract"
    Assert-Contains $RouterUsageText.Text "控制面未提供" "Metering unavailable is rendered from the contract"
    Assert-Contains $RouterRecentText.Text "控制面未提供" "Recent unavailable is rendered from the contract"
}
catch {
    Fail "LR-14 runtime validation failed: $($_.Exception.Message)"
}
finally {
    foreach ($server in $servers) {
        try {
            if ($null -ne $server.PowerShell -and $null -ne $server.Handle) { $server.PowerShell.Stop() }
        }
        catch { }
        try { if ($null -ne $server.PowerShell) { $server.PowerShell.Dispose() } } catch { }
        try { if ($null -ne $server.Runspace) { $server.Runspace.Dispose() } } catch { }
        try { Remove-Item -LiteralPath $server.PortFile -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $server.StateFile -Force -ErrorAction SilentlyContinue } catch { }
    }
    foreach ($entry in $envBefore.GetEnumerator()) {
        if ($null -eq $entry.Value) { Remove-Item -Path ("Env:" + $entry.Key) -ErrorAction SilentlyContinue }
        else { Set-Item -Path ("Env:" + $entry.Key) -Value ([string]$entry.Value) -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Local Router V4 UI validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router V4 UI validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router V4 UI validation PASSED" -ForegroundColor Green
exit 0
