#requires -Version 7
$ErrorActionPreference = "Stop"

# LR-14 V4 presentation/integration runtime.
#
# The LR-14P authenticated Control Plane is the single data source for Router
# feature state, lifecycle, health, usage/cost, recent requests and policy.
# This runtime never re-derives that data from raw logs, never calls a provider
# endpoint, never rewrites Router config / Codex config / CLI state / Desktop
# route state, and never exposes a token. Every network action runs inside a
# background runspace and only safe allowlisted DTOs cross back to the WPF
# thread.

function Get-RouterV4RuntimeDirectory {
    $path = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($path)) {
        return (Split-Path -Parent $PSScriptRoot)
    }
    return (Split-Path -Parent $path)
}

$routerV4ScriptsDir = Get-RouterV4RuntimeDirectory
$script:RouterV4CliModule = Join-Path $routerV4ScriptsDir "router-codex-cli.ps1"
$script:RouterV4DesktopAdapter = Join-Path $routerV4ScriptsDir "desktop-router-route.ps1"
if (Test-Path -LiteralPath $script:RouterV4CliModule) {
    . $script:RouterV4CliModule
}

# --- LR-14P control-plane contract constants -------------------------------
# Paths and shapes follow schemas/control-plane-*.v1.schema.json and
# Router.Ingress.Handlers.ControlPlaneHandlers on main. The UI never invents a
# second status contract and never falls back to the legacy status endpoint.
$script:RouterV4LoopbackHost = "127.0.0.1"
$script:RouterV4StatusPath = "/v1/router/control-plane/status"
$script:RouterV4UsagePath = "/v1/router/control-plane/usage"
$script:RouterV4RequestsPath = "/v1/router/control-plane/requests"
$script:RouterV4PolicyPath = "/v1/router/control-plane/policy"
$script:RouterV4FeaturePath = "/v1/router/control-plane/feature"
$script:RouterV4RequestLimit = 20
$script:RouterV4HttpTimeoutMs = 800
$script:RouterV4CrossModelFallbackHardOff = "HARD_OFF"
$script:RouterV4BreakerGapCode = "CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP"
$script:RouterV4LifecycleControlGapCode = "LIFECYCLE_CONTROL_GAP"
$script:RouterV4HealthNotComposedCode = "HEALTH_SNAPSHOT_NOT_COMPOSED"
$script:RouterV4TokenVariableName = "CODEX_LOCAL_ROUTER_TOKEN"

# --- Control-plane transport (runs inside background runspaces) ------------
$script:RouterV4TransportSource = @'
function Get-RouterV4FieldValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-RouterV4FieldString($Object, [string]$Name) {
    $value = Get-RouterV4FieldValue $Object $Name
    if ($null -eq $value) { return "" }
    return [string]$value
}

function Get-RouterV4FieldBool($Object, [string]$Name) {
    $value = Get-RouterV4FieldValue $Object $Name
    if ($null -eq $value) { return $false }
    return [bool]$value
}

function Get-RouterV4FieldInt($Object, [string]$Name) {
    $value = Get-RouterV4FieldValue $Object $Name
    if ($null -eq $value) { return $null }
    $parsed = 0
    if (-not [int]::TryParse([string]$value, [ref]$parsed)) { return $null }
    return $parsed
}

function Get-RouterV4FieldLong($Object, [string]$Name) {
    $value = Get-RouterV4FieldValue $Object $Name
    if ($null -eq $value) { return $null }
    $parsed = 0L
    if (-not [long]::TryParse([string]$value, [ref]$parsed)) { return $null }
    return $parsed
}

function Get-RouterV4FieldDecimal($Object, [string]$Name) {
    $value = Get-RouterV4FieldValue $Object $Name
    if ($null -eq $value) { return $null }
    $parsed = [decimal]0
    $styles = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [decimal]::TryParse([string]$value, $styles, $culture, [ref]$parsed)) { return $null }
    return $parsed
}

# Only values matching a fixed shape may leave the worker; anything else
# collapses to an empty string instead of leaking contract-external content.
function Get-RouterV4SafeToken([string]$Value, [string]$Pattern) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    if ($Value -match $Pattern) { return $Value }
    return ""
}

function Get-RouterV4SafeTokenList($Values, [string]$Pattern) {
    $result = @()
    foreach ($value in @($Values)) {
        $safe = Get-RouterV4SafeToken ([string]$value) $Pattern
        if (-not [string]::IsNullOrWhiteSpace($safe)) { $result += $safe }
    }
    return @($result)
}

function Get-RouterV4IsoTime([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $parsed = [DateTimeOffset]::MinValue
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
    if (-not [DateTimeOffset]::TryParse($Value, $culture, $styles, [ref]$parsed)) { return "" }
    return $parsed.ToLocalTime().ToString("MM-dd HH:mm:ss")
}

function Resolve-RouterV4ControlPlaneToken {
    $token = [Environment]::GetEnvironmentVariable("CODEX_LOCAL_ROUTER_TOKEN", [EnvironmentVariableTarget]::Process)
    if ([string]::IsNullOrWhiteSpace($token)) {
        try {
            $token = [Environment]::GetEnvironmentVariable("CODEX_LOCAL_ROUTER_TOKEN", [EnvironmentVariableTarget]::User)
        }
        catch {
            $token = ""
        }
    }
    if ($null -eq $token) { return "" }
    return [string]$token
}

# HTTP status is the only failure signal: error bodies are never parsed, so no
# response text, path, URL, or exception message can reach the UI.
function Get-RouterV4ControlPlaneFailureCode([int]$StatusCode) {
    switch ($StatusCode) {
        400 { return "control_invalid_request" }
        401 { return "authentication_required" }
        403 { return "scope_denied" }
        404 { return "control_policy_not_found" }
        409 { return "control_generation_conflict" }
        413 { return "control_payload_too_large" }
        429 { return "control_mutation_busy" }
    }
    if ($StatusCode -ge 500) { return "control_read_unavailable" }
    return "control_mutation_failed"
}

function Get-RouterV4MutationFailureCode([int]$StatusCode, [string]$Operation) {
    # Operation-specific HS-1B mappings come FIRST. A typed thread-selection or
    # capture failure must never be collapsed into the generic config-conflict
    # mapping (for example capture-open + 409 is capture busy, not a stale config
    # generation).
    if ($Operation -eq "thread-selection" -or $Operation -eq "thread-selection-clear") {
        if ($StatusCode -eq 400) { return "control_invalid_request" }
        if ($StatusCode -eq 404) { return "control_thread_not_observed" }
        if ($StatusCode -eq 409) { return "control_thread_selection_conflict" }
        if ($StatusCode -eq 422) { return "control_model_not_approved" }
        if ($StatusCode -eq 503) { return "control_thread_selection_disabled" }
    }
    if ($Operation -eq "thread-selection-clear-all") {
        if ($StatusCode -eq 400) { return "control_invalid_request" }
        if ($StatusCode -eq 503) { return "control_thread_selection_unavailable" }
    }
    if ($Operation -eq "thread-feature") {
        if ($StatusCode -eq 400) { return "control_invalid_request" }
        if ($StatusCode -eq 409) { return "control_generation_conflict" }
        if ($StatusCode -eq 503) { return "control_thread_selection_unavailable" }
    }
    if ($Operation -eq "capture-open") {
        if ($StatusCode -eq 409) { return "control_thread_capture_busy" }
        if ($StatusCode -eq 400) { return "control_invalid_request" }
        if ($StatusCode -eq 503) { return "control_thread_selection_disabled" }
    }
    if ($Operation -eq "capture-cancel") {
        if ($StatusCode -eq 400) { return "control_invalid_request" }
        if ($StatusCode -eq 404) { return "control_thread_capture_not_found" }
    }

    # Anything a block above did not explicitly claim continues into the generic
    # HTTP mapping below (401/403/409/413/429/5xx), so an unhandled status can
    # never be mislabelled as an HS-1B-specific failure.
    switch ($StatusCode) {
        400 {
            if ($Operation -eq "feature") { return "control_invalid_request" }
            return "control_policy_invalid"
        }
        401 { return "authentication_required" }
        403 { return "scope_denied" }
        409 { return "control_generation_conflict" }
        413 { return "control_payload_too_large" }
        429 { return "control_mutation_busy" }
    }
    if ($Operation -eq "feature") { return "control_feature_update_failed" }
    if ($StatusCode -ge 500) { return "control_mutation_failed" }
    return "control_policy_invalid"
}

function Invoke-RouterV4ControlPlaneCall(
    [string]$Method,
    [string]$Path,
    [string]$Body,
    [string]$Token,
    [int]$Port,
    [int]$TimeoutMs,
    [string]$Operation
) {
    $outcome = [ordered]@{
        Reachable = $false
        Ok = $false
        StatusCode = 0
        Failure = "control_read_unavailable"
        Json = $null
    }
    $client = $null
    $request = $null
    try {
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)
        $httpMethod = switch ($Method) {
            "PUT" { [System.Net.Http.HttpMethod]::Put; break }
            "POST" { [System.Net.Http.HttpMethod]::Post; break }
            "DELETE" { [System.Net.Http.HttpMethod]::Delete; break }
            default { [System.Net.Http.HttpMethod]::Get }
        }
        $request = [System.Net.Http.HttpRequestMessage]::new($httpMethod, ("http://127.0.0.1:{0}{1}" -f $Port, $Path))
        $request.Headers.TryAddWithoutValidation("Authorization", ("Bearer " + $Token)) | Out-Null
        if (-not [string]::IsNullOrEmpty($Body)) {
            $request.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, "application/json")
        }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $outcome.Reachable = $true
        $outcome.StatusCode = [int]$response.StatusCode
        if ($outcome.StatusCode -ge 200 -and $outcome.StatusCode -lt 300) {
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            try {
                $outcome.Json = $text | ConvertFrom-Json
                $outcome.Ok = $true
                $outcome.Failure = ""
            }
            catch {
                $outcome.Ok = $false
                $outcome.Failure = "control_read_unavailable"
            }
        }
        elseif ($Operation -eq "read") {
            $outcome.Failure = Get-RouterV4ControlPlaneFailureCode $outcome.StatusCode
        }
        else {
            $outcome.Failure = Get-RouterV4MutationFailureCode $outcome.StatusCode $Operation
        }
        $response.Dispose()
    }
    catch {
        $outcome.Reachable = $false
        $outcome.Ok = $false
        $outcome.Failure = "control_plane_unreachable"
    }
    finally {
        if ($null -ne $request) { try { $request.Dispose() } catch { } }
        if ($null -ne $client) { try { $client.Dispose() } catch { } }
    }
    [pscustomobject]$outcome
}

function Convert-RouterV4RetryBody($Object) {
    if ($null -eq $Object) { return $null }
    return [pscustomobject]@{
        SchemaVersion = Get-RouterV4FieldInt $Object "schema_version"
        MaxAttempts = Get-RouterV4FieldInt $Object "max_attempts"
        BaseDelayMs = Get-RouterV4FieldLong $Object "base_delay_ms"
        MaxDelayMs = Get-RouterV4FieldLong $Object "max_delay_ms"
        Jitter = Get-RouterV4FieldDecimal $Object "jitter"
        RespectRetryAfter = Get-RouterV4FieldBool $Object "respect_retry_after"
        MaxRetryAfterMs = Get-RouterV4FieldLong $Object "max_retry_after_ms"
    }
}

function Convert-RouterV4TimeoutBody($Object) {
    if ($null -eq $Object) { return $null }
    return [pscustomobject]@{
        SchemaVersion = Get-RouterV4FieldInt $Object "schema_version"
        ConnectTimeoutMs = Get-RouterV4FieldLong $Object "connect_timeout_ms"
        FirstByteTimeoutMs = Get-RouterV4FieldLong $Object "first_byte_timeout_ms"
        IdleTimeoutMs = Get-RouterV4FieldLong $Object "idle_timeout_ms"
        AttemptTimeoutMs = Get-RouterV4FieldLong $Object "attempt_timeout_ms"
        TotalTimeoutMs = Get-RouterV4FieldLong $Object "total_timeout_ms"
    }
}

function Convert-RouterV4FailoverBody($Object) {
    if ($null -eq $Object) { return $null }
    return [pscustomobject]@{
        SchemaVersion = Get-RouterV4FieldInt $Object "schema_version"
        AllowSameModelAlternateEndpoint = Get-RouterV4FieldBool $Object "allow_same_model_alternate_endpoint"
        AllowSameModelAlternateProvider = Get-RouterV4FieldBool $Object "allow_same_model_alternate_provider"
    }
}
'@

# --- Control-plane worker functions ---------------------------------------
# These definitions are pre-loaded into the persistent runspaces once, so a
# timer tick only dispatches a command instead of re-parsing a script.
$script:RouterV4StatusWorkerBody = @'
function Invoke-RouterV4StatusWorker {
    param(
        [Parameter(Mandatory = $false)][int]$Port = 0,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 800,
        [Parameter(Mandatory = $false)][int]$Limit = 20
    )

$snapshot = [ordered]@{
    Reachable = $false
    StatusOk = $false
    FailureCode = ""
    ConfigGeneration = ""
    Lifecycle = "UNKNOWN"
    Ready = $false
    InFlightCount = $null
    LocalRouterEnabled = $null
    PolicyMutationAvailable = $false
    FeatureMutationAvailable = $false
    MeteringAvailable = $false
    RecentRequestAvailable = $false
    SupportedContracts = @()
    HealthAvailable = $false
    HealthReasonCode = ""
    HealthGeneratedAt = ""
    HealthRouteCount = $null
    HealthHealthyCount = $null
    HealthDegradedCount = $null
    HealthUnhealthyCount = $null
    HealthUnknownCount = $null
    BreakerEffectiveState = ""
    BreakerConfiguredPresent = $false
    BreakerMutationAvailable = $false
    BreakerReasonCode = ""
    LifecycleStartStopAvailable = $false
    LifecycleReasonCode = ""
    UsageOk = $false
    UsageFailureCode = ""
    UsageScope = ""
    UsageBillingNote = ""
    UsageRecordCount = $null
    UsageCapacity = $null
    UsageKnownCount = $null
    UsageUnknownCount = $null
    UsageKnownCostCount = $null
    UsageUnknownCostCount = $null
    UsageInputTokensTotal = $null
    UsageOutputTokensTotal = $null
    UsageDegraded = $false
    UsageDegradationCodes = @()
    UsageCurrencies = @()
    RecentOk = $false
    RecentFailureCode = ""
    RecentScope = ""
    RecentRecordCount = $null
    RecentDegraded = $false
    RecentDegradationCodes = @()
    RecentItems = @()
    PolicyOk = $false
    PolicyFailureCode = ""
    PolicyConfigGeneration = ""
    PolicyCrossModelFallback = ""
    PolicyBreakerEffectiveState = ""
    PolicyBreakerMutationAvailable = $false
    PolicyBreakerReasonCode = ""
    Policies = @()
    Routes = @()
}

$token = Resolve-RouterV4ControlPlaneToken
if ($Port -lt 1 -or $Port -gt 65535 -or [string]::IsNullOrWhiteSpace($token)) {
    $snapshot.FailureCode = "control_read_unavailable"
    return [pscustomobject]$snapshot
}

# Cheapest reachability check first: one bounded control-plane status read. An
# unreachable host short-circuits and never waits on usage/requests/policy.
$statusResponse = Invoke-RouterV4ControlPlaneCall -Method "GET" -Path "/v1/router/control-plane/status" -Body "" -Token $token -Port $Port -TimeoutMs $TimeoutMs -Operation "read"
$snapshot.Reachable = [bool]$statusResponse.Reachable
if (-not $statusResponse.Reachable) {
    $snapshot.FailureCode = "control_plane_unreachable"
    return [pscustomobject]$snapshot
}
if (-not $statusResponse.Ok) {
    $snapshot.FailureCode = [string]$statusResponse.Failure
    return [pscustomobject]$snapshot
}

$status = $statusResponse.Json
$snapshot.StatusOk = $true
$snapshot.ConfigGeneration = Get-RouterV4SafeToken (Get-RouterV4FieldString $status "config_generation") '^[0-9a-f]{64}$'
$snapshot.Lifecycle = Get-RouterV4SafeToken (Get-RouterV4FieldString $status "lifecycle") '^[A-Z]{3,16}$'
$snapshot.Ready = Get-RouterV4FieldBool $status "ready"
$snapshot.InFlightCount = Get-RouterV4FieldInt $status "in_flight_count"
$snapshot.LocalRouterEnabled = Get-RouterV4FieldBool $status "local_router_enabled"
$snapshot.PolicyMutationAvailable = Get-RouterV4FieldBool $status "policy_mutation_available"
$snapshot.FeatureMutationAvailable = Get-RouterV4FieldBool $status "feature_mutation_available"
$snapshot.MeteringAvailable = Get-RouterV4FieldBool (Get-RouterV4FieldValue $status "metering_availability") "available"
$snapshot.RecentRequestAvailable = Get-RouterV4FieldBool (Get-RouterV4FieldValue $status "recent_request_availability") "available"
$snapshot.SupportedContracts = Get-RouterV4SafeTokenList (Get-RouterV4FieldValue $status "supported_control_plane_contracts") '^control-plane/[a-z-]+/v1$'

$health = Get-RouterV4FieldValue $status "health_summary"
$snapshot.HealthAvailable = Get-RouterV4FieldBool $health "available"
$snapshot.HealthReasonCode = Get-RouterV4SafeToken (Get-RouterV4FieldString $health "reason_code") '^[A-Z0-9_]{1,64}$'
$snapshot.HealthGeneratedAt = Get-RouterV4IsoTime (Get-RouterV4FieldString $health "generated_at")
$snapshot.HealthRouteCount = Get-RouterV4FieldInt $health "route_count"
$snapshot.HealthHealthyCount = Get-RouterV4FieldInt $health "healthy_count"
$snapshot.HealthDegradedCount = Get-RouterV4FieldInt $health "degraded_count"
$snapshot.HealthUnhealthyCount = Get-RouterV4FieldInt $health "unhealthy_count"
$snapshot.HealthUnknownCount = Get-RouterV4FieldInt $health "unknown_count"

$breaker = Get-RouterV4FieldValue $status "circuit_breaker"
$snapshot.BreakerEffectiveState = Get-RouterV4SafeToken (Get-RouterV4FieldString $breaker "effective_state") '^[a-z_]{1,32}$'
$snapshot.BreakerConfiguredPresent = ($null -ne (Get-RouterV4FieldValue $breaker "configured"))
$snapshot.BreakerMutationAvailable = Get-RouterV4FieldBool $breaker "mutation_available"
$snapshot.BreakerReasonCode = Get-RouterV4SafeToken (Get-RouterV4FieldString $breaker "reason_code") '^[A-Z0-9_]{1,64}$'

$lifecycleControl = Get-RouterV4FieldValue $status "lifecycle_control"
$snapshot.LifecycleStartStopAvailable = Get-RouterV4FieldBool $lifecycleControl "start_stop_available"
$snapshot.LifecycleReasonCode = Get-RouterV4SafeToken (Get-RouterV4FieldString $lifecycleControl "reason_code") '^[A-Z0-9_]{1,64}$'

if ($snapshot.MeteringAvailable) {
    $usageResponse = Invoke-RouterV4ControlPlaneCall -Method "GET" -Path ("/v1/router/control-plane/usage?limit=" + [string]$Limit) -Body "" -Token $token -Port $Port -TimeoutMs $TimeoutMs -Operation "read"
    if ($usageResponse.Ok) {
        $usage = $usageResponse.Json
        $snapshot.UsageOk = $true
        $snapshot.UsageScope = Get-RouterV4SafeToken (Get-RouterV4FieldString $usage "scope") '^[a-z_]{1,64}$'
        $snapshot.UsageBillingNote = Get-RouterV4SafeToken (Get-RouterV4FieldString $usage "billing_note") '^[a-z_]{1,64}$'
        $snapshot.UsageRecordCount = Get-RouterV4FieldInt $usage "record_count"
        $snapshot.UsageCapacity = Get-RouterV4FieldInt $usage "capacity"
        $snapshot.UsageKnownCount = Get-RouterV4FieldInt $usage "known_usage_count"
        $snapshot.UsageUnknownCount = Get-RouterV4FieldInt $usage "unknown_usage_count"
        $snapshot.UsageKnownCostCount = Get-RouterV4FieldInt $usage "known_cost_count"
        $snapshot.UsageUnknownCostCount = Get-RouterV4FieldInt $usage "unknown_cost_count"
        $snapshot.UsageInputTokensTotal = Get-RouterV4FieldLong $usage "input_tokens_total"
        $snapshot.UsageOutputTokensTotal = Get-RouterV4FieldLong $usage "output_tokens_total"
        $snapshot.UsageDegraded = Get-RouterV4FieldBool $usage "degraded"
        $snapshot.UsageDegradationCodes = Get-RouterV4SafeTokenList (Get-RouterV4FieldValue $usage "degradation_codes") '^[A-Za-z0-9_]{1,64}$'
        $currencies = @()
        foreach ($entry in @(Get-RouterV4FieldValue $usage "estimated_cost_by_currency")) {
            $currency = Get-RouterV4SafeToken (Get-RouterV4FieldString $entry "currency") '^[A-Za-z]{3,8}$'
            $total = Get-RouterV4FieldDecimal $entry "total_cost"
            if (-not [string]::IsNullOrWhiteSpace($currency) -and $null -ne $total) {
                $currencies += [pscustomobject]@{
                    Currency = $currency.ToUpperInvariant()
                    TotalCost = $total
                }
            }
        }
        $snapshot.UsageCurrencies = @($currencies)
    }
    else {
        $snapshot.UsageFailureCode = [string]$usageResponse.Failure
    }
}

if ($snapshot.RecentRequestAvailable) {
    $recentResponse = Invoke-RouterV4ControlPlaneCall -Method "GET" -Path ("/v1/router/control-plane/requests?limit=" + [string]$Limit) -Body "" -Token $token -Port $Port -TimeoutMs $TimeoutMs -Operation "read"
    if ($recentResponse.Ok) {
        $recent = $recentResponse.Json
        $snapshot.RecentOk = $true
        $snapshot.RecentScope = Get-RouterV4SafeToken (Get-RouterV4FieldString $recent "scope") '^[a-z_]{1,64}$'
        $snapshot.RecentRecordCount = Get-RouterV4FieldInt $recent "record_count"
        $snapshot.RecentDegraded = Get-RouterV4FieldBool $recent "degraded"
        $snapshot.RecentDegradationCodes = Get-RouterV4SafeTokenList (Get-RouterV4FieldValue $recent "degradation_codes") '^[A-Za-z0-9_]{1,64}$'
        $items = @()
        foreach ($record in @(Get-RouterV4FieldValue $recent "records")) {
            if ($items.Count -ge $Limit) { break }
            $items += [pscustomobject]@{
                RequestId = Get-RouterV4SafeToken (Get-RouterV4FieldString $record "request_id") '^[A-Za-z0-9_\-]{1,64}$'
                TraceId = Get-RouterV4SafeToken (Get-RouterV4FieldString $record "trace_id") '^[A-Za-z0-9_\-]{1,64}$'
                Time = Get-RouterV4IsoTime (Get-RouterV4FieldString $record "started_at")
                TerminalState = Get-RouterV4SafeToken (Get-RouterV4FieldString $record "terminal_state") '^[a-z0-9_]{1,32}$'
                ProviderId = Get-RouterV4SafeToken (Get-RouterV4FieldString $record "provider_id") '^[A-Za-z0-9_\-\.]{1,64}$'
                ModelRouteId = Get-RouterV4SafeToken (Get-RouterV4FieldString $record "model_route_id") '^[A-Za-z0-9_\-\.]{1,64}$'
                RouteId = Get-RouterV4SafeToken (Get-RouterV4FieldString $record "route_id") '^[A-Za-z0-9_\-\.]{1,64}$'
                ProtocolId = Get-RouterV4SafeToken (Get-RouterV4FieldString $record "protocol_id") '^[A-Za-z0-9_\-\.]{1,64}$'
                DurationMs = Get-RouterV4FieldLong $record "duration_ms"
                HttpStatus = Get-RouterV4FieldInt $record "http_status"
                ErrorCode = Get-RouterV4SafeToken (Get-RouterV4FieldString $record "error_code") '^[a-z0-9_]{1,64}$'
                AttemptCount = Get-RouterV4FieldInt $record "attempt_count"
                RetryCount = Get-RouterV4FieldInt $record "retry_count"
                FallbackCount = Get-RouterV4FieldInt $record "fallback_count"
                UsagePresent = Get-RouterV4FieldBool $record "usage_present"
                Stream = Get-RouterV4FieldBool $record "stream"
            }
        }
        $snapshot.RecentItems = @($items)
    }
    else {
        $snapshot.RecentFailureCode = [string]$recentResponse.Failure
    }
}

$policyResponse = Invoke-RouterV4ControlPlaneCall -Method "GET" -Path "/v1/router/control-plane/policy" -Body "" -Token $token -Port $Port -TimeoutMs $TimeoutMs -Operation "read"
if ($policyResponse.Ok) {
    $policy = $policyResponse.Json
    $snapshot.PolicyOk = $true
    $snapshot.PolicyConfigGeneration = Get-RouterV4SafeToken (Get-RouterV4FieldString $policy "config_generation") '^[0-9a-f]{64}$'
    $snapshot.PolicyCrossModelFallback = Get-RouterV4SafeToken (Get-RouterV4FieldString $policy "cross_model_fallback") '^[A-Z_]{1,32}$'
    $policyBreaker = Get-RouterV4FieldValue $policy "circuit_breaker"
    $snapshot.PolicyBreakerEffectiveState = Get-RouterV4SafeToken (Get-RouterV4FieldString $policyBreaker "effective_state") '^[a-z_]{1,32}$'
    $snapshot.PolicyBreakerMutationAvailable = Get-RouterV4FieldBool $policyBreaker "mutation_available"
    $snapshot.PolicyBreakerReasonCode = Get-RouterV4SafeToken (Get-RouterV4FieldString $policyBreaker "reason_code") '^[A-Z0-9_]{1,64}$'
    $policies = @()
    foreach ($entry in @(Get-RouterV4FieldValue $policy "policies")) {
        if ($policies.Count -ge $Limit) { break }
        $policyId = Get-RouterV4SafeToken (Get-RouterV4FieldString $entry "policy_id") '^policy\.[a-z0-9\-]{1,48}$'
        if ([string]::IsNullOrWhiteSpace($policyId)) { continue }
        $policies += [pscustomobject]@{
            PolicyId = $policyId
            Version = Get-RouterV4FieldInt $entry "version"
            ConfiguredRetry = Convert-RouterV4RetryBody (Get-RouterV4FieldValue $entry "configured_retry")
            EffectiveRetry = Convert-RouterV4RetryBody (Get-RouterV4FieldValue $entry "effective_retry")
            ConfiguredTimeout = Convert-RouterV4TimeoutBody (Get-RouterV4FieldValue $entry "configured_timeout")
            EffectiveTimeout = Convert-RouterV4TimeoutBody (Get-RouterV4FieldValue $entry "effective_timeout")
            ConfiguredFailover = Convert-RouterV4FailoverBody (Get-RouterV4FieldValue $entry "configured_failover")
            EffectiveFailover = Convert-RouterV4FailoverBody (Get-RouterV4FieldValue $entry "effective_failover")
            EffectiveRetrySource = Get-RouterV4SafeToken (Get-RouterV4FieldString $entry "effective_retry_source") '^[a-z_]{1,32}$'
            EffectiveTimeoutSource = Get-RouterV4SafeToken (Get-RouterV4FieldString $entry "effective_timeout_source") '^[a-z_]{1,32}$'
            EffectiveFailoverSource = Get-RouterV4SafeToken (Get-RouterV4FieldString $entry "effective_failover_source") '^[a-z_]{1,32}$'
        }
    }
    $snapshot.Policies = @($policies)
    $routes = @()
    foreach ($route in @(Get-RouterV4FieldValue $policy "routes")) {
        if ($routes.Count -ge $Limit) { break }
        $routes += [pscustomobject]@{
            RouteId = Get-RouterV4SafeToken (Get-RouterV4FieldString $route "route_id") '^[A-Za-z0-9_\-\.]{1,64}$'
            TimeoutPolicyId = Get-RouterV4SafeToken (Get-RouterV4FieldString $route "timeout_policy_id") '^policy\.[a-z0-9\-]{1,48}$'
            RetryPolicyId = Get-RouterV4SafeToken (Get-RouterV4FieldString $route "retry_policy_id") '^policy\.[a-z0-9\-]{1,48}$'
            FailoverPolicyId = Get-RouterV4SafeToken (Get-RouterV4FieldString $route "failover_policy_id") '^policy\.[a-z0-9\-]{1,48}$'
        }
    }
    $snapshot.Routes = @($routes)
}
else {
    $snapshot.PolicyFailureCode = [string]$policyResponse.Failure
}

[pscustomobject]$snapshot
}
'@

# --- Control-plane mutation worker ---------------------------------------
$script:RouterV4MutationWorkerBody = @'
function Invoke-RouterV4MutationWorker {
    param(
        [Parameter(Mandatory = $false)][int]$Port = 0,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 800,
        [Parameter(Mandatory = $false)][string]$Path = "",
        [Parameter(Mandatory = $false)][string]$Body = "",
        [Parameter(Mandatory = $false)][string]$Operation = "policy",
        [Parameter(Mandatory = $false)][string]$Method = "PUT"
    )

$outcome = [ordered]@{
    Reachable = $false
    Ok = $false
    StatusCode = 0
    FailureCode = "control_mutation_failed"
    ResultCode = ""
    ConfigGeneration = ""
    LocalRouterEnabled = $null
    StartStopAvailable = $false
    LifecycleReasonCode = ""
    SelectionState = ""
    SelectionModel = ""
    SelectionGeneration = $null
    ExpiresAt = ""
    CaptureToken = ""
    CaptureStatus = ""
    ThreadRef = ""
}

$token = Resolve-RouterV4ControlPlaneToken
if ($Port -lt 1 -or $Port -gt 65535 -or [string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($Path)) {
    $outcome.FailureCode = "control_read_unavailable"
    return [pscustomobject]$outcome
}

$safeMethod = switch ($Method) {
    "POST" { "POST"; break }
    "DELETE" { "DELETE"; break }
    default { "PUT" }
}

$response = Invoke-RouterV4ControlPlaneCall -Method $safeMethod -Path $Path -Body $Body -Token $token -Port $Port -TimeoutMs $TimeoutMs -Operation $Operation
$outcome.Reachable = [bool]$response.Reachable
$outcome.StatusCode = [int]$response.StatusCode
if (-not $response.Ok) {
    $outcome.FailureCode = [string]$response.Failure
    return [pscustomobject]$outcome
}

$outcome.Ok = $true
$outcome.FailureCode = ""
$json = $response.Json
$outcome.ResultCode = Get-RouterV4SafeToken (Get-RouterV4FieldString $json "result_code") '^[a-z_]{1,32}$'
$outcome.ConfigGeneration = Get-RouterV4SafeToken (Get-RouterV4FieldString $json "config_generation") '^[0-9a-f]{64}$'
if ($Operation -eq "feature") {
    $outcome.LocalRouterEnabled = Get-RouterV4FieldBool $json "local_router_enabled"
    $outcome.StartStopAvailable = Get-RouterV4FieldBool $json "start_stop_available"
    $outcome.LifecycleReasonCode = Get-RouterV4SafeToken (Get-RouterV4FieldString $json "lifecycle_reason_code") '^[A-Z0-9_]{1,64}$'
}
$outcome.SelectionState = Get-RouterV4SafeToken (Get-RouterV4FieldString $json "selection_state") '^[a-z_]{1,32}$'
$outcome.SelectionModel = Get-RouterV4SafeToken (Get-RouterV4FieldString $json "selection_model") '^[A-Za-z0-9_.\-/:]{1,128}$'
$outcome.SelectionGeneration = Get-RouterV4FieldLong $json "selection_generation"
$outcome.ExpiresAt = Get-RouterV4IsoTime (Get-RouterV4FieldString $json "expires_at")
$outcome.CaptureToken = Get-RouterV4SafeToken (Get-RouterV4FieldString $json "capture_token") '^[0-9a-f]{32}$'
$outcome.CaptureStatus = Get-RouterV4SafeToken (Get-RouterV4FieldString $json "status") '^[a-z_]{1,32}$'
$outcome.ThreadRef = Get-RouterV4SafeToken (Get-RouterV4FieldString $json "thread_ref") '^[0-9a-f]{16}$'
[pscustomobject]$outcome
}
'@

# HS-1B thread-scoped model controls: read worker (feature + observed threads)
# and the bounded capture poll worker. Both run only inside the persistent
# background runspace, so the UI thread never performs a blocking HTTP wait.
$script:RouterV4ThreadWorkerBody = @'
function Invoke-RouterV4ThreadReadWorker {
    param(
        [Parameter(Mandatory = $false)][int]$Port = 0,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 800,
        [Parameter(Mandatory = $false)][int]$Limit = 20
    )

    $outcome = [ordered]@{
        Ok = $false
        FailureCode = "control_read_unavailable"
        ConfiguredEnabled = $false
        EffectiveEnabled = $false
        MutationAvailable = $false
        ConfigGeneration = ""
        ObservedThreadCount = 0
        Threads = @()
    }

    $token = Resolve-RouterV4ControlPlaneToken
    if ($Port -lt 1 -or $Port -gt 65535 -or [string]::IsNullOrWhiteSpace($token)) {
        return [pscustomobject]$outcome
    }

    $feature = Invoke-RouterV4ControlPlaneCall -Method "GET" -Path "/v1/router/control-plane/thread-selection-feature" -Body "" -Token $token -Port $Port -TimeoutMs $TimeoutMs -Operation "read"
    if (-not $feature.Ok) {
        if (-not $feature.Reachable) { $outcome.FailureCode = "control_plane_unreachable" }
        else { $outcome.FailureCode = [string]$feature.Failure }
        return [pscustomobject]$outcome
    }

    $outcome.ConfiguredEnabled = Get-RouterV4FieldBool $feature.Json "configured_enabled"
    $outcome.EffectiveEnabled = Get-RouterV4FieldBool $feature.Json "effective_enabled"
    $outcome.MutationAvailable = Get-RouterV4FieldBool $feature.Json "mutation_available"
    $outcome.ConfigGeneration = Get-RouterV4SafeToken (Get-RouterV4FieldString $feature.Json "config_generation") '^[0-9a-f]{64}$'
    $outcome.ObservedThreadCount = Get-RouterV4FieldInt $feature.Json "observed_thread_count"

    $threads = Invoke-RouterV4ControlPlaneCall -Method "GET" -Path ("/v1/router/control-plane/threads?limit=" + [string]$Limit) -Body "" -Token $token -Port $Port -TimeoutMs $TimeoutMs -Operation "read"
    if (-not $threads.Ok) {
        if (-not $threads.Reachable) { $outcome.FailureCode = "control_plane_unreachable" }
        else { $outcome.FailureCode = [string]$threads.Failure }
        return [pscustomobject]$outcome
    }

    $items = @()
    foreach ($thread in @($threads.Json.threads)) {
        $items += [pscustomobject][ordered]@{
            ThreadRef = Get-RouterV4SafeToken (Get-RouterV4FieldString $thread "thread_ref") '^[0-9a-f]{16}$'
            ClientId = Get-RouterV4SafeToken (Get-RouterV4FieldString $thread "client_id") '^[A-Za-z0-9_.\-]{1,64}$'
            LastSeen = Get-RouterV4IsoTime (Get-RouterV4FieldString $thread "last_seen")
            RequestKind = Get-RouterV4SafeToken (Get-RouterV4FieldString $thread "request_kind") '^[a-z0-9_\-]{1,32}$'
            RequestedModel = Get-RouterV4SafeToken (Get-RouterV4FieldString $thread "requested_model") '^[A-Za-z0-9_.\-/:]{1,128}$'
            SelectedModel = Get-RouterV4SafeToken (Get-RouterV4FieldString $thread "selected_model") '^[A-Za-z0-9_.\-/:]{1,128}$'
            SelectionState = Get-RouterV4SafeToken (Get-RouterV4FieldString $thread "selection_state") '^[a-z_]{1,32}$'
            SelectionGeneration = Get-RouterV4FieldLong $thread "selection_generation"
            LastFailureCode = Get-RouterV4SafeToken (Get-RouterV4FieldString $thread "last_failure_code") '^[a-z_]{1,64}$'
        }
    }

    $outcome.Ok = $true
    $outcome.FailureCode = ""
    $outcome.Threads = $items
    return [pscustomobject]$outcome
}

function Invoke-RouterV4CapturePollWorker {
    param(
        [Parameter(Mandatory = $false)][int]$Port = 0,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 800,
        [Parameter(Mandatory = $false)][string]$CaptureToken = "",
        [Parameter(Mandatory = $false)][int]$MaxAttempts = 30,
        [Parameter(Mandatory = $false)][int]$IntervalMs = 2000
    )

    # Bounded, expiry-aware, cancellable-by-404 poll loop. It sleeps only inside
    # this background worker, never on the UI thread.
    $outcome = [ordered]@{
        Ok = $false
        Terminal = "pending"
        FailureCode = ""
        Status = ""
        ThreadRef = ""
        Attempts = 0
    }

    $token = Resolve-RouterV4ControlPlaneToken
    if ($Port -lt 1 -or $Port -gt 65535 -or [string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($CaptureToken)) {
        $outcome.Terminal = "failed"
        $outcome.FailureCode = "control_read_unavailable"
        return [pscustomobject]$outcome
    }

    $attempts = [int]$MaxAttempts
    if ($attempts -lt 1) { $attempts = 1 }
    if ($attempts -gt 60) { $attempts = 60 }
    $interval = [int]$IntervalMs
    if ($interval -lt 250) { $interval = 250 }

    for ($index = 0; $index -lt $attempts; $index++) {
        $outcome.Attempts = $index + 1
        $path = "/v1/router/control-plane/threads/capture/" + $CaptureToken
        $response = Invoke-RouterV4ControlPlaneCall -Method "GET" -Path $path -Body "" -Token $token -Port $Port -TimeoutMs $TimeoutMs -Operation "read"
        if ($response.Ok) {
            $outcome.Status = Get-RouterV4SafeToken (Get-RouterV4FieldString $response.Json "status") '^[a-z_]{1,32}$'
            $outcome.ThreadRef = Get-RouterV4SafeToken (Get-RouterV4FieldString $response.Json "thread_ref") '^[0-9a-f]{16}$'
            if ($outcome.Status -eq "captured") {
                $outcome.Ok = $true
                $outcome.Terminal = "captured"
                return [pscustomobject]$outcome
            }
            if ($outcome.Status -eq "cancelled" -or $outcome.Status -eq "expired") {
                $outcome.Terminal = [string]$outcome.Status
                $outcome.FailureCode = "control_thread_capture_not_found"
                return [pscustomobject]$outcome
            }
        }
        elseif ($response.StatusCode -eq 404) {
            $outcome.Terminal = "not_found"
            $outcome.FailureCode = "control_thread_capture_not_found"
            return [pscustomobject]$outcome
        }
        elseif (-not $response.Reachable) {
            $outcome.Terminal = "failed"
            $outcome.FailureCode = "control_plane_unreachable"
            return [pscustomobject]$outcome
        }

        Start-Sleep -Milliseconds $interval
    }

    $outcome.Terminal = "timeout"
    $outcome.FailureCode = "control_thread_capture_not_found"
    return [pscustomobject]$outcome
}
'@

# Composed engine source: transport helpers plus all pre-loaded workers.
$script:RouterV4EngineSource = $script:RouterV4TransportSource + "`n" + $script:RouterV4StatusWorkerBody + "`n" + $script:RouterV4MutationWorkerBody + "`n" + $script:RouterV4ThreadWorkerBody

# --- Runtime state --------------------------------------------------------
$script:RouterV4RefreshTimer = $null
$script:RouterV4MutationTimer = $null
$script:RouterV4LastRefreshUtc = $null
$script:RouterV4BackgroundInFlight = $false
$script:RouterV4RefreshGeneration = 0
$script:RouterV4Closing = $false
$script:RouterV4BackgroundPowerShell = $null
$script:RouterV4BackgroundRunspace = $null
$script:RouterV4MutationRunspace = $null
$script:RouterV4BackgroundHandle = $null
$script:RouterV4BackgroundGeneration = 0
$script:RouterV4MutationInFlight = $false
$script:RouterV4MutationPowerShell = $null
$script:RouterV4MutationHandle = $null
$script:RouterV4MutationOperation = ""
$script:RouterV4LastControlPlane = $null
$script:RouterV4LastSnapshot = $null
$script:RouterV4PolicyEditorKey = ""
$script:RouterV4MutationStatusText = ""
$script:RouterV4RecentItems = [System.Collections.ObjectModel.ObservableCollection[object]]::new()

function Get-RouterV4CodexHome {
    if ($env:CODEX_HOME -and -not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { return $env:CODEX_HOME }
    return (Join-Path $HOME ".codex")
}

function Get-RouterV4ManagerPath {
    return (Join-Path (Get-RouterV4CodexHome) "multimodel-manager")
}

function Get-RouterV4RouterConfigPath {
    return (Join-Path (Get-RouterV4ManagerPath) "local-router/router.config.json")
}

function Get-RouterV4CliStatePath {
    return (Join-Path (Get-RouterV4ManagerPath) "router-cli-state.json")
}

function Get-RouterV4DesktopRouteStatePath {
    return (Join-Path (Get-RouterV4ManagerPath) "desktop-route-state.json")
}

function Get-RouterV4VisualStatePath {
    return (Join-Path (Get-RouterV4ManagerPath) "visual-console-state.json")
}

function Read-RouterV4JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
    }
    catch {
        return [pscustomobject]@{ __corrupt = $true }
    }
}

function Get-RouterV4FeatureState {
    # Configured state only (router.config.json). This is never treated as
    # process existence, readiness, or control-plane reachability.
    $config = Read-RouterV4JsonFile (Get-RouterV4RouterConfigPath)
    if ($null -eq $config) {
        return [pscustomobject]@{ Enabled = $false; Invalid = $false; Mode = "direct"; Port = $null; Host = "" }
    }
    if ($config.PSObject.Properties["__corrupt"]) {
        return [pscustomobject]@{ Enabled = $false; Invalid = $true; Mode = "unknown"; Port = $null; Host = "" }
    }
    $mode = if ($config.PSObject.Properties["mode"]) { [string]$config.mode } else { "direct" }
    $enabled = $false
    if ($null -ne $config.local_router -and $null -ne $config.local_router.enabled) {
        $enabled = [bool]$config.local_router.enabled
    }
    $port = $null
    $hostValue = ""
    if ($null -ne $config.local_router) {
        if ($null -ne $config.local_router.port) { $port = [int]$config.local_router.port }
        if ($null -ne $config.local_router.host) { $hostValue = [string]$config.local_router.host }
    }
    return [pscustomobject]@{ Enabled = ($mode -eq "router" -and $enabled); Invalid = $false; Mode = $mode; Port = $port; Host = $hostValue }
}

function Get-RouterV4UiFeatureEnabled {
    $state = Read-RouterV4JsonFile (Get-RouterV4VisualStatePath)
    if ($null -eq $state -or $state.PSObject.Properties["__corrupt"]) { return $true }
    if ($state.PSObject.Properties["router_ui_visible"]) { return [bool]$state.router_ui_visible }
    return $true
}

function Get-RouterV4Token {
    $processValue = [Environment]::GetEnvironmentVariable($script:RouterV4TokenVariableName, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($processValue)) { return [string]$processValue }
    $userValue = if (Get-Command Get-RouterCliUserEnvironmentValue -ErrorAction SilentlyContinue) {
        Get-RouterCliUserEnvironmentValue $script:RouterV4TokenVariableName
    }
    else {
        [Environment]::GetEnvironmentVariable($script:RouterV4TokenVariableName, [EnvironmentVariableTarget]::User)
    }
    if ([string]::IsNullOrWhiteSpace($userValue)) { return "" }
    return [string]$userValue
}

function Get-RouterV4TokenPresent {
    return (-not [string]::IsNullOrWhiteSpace((Get-RouterV4Token)))
}

# Fail closed: only plain loopback with a valid port may be contacted. A
# configured remote host or an invalid port yields no request at all.
function Test-RouterV4LoopbackTarget([string]$HostValue, $Port) {
    if ([string]::IsNullOrWhiteSpace($HostValue)) { return $false }
    if ($HostValue -ne $script:RouterV4LoopbackHost) { return $false }
    if ($null -eq $Port) { return $false }
    $portValue = 0
    if (-not [int]::TryParse([string]$Port, [ref]$portValue)) { return $false }
    if ($portValue -lt 1 -or $portValue -gt 65535) { return $false }
    return $true
}

# --- Safe display helpers -------------------------------------------------
function Format-RouterV4TokenTotal($Value) {
    # Unknown is never zero.
    if ($null -eq $Value) { return "未知（≠ 0）" }
    return ([string]([long]$Value))
}

function Format-RouterV4CurrencyCosts($Currencies) {
    $entries = @()
    foreach ($entry in @($Currencies)) {
        if ($null -eq $entry) { continue }
        $currency = [string]$entry.Currency
        if ([string]::IsNullOrWhiteSpace($currency)) { continue }
        if ($null -eq $entry.TotalCost) { continue }
        $amount = [decimal]$entry.TotalCost
        $entries += ($currency + " " + $amount.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture))
    }
    if ($entries.Count -eq 0) { return "未知 / 不可用（≠ $0.00）" }
    # Multiple currencies are listed separately and never summed.
    return ($entries -join " · ")
}

function Test-RouterV4ZeroMayDisplay([decimal]$Amount, [string]$Status) {
    return ($Status -eq "COMPLETE" -and $Amount -eq 0)
}

function Format-RouterV4Count($Value) {
    if ($null -eq $Value) { return "未知" }
    return ([string][int]$Value)
}

function Get-RouterV4LabelColor([string]$Value) {
    switch ($Value) {
        "READY" { return "#2DD4A3" }
        "ROUTER" { return "#8CA9FF" }
        "DEGRADED" { return "#F6B94A" }
        { $_ -in @("FAILED","CONFIG INVALID") } { return "#FF6B81" }
        default { return "#B6C2D9" }
    }
}

# --- UI error allowlist ---------------------------------------------------
function Convert-RouterV4ControlCodeToUiCode([string]$Code) {
    switch ($Code) {
        "authentication_required" { return "AUTH_REQUIRED" }
        "authentication_invalid" { return "AUTH_INVALID" }
        "scope_denied" { return "SCOPE_DENIED" }
        "control_generation_conflict" { return "GENERATION_CONFLICT" }
        "control_mutation_busy" { return "MUTATION_BUSY" }
        "control_payload_too_large" { return "PAYLOAD_TOO_LARGE" }
        "control_policy_invalid" { return "POLICY_INVALID" }
        "control_policy_not_found" { return "POLICY_INVALID" }
        "control_feature_update_failed" { return "FEATURE_UPDATE_FAILED" }
        "control_mutation_failed" { return "POLICY_UPDATE_FAILED" }
        "control_read_unavailable" { return "CONTROL_PLANE_UNAVAILABLE" }
        "control_read_degraded" { return "READ_DEGRADED" }
        "control_plane_unreachable" { return "ROUTER_UNREACHABLE" }
        "control_invalid_request" { return "CONTROL_INVALID_REQUEST" }
        "control_thread_not_observed" { return "THREAD_NOT_OBSERVED" }
        "control_thread_selection_conflict" { return "THREAD_SELECTION_CONFLICT" }
        "control_thread_selection_expired" { return "THREAD_SELECTION_EXPIRED" }
        "control_thread_selection_disabled" { return "THREAD_SELECTION_DISABLED" }
        "control_thread_selection_unavailable" { return "THREAD_SELECTION_UNAVAILABLE" }
        "control_thread_selection_feature_update_failed" { return "THREAD_SELECTION_FEATURE_UPDATE_FAILED" }
        "control_thread_capture_busy" { return "THREAD_CAPTURE_BUSY" }
        "control_thread_capture_not_found" { return "THREAD_CAPTURE_NOT_FOUND" }
        "control_thread_capture_unavailable" { return "THREAD_CAPTURE_UNAVAILABLE" }
        "control_model_not_approved" { return "MODEL_NOT_APPROVED" }
        "control_model_route_unavailable" { return "MODEL_ROUTE_UNAVAILABLE" }
        "control_model_capability_mismatch" { return "MODEL_CAPABILITY_MISMATCH" }
        default { return "ROUTER_OPERATION_FAILED" }
    }
}

function Convert-RouterV4UiErrorMessage([string]$Code) {
    # Fixed allowlisted text only: no exception text, HTTP body, URL, or path.
    # HS-1B (thread-scoped model selection): fixed localized text only, and the
    # unknown/foreign/expired capture cases deliberately share one message.
    $hs1b = [ordered]@{
        "CONTROL_INVALID_REQUEST" = "控制面请求无效，未应用。"
        "THREAD_NOT_OBSERVED" = "该会话尚未被 Router 观察到，请刷新后重试。"
        "THREAD_SELECTION_CONFLICT" = "该会话的 selection 状态已被其他操作更新，请刷新后重试。"
        "THREAD_SELECTION_EXPIRED" = "该会话的 selection 已过期，请刷新后重试。"
        "THREAD_SELECTION_DISABLED" = "会话模型切换当前已停用，请先启用。"
        "THREAD_SELECTION_UNAVAILABLE" = "会话模型切换在当前运行时不可用。"
        "THREAD_SELECTION_FEATURE_UPDATE_FAILED" = "会话模型切换开关未应用，请刷新后重试。"
        "THREAD_CAPTURE_BUSY" = "当前已有一个会话识别窗口正在等待消息。请完成或取消当前识别后再试。"
        "THREAD_CAPTURE_NOT_FOUND" = "识别窗口不存在、已过期或已结束。"
        "THREAD_CAPTURE_UNAVAILABLE" = "会话识别当前不可用。"
        "MODEL_NOT_APPROVED" = "该模型不在当前已批准的 Router 模型列表中。"
        "MODEL_ROUTE_UNAVAILABLE" = "该模型当前没有可用的 Router 路由。"
        "MODEL_CAPABILITY_MISMATCH" = "该模型无法满足当前请求能力，未应用。"
    }
    if ($hs1b.Contains($Code)) { return [string]$hs1b[$Code] }
    $fixed = [ordered]@{
        "ROUTER_NOT_READY" = "Local Router 尚未就绪。"
        "TOKEN_MISSING" = "缺少 Local Router 客户端凭据。"
        "MODEL_NOT_AVAILABLE" = "当前模型没有可用的 Router 路由。"
        "CONFIG_INVALID" = "Local Router 配置无效，请先运行 Doctor。"
        "ROUTER_UNREACHABLE" = "无法连接本机 Local Router。"
        "DESKTOP_RESTART_REQUIRED" = "Desktop 路由已更新，请彻底重启并新建会话。"
        "ROLLBACK_REQUIRED" = "操作未完整完成，请执行安全恢复。"
        "AUTH_REQUIRED" = "Local Router 认证失败：请检查本机客户端凭据是否有效。"
        "AUTH_INVALID" = "Local Router 认证失败：请检查本机客户端凭据是否有效。"
        "SCOPE_DENIED" = "当前客户端缺少 router:control-plane 作用域，请求已被拒绝。"
        "GENERATION_CONFLICT" = "配置已被其他操作更新，请刷新后重试。"
        "MUTATION_BUSY" = "另一个配置操作正在进行，请稍后重试。"
        "PAYLOAD_TOO_LARGE" = "策略请求体超过控制面硬限制，未应用。"
        "POLICY_INVALID" = "策略内容无效或不受支持，未应用。"
        "POLICY_UPDATE_FAILED" = "策略更新未应用，请刷新后重试。"
        "FEATURE_UPDATE_FAILED" = "Router 功能开关更新失败，未应用。"
        "CONTROL_PLANE_UNAVAILABLE" = "本机控制面读取不可用。"
        "READ_DEGRADED" = "控制面读取降级，显示的数据可能不完整。"
    }
    if ($fixed.Contains($Code)) { return [string]$fixed[$Code] }
    return "Local Router 操作失败。请运行 Doctor 查看安全诊断。"
}

function Convert-RouterV4UiError($Exception) {
    # UI errors are allowlisted fixed text. Raw exception content, paths,
    # URLs, secret references, provider bodies, and stack traces never reach UI.
    $null = $Exception
    return "ROUTER_OPERATION_FAILED"
}

# --- Local integration dispatch (LR-12 / LR-13) --------------------------
function Invoke-RouterV4CliAction([string]$Action, [string]$Model, [string]$Effort, [string]$ProjectPath) {
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add("-Action")
    $arguments.Add($Action)
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $arguments.Add("-Model"); $arguments.Add($Model)
    }
    if (-not [string]::IsNullOrWhiteSpace($Effort)) {
        $arguments.Add("-ReasoningEffort"); $arguments.Add($Effort)
    }
    if ($Action -eq "Enable" -or $Action -eq "Disable") {
        $arguments.Add("-Force")
    }
    if ($Action -eq "Launch") {
        $arguments.Add("-Ping")
        if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
            $arguments.Add("-ProjectPath"); $arguments.Add($ProjectPath)
        }
    }
    return [pscustomobject]@{ Script = $script:RouterV4CliModule; Arguments = @($arguments.ToArray()) }
}

function Invoke-RouterV4DesktopAction([string]$Mode, [string]$Model, [string]$Effort) {
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add("-Mode")
    $arguments.Add($Mode)
    if ($Mode -eq "activate") {
        if (-not [string]::IsNullOrWhiteSpace($Model)) { $arguments.Add("-ModelId"); $arguments.Add($Model) }
        if (-not [string]::IsNullOrWhiteSpace($Effort)) { $arguments.Add("-Effort"); $arguments.Add($Effort) }
        $arguments.Add("-ConfirmationCode"); $arguments.Add("ROUTER")
    }
    return [pscustomobject]@{ Script = $script:RouterV4DesktopAdapter; Arguments = @($arguments.ToArray()) }
}

function Start-RouterV4Subprocess($Dispatch, [switch]$Interactive) {
    $scriptPath = [string]$Dispatch.Script
    $args = [string[]]$Dispatch.Arguments
    if ($Interactive) {
        $pwshArgs = New-Object System.Collections.Generic.List[string]
        $pwshArgs.Add("-NoExit")
        $pwshArgs.Add("-NoProfile")
        $pwshArgs.Add("-ExecutionPolicy"); $pwshArgs.Add("Bypass")
        $pwshArgs.Add("-File"); $pwshArgs.Add($scriptPath)
        foreach ($arg in $args) { $pwshArgs.Add($arg) }
        Start-Process -FilePath "pwsh.exe" -ArgumentList $pwshArgs.ToArray() | Out-Null
        return
    }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath @args
    if ($LASTEXITCODE -ne 0) {
        throw "ROUTER_COMMAND_FAILED"
    }
}

function Show-RouterV4Error([string]$Code, [string]$Detail = "") {
    $null = $Detail
    [System.Windows.MessageBox]::Show((Convert-RouterV4UiErrorMessage $Code), "Local Router", "OK", "Warning") | Out-Null
}

function Get-RouterV4SafeRestorePlan {
    # Fresh local state only; never cached display data.
    $snapshot = Get-RouterV4SnapshotCore
    $actions = New-Object System.Collections.Generic.List[string]
    if ($snapshot.DesktopRouteKind -eq "router") { $actions.Add("restore_desktop") }
    if ($snapshot.CliMode -eq "ROUTER") { $actions.Add("disable_cli") }
    return @($actions.ToArray())
}

# --- Snapshot model (control plane is authoritative) ---------------------
function Get-RouterV4SnapshotCore {
    $feature = Get-RouterV4FeatureState
    $controlPlane = $script:RouterV4LastControlPlane
    $reachable = ($null -ne $controlPlane) -and [bool]$controlPlane.Reachable
    $statusOk = ($null -ne $controlPlane) -and [bool]$controlPlane.StatusOk
    $failureCode = if ($null -ne $controlPlane) { [string]$controlPlane.FailureCode } else { "" }
    $uiFailureCode = if ([string]::IsNullOrWhiteSpace($failureCode)) { "" } else { Convert-RouterV4ControlCodeToUiCode $failureCode }

    # Configured feature state comes from router.config.json; runtime feature
    # state comes only from the authoritative control plane.
    $runtimeFeatureEnabled = if ($statusOk) { [bool]$controlPlane.LocalRouterEnabled } else { $null }

    $cliState = Read-RouterV4JsonFile (Get-RouterV4CliStatePath)
    $cliMode = "DIRECT"
    $cliModel = ""
    $cliEffort = ""
    if ($null -ne $cliState -and -not $cliState.PSObject.Properties["__corrupt"] -and $cliState.PSObject.Properties["mode"]) {
        if ([string]$cliState.mode -eq "router") { $cliMode = "ROUTER" }
    }
    if ($null -ne $cliState -and $cliState.PSObject.Properties["selected_model"]) { $cliModel = [string]$cliState.selected_model }
    if ($null -ne $cliState -and $cliState.PSObject.Properties["reasoning_effort"]) { $cliEffort = [string]$cliState.reasoning_effort }

    $desktopState = Read-RouterV4JsonFile (Get-RouterV4DesktopRouteStatePath)
    $desktopMode = "DIRECT"
    $desktopModel = ""
    $desktopEffort = ""
    $desktopRouteKind = ""
    $desktopActive = $false
    if ($null -ne $desktopState -and -not $desktopState.PSObject.Properties["__corrupt"]) {
        if ($desktopState.PSObject.Properties["active"]) { $desktopActive = [bool]$desktopState.active }
        if ($desktopState.PSObject.Properties["route_kind"]) { $desktopRouteKind = [string]$desktopState.route_kind }
    }
    if ($desktopActive) {
        $desktopMode = if ($desktopRouteKind -eq "router") { "ROUTER" } else { "DIRECT" }
        if ($desktopState.PSObject.Properties["model"]) { $desktopModel = [string]$desktopState.model }
        if ($desktopState.PSObject.Properties["effort"]) { $desktopEffort = [string]$desktopState.effort }
    }

    $overall = if ($cliMode -eq "ROUTER" -and $desktopMode -eq "ROUTER") { "ROUTER" }
    elseif ($cliMode -eq "DIRECT" -and $desktopMode -eq "DIRECT") { "DIRECT" }
    else { "MIXED" }

    $warnings = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    if ($feature.Invalid) {
        $errors.Add("CONFIG INVALID")
        $warnings.Add("Router 配置损坏；已禁止写入操作。")
    }
    if (-not (Test-RouterV4LoopbackTarget $feature.Host $feature.Port)) {
        $warnings.Add("Router 目标不是有效的 127.0.0.1 回环地址；已拒绝网络访问。")
    }
    elseif (-not (Get-RouterV4TokenPresent)) {
        $warnings.Add("缺少 Local Router 客户端凭据；控制面读取未执行。")
    }
    elseif (-not $reachable) {
        $warnings.Add("Local Router 控制面不可达（不会自动启动，也不会访问 Provider）。")
    }
    elseif (-not $statusOk) {
        $warnings.Add((Convert-RouterV4UiErrorMessage $uiFailureCode))
    }

    return [pscustomobject]@{
        ConfiguredFeatureEnabled = $feature.Enabled
        FeatureInvalid = $feature.Invalid
        Host = $feature.Host
        Port = $feature.Port
        TargetValid = (Test-RouterV4LoopbackTarget $feature.Host $feature.Port)
        TokenPresent = (Get-RouterV4TokenPresent)
        ControlPlaneRequested = ($null -ne $controlPlane)
        ControlPlaneReachable = $reachable
        ControlPlaneStatusOk = $statusOk
        ControlPlaneFailureCode = $failureCode
        ControlPlaneFailureUiCode = $uiFailureCode
        FeatureEnabled = $runtimeFeatureEnabled
        RuntimeFeatureEnabled = $runtimeFeatureEnabled
        RuntimeLifecycle = if ($statusOk) { [string]$controlPlane.Lifecycle } else { "UNKNOWN" }
        RuntimeReady = if ($statusOk) { [bool]$controlPlane.Ready } else { $false }
        RuntimeReachable = $reachable
        ConfigGeneration = if ($statusOk) { [string]$controlPlane.ConfigGeneration } else { "" }
        InFlightCount = if ($statusOk) { $controlPlane.InFlightCount } else { $null }
        FeatureMutationAvailable = if ($statusOk) { [bool]$controlPlane.FeatureMutationAvailable } else { $false }
        PolicyMutationAvailable = if ($statusOk) { [bool]$controlPlane.PolicyMutationAvailable } else { $false }
        MeteringAvailable = if ($statusOk) { [bool]$controlPlane.MeteringAvailable } else { $false }
        RecentRequestAvailable = if ($statusOk) { [bool]$controlPlane.RecentRequestAvailable } else { $false }
        HealthAvailable = if ($statusOk) { [bool]$controlPlane.HealthAvailable } else { $false }
        HealthReasonCode = if ($statusOk) { [string]$controlPlane.HealthReasonCode } else { "" }
        HealthGeneratedAt = if ($statusOk) { [string]$controlPlane.HealthGeneratedAt } else { "" }
        HealthRouteCount = if ($statusOk) { $controlPlane.HealthRouteCount } else { $null }
        HealthHealthyCount = if ($statusOk) { $controlPlane.HealthHealthyCount } else { $null }
        HealthDegradedCount = if ($statusOk) { $controlPlane.HealthDegradedCount } else { $null }
        HealthUnhealthyCount = if ($statusOk) { $controlPlane.HealthUnhealthyCount } else { $null }
        HealthUnknownCount = if ($statusOk) { $controlPlane.HealthUnknownCount } else { $null }
        BreakerEffectiveState = if ($statusOk) { [string]$controlPlane.BreakerEffectiveState } else { "" }
        BreakerMutationAvailable = if ($statusOk) { [bool]$controlPlane.BreakerMutationAvailable } else { $false }
        BreakerReasonCode = if ($statusOk) { [string]$controlPlane.BreakerReasonCode } else { "" }
        LifecycleStartStopAvailable = if ($statusOk) { [bool]$controlPlane.LifecycleStartStopAvailable } else { $false }
        LifecycleReasonCode = if ($statusOk) { [string]$controlPlane.LifecycleReasonCode } else { "" }
        UsageOk = if ($statusOk) { [bool]$controlPlane.UsageOk } else { $false }
        UsageFailureCode = if ($statusOk) { [string]$controlPlane.UsageFailureCode } else { "" }
        UsageRecordCount = if ($statusOk) { $controlPlane.UsageRecordCount } else { $null }
        UsageCapacity = if ($statusOk) { $controlPlane.UsageCapacity } else { $null }
        UsageKnownCount = if ($statusOk) { $controlPlane.UsageKnownCount } else { $null }
        UsageUnknownCount = if ($statusOk) { $controlPlane.UsageUnknownCount } else { $null }
        UsageKnownCostCount = if ($statusOk) { $controlPlane.UsageKnownCostCount } else { $null }
        UsageUnknownCostCount = if ($statusOk) { $controlPlane.UsageUnknownCostCount } else { $null }
        UsageInputTokensTotal = if ($statusOk) { $controlPlane.UsageInputTokensTotal } else { $null }
        UsageOutputTokensTotal = if ($statusOk) { $controlPlane.UsageOutputTokensTotal } else { $null }
        UsageDegraded = if ($statusOk) { [bool]$controlPlane.UsageDegraded } else { $false }
        UsageDegradationCodes = if ($statusOk) { @($controlPlane.UsageDegradationCodes) } else { @() }
        UsageCurrencies = if ($statusOk) { @($controlPlane.UsageCurrencies) } else { @() }
        RecentOk = if ($statusOk) { [bool]$controlPlane.RecentOk } else { $false }
        RecentFailureCode = if ($statusOk) { [string]$controlPlane.RecentFailureCode } else { "" }
        RecentRecordCount = if ($statusOk) { $controlPlane.RecentRecordCount } else { $null }
        RecentDegraded = if ($statusOk) { [bool]$controlPlane.RecentDegraded } else { $false }
        RecentItems = if ($statusOk) { @($controlPlane.RecentItems) } else { @() }
        PolicyOk = if ($statusOk) { [bool]$controlPlane.PolicyOk } else { $false }
        PolicyFailureCode = if ($statusOk) { [string]$controlPlane.PolicyFailureCode } else { "" }
        PolicyCrossModelFallback = if ($statusOk) { [string]$controlPlane.PolicyCrossModelFallback } else { "" }
        PolicyBreakerEffectiveState = if ($statusOk) { [string]$controlPlane.PolicyBreakerEffectiveState } else { "" }
        PolicyBreakerMutationAvailable = if ($statusOk) { [bool]$controlPlane.PolicyBreakerMutationAvailable } else { $false }
        PolicyBreakerReasonCode = if ($statusOk) { [string]$controlPlane.PolicyBreakerReasonCode } else { "" }
        Policies = if ($statusOk) { @($controlPlane.Policies) } else { @() }
        PolicyRoutes = if ($statusOk) { @($controlPlane.Routes) } else { @() }
        CliMode = $cliMode
        CliModel = $cliModel
        CliEffort = $cliEffort
        DesktopMode = $desktopMode
        DesktopModel = $desktopModel
        DesktopEffort = $desktopEffort
        DesktopRouteKind = $desktopRouteKind
        Overall = $overall
        MutationInFlight = $script:RouterV4MutationInFlight
        MutationStatusText = $script:RouterV4MutationStatusText
        Warnings = @($warnings.ToArray())
        Errors = @($errors.ToArray())
        CrossModelFallback = $script:RouterV4CrossModelFallbackHardOff
        TransportLabel = "Loopback control plane only"
    }
}

# --- Background read engine ----------------------------------------------
function New-RouterV4EngineRunspace {
    # One runspace with the transport helpers and both worker functions
    # pre-loaded. Parsing happens here once, never inside a timer tick.
    $runspace = $null
    $warmup = $null
    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $warmup = [powershell]::Create()
        $warmup.Runspace = $runspace
        [void]$warmup.AddScript($script:RouterV4EngineSource)
        $null = $warmup.Invoke()
        if ($warmup.HadErrors) { throw "engine warmup failed" }
    }
    catch {
        if ($null -ne $warmup) { try { $warmup.Dispose() } catch { } }
        if ($null -ne $runspace) { try { $runspace.Dispose() } catch { } }
        return $null
    }
    $warmup.Dispose()
    return $runspace
}

function Initialize-RouterV4BackgroundEngine {
    # Separate persistent runspaces for reads and mutations so a timer-tick read
    # can never contend with a user-initiated mutation on one pipeline.
    if ($null -eq $script:RouterV4BackgroundRunspace) {
        $script:RouterV4BackgroundRunspace = New-RouterV4EngineRunspace
    }
    if ($null -eq $script:RouterV4MutationRunspace) {
        $script:RouterV4MutationRunspace = New-RouterV4EngineRunspace
    }
}

function Test-RouterV4SnapshotGenerationCurrent([int]$Generation) {
    return ($Generation -eq [int]$script:RouterV4RefreshGeneration)
}

function Start-RouterV4BackgroundRefresh {
    # Feature Enabled is request admission state, not process existence: the
    # refresh runs whenever a valid loopback target and a token are available
    # so a disabled-but-running Host stays observable and re-enableable.
    if ($script:RouterV4Closing -or $script:RouterV4BackgroundInFlight) { return }
    $feature = Get-RouterV4FeatureState
    if ($feature.Invalid) { return }
    if (-not (Test-RouterV4LoopbackTarget $feature.Host $feature.Port)) { return }
    if (-not (Get-RouterV4TokenPresent)) { return }
    Initialize-RouterV4BackgroundEngine
    if ($null -eq $script:RouterV4BackgroundRunspace) { return }

    $script:RouterV4BackgroundInFlight = $true
    $script:RouterV4RefreshGeneration = [int]$script:RouterV4RefreshGeneration + 1
    $script:RouterV4BackgroundGeneration = [int]$script:RouterV4RefreshGeneration
    $port = [int]$feature.Port
    $timeout = [int]$script:RouterV4HttpTimeoutMs
    $limit = [int]$script:RouterV4RequestLimit

    $ps = $null
    try {
        $ps = [powershell]::Create()
        $ps.Runspace = $script:RouterV4BackgroundRunspace
        [void]$ps.AddCommand("Invoke-RouterV4StatusWorker")
        [void]$ps.AddParameter("Port", $port)
        [void]$ps.AddParameter("TimeoutMs", $timeout)
        [void]$ps.AddParameter("Limit", $limit)
        $handle = $ps.BeginInvoke()
    }
    catch {
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        $script:RouterV4BackgroundInFlight = $false
        return
    }
    $script:RouterV4BackgroundPowerShell = $ps
    $script:RouterV4BackgroundHandle = $handle
}

function Complete-RouterV4BackgroundRefresh {
    # Runs on the UI thread. The network work already finished in the
    # background runspace, so EndInvoke on a completed handle returns
    # immediately and never waits on HTTP.
    if ($script:RouterV4Closing) { return }
    if (-not $script:RouterV4BackgroundInFlight) { return }
    $ps = $script:RouterV4BackgroundPowerShell
    $handle = $script:RouterV4BackgroundHandle
    if ($null -eq $ps -or $null -eq $handle) { return }
    if (-not $handle.IsCompleted) { return }

    $generation = [int]$script:RouterV4BackgroundGeneration
    $networkResult = $null
    $errorOccurred = $false
    try {
        $results = $ps.EndInvoke($handle)
        if ($null -ne $results -and $results.Count -gt 0) { $networkResult = $results[0] }
    }
    catch {
        $errorOccurred = $true
    }
    finally {
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        $script:RouterV4BackgroundPowerShell = $null
        $script:RouterV4BackgroundHandle = $null
        $script:RouterV4BackgroundGeneration = 0
        $script:RouterV4BackgroundInFlight = $false
    }

    if ($script:RouterV4Closing -or $errorOccurred -or $null -eq $networkResult) { return }
    # A stale generation (including one invalidated by a mutation commit) must
    # never overwrite a newer refresh result.
    if (-not (Test-RouterV4SnapshotGenerationCurrent $generation)) { return }

    $script:RouterV4LastControlPlane = $networkResult
    $script:RouterV4LastRefreshUtc = (Get-Date).ToUniversalTime()
    Apply-RouterV4SnapshotToUi (Get-RouterV4SnapshotCore)
}

# --- Generation-aware mutations ------------------------------------------
function Invalidate-RouterV4RefreshGeneration {
    $script:RouterV4RefreshGeneration = [int]$script:RouterV4RefreshGeneration + 1
}

function Start-RouterV4Mutation([string]$Path, [string]$Body, [string]$Operation, [string]$Method = "PUT") {
    if ($script:RouterV4Closing -or $script:RouterV4MutationInFlight) { return $false }
    $feature = Get-RouterV4FeatureState
    if ($feature.Invalid) { return $false }
    if (-not (Test-RouterV4LoopbackTarget $feature.Host $feature.Port)) { return $false }
    if (-not (Get-RouterV4TokenPresent)) { return $false }
    Initialize-RouterV4BackgroundEngine
    if ($null -eq $script:RouterV4MutationRunspace) { return $false }

    $script:RouterV4MutationInFlight = $true
    $script:RouterV4MutationOperation = $Operation
    $port = [int]$feature.Port
    $timeout = [int]$script:RouterV4HttpTimeoutMs

    $ps = $null
    try {
        $ps = [powershell]::Create()
        $ps.Runspace = $script:RouterV4MutationRunspace
        [void]$ps.AddCommand("Invoke-RouterV4MutationWorker")
        [void]$ps.AddParameter("Port", $port)
        [void]$ps.AddParameter("TimeoutMs", $timeout)
        [void]$ps.AddParameter("Path", $Path)
        [void]$ps.AddParameter("Body", $Body)
        [void]$ps.AddParameter("Operation", $Operation)
        [void]$ps.AddParameter("Method", $Method)
        $handle = $ps.BeginInvoke()
    }
    catch {
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        $script:RouterV4MutationInFlight = $false
        $script:RouterV4MutationOperation = ""
        return $false
    }
    $script:RouterV4MutationPowerShell = $ps
    $script:RouterV4MutationHandle = $handle
    if ($null -ne $script:RouterV4MutationTimer) { $script:RouterV4MutationTimer.Start() }
    return $true
}

function Complete-RouterV4Mutation {
    if ($script:RouterV4Closing) { return }
    if (-not $script:RouterV4MutationInFlight) { return }
    $ps = $script:RouterV4MutationPowerShell
    $handle = $script:RouterV4MutationHandle
    if ($null -eq $ps -or $null -eq $handle) { return }
    if (-not $handle.IsCompleted) { return }

    $operation = [string]$script:RouterV4MutationOperation
    $result = $null
    $errorOccurred = $false
    try {
        $results = $ps.EndInvoke($handle)
        if ($null -ne $results -and $results.Count -gt 0) { $result = $results[0] }
    }
    catch {
        $errorOccurred = $true
    }
    finally {
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        $script:RouterV4MutationPowerShell = $null
        $script:RouterV4MutationHandle = $null
        $script:RouterV4MutationInFlight = $false
        $script:RouterV4MutationOperation = ""
        if ($null -ne $script:RouterV4MutationTimer) { $script:RouterV4MutationTimer.Stop() }
    }

    if ($script:RouterV4Closing) { return }
    if ($errorOccurred -or $null -eq $result) {
        Show-RouterV4Error "ROUTER_OPERATION_FAILED"
        Apply-RouterV4SnapshotToUi (Get-RouterV4SnapshotCore)
        return
    }

    $failureCode = [string]$result.FailureCode
    if (-not [bool]$result.Ok) {
        $uiCode = Convert-RouterV4ControlCodeToUiCode $failureCode
        $script:RouterV4MutationStatusText = (Convert-RouterV4UiErrorMessage $uiCode)
        Show-RouterV4Error $uiCode
        # A rejected mutation is never retried automatically. A generation
        # conflict only triggers a fresh read of the authoritative snapshot.
        Invalidate-RouterV4RefreshGeneration
        Start-RouterV4BackgroundRefresh
        Apply-RouterV4SnapshotToUi (Get-RouterV4SnapshotCore)
        return
    }

    # Success: adopt the server generation, invalidate stale refreshes, then
    # re-read the control plane instead of assuming local state.
    $script:RouterV4LastKnownGeneration = [string]$result.ConfigGeneration
    if ($operation -eq "feature") {
        $state = if ([bool]$result.LocalRouterEnabled) { "ENABLED" } else { "DISABLED" }
        $script:RouterV4MutationStatusText = ("Router 功能已更新：{0}（启用 ≠ 启动进程；生命周期控制仍不可用）" -f $state)
    }
    else {
        $script:RouterV4MutationStatusText = "策略已更新（generation 已由服务器推进）"
    }
    if ($operation -eq "thread-feature") {
        $script:RouterV4MutationStatusText = if ([bool]$result.EffectiveEnabled) {
            "会话模型切换已启用（默认关闭，需显式开启；不会自动创建任何覆盖）。"
        }
        else {
            "会话模型切换已停用：全部覆盖已清除，识别窗口已取消。"
        }
    }
    elseif ($operation -eq "thread-selection") {
        $script:RouterV4MutationStatusText = "已提交切换：状态 " + [string]$result.SelectionState + "（PENDING 将在该会话下一条普通 turn 变为 ACTIVE；Codex 请求模型与推理强度不受影响）。"
    }
    elseif ($operation -eq "thread-selection-clear") {
        $script:RouterV4MutationStatusText = "已恢复该会话的 Codex 请求模型（状态 " + [string]$result.SelectionState + "）。"
    }
    elseif ($operation -eq "thread-selection-clear-all") {
        $script:RouterV4MutationStatusText = "已清除全部会话模型覆盖，并取消所有识别窗口。"
    }
    elseif ($operation -eq "capture-open") {
        $script:RouterV4CaptureToken = [string]$result.CaptureToken
        $script:RouterV4CaptureTerminal = "open"
        Set-RouterV4TextBlock "RouterThreadCaptureText" ("识别窗口已打开，有效期至 " + [string]$result.ExpiresAt + "。请在目标 Codex 对话中发送一条普通消息。")
        $script:RouterV4MutationStatusText = "识别窗口已打开。"
        if (-not [string]::IsNullOrWhiteSpace($script:RouterV4CaptureToken)) {
            [void](Start-RouterV4CapturePoll $script:RouterV4CaptureToken)
        }
    }
    elseif ($operation -eq "capture-cancel") {
        $script:RouterV4CaptureToken = ""
        $script:RouterV4CaptureTerminal = "cancelled"
        Set-RouterV4TextBlock "RouterThreadCaptureText" "识别窗口已取消。"
        $script:RouterV4MutationStatusText = "识别窗口已取消。"
    }

    Invalidate-RouterV4RefreshGeneration
    Start-RouterV4BackgroundRefresh
    Apply-RouterV4SnapshotToUi (Get-RouterV4SnapshotCore)
}

function Invoke-RouterV4FeatureMutation([bool]$Enabled) {
    $snapshot = Get-RouterV4SnapshotCore
    if (-not $snapshot.ControlPlaneStatusOk -or -not [bool]$snapshot.FeatureMutationAvailable) {
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$snapshot.ConfigGeneration)) {
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
        return
    }
    $body = [ordered]@{
        schema_version = 1
        expected_generation = [string]$snapshot.ConfigGeneration
        enabled = $Enabled
    } | ConvertTo-Json -Depth 4 -Compress
    $script:RouterV4MutationStatusText = if ($Enabled) { "正在启用 Router 功能…" } else { "正在停用 Router 功能…" }
    if (-not (Start-RouterV4Mutation $script:RouterV4FeaturePath $body "feature")) {
        $script:RouterV4MutationStatusText = ""
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
    }
}

function Invoke-RouterV4PolicyMutation([string]$Kind, [string]$PolicyId, $BodyValues) {
    $snapshot = Get-RouterV4SnapshotCore
    if (-not $snapshot.ControlPlaneStatusOk -or -not [bool]$snapshot.PolicyMutationAvailable) {
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$snapshot.ConfigGeneration) -or [string]::IsNullOrWhiteSpace($PolicyId)) {
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
        return
    }
    # Exactly one typed body kind per request, with the expected generation.
    $request = [ordered]@{
        schema_version = 1
        expected_generation = [string]$snapshot.ConfigGeneration
        policy_id = $PolicyId
    }
    $request[$Kind] = $BodyValues
    $body = $request | ConvertTo-Json -Depth 6 -Compress
    $script:RouterV4MutationStatusText = "正在保存策略…"
    if (-not (Start-RouterV4Mutation $script:RouterV4PolicyPath $body "policy")) {
        $script:RouterV4MutationStatusText = ""
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
    }
}

# --- UI binding -----------------------------------------------------------
function Set-RouterV4TextBlock([string]$Name, [string]$Text) {
    $control = Get-Variable -Name $Name -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $control -and $control -is [System.Windows.Controls.TextBlock]) {
        $control.Text = $Text
    }
}

function Set-RouterV4TextBoxText([string]$Name, [string]$Text) {
    $control = Get-Variable -Name $Name -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $control -and $control -is [System.Windows.Controls.TextBox]) {
        $control.Text = $Text
    }
}

function Set-RouterV4ControlEnabled([string]$Name, [bool]$Enabled) {
    $control = Get-Variable -Name $Name -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $control -and $null -ne $control.PSObject.Properties["IsEnabled"]) {
        $control.IsEnabled = $Enabled
    }
}

function Update-RouterV4Badge([string]$BadgeName, [string]$TextName, [string]$Value, [string]$Color) {
    $badge = Get-Variable -Name $BadgeName -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $badge -and $badge -is [System.Windows.Controls.TextBlock]) {
        $badge.Text = $Value
        $badge.Foreground = (Get-ColorBrush $Color)
    }
    $text = Get-Variable -Name $TextName -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $text -and $text -is [System.Windows.Controls.TextBlock]) {
        $text.Text = $Value
        $text.Foreground = (Get-ColorBrush $Color)
    }
}

function Get-RouterV4SelectedPolicy($Snapshot) {
    $policies = @($Snapshot.Policies)
    if ($policies.Count -eq 0) { return $null }
    $combo = Get-Variable -Name "RouterPolicyCombo" -ValueOnly -ErrorAction SilentlyContinue
    $selected = ""
    if ($null -ne $combo -and $combo -is [System.Windows.Controls.ComboBox]) {
        $selected = [string]$combo.SelectedItem
    }
    if (-not [string]::IsNullOrWhiteSpace($selected)) {
        foreach ($policy in $policies) {
            if ([string]$policy.PolicyId -eq $selected) { return $policy }
        }
    }
    return $policies[0]
}

function Get-RouterV4EffectiveRetry($Policy) {
    if ($null -ne $Policy.ConfiguredRetry) { return $Policy.ConfiguredRetry }
    return $Policy.EffectiveRetry
}

function Get-RouterV4EffectiveTimeout($Policy) {
    if ($null -ne $Policy.ConfiguredTimeout) { return $Policy.ConfiguredTimeout }
    return $Policy.EffectiveTimeout
}

function Get-RouterV4EffectiveFailover($Policy) {
    if ($null -ne $Policy.ConfiguredFailover) { return $Policy.ConfiguredFailover }
    return $Policy.EffectiveFailover
}

function Update-RouterV4PolicyEditor($Snapshot) {
    $combo = Get-Variable -Name "RouterPolicyCombo" -ValueOnly -ErrorAction SilentlyContinue
    $policies = @($Snapshot.Policies)
    if ($null -ne $combo -and $combo -is [System.Windows.Controls.ComboBox]) {
        $ids = @($policies | ForEach-Object { [string]$_.PolicyId })
        if ((@($combo.ItemsSource) -join "|") -ne ($ids -join "|")) {
            $combo.ItemsSource = $ids
            if ($ids.Count -gt 0) { $combo.SelectedIndex = 0 }
        }
    }

    $policy = Get-RouterV4SelectedPolicy $Snapshot
    $editable = ([bool]$Snapshot.PolicyMutationAvailable -and -not [bool]$Snapshot.MutationInFlight)
    $key = if ($null -eq $policy) { "" } else { ([string]$policy.PolicyId + "|" + [string]$Snapshot.ConfigGeneration) }
    if ($key -ne $script:RouterV4PolicyEditorKey) {
        $script:RouterV4PolicyEditorKey = $key
        if ($null -ne $policy) {
            # Initial editor values come from the real configured/effective
            # snapshot; PowerShell never defines its own policy defaults.
            $retry = Get-RouterV4EffectiveRetry $policy
            $timeout = Get-RouterV4EffectiveTimeout $policy
            $failover = Get-RouterV4EffectiveFailover $policy
            Set-RouterV4TextBoxText "RouterPolicyRetryAttemptsBox" (Format-RouterV4Count $retry.MaxAttempts)
            Set-RouterV4TextBoxText "RouterPolicyTimeoutTotalBox" (Format-RouterV4Count $timeout.TotalTimeoutMs)
            $check = Get-Variable -Name "RouterPolicyFailoverProviderCheck" -ValueOnly -ErrorAction SilentlyContinue
            if ($null -ne $check -and $null -ne $failover) { $check.IsChecked = [bool]$failover.AllowSameModelAlternateProvider }
        }
    }

    Set-RouterV4ControlEnabled "RouterPolicyRetrySaveButton" $editable
    Set-RouterV4ControlEnabled "RouterPolicyTimeoutSaveButton" $editable
    Set-RouterV4ControlEnabled "RouterPolicyFailoverSaveButton" $editable

    if ($null -eq $policy) {
        Set-RouterV4TextBlock "RouterPolicyText" "Policy：控制面未提供可读策略快照。"
        return
    }

    $retryEffective = Get-RouterV4EffectiveRetry $policy
    $timeoutEffective = Get-RouterV4EffectiveTimeout $policy
    $failoverEffective = Get-RouterV4EffectiveFailover $policy
    $retryConfigured = if ($null -ne $policy.ConfiguredRetry) { "max_attempts=" + (Format-RouterV4Count $policy.ConfiguredRetry.MaxAttempts) } else { "null" }
    $timeoutConfigured = if ($null -ne $policy.ConfiguredTimeout) { "total_ms=" + (Format-RouterV4Count $policy.ConfiguredTimeout.TotalTimeoutMs) } else { "null" }
    $failoverConfigured = if ($null -ne $policy.ConfiguredFailover) { "set" } else { "null" }
    $retryText = "Retry：configured " + $retryConfigured + " · effective max_attempts=" + (Format-RouterV4Count $retryEffective.MaxAttempts) + "（" + [string]$policy.EffectiveRetrySource + "）"
    $timeoutText = "Timeout：configured " + $timeoutConfigured + " · effective total_ms=" + (Format-RouterV4Count $timeoutEffective.TotalTimeoutMs) + "（" + [string]$policy.EffectiveTimeoutSource + "）"
    $failoverText = "Failover：configured " + $failoverConfigured + " · effective same-model alternate provider=" + ([string][bool]$failoverEffective.AllowSameModelAlternateProvider) + "（" + [string]$policy.EffectiveFailoverSource + "）"
    Set-RouterV4TextBlock "RouterPolicyText" (@($retryText, $timeoutText, $failoverText) -join "`n")
}

function Update-RouterV4RecentList($Snapshot) {
    $list = Get-Variable -Name "RouterRecentList" -ValueOnly -ErrorAction SilentlyContinue
    $items = @()
    foreach ($record in @($Snapshot.RecentItems)) {
        $requestId = [string]$record.RequestId
        if ($requestId.Length -gt 8) { $requestId = $requestId.Substring(0, 8) }
        $route = [string]$record.ModelRouteId
        if ([string]::IsNullOrWhiteSpace($route)) { $route = [string]$record.RouteId }
        $items += [pscustomobject]@{
            Time = [string]$record.Time
            RequestId = $requestId
            TerminalState = [string]$record.TerminalState
            Provider = [string]$record.ProviderId
            Route = $route
            DurationMs = if ($null -eq $record.DurationMs) { "未知" } else { ([string][long]$record.DurationMs + " ms") }
            Attempts = if ($null -eq $record.AttemptCount) { "未知" } else { ([string][int]$record.AttemptCount) }
            Stream = if ([bool]$record.Stream) { "stream" } else { "non-stream" }
            UsagePresent = if ([bool]$record.UsagePresent) { "usage" } else { "no-usage" }
            ErrorCode = [string]$record.ErrorCode
        }
    }
    $script:RouterV4RecentItems.Clear()
    foreach ($item in $items) { $script:RouterV4RecentItems.Add($item) | Out-Null }
    if ($null -ne $list) { $list.ItemsSource = $script:RouterV4RecentItems }
}

function Apply-RouterV4SnapshotToUi($Snapshot) {
    if (-not (Get-RouterV4UiFeatureEnabled)) { return }
    $script:RouterV4LastSnapshot = $Snapshot

    $featureText = if ($Snapshot.ControlPlaneStatusOk) {
        if ([bool]$Snapshot.RuntimeFeatureEnabled) { "ENABLED" } else { "DISABLED" }
    }
    else {
        "UNKNOWN"
    }
    $featureColor = if ($Snapshot.ControlPlaneStatusOk -and [bool]$Snapshot.RuntimeFeatureEnabled) { "#2DD4A3" } else { "#7C8BA5" }
    Update-RouterV4Badge "RouterFeatureBadge" "RouterFeatureText" $featureText $featureColor

    $lifecycle = if ($Snapshot.ControlPlaneStatusOk) { [string]$Snapshot.RuntimeLifecycle } elseif ($Snapshot.ControlPlaneReachable) { "UNKNOWN" } else { "UNREACHABLE" }
    Update-RouterV4Badge "RouterRuntimeBadge" "RouterRuntimeText" $lifecycle (Get-RouterV4LabelColor $lifecycle)

    Set-RouterV4TextBlock "RouterOverallText" ("Overall: {0}" -f $Snapshot.Overall)
    Set-RouterV4TextBlock "RouterConfiguredText" ("Configured Feature：{0} · Runtime Reachable：{1} · Runtime Lifecycle：{2} · Runtime Ready：{3}" -f
        $(if ($Snapshot.ConfiguredFeatureEnabled) { "ENABLED" } else { "DISABLED" }),
        $(if ($Snapshot.ControlPlaneReachable) { "YES" } else { "NO" }),
        $(if ($Snapshot.ControlPlaneStatusOk) { [string]$Snapshot.RuntimeLifecycle } else { "UNKNOWN" }),
        $(if ($Snapshot.ControlPlaneStatusOk -and [bool]$Snapshot.RuntimeReady) { "YES" } else { "NO" }))
    Set-RouterV4TextBlock "RouterInFlightText" ("In-flight：{0} · Config generation：{1}" -f
        (Format-RouterV4Count $Snapshot.InFlightCount),
        $(if ([string]::IsNullOrWhiteSpace([string]$Snapshot.ConfigGeneration)) { "未知" } else { ([string]$Snapshot.ConfigGeneration).Substring(0, 12) }))

    if ($Snapshot.ControlPlaneStatusOk -and $Snapshot.HealthAvailable) {
        Set-RouterV4TextBlock "RouterHealthText" ("Health：available · routes {0}（healthy {1} / degraded {2} / unhealthy {3} / unknown {4}）· {5}" -f
            (Format-RouterV4Count $Snapshot.HealthRouteCount),
            (Format-RouterV4Count $Snapshot.HealthHealthyCount),
            (Format-RouterV4Count $Snapshot.HealthDegradedCount),
            (Format-RouterV4Count $Snapshot.HealthUnhealthyCount),
            (Format-RouterV4Count $Snapshot.HealthUnknownCount),
            $(if ([string]::IsNullOrWhiteSpace([string]$Snapshot.HealthGeneratedAt)) { "generated_at 未知" } else { [string]$Snapshot.HealthGeneratedAt }))
    }
    elseif ($Snapshot.ControlPlaneStatusOk) {
        $reason = if ([string]::IsNullOrWhiteSpace([string]$Snapshot.HealthReasonCode)) { $script:RouterV4HealthNotComposedCode } else { [string]$Snapshot.HealthReasonCode }
        Set-RouterV4TextBlock "RouterHealthText" ("Health：unavailable（{0}）" -f $reason)
    }
    else {
        Set-RouterV4TextBlock "RouterHealthText" "Health：未知（控制面状态不可用）"
    }

    if ($Snapshot.ControlPlaneStatusOk -and $Snapshot.UsageOk) {
        $degradedNote = if ([bool]$Snapshot.UsageDegraded) { " · 读取降级：" + ((@($Snapshot.UsageDegradationCodes) -join ",")) } else { "" }
        Set-RouterV4TextBlock "RouterUsageText" ("用量：records {0} / capacity {1} · known {2} / unknown {3} · input {4} · output {5}{6}" -f
            (Format-RouterV4Count $Snapshot.UsageRecordCount),
            (Format-RouterV4Count $Snapshot.UsageCapacity),
            (Format-RouterV4Count $Snapshot.UsageKnownCount),
            (Format-RouterV4Count $Snapshot.UsageUnknownCount),
            (Format-RouterV4TokenTotal $Snapshot.UsageInputTokensTotal),
            (Format-RouterV4TokenTotal $Snapshot.UsageOutputTokensTotal),
            $degradedNote)
    }
    elseif ($Snapshot.ControlPlaneStatusOk) {
        Set-RouterV4TextBlock "RouterUsageText" "用量：控制面未提供（metering unavailable）"
    }
    else {
        Set-RouterV4TextBlock "RouterUsageText" "用量：未知（控制面状态不可用）"
    }

    $costLine = Format-RouterV4CurrencyCosts $Snapshot.UsageCurrencies
    $unknownCostNote = if ($null -eq $Snapshot.UsageUnknownCostCount -or [int]$Snapshot.UsageUnknownCostCount -eq 0) {
        ""
    }
    else {
        ("（另有 {0} 条价格未知，未计入，≠ $0.00）" -f [int]$Snapshot.UsageUnknownCostCount)
    }
    Set-RouterV4TextBlock "RouterCostText" ("成本（估算，非账单）：{0} · known {1} / unknown {2}{3}" -f
        $costLine,
        (Format-RouterV4Count $Snapshot.UsageKnownCostCount),
        (Format-RouterV4Count $Snapshot.UsageUnknownCostCount),
        $unknownCostNote)

    Update-RouterV4PolicyEditor $Snapshot

    $breakerLine = if ($Snapshot.ControlPlaneStatusOk) {
        "Circuit Breaker：effective {0} · configured null · mutation_available {1} · 当前不可配置（{2}）" -f
            $(if ([string]::IsNullOrWhiteSpace([string]$Snapshot.BreakerEffectiveState)) { "unknown" } else { [string]$Snapshot.BreakerEffectiveState }),
            ([string][bool]$Snapshot.BreakerMutationAvailable),
            $(if ([string]::IsNullOrWhiteSpace([string]$Snapshot.BreakerReasonCode)) { $script:RouterV4BreakerGapCode } else { [string]$Snapshot.BreakerReasonCode })
    }
    else {
        "Circuit Breaker：effective unknown · mutation_available false · 当前不可配置（{0}）" -f $script:RouterV4BreakerGapCode
    }
    Set-RouterV4TextBlock "RouterCircuitBreakerText" $breakerLine
    Set-RouterV4TextBlock "RouterCrossModelText" ("Cross-model fallback：{0}（无任何启用控件）" -f $script:RouterV4CrossModelFallbackHardOff)

    if ($Snapshot.ControlPlaneStatusOk -and $Snapshot.RecentOk) {
        Set-RouterV4TextBlock "RouterRecentText" ("最近请求（安全元数据，最多 {0} 条）：records {1}{2}" -f
            $script:RouterV4RequestLimit,
            (Format-RouterV4Count $Snapshot.RecentRecordCount),
            $(if ([bool]$Snapshot.RecentDegraded) { " · 读取降级（仅返回可用安全记录）" } else { "" }))
    }
    elseif ($Snapshot.ControlPlaneStatusOk) {
        Set-RouterV4TextBlock "RouterRecentText" "最近请求：控制面未提供（recent log unavailable）"
    }
    else {
        Set-RouterV4TextBlock "RouterRecentText" "最近请求：未知（控制面状态不可用）"
    }
    Update-RouterV4RecentList $Snapshot

    $mutationAvailable = ([bool]$Snapshot.FeatureMutationAvailable -and [bool]$Snapshot.ControlPlaneStatusOk -and -not [bool]$Snapshot.MutationInFlight)
    Set-RouterV4ControlEnabled "RouterFeatureEnableButton" $mutationAvailable
    Set-RouterV4ControlEnabled "RouterFeatureDisableButton" $mutationAvailable
    $featureMutationText = if ($Snapshot.ControlPlaneStatusOk) {
        if ([bool]$Snapshot.FeatureMutationAvailable) { "Feature mutation：available（启用 ≠ 启动进程）" } else { "Feature mutation：unavailable（需要运行中的本机 Host）" }
    }
    else {
        "Feature mutation：unavailable（控制面状态不可用）"
    }
    Set-RouterV4TextBlock "RouterFeatureMutationText" $featureMutationText
    $lifecycleReason = if ([string]::IsNullOrWhiteSpace([string]$Snapshot.LifecycleReasonCode)) { $script:RouterV4LifecycleControlGapCode } else { [string]$Snapshot.LifecycleReasonCode }
    Set-RouterV4TextBlock "RouterLifecycleText" ("Lifecycle 控制（Start / Stop / Restart）：unavailable（{0}）" -f $lifecycleReason)
    Set-RouterV4TextBlock "RouterMutationStatusText" ([string]$Snapshot.MutationStatusText)

    Set-RouterV4TextBlock "CliModeText" ("CLI: {0}" -f $Snapshot.CliMode)
    Set-RouterV4TextBlock "CliModelText" ("模型：{0}" -f $(if ($Snapshot.CliModel) { $Snapshot.CliModel } else { "—" }))
    Set-RouterV4TextBlock "CliEffortText" ("推理：{0}" -f $(if ($Snapshot.CliEffort) { $Snapshot.CliEffort } else { "—" }))
    Set-RouterV4TextBlock "CliReadinessText" ("CLI Router 就绪：{0}" -f $(if ($Snapshot.CliMode -eq "ROUTER" -and $Snapshot.ControlPlaneStatusOk -and [bool]$Snapshot.RuntimeReady) { "READY" } else { "—" }))
    Set-RouterV4TextBlock "DesktopModeText" ("Desktop: {0}" -f $Snapshot.DesktopMode)
    Set-RouterV4TextBlock "DesktopModelText" ("模型：{0}" -f $(if ($Snapshot.DesktopModel) { $Snapshot.DesktopModel } else { "—" }))
    Set-RouterV4TextBlock "DesktopEffortText" ("推理：{0}" -f $(if ($Snapshot.DesktopEffort) { $Snapshot.DesktopEffort } else { "—" }))
    Set-RouterV4TextBlock "DesktopReadinessText" ("需重启并新建对话：{0}" -f $(if ($Snapshot.DesktopMode -eq "ROUTER") { "YES" } else { "NO" }))

    $warningText = (@($Snapshot.Errors) + @($Snapshot.Warnings)) -join " · "
    Set-RouterV4TextBlock "RouterWarningsText" $warningText

    Set-RouterV4ControlEnabled "RouterDesktopRestoreButton" ($Snapshot.DesktopRouteKind -eq "router")
    Set-RouterV4ControlEnabled "RouterCliEnableButton" (-not $Snapshot.FeatureInvalid)
    Set-RouterV4ControlEnabled "RouterCliDisableButton" (-not $Snapshot.FeatureInvalid)
}

function Refresh-RouterV4UI {
    if ($script:RouterV4Closing) { return }
    if (-not (Get-RouterV4UiFeatureEnabled)) { return }
    if ($script:RouterV4MutationInFlight) { Complete-RouterV4Mutation }
    if ($script:RouterV4BackgroundInFlight) { Complete-RouterV4BackgroundRefresh }
    if ($script:RouterV4CapturePollInFlight) { Complete-RouterV4CapturePoll }
    if ($script:RouterV4ThreadInFlight) { Complete-RouterV4ThreadRefresh }
    Apply-RouterV4SnapshotToUi (Get-RouterV4SnapshotCore)
    Start-RouterV4BackgroundRefresh
    Start-RouterV4ThreadRefresh
}

# --- HS-1B thread-scoped model controls -----------------------------------
# Dedicated runspaces keep thread reads and capture polling from ever
# contending with the status refresh or a user-initiated mutation.
$script:RouterV4ThreadsPath = "/v1/router/control-plane/threads"
$script:RouterV4ThreadFeaturePath = "/v1/router/control-plane/thread-selection-feature"
$script:RouterV4ThreadRunspace = $null
$script:RouterV4ThreadInFlight = $false
$script:RouterV4ThreadPowerShell = $null
$script:RouterV4ThreadHandle = $null
$script:RouterV4ThreadSnapshot = $null
$script:RouterV4CaptureRunspace = $null
$script:RouterV4CapturePollInFlight = $false
$script:RouterV4CapturePollPowerShell = $null
$script:RouterV4CapturePollHandle = $null
$script:RouterV4CaptureToken = ""
$script:RouterV4CaptureTerminal = ""
$script:RouterV4ThreadItems = [System.Collections.ObjectModel.ObservableCollection[object]]::new()

function Initialize-RouterV4ThreadEngine {
    if ($null -eq $script:RouterV4ThreadRunspace) {
        $script:RouterV4ThreadRunspace = New-RouterV4EngineRunspace
    }
    if ($null -eq $script:RouterV4CaptureRunspace) {
        $script:RouterV4CaptureRunspace = New-RouterV4EngineRunspace
    }
}

function Start-RouterV4ThreadRefresh {
    if ($script:RouterV4Closing -or $script:RouterV4ThreadInFlight) { return }
    $feature = Get-RouterV4FeatureState
    if ($feature.Invalid) { return }
    if (-not (Test-RouterV4LoopbackTarget $feature.Host $feature.Port)) { return }
    if (-not (Get-RouterV4TokenPresent)) { return }
    Initialize-RouterV4ThreadEngine
    if ($null -eq $script:RouterV4ThreadRunspace) { return }

    $script:RouterV4ThreadInFlight = $true
    $ps = $null
    try {
        $ps = [powershell]::Create()
        $ps.Runspace = $script:RouterV4ThreadRunspace
        [void]$ps.AddCommand("Invoke-RouterV4ThreadReadWorker")
        [void]$ps.AddParameter("Port", [int]$feature.Port)
        [void]$ps.AddParameter("TimeoutMs", [int]$script:RouterV4HttpTimeoutMs)
        [void]$ps.AddParameter("Limit", [int]$script:RouterV4RequestLimit)
        $handle = $ps.BeginInvoke()
    }
    catch {
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        $script:RouterV4ThreadInFlight = $false
        return
    }
    $script:RouterV4ThreadPowerShell = $ps
    $script:RouterV4ThreadHandle = $handle
}

function Complete-RouterV4ThreadRefresh {
    # Runs on the UI thread and only harvests an already-completed handle.
    if ($script:RouterV4Closing) { return }
    if (-not $script:RouterV4ThreadInFlight) { return }
    $ps = $script:RouterV4ThreadPowerShell
    $handle = $script:RouterV4ThreadHandle
    if ($null -eq $ps -or $null -eq $handle) { return }
    if (-not $handle.IsCompleted) { return }

    $result = $null
    $errorOccurred = $false
    try {
        $results = $ps.EndInvoke($handle)
        if ($null -ne $results -and $results.Count -gt 0) { $result = $results[0] }
    }
    catch {
        $errorOccurred = $true
    }
    finally {
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        $script:RouterV4ThreadPowerShell = $null
        $script:RouterV4ThreadHandle = $null
        $script:RouterV4ThreadInFlight = $false
    }

    if ($errorOccurred -or $null -eq $result) { return }
    $script:RouterV4ThreadSnapshot = $result
    Update-RouterV4ThreadSection
}

function Start-RouterV4CapturePoll([string]$CaptureToken) {
    if ($script:RouterV4Closing -or $script:RouterV4CapturePollInFlight) { return $false }
    if ([string]::IsNullOrWhiteSpace($CaptureToken)) { return $false }
    $feature = Get-RouterV4FeatureState
    if ($feature.Invalid) { return $false }
    if (-not (Test-RouterV4LoopbackTarget $feature.Host $feature.Port)) { return $false }
    if (-not (Get-RouterV4TokenPresent)) { return $false }
    Initialize-RouterV4ThreadEngine
    if ($null -eq $script:RouterV4CaptureRunspace) { return $false }

    $script:RouterV4CapturePollInFlight = $true
    $ps = $null
    try {
        $ps = [powershell]::Create()
        $ps.Runspace = $script:RouterV4CaptureRunspace
        [void]$ps.AddCommand("Invoke-RouterV4CapturePollWorker")
        [void]$ps.AddParameter("Port", [int]$feature.Port)
        [void]$ps.AddParameter("TimeoutMs", [int]$script:RouterV4HttpTimeoutMs)
        [void]$ps.AddParameter("CaptureToken", $CaptureToken)
        [void]$ps.AddParameter("MaxAttempts", 30)
        [void]$ps.AddParameter("IntervalMs", 2000)
        $handle = $ps.BeginInvoke()
    }
    catch {
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        $script:RouterV4CapturePollInFlight = $false
        return $false
    }
    $script:RouterV4CapturePollPowerShell = $ps
    $script:RouterV4CapturePollHandle = $handle
    return $true
}

function Complete-RouterV4CapturePoll {
    if ($script:RouterV4Closing) { return }
    if (-not $script:RouterV4CapturePollInFlight) { return }
    $ps = $script:RouterV4CapturePollPowerShell
    $handle = $script:RouterV4CapturePollHandle
    if ($null -eq $ps -or $null -eq $handle) { return }
    if (-not $handle.IsCompleted) { return }

    $result = $null
    $errorOccurred = $false
    try {
        $results = $ps.EndInvoke($handle)
        if ($null -ne $results -and $results.Count -gt 0) { $result = $results[0] }
    }
    catch {
        $errorOccurred = $true
    }
    finally {
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        $script:RouterV4CapturePollPowerShell = $null
        $script:RouterV4CapturePollHandle = $null
        $script:RouterV4CapturePollInFlight = $false
    }

    if ($errorOccurred -or $null -eq $result) {
        $script:RouterV4CaptureTerminal = "failed"
        Set-RouterV4TextBlock "RouterThreadCaptureText" (Convert-RouterV4UiErrorMessage "ROUTER_OPERATION_FAILED")
        return
    }

    $script:RouterV4CaptureTerminal = [string]$result.Terminal
    if ([bool]$result.Ok -and [string]$result.Terminal -eq "captured") {
        $ref = [string]$result.ThreadRef
        Set-RouterV4TextBlock "RouterThreadCaptureText" ("已识别会话 " + $ref + "。请选择目标模型并确认切换。")
        Start-RouterV4ThreadRefresh
        return
    }

    $message = Convert-RouterV4UiErrorMessage (Convert-RouterV4ControlCodeToUiCode ([string]$result.FailureCode))
    Set-RouterV4TextBlock "RouterThreadCaptureText" ("识别窗口已结束（" + [string]$result.Terminal + "）：" + $message)
}

function Update-RouterV4ThreadSection {
    if (-not (Get-RouterV4UiFeatureEnabled)) { return }
    $snapshot = $script:RouterV4ThreadSnapshot
    $reachable = $false
    $configured = $false
    $effective = $false
    $generation = ""
    $failure = ""
    $threads = @()
    if ($null -ne $snapshot) {
        $reachable = [bool]$snapshot.Ok
        $failure = [string]$snapshot.FailureCode
        $configured = [bool]$snapshot.ConfiguredEnabled
        $effective = [bool]$snapshot.EffectiveEnabled
        $generation = [string]$snapshot.ConfigGeneration
        $threads = @($snapshot.Threads)
    }

    if (-not $reachable) {
        $reason = if ([string]::IsNullOrWhiteSpace($failure)) { "CONTROL_PLANE_UNAVAILABLE" } else { Convert-RouterV4ControlCodeToUiCode $failure }
        Set-RouterV4TextBlock "RouterThreadCapabilityText" ("会话模型切换：不可用（" + $reason + "）")
        Set-RouterV4TextBlock "RouterThreadReadyText" "就绪状态：控制面不可读，会话控件已停用。"
    }
    else {
        $capability = if ($effective) { "已启用" } elseif ($configured) { "已配置但未生效" } else { "已停用" }
        Set-RouterV4TextBlock "RouterThreadCapabilityText" ("会话模型切换：" + $capability + "（configured=" + [string]$configured + " / effective=" + [string]$effective + "）")
        if ($effective) {
            Set-RouterV4TextBlock "RouterThreadReadyText" "就绪状态：可读取、可识别、可切换；切换会在该会话下一条普通 turn 生效。"
        }
        else {
            Set-RouterV4TextBlock "RouterThreadReadyText" "就绪状态：会话模型切换未启用（默认关闭），请先启用后再使用识别与切换。"
        }
    }

    $rows = @()
    foreach ($thread in $threads) {
        $selected = [string]$thread.SelectedModel
        if ([string]::IsNullOrWhiteSpace($selected)) { $selected = [string]$thread.RequestedModel }
        $rows += [pscustomobject]@{
            ThreadRef = [string]$thread.ThreadRef
            LastSeen = [string]$thread.LastSeen
            ClientId = [string]$thread.ClientId
            RequestedModel = [string]$thread.RequestedModel
            EffectiveModel = $selected
            SelectionState = if ([string]::IsNullOrWhiteSpace([string]$thread.SelectionState)) { "none" } else { [string]$thread.SelectionState }
            SelectionGeneration = if ($null -eq $thread.SelectionGeneration) { "-" } else { [string][long]$thread.SelectionGeneration }
            LastFailureCode = [string]$thread.LastFailureCode
        }
    }
    $script:RouterV4ThreadItems.Clear()
    foreach ($row in $rows) { $script:RouterV4ThreadItems.Add($row) | Out-Null }

    $list = Get-Variable -Name "RouterThreadList" -ValueOnly -ErrorAction SilentlyContinue
    $selectedRef = ""
    if ($null -ne $list) {
        if ($null -eq $list.ItemsSource) { $list.ItemsSource = $script:RouterV4ThreadItems }
        if ($null -ne $list.SelectedItem) { $selectedRef = [string]$list.SelectedItem.ThreadRef }
        if ([string]::IsNullOrWhiteSpace($selectedRef) -and $rows.Count -gt 0) {
            $list.SelectedIndex = 0
            $selectedRef = [string]$rows[0].ThreadRef
        }
    }

    $dualTruth = "Codex 请求模型：—    Router 当前生效模型：—"
    foreach ($row in $rows) {
        if ($row.ThreadRef -eq $selectedRef) {
            $dualTruth = "Codex 请求模型：" + [string]$row.RequestedModel + "    Router 当前生效模型：" + [string]$row.EffectiveModel + "（" + [string]$row.SelectionState + "）"
        }
    }
    Set-RouterV4TextBlock "RouterThreadDualTruthText" $dualTruth

    $ready = $reachable -and $configured -and $effective
    Set-RouterV4ControlEnabled "RouterThreadFeatureEnableButton" (-not $configured)
    Set-RouterV4ControlEnabled "RouterThreadFeatureDisableButton" $configured
    Set-RouterV4ControlEnabled "RouterThreadSwitchButton" $ready
    Set-RouterV4ControlEnabled "RouterThreadRestoreButton" $ready
    Set-RouterV4ControlEnabled "RouterThreadCaptureButton" $ready
    Set-RouterV4ControlEnabled "RouterThreadCaptureCancelButton" ($ready -and -not [string]::IsNullOrWhiteSpace($script:RouterV4CaptureToken))
    Set-RouterV4ControlEnabled "RouterThreadClearAllButton" $ready
    Set-RouterV4ControlEnabled "RouterThreadModelCombo" $ready
    $script:RouterV4ThreadConfigGeneration = $generation
}

function Get-RouterV4SelectedThreadRef {
    $list = Get-Variable -Name "RouterThreadList" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $list -or $null -eq $list.SelectedItem) { return "" }
    return [string]$list.SelectedItem.ThreadRef
}

function Invoke-RouterV4ThreadSelectionMutation([string]$ThreadRef, [string]$Model) {
    $snapshot = $script:RouterV4ThreadSnapshot
    if ($null -eq $snapshot -or -not [bool]$snapshot.Ok -or -not [bool]$snapshot.EffectiveEnabled) {
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
        return
    }
    $current = $null
    foreach ($thread in @($snapshot.Threads)) {
        if ([string]$thread.ThreadRef -eq $ThreadRef) { $current = $thread }
    }
    if ($null -eq $current) { Show-RouterV4Error "CONTROL_THREAD_NOT_OBSERVED"; return }
    if ([string]::IsNullOrWhiteSpace($Model)) { Show-RouterV4Error "MODEL_NOT_AVAILABLE"; return }

    # Per-thread selection generation CAS - never the config generation.
    $expected = [long]$current.SelectionGeneration
    if ($expected -lt 0) { $expected = 0 }
    $body = [ordered]@{
        schema_version = 1
        expected_generation = $expected
        model = $Model
    } | ConvertTo-Json -Depth 4 -Compress
    $path = $script:RouterV4ThreadsPath + "/" + $ThreadRef + "/selection"
    $script:RouterV4MutationStatusText = "正在切换该会话模型…"
    if (-not (Start-RouterV4Mutation $path $body "thread-selection")) {
        $script:RouterV4MutationStatusText = ""
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
    }
}

function Invoke-RouterV4ThreadSelectionClear([string]$ThreadRef) {
    $snapshot = $script:RouterV4ThreadSnapshot
    if ($null -eq $snapshot -or -not [bool]$snapshot.Ok -or -not [bool]$snapshot.EffectiveEnabled) {
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
        return
    }
    $current = $null
    foreach ($thread in @($snapshot.Threads)) {
        if ([string]$thread.ThreadRef -eq $ThreadRef) { $current = $thread }
    }
    if ($null -eq $current) { Show-RouterV4Error "CONTROL_THREAD_NOT_OBSERVED"; return }

    $expected = [long]$current.SelectionGeneration
    if ($expected -lt 0) { $expected = 0 }
    $body = [ordered]@{
        schema_version = 1
        expected_generation = $expected
    } | ConvertTo-Json -Depth 4 -Compress
    $path = $script:RouterV4ThreadsPath + "/" + $ThreadRef + "/selection"
    $script:RouterV4MutationStatusText = "正在恢复该会话的 Codex 请求模型…"
    if (-not (Start-RouterV4Mutation $path $body "thread-selection-clear" -Method "DELETE")) {
        $script:RouterV4MutationStatusText = ""
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
    }
}

function Invoke-RouterV4ThreadSelectionsClearAll {
    $snapshot = $script:RouterV4ThreadSnapshot
    if ($null -eq $snapshot -or -not [bool]$snapshot.Ok -or -not [bool]$snapshot.EffectiveEnabled) {
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
        return
    }
    $body = [ordered]@{
        schema_version = 1
        confirm = $true
    } | ConvertTo-Json -Depth 4 -Compress
    $script:RouterV4MutationStatusText = "正在清除全部会话模型覆盖…"
    if (-not (Start-RouterV4Mutation ($script:RouterV4ThreadsPath + "/selections") $body "thread-selection-clear-all" -Method "DELETE")) {
        $script:RouterV4MutationStatusText = ""
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
    }
}

function Invoke-RouterV4ThreadFeatureMutation([bool]$Enabled) {
    $snapshot = $script:RouterV4ThreadSnapshot
    if ($null -eq $snapshot -or -not [bool]$snapshot.Ok -or [string]::IsNullOrWhiteSpace([string]$snapshot.ConfigGeneration)) {
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
        return
    }
    # Global config generation CAS - never the per-thread selection generation.
    $body = [ordered]@{
        schema_version = 1
        expected_generation = [string]$snapshot.ConfigGeneration
        enabled = $Enabled
    } | ConvertTo-Json -Depth 4 -Compress
    $script:RouterV4MutationStatusText = if ($Enabled) { "正在启用会话模型切换…" } else { "正在停用会话模型切换…" }
    if (-not (Start-RouterV4Mutation $script:RouterV4ThreadFeaturePath $body "thread-feature")) {
        $script:RouterV4MutationStatusText = ""
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
    }
}

function Invoke-RouterV4CaptureOpen {
    $snapshot = $script:RouterV4ThreadSnapshot
    if ($null -eq $snapshot -or -not [bool]$snapshot.Ok -or -not [bool]$snapshot.EffectiveEnabled) {
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
        return
    }
    $body = [ordered]@{ schema_version = 1 } | ConvertTo-Json -Depth 3 -Compress
    $script:RouterV4CaptureToken = ""
    $script:RouterV4CaptureTerminal = ""
    Set-RouterV4TextBlock "RouterThreadCaptureText" "识别窗口：正在创建…请在目标 Codex 对话中发送一条普通消息。"
    $script:RouterV4MutationStatusText = "正在创建识别窗口…"
    if (-not (Start-RouterV4Mutation ($script:RouterV4ThreadsPath + "/capture") $body "capture-open" -Method "POST")) {
        $script:RouterV4MutationStatusText = ""
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
    }
}

function Invoke-RouterV4CaptureCancel {
    if ([string]::IsNullOrWhiteSpace($script:RouterV4CaptureToken)) {
        Set-RouterV4TextBlock "RouterThreadCaptureText" "识别窗口：当前没有可取消的窗口。"
        return
    }
    $path = $script:RouterV4ThreadsPath + "/capture/" + $script:RouterV4CaptureToken
    $script:RouterV4MutationStatusText = "正在取消识别窗口…"
    if (-not (Start-RouterV4Mutation $path "" "capture-cancel" -Method "DELETE")) {
        $script:RouterV4MutationStatusText = ""
        Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"
    }
}

# --- UI initialization ----------------------------------------------------
function Initialize-RouterV4Ui {
    if (-not (Get-RouterV4UiFeatureEnabled)) {
        $nav = Get-Variable -Name "NavRouter" -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $nav) { $nav.Visibility = [System.Windows.Visibility]::Collapsed }
        return
    }
    Initialize-RouterV4BackgroundEngine

    $modelCombo = Get-Variable -Name "RouterModelCombo" -ValueOnly -ErrorAction SilentlyContinue
    $effortCombo = Get-Variable -Name "RouterEffortCombo" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $modelCombo) {
        try {
            $models = @(Get-RouterCliAvailableModels)
            $modelCombo.ItemsSource = @($models | ForEach-Object { $_.model_id })
            if ($modelCombo.Items.Count -gt 0) { $modelCombo.SelectedIndex = 0 }
        }
        catch {
            $modelCombo.ItemsSource = @()
        }
    }
    if ($null -ne $effortCombo) { $effortCombo.ItemsSource = @() }

    $refresh = Get-Variable -Name "RouterRefreshButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $refresh) {
        $refresh.Add_Click({ Refresh-RouterV4UI })
    }
    $modelComboCtl = Get-Variable -Name "RouterModelCombo" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $modelComboCtl) {
        $modelComboCtl.Add_SelectionChanged({
            $model = [string]$RouterModelCombo.SelectedItem
            $efforts = @()
            if (-not [string]::IsNullOrWhiteSpace($model)) {
                try {
                    $candidate = Test-RouterModelCandidate $model
                    if ($candidate.Valid -and $null -ne $candidate.CatalogRecord) {
                        $efforts = @($candidate.CatalogRecord.performance_levels)
                    }
                }
                catch { $efforts = @() }
            }
            $RouterEffortCombo.ItemsSource = $efforts
            if ($efforts.Count -gt 0) { $RouterEffortCombo.SelectedIndex = 0 }
        })
    }

    # HS-1B thread-scoped model controls. The thread model combo reuses the SAME
    # approved Router model source as RouterModelCombo; it never reads the model
    # catalog again and never invents a second model list.
    $threadModelCombo = Get-Variable -Name "RouterThreadModelCombo" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $threadModelCombo) {
        try {
            $threadModels = @(Get-RouterCliAvailableModels)
            $threadModelCombo.ItemsSource = @($threadModels | ForEach-Object { $_.model_id })
            if ($threadModelCombo.Items.Count -gt 0) { $threadModelCombo.SelectedIndex = 0 }
        }
        catch {
            $threadModelCombo.ItemsSource = @()
        }
    }

    $threadListCtl = Get-Variable -Name "RouterThreadList" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $threadListCtl) {
        $threadListCtl.Add_SelectionChanged({ Update-RouterV4ThreadSection })
    }

    $threadSwitch = Get-Variable -Name "RouterThreadSwitchButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $threadSwitch) {
        $threadSwitch.Add_Click({
            $ref = Get-RouterV4SelectedThreadRef
            $model = [string]$RouterThreadModelCombo.SelectedItem
            if ([string]::IsNullOrWhiteSpace($ref)) { Show-RouterV4Error "THREAD_NOT_OBSERVED"; return }
            if ([string]::IsNullOrWhiteSpace($model)) { Show-RouterV4Error "MODEL_NOT_AVAILABLE"; return }
            try { Invoke-RouterV4ThreadSelectionMutation $ref $model }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }

    $threadRestore = Get-Variable -Name "RouterThreadRestoreButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $threadRestore) {
        $threadRestore.Add_Click({
            $ref = Get-RouterV4SelectedThreadRef
            if ([string]::IsNullOrWhiteSpace($ref)) { Show-RouterV4Error "THREAD_NOT_OBSERVED"; return }
            try { Invoke-RouterV4ThreadSelectionClear $ref }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }

    $threadClearAll = Get-Variable -Name "RouterThreadClearAllButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $threadClearAll) {
        $threadClearAll.Add_Click({
            $confirm = [System.Windows.MessageBox]::Show(
                "清除全部会话模型覆盖？`n`n· 只清除会话级 Router 覆盖（PENDING / ACTIVE）并取消识别窗口`n· 不修改 local_router.enabled，不改 CLI / Desktop 路由，不改 Provider 配置`n· 不停止或重启 Router 进程`n`n继续？",
                "清除全部会话模型覆盖", "YesNo", "Warning")
            if ($confirm -ne "Yes") { return }
            try { Invoke-RouterV4ThreadSelectionsClearAll }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }

    $threadCapture = Get-Variable -Name "RouterThreadCaptureButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $threadCapture) {
        $threadCapture.Add_Click({
            try { Invoke-RouterV4CaptureOpen }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }

    $threadCaptureCancel = Get-Variable -Name "RouterThreadCaptureCancelButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $threadCaptureCancel) {
        $threadCaptureCancel.Add_Click({
            try { Invoke-RouterV4CaptureCancel }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }

    $threadFeatureEnable = Get-Variable -Name "RouterThreadFeatureEnableButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $threadFeatureEnable) {
        $threadFeatureEnable.Add_Click({
            $confirm = [System.Windows.MessageBox]::Show(
                "启用会话模型切换？`n`n· 只授予能力：不创建任何会话覆盖、不识别会话、不改变任何请求模型`n· 该能力默认关闭；携带 config generation CAS`n· 停用时才会清除覆盖并取消识别窗口`n`n继续？",
                "启用会话模型切换", "YesNo", "Warning")
            if ($confirm -ne "Yes") { return }
            try { Invoke-RouterV4ThreadFeatureMutation $true }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }

    $threadFeatureDisable = Get-Variable -Name "RouterThreadFeatureDisableButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $threadFeatureDisable) {
        $threadFeatureDisable.Add_Click({
            $confirm = [System.Windows.MessageBox]::Show(
                "停用会话模型切换？`n`n· 清除全部 PENDING / ACTIVE 覆盖并取消识别窗口`n· 不修改 local_router.enabled，不改 CLI / Desktop 路由，不移除密钥`n· 携带 config generation CAS`n`n继续？",
                "停用会话模型切换", "YesNo", "Warning")
            if ($confirm -ne "Yes") { return }
            try { Invoke-RouterV4ThreadFeatureMutation $false }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }

    $featureEnable = Get-Variable -Name "RouterFeatureEnableButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $featureEnable) {
        $featureEnable.Add_Click({
            $confirm = [System.Windows.MessageBox]::Show(
                "启用 Router 功能？`n`n· 只修改 Router 的请求准入开关（local_router.enabled）`n· 不会启动、停止或重启 Router 进程（LIFECYCLE_CONTROL_GAP）`n· 携带 expected_generation 的 generation CAS`n`n继续？",
                "启用 Router 功能", "YesNo", "Warning"
            )
            if ($confirm -ne "Yes") { return }
            try { Invoke-RouterV4FeatureMutation $true }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }
    $featureDisable = Get-Variable -Name "RouterFeatureDisableButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $featureDisable) {
        $featureDisable.Add_Click({
            $confirm = [System.Windows.MessageBox]::Show(
                "停用 Router 功能？`n`n· 只修改 Router 的请求准入开关（local_router.enabled）`n· 不会停止 Router 进程，控制面仍可读取并可再次启用`n· 携带 expected_generation 的 generation CAS`n`n继续？",
                "停用 Router 功能", "YesNo", "Warning"
            )
            if ($confirm -ne "Yes") { return }
            try { Invoke-RouterV4FeatureMutation $false }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }

    $policyCombo = Get-Variable -Name "RouterPolicyCombo" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $policyCombo) {
        $policyCombo.Add_SelectionChanged({
            $script:RouterV4PolicyEditorKey = ""
            Apply-RouterV4SnapshotToUi (Get-RouterV4SnapshotCore)
        })
    }

    $retrySave = Get-Variable -Name "RouterPolicyRetrySaveButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $retrySave) {
        $retrySave.Add_Click({
            $policy = Get-RouterV4SelectedPolicy (Get-RouterV4SnapshotCore)
            if ($null -eq $policy) { Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"; return }
            $attempts = 0
            if (-not [int]::TryParse(([string]$RouterPolicyRetryAttemptsBox.Text).Trim(), [ref]$attempts) -or $attempts -lt 1 -or $attempts -gt 10) {
                Show-RouterV4Error "POLICY_INVALID"
                return
            }
            $retry = Get-RouterV4EffectiveRetry $policy
            $body = [ordered]@{
                schema_version = 1
                max_attempts = $attempts
                base_delay_ms = [long]$retry.BaseDelayMs
                max_delay_ms = [long]$retry.MaxDelayMs
                jitter = [decimal]$retry.Jitter
                respect_retry_after = [bool]$retry.RespectRetryAfter
                max_retry_after_ms = [long]$retry.MaxRetryAfterMs
            }
            try { Invoke-RouterV4PolicyMutation "retry" ([string]$policy.PolicyId) $body }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }

    $timeoutSave = Get-Variable -Name "RouterPolicyTimeoutSaveButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $timeoutSave) {
        $timeoutSave.Add_Click({
            $policy = Get-RouterV4SelectedPolicy (Get-RouterV4SnapshotCore)
            if ($null -eq $policy) { Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"; return }
            $total = 0L
            if (-not [long]::TryParse(([string]$RouterPolicyTimeoutTotalBox.Text).Trim(), [ref]$total) -or $total -lt 1) {
                Show-RouterV4Error "POLICY_INVALID"
                return
            }
            $effective = Get-RouterV4EffectiveTimeout $policy
            $body = [ordered]@{
                schema_version = 1
                connect_timeout_ms = [long]$effective.ConnectTimeoutMs
                first_byte_timeout_ms = [long]$effective.FirstByteTimeoutMs
                idle_timeout_ms = [long]$effective.IdleTimeoutMs
                attempt_timeout_ms = [long]$effective.AttemptTimeoutMs
                total_timeout_ms = $total
            }
            try { Invoke-RouterV4PolicyMutation "timeout" ([string]$policy.PolicyId) $body }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }

    $failoverSave = Get-Variable -Name "RouterPolicyFailoverSaveButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $failoverSave) {
        $failoverSave.Add_Click({
            $policy = Get-RouterV4SelectedPolicy (Get-RouterV4SnapshotCore)
            if ($null -eq $policy) { Show-RouterV4Error "CONTROL_PLANE_UNAVAILABLE"; return }
            $effective = Get-RouterV4EffectiveFailover $policy
            $body = [ordered]@{
                schema_version = 1
                allow_same_model_alternate_endpoint = [bool]$effective.AllowSameModelAlternateEndpoint
                allow_same_model_alternate_provider = [bool]$RouterPolicyFailoverProviderCheck.IsChecked
            }
            try { Invoke-RouterV4PolicyMutation "failover" ([string]$policy.PolicyId) $body }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }

    $cliEnable = Get-Variable -Name "RouterCliEnableButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $cliEnable) {
        $cliEnable.Add_Click({
            $model = [string]$RouterModelCombo.SelectedItem
            $effort = [string]$RouterEffortCombo.SelectedItem
            if ([string]::IsNullOrWhiteSpace($model)) {
                Show-RouterV4Error "MODEL_NOT_AVAILABLE"; return
            }
            $confirm = [System.Windows.MessageBox]::Show(
                "启用 Codex CLI Router？`n`n· Codex CLI 将通过 Local Router`n· Direct Mode 可恢复`n· Codex 只接受 CODEX_LOCAL_ROUTER_TOKEN`n· 不会自动调用付费 Provider`n· 这不是 Router 功能开关（Feature Enable）`n`n继续？",
                "启用 CLI Router", "YesNo", "Warning"
            )
            if ($confirm -ne "Yes") { return }
            try {
                $dispatch = Invoke-RouterV4CliAction "Enable" $model $effort ""
                Start-RouterV4Subprocess $dispatch
                Refresh-RouterV4UI
            }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }
    $cliDisable = Get-Variable -Name "RouterCliDisableButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $cliDisable) {
        $cliDisable.Add_Click({
            $confirm = [System.Windows.MessageBox]::Show("关闭 CLI Router 并恢复 CLI Direct？", "关闭 CLI Router", "YesNo", "Warning")
            if ($confirm -ne "Yes") { return }
            try {
                $dispatch = Invoke-RouterV4CliAction "Disable" "" "" ""
                Start-RouterV4Subprocess $dispatch
                Refresh-RouterV4UI
            }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }
    $cliLaunch = Get-Variable -Name "RouterCliLaunchButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $cliLaunch) {
        $cliLaunch.Add_Click({
            $model = [string]$RouterModelCombo.SelectedItem
            $effort = [string]$RouterEffortCombo.SelectedItem
            $project = ([string]$WorkspaceCombo.Text).Trim()
            if ([string]::IsNullOrWhiteSpace($model)) { Show-RouterV4Error "MODEL_NOT_AVAILABLE"; return }
            try {
                $dispatch = Invoke-RouterV4CliAction "Launch" $model $effort $project
                Start-RouterV4Subprocess $dispatch -Interactive
            }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }
    $desktopActivate = Get-Variable -Name "RouterDesktopActivateButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $desktopActivate) {
        $desktopActivate.Add_Click({
            $model = [string]$RouterModelCombo.SelectedItem
            $effort = [string]$RouterEffortCombo.SelectedItem
            if ([string]::IsNullOrWhiteSpace($model)) { Show-RouterV4Error "MODEL_NOT_AVAILABLE"; return }
            $confirm = [System.Windows.MessageBox]::Show(
                "Desktop → Local Router？`n`n· 将修改 Desktop 默认路由`n· 不修改 Desktop 程序本体`n· 只连接 Local Router`n· 必须彻底退出并重新打开 Desktop`n· 必须新建 conversation，当前 thread 不会热切换`n· 可以一键恢复`n`n继续？",
                "Desktop → Local Router", "YesNo", "Warning"
            )
            if ($confirm -ne "Yes") { return }
            try {
                $dispatch = Invoke-RouterV4DesktopAction "activate" $model $effort
                Start-RouterV4Subprocess $dispatch
                Refresh-RouterV4UI
            }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }
    $desktopRestore = Get-Variable -Name "RouterDesktopRestoreButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $desktopRestore) {
        $desktopRestore.Add_Click({
            $confirm = [System.Windows.MessageBox]::Show("恢复 Desktop Router（回到激活前状态）？恢复后需重启并新建对话。", "恢复 Desktop", "YesNo", "Warning")
            if ($confirm -ne "Yes") { return }
            try {
                $dispatch = Invoke-RouterV4DesktopAction "restore" "" ""
                Start-RouterV4Subprocess $dispatch
                Refresh-RouterV4UI
            }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }
    $restoreDirect = Get-Variable -Name "RouterRestoreDirectButton" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $restoreDirect) {
        $restoreDirect.Add_Click({
            $confirm = [System.Windows.MessageBox]::Show(
                "安全恢复 Direct？`n`n只恢复 Router 相关状态；不会删除用户 secret，也不会把本来就是 Manager Direct 的 Desktop 误恢复成 ChatGPT。",
                "安全恢复 Direct", "YesNo", "Warning"
            )
            if ($confirm -ne "Yes") { return }
            try {
                $plan = @(Get-RouterV4SafeRestorePlan)
                if ("restore_desktop" -in $plan) {
                    Start-RouterV4Subprocess (Invoke-RouterV4DesktopAction "restore" "" "")
                }
                if ("disable_cli" -in $plan) {
                    Start-RouterV4Subprocess (Invoke-RouterV4CliAction "Disable" "" "" "")
                }
                Refresh-RouterV4UI
            }
            catch { Show-RouterV4Error (Convert-RouterV4UiError $_) }
        })
    }

    $script:RouterV4MutationTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:RouterV4MutationTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:RouterV4MutationTimer.Add_Tick({ Complete-RouterV4Mutation })

    $script:RouterV4RefreshTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:RouterV4RefreshTimer.Interval = [TimeSpan]::FromSeconds(4)
    $script:RouterV4RefreshTimer.Add_Tick({
        if ($MainTabs.SelectedIndex -eq 5) { Refresh-RouterV4UI }
    })
    $script:RouterV4RefreshTimer.Start()

    $window.Add_Closing({
        $script:RouterV4Closing = $true
        if ($null -ne $script:RouterV4RefreshTimer) { $script:RouterV4RefreshTimer.Stop() }
        if ($null -ne $script:RouterV4MutationTimer) { $script:RouterV4MutationTimer.Stop() }
        foreach ($pending in @($script:RouterV4BackgroundPowerShell, $script:RouterV4MutationPowerShell)) {
            if ($null -ne $pending) {
                try { $pending.Stop() } catch { }
                try { $pending.Dispose() } catch { }
            }
        }
        $pendingRunspace = $script:RouterV4BackgroundRunspace
        if ($null -ne $pendingRunspace) { try { $pendingRunspace.Dispose() } catch { } }
        $pendingMutationRunspace = $script:RouterV4MutationRunspace
        if ($null -ne $pendingMutationRunspace) { try { $pendingMutationRunspace.Dispose() } catch { } }
        $script:RouterV4BackgroundPowerShell = $null
        $script:RouterV4MutationPowerShell = $null
        $script:RouterV4BackgroundRunspace = $null
        $script:RouterV4MutationRunspace = $null
        $script:RouterV4BackgroundHandle = $null
        $script:RouterV4MutationHandle = $null
        $script:RouterV4BackgroundGeneration = 0
        $script:RouterV4BackgroundInFlight = $false
        $script:RouterV4MutationInFlight = $false
    })

    Refresh-RouterV4UI
}

$routerV4Window = Get-Variable -Name "window" -Scope Script -ErrorAction SilentlyContinue
if ($null -ne $routerV4Window -and $null -ne $routerV4Window.Value) {
    Initialize-RouterV4Ui
}
