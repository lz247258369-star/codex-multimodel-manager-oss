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

function Read-SourceText([string]$RelativePath) {
    $path = Join-Path $RepositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Fail "Missing expected file: $RelativePath"
        return ""
    }

    Pass "Expected file exists: $RelativePath"
    return (Get-Content -Raw -LiteralPath $path)
}

function Require-Contains([string]$Name, [string]$Text, [string]$Needle, [string]$Description) {
    if ($Text.Contains($Needle)) {
        Pass "$Name contains '$Needle' ($Description)"
    }
    else {
        Fail "$Name must contain '$Needle': $Description"
    }
}

function Require-NotContain([string]$Name, [string]$Text, [string]$Needle, [string]$Description) {
    if ($Text.Contains($Needle)) {
        Fail "$Name contains forbidden marker '$Needle': $Description"
    }
    else {
        Pass "$Name has no '$Needle' ($Description)"
    }
}

Write-Host "Repository: $RepositoryRoot" -ForegroundColor Cyan

$executionSource = Read-SourceText "local-router/src/Router.Execution/RouterExecutionResponsesService.cs"
$defaultsSource = Read-SourceText "local-router/src/Router.Execution/RouterExecutionDefaults.cs"
$factorySource = Read-SourceText "local-router/src/Router.Execution/RouterExecutionServiceFactory.cs"
$endpointSource = Read-SourceText "local-router/src/Router.Execution/RouterExecutionEndpoints.cs"
$policySource = Read-SourceText "local-router/src/Router.Execution/RouterExecutionPolicySet.cs"
$hostSource = Read-SourceText "local-router/src/Router.Host/RouterHostBootstrap.cs"
$metadataSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ResponsesExecutionMetadata.cs"
$serviceContractSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/IResponsesService.cs"
$terminalStreamSource = Read-SourceText "local-router/src/Router.Execution/TerminalAwareEventStream.cs"
$terminalTestSource = Read-SourceText "local-router/tests/Router.Execution.Tests/TerminalAwareEventStreamTests.cs"
$endpointContractTestSource = Read-SourceText "local-router/tests/Router.Execution.Tests/RouterExecutionEndpointContractTests.cs"
$openRouterCapabilitiesSource = Read-SourceText "local-router/src/Router.ProviderAdapters.OpenRouter/OpenRouterCapabilities.cs"
$lifecycleTestSource = Read-SourceText "local-router/tests/Router.Execution.Tests/RouterExecutionLifecycleTests.cs"

$executionAll = $executionSource + $defaultsSource + $factorySource + $endpointSource + $policySource

# 1. Production execution service exists and is the ingress boundary implementation.
Require-Contains "Execution service" $executionSource "class RouterExecutionResponsesService" "production execution service must exist"
Require-Contains "Execution boundary" $executionSource "IResponsesService" "production service must implement IResponsesService"
Require-Contains "Execution result boundary" $serviceContractSource "ResponsesExecutionMetadata" "service result must carry authoritative metadata"

# 2. Host production default path composes the real service; Fake is test-only.
Require-Contains "Host production composition" $hostSource "RouterExecutionServiceFactory.Create" "Host enabled path must build the production execution service"
Require-Contains "Host test override" $hostSource "IResponsesService? responsesService" "Host may keep a test-only injectable service override"
Require-NotContain "Host fake production" $hostSource "new FakeResponsesService(" "Host production source must never construct the fake service"

$srcFakeUsage = @()
$srcCsFiles = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/src") -Recurse -File -Filter "*.cs"
foreach ($file in $srcCsFiles) {
    $text = Get-Content -Raw -LiteralPath $file.FullName
    if ($text.Contains("new FakeResponsesService(")) {
        $srcFakeUsage += $file.FullName
    }
}
if ($srcFakeUsage.Count -eq 0) {
    Pass "FakeResponsesService is never constructed inside local-router/src"
}
else {
    Fail "FakeResponsesService is constructed in production source: $($srcFakeUsage -join ', ')"
}

# 3. Real execution stack components are actually composed.
Require-Contains "Registry snapshot composition" $factorySource "RegistrySnapshotBuilder.Build" "registry snapshot must be built for production execution"
Require-Contains "RouteResolver composition" $factorySource "new RouteResolver()" "real LR-4 RouteResolver must be invoked"
Require-Contains "Provider adapter registry" $defaultsSource "CreateProviderAdapterRegistry" "ProviderAdapterRegistry must be registered"
Require-Contains "Provider harness" $executionSource "new ProviderAdapterHarness" "ProviderAdapterHarness must execute adapters"
Require-Contains "UpstreamHttp composition" $factorySource "new HttpUpstreamTransport" "UpstreamHttp must own the transport"
Require-Contains "Protocol gate" $executionSource "MapRequest" "Responses protocol compatibility gate must run before provider attempts"
Require-Contains "Passive health seam" $executionSource "PassiveOutcomeObservation" "real provider outcomes must feed passive health"
Require-Contains "Retry engine seam" $executionSource "RetryPolicyEngine.Decide" "LR-11 retry engine must drive bounded pre-output retries"
Require-Contains "Failover engine seam" $executionSource "FailoverPolicyEngine.Decide" "LR-11 failover engine must gate alternate routes"
Require-Contains "Breaker seam" $executionSource "CircuitBreakerKey" "LR-11 breaker admission must gate attempts"

# 3b. Current dynamic passive health is fed to every resolver call.
Require-Contains "Health bridge projection" $executionSource "ProjectRoutes" "passive-health route projection must be consumed by resolution"
Require-Contains "Resolver health input" $executionSource "RouteHealthSnapshot" "route resolution must accept the current dynamic health snapshot"
Require-NotContain "Resolver health null" $executionSource "health: null" "production resolution must never pass a null health snapshot when passive health is composed"
Require-Contains "Health feedback behavior test" $lifecycleTestSource "Passive_health_feedback_moves_unhealthy_route_out_of_resolution" "real requests must prove unhealthy routes leave eligibility"

# 3c. Streaming executions are finalized only at their terminal boundary.
Require-Contains "Terminal stream boundary" $executionSource "ExecuteTerminalStreamAsync" "streamed outcomes must be finalized by the terminal-aware boundary"
Require-Contains "Terminal wrapper" $terminalStreamSource "class TerminalAwareEventStream" "the terminal-aware stream wrapper must exist"
Require-Contains "Terminal once guard" $terminalStreamSource "TryMark" "terminal observations must commit exactly once"
Require-NotContain "Terminal stream retry" $terminalStreamSource "RetryPolicyEngine" "stream wrapper must never retry"
Require-NotContain "Terminal stream failover" $terminalStreamSource "FailoverPolicyEngine" "stream wrapper must never fail over"
Require-Contains "Mapped event current" $terminalStreamSource "_current = canonical" "the mapped canonical event must be stored as the enumerator current"
Require-Contains "Mapped event current test" $terminalTestSource "Current_returns_the_protocol_mapped_event_never_the_raw_inner_event" "consumers must observe mapped events, never raw inner events"
Require-Contains "Mapping failure once test" $terminalTestSource "Mapping_failure_is_a_safe_terminal_failure_observed_exactly_once" "protocol mapping failure must remain a terminal failure observed exactly once"
Require-Contains "Terminal success test" $lifecycleTestSource "Streaming_completion_records_terminal_success_exactly_once" "stream success must be observed exactly once"
Require-Contains "Terminal failure test" $lifecycleTestSource "Streaming_terminal_error_records_failure_without_retry_or_failover" "stream terminal failure must update health/breaker without retry or failover"
Require-Contains "Stream cancel test" $lifecycleTestSource "Streaming_client_cancellation_never_pollutes_passive_health" "client cancellation must never degrade passive health"
Require-Contains "Mapping failure test" $lifecycleTestSource "Protocol_mapping_failure_normalizes_safe_terminal_failure" "protocol mapping failure must be a normalized terminal failure"

# 3d. Retry delay is bounded by the deadline remaining after the attempt.
Require-Contains "Post-attempt deadline recompute" $executionSource "actualRemaining" "retry decisions must use the deadline remaining after the attempt"
Require-Contains "Deadline bounded test" $lifecycleTestSource "Retry_delay_never_exceeds_the_deadline_that_remains_after_the_attempt" "no retry sleep may exceed the total deadline"

# 3e. OpenRouter production endpoint resolution is a closed composition
# contract: no test override, no outbound request, exact production URI.
Require-Contains "OpenRouter production composition test" $lifecycleTestSource "OpenRouter_production_endpoint_resolves_without_override_to_exact_responses_uri" "production OpenRouter resolution must compose the exact production URI without a test override"

# 3f. Enabled failover paths execute and report the final route/provider.
Require-Contains "Alternate endpoint test" $lifecycleTestSource "Same_model_alternate_endpoint_executes_when_policy_allows" "same-model alternate endpoint failover must be executed when policy allows"
Require-Contains "Alternate provider test" $lifecycleTestSource "Same_model_alternate_provider_executes_only_when_explicitly_approved" "same-model alternate provider failover must require explicit approval"

# 3g. Terminal metadata timing is explicit and authoritative.
Require-Contains "Terminal metadata timing test" $lifecycleTestSource "Streamed_execution_metadata_completed_at_is_terminal_not_stream_return" "CompletedAt must be the stream terminal instant"
Require-Contains "ExecutionStartedAt contract" $metadataSource "ExecutionStartedAt" "execution start must be an explicit versioned field"
Require-Contains "CompletedAt nullable contract" $metadataSource "DateTimeOffset? CompletedAt" "streamed in-flight metadata must carry CompletedAt == null until terminal"
Require-Contains "Stream identity pre-terminal test" $lifecycleTestSource "Streaming_consumer_binds_terminal_usage_to_pre_enumerated_authoritative_identity" "future metering consumers must obtain authoritative identity before enumeration"

# 3h. Four-provider production final-URI contract: endpoint + concrete adapter
# request path + UpstreamRequest.FullUri, exact, with no network.
Require-Contains "Final URI contract tests" $endpointContractTestSource "Production_base_url_plus_adapter_request_path_composes_exact_responses_uri" "base URL + adapter request path + FullUri must be contracted"
foreach ($needle in @('https://api.openai.com/v1/responses', 'https://dashscope.aliyuncs.com/compatible-mode/v1/responses', 'https://openrouter.ai/api/v1/responses', 'https://api.xiaomimimo.com/v1/responses')) {
    Require-Contains "Final URI contract" $endpointContractTestSource $needle "exact $needle must be pinned"
}

# 4. Authoritative execution identity.
foreach ($field in @('ProviderId', 'RouteId', 'ModelRouteId', 'CatalogModelId', 'UpstreamModelId')) {
    Require-Contains "Execution metadata" $metadataSource $field "authoritative identity field '$field'"
}
Require-NotContain "Metadata guessing" $executionSource "startswith" "execution must never guess provider from model names"

# 5. Exactly the four existing providers are explicitly registered.
foreach ($marker in @('OpenRouterProviderAdapter', 'ModelStudioProviderAdapter', 'OpenAIProviderAdapter', 'MiMoProviderAdapter')) {
    Require-Contains "Provider registration" $defaultsSource $marker "$marker must be explicitly registered"
}
Require-NotContain "chatgpt provider registration" $defaultsSource '"adapter.provider.chatgpt' "chatgpt must never be registered as a Router provider"
Require-NotContain "chatgpt OpenAI mix" $executionSource "chatgpt" "chatgpt must stay DIRECT_ONLY and never enter execution identity"

# 6. Responses-only, no Chat Completions, no /models discovery.
foreach ($needle in @('chat/completions', 'Chat Completions', '/v1/models', 'wire_api = "chat"')) {
    Require-NotContain "Execution protocol" $executionAll $needle "Responses-only protocol boundary"
    Require-NotContain "Host protocol" $hostSource $needle "Responses-only host boundary"
}

# 7. Failover and endpoint safety defaults.
Require-Contains "Failover default OFF" $policySource "FailoverPolicy.Off" "same-model failover must default OFF"
Require-Contains "Cross-model hard OFF" $policySource "hard-OFF" "cross-model fallback must remain hard OFF"
Require-Contains "Endpoint approval" $endpointSource "ApprovedProductionBaseUrls" "endpoint references must be explicitly approved"
Require-NotContain "OpenRouter base gap removed" $endpointSource "OPENROUTER_PRODUCTION_BASE_URL_GAP" "the resolved OpenRouter production base must not be re-declared as a gap"
Require-Contains "OpenRouter production base" $endpointSource "https://openrouter.ai/api/v1" "the approved mm_openrouter base URL must compose the production Responses endpoint"
Require-Contains "OpenRouter adapter path" $openRouterCapabilitiesSource "/api/v1/responses" "the OpenRouter adapter path must carry the gateway prefix"

# 8. No secrets in execution metadata or Host source.
Require-NotContain "Host auth.json" $hostSource "auth.json" "no auth.json access"
Require-NotContain "Execution auth.json" $executionAll "auth.json" "no auth.json access"
Require-NotContain "Execution env reads" $executionSource "Environment.GetEnvironmentVariable" "provider secrets must resolve through SecretResolver only"
Require-Contains "SecretResolver seam" $executionSource "ISecretResolver" "provider secrets must be resolved through the existing SecretResolver"

# 9. Test network guard and loopback-only seams.
$e2eTestSource = Read-SourceText "local-router/tests/Router.Execution.Tests/RouterExecutionE2ETests.cs"
$policyTestSource = Read-SourceText "local-router/tests/Router.Execution.Tests/RouterExecutionPolicySafetyTests.cs"
Require-Contains "E2E network guard" $e2eTestSource "LoopbackOnlyHandler" "HTTP E2E must use the loopback-only guard"
Require-Contains "Service network guard" $policyTestSource "network-guard: non-loopback target rejected" "service tests must reject non-loopback targets"
foreach ($needle in @('api.openai.com', 'openrouter.ai', 'dashscope.aliyuncs.com', 'api.xiaomimimo.com')) {
    Require-NotContain "Execution tests live hosts" ($e2eTestSource + $policyTestSource) $needle "tests must never contact a real provider host"
}

# 10. Execution composition tests are wired into the solution.
$sln = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/LocalRouter.sln")
foreach ($project in @("Router.Execution", "Router.Execution.Tests")) {
    if ($sln.Contains($project)) {
        Pass "LocalRouter.sln includes: $project"
    }
    else {
        Fail "LocalRouter.sln is missing: $project"
    }
}

# 11. Defaults stay disabled; protected roadmap state is unchanged.
$defaults = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/config/router.defaults.json") | ConvertFrom-Json
if ($defaults.local_router.enabled -eq $false -and $defaults.mode -eq "direct") {
    Pass "router.defaults.json remains disabled (mode=direct, enabled=false)"
}
else {
    Fail "router.defaults.json must keep mode=direct and local_router.enabled=false"
}

# 12. New validator is wired into the Development Gate workflow.
$workflow = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot ".github/workflows/ci.yml")
if ($workflow.Contains("tests/validate-local-router-execution-composition.ps1")) {
    Pass "Development Gate workflow runs tests/validate-local-router-execution-composition.ps1"
}
else {
    Fail "Development Gate workflow must run tests/validate-local-router-execution-composition.ps1"
}

Write-Host ""
Write-Host "Local Router production execution composition validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router production execution composition validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router production execution composition validation PASSED" -ForegroundColor Green
exit 0
