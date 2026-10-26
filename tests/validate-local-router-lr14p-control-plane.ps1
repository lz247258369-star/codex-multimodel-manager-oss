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

function Require-Contains([string]$Name, [string]$Text, [string]$Needle, [string]$Description) {
    if ($Text.Contains($Needle)) {
        Pass "$Name contains '$Needle' ($Description)"
    }
    else {
        Fail "$Name is missing '$Needle' ($Description)"
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

# 1. Versioned contract schemas.
$schemaDir = Join-Path $RepositoryRoot "local-router/schemas"
foreach ($schema in @(
    "control-plane-status.v1.schema.json",
    "control-plane-usage.v1.schema.json",
    "control-plane-recent-requests.v1.schema.json",
    "control-plane-policy.v1.schema.json",
    "control-plane-policy-mutation.v1.schema.json",
    "control-plane-policy-mutation-result.v1.schema.json",
    "control-plane-feature-mutation.v1.schema.json",
    "control-plane-feature-mutation-result.v1.schema.json"
)) {
    if (Test-Path -LiteralPath (Join-Path $schemaDir $schema)) {
        Pass "Schema exists: $schema"
    }
    else {
        Fail "Schema missing: $schema"
    }
}

$statusSchema = Get-Content -Raw -LiteralPath (Join-Path $schemaDir "router-status.v1.schema.json")
if ($statusSchema.Contains('"additionalProperties": false') -and $statusSchema.Contains('"schema_version": { "const": 1 }')) {
    Pass "v1 status schema remains fixed (additionalProperties=false, schema_version const 1)"
}
else {
    Fail "v1 status schema was changed incompatibly"
}

# 2. Endpoint registration + auth scope on every control-plane endpoint.
$ingressSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Ingress/ResponsesIngress.cs")
foreach ($path in @(
    "/v1/router/control-plane/status",
    "/v1/router/control-plane/usage",
    "/v1/router/control-plane/requests",
    "/v1/router/control-plane/policy",
    "/v1/router/control-plane/feature"
)) {
    Require-Contains "ResponsesIngress" $ingressSource $path "endpoint is registered"
}
$handlerSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Ingress/Handlers/ControlPlaneHandlers.cs")
Require-Contains "ControlPlaneHandlers" $handlerSource '"router:control-plane"' "single control-plane scope"
Require-Contains "ControlPlaneHandlers" $handlerSource 'ScopeDenied' "scope failure is normalized"
Require-NotContain "ControlPlaneHandlers" $handlerSource "ex.Message" "raw exception text is never returned"
Require-NotContain "ControlPlaneHandlers" $handlerSource "RequestPipeline.Record" "control-plane calls never pollute the durable request log"

# 3. Bounded usage read over the production store; no second metering store.
$projectionSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Ingress/ControlPlane/ControlPlaneProjections.cs")
Require-Contains "ControlPlaneProjections" $projectionSource "BuildUsagePayload" "usage projection exists"
Require-Contains "ControlPlaneProjections" $projectionSource "ReadDefaultLimit = 20" "default limit is 20"
Require-Contains "ControlPlaneProjections" $projectionSource "ReadHardLimit = 100" "hard max is 100"
Require-Contains "ControlPlaneProjections" $projectionSource "informational_estimate_not_billing" "estimate is never billing truth"
Require-Contains "ControlPlaneProjections" $projectionSource "bounded_recent_records" "scope is bounded recent"
$ingressControlDir = Join-Path $RepositoryRoot "local-router/src/Router.Ingress"
$controlSource = Get-ChildItem -LiteralPath $ingressControlDir -Recurse -File -Filter "*.cs" | Where-Object { $_.FullName -notlike "*ControlPlaneHandlers*" } | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
Require-NotContain "Router.Ingress control-plane code" $controlSource "new RequestMeteringStore(" "a second metering store must never be created"

# 4. Durable recent reader: bounded, read-only, no path input, degradation.
$logSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Observability/DurableRequestLog.cs")
Require-Contains "DurableRequestLog" $logSource "ReadRecentAsync" "safe recent reader exists"
Require-Contains "DurableRequestLog" $logSource "HardRecentMaxCount = 100" "reader hard max is 100"
Require-Contains "DurableRequestLog" $logSource "MaxRecentScanFiles" "reader scan is bounded"

# 5. Null semantics in the control-plane projection.
Require-Contains "ControlPlaneProjections" $projectionSource "HasUsage" "null/unknown usage handling exists"
Require-Contains "ControlPlaneProjections" $projectionSource "HasCost" "null/unknown cost handling exists"

# 6. Policy read/mutation: configured vs effective, CAS, cross-model hard off.
$operatorSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Configuration/LocalRouterConfigOperator.cs")
Require-Contains "LocalRouterConfigOperator" $operatorSource "ControlPlaneErrors.GenerationConflict()" "generation conflict is enforced"
Require-Contains "LocalRouterConfigOperator" $operatorSource "RouterConfigValidator.Validate(updated)" "mutation validates before write"
Require-Contains "LocalRouterConfigOperator" $operatorSource "ReplaceFile(tempPath, _userConfigPath)" "atomic replace write"
$policySourceFile = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Execution/RouterExecutionPolicySource.cs")
Require-Contains "ConfigRouterExecutionPolicySource" $policySourceFile "RouterExecutionPolicySet Resolve(" "policy projection to execution exists"
Require-Contains "ConfigRouterExecutionPolicySource" $policySourceFile "FailoverPolicy.Create" "failover maps through LR-11 factory"
$configValidatorSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Configuration/RouterConfigValidator.cs")
Require-Contains "RouterConfigValidator" $configValidatorSource "ValidatePolicyBodies" "policy bodies are validated"
$policyMutationSchema = Get-Content -Raw -LiteralPath (Join-Path $schemaDir "control-plane-policy-mutation.v1.schema.json")
Require-NotContain "policy mutation schema" $policyMutationSchema "allow_cross_model_fallback" "cross-model enable cannot be expressed"
Require-Contains "policy mutation schema" $policyMutationSchema '"oneOf"' "exactly one policy body kind"
$policyProjectionPayload = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Ingress/ControlPlane/ControlPlaneProjections.cs")
Require-Contains "policy projection payload" $policyProjectionPayload '"configured"' "configured source marker exists"
Require-Contains "policy projection payload" $policyProjectionPayload '"safe_defaults"' "safe-default source marker exists"

# 7. Feature mutation: host-independent, only enabled/mode marker changes, no Start/Stop.
Require-Contains "LocalRouterConfigOperator" $operatorSource "SetFeatureEnabledAsync" "feature operator exists"
Require-Contains "feature status code" $handlerSource "LifecycleControlGapCode" "lifecycle gap is explicit"
$statusSchemaControl = Get-Content -Raw -LiteralPath (Join-Path $schemaDir "control-plane-status.v1.schema.json")
Require-Contains "control-plane status schema" $statusSchemaControl '"start_stop_available": { "const": false }' "Start/Stop is never faked"

# 8. Same production store/log composition in E2E.
$e2eSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/tests/Router.Execution.Tests/ControlPlaneProductionE2ETests.cs")
Require-Contains "ControlPlaneProductionE2ETests" $e2eSource "ProductionCompletionObserver observer = new(metering, requestLog, clock)" "observer shares the production metering/log instances"
Require-Contains "ControlPlaneProductionE2ETests" $e2eSource "Metering = metering" "control plane reads the same metering instance"
Require-Contains "ControlPlaneProductionE2ETests" $e2eSource "RequestLog = requestLog" "control plane reads the same durable log instance"
Require-Contains "ControlPlaneProductionE2ETests" $e2eSource "CONTROL_PLANE_SECRET_SENTINEL_123" "sentinel tests exist"

# 9. LR-14P is a prerequisite, not a roadmap slice.
$prereqDoc = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "docs/LOCAL_ROUTER_LR14P_CONTROL_PLANE.md")
Require-Contains "prerequisite doc" $prereqDoc "16 / 18" "formal roadmap stays 16/18"
Require-Contains "prerequisite doc" $prereqDoc "LIFECYCLE_CONTROL_GAP = YES" "lifecycle gap is documented"
Require-Contains "prerequisite doc" $prereqDoc "LR14P_ARCHITECTURE_PREREQUISITE = NO" "no architecture rewrite was required"

# 10. Scope diff audit: protected V4/Direct/provider algorithm files untouched.
$changedFiles = @(& git -C $RepositoryRoot diff --name-only "main...HEAD" 2>$null)
$changedFiles += @(& git -C $RepositoryRoot ls-files --modified)
$changedFiles = @($changedFiles | Where-Object { $_ } | Sort-Object -Unique)
$protectedPatterns = @(
    '(?i)^installer/scripts/launch-controller-model\.ps1$',
    '(?i)^installer/scripts/visual-',
    '(?i)^installer/ui/',
    '(?i)^installer/model-catalog\.json$',
    '(?i)^local-router/src/Router\.ProviderAdapters\.',
    '(?i)^local-router/src/Router\.ProtocolAdapters\.',
    '(?i)^local-router/src/Router\.Routing/',
    '(?i)^local-router/src/Router\.Health/(PassiveHealthTracker|PassiveHealthPolicy|HealthKey|HealthSnapshot|RouteHealthProjection|PassiveOutcomeObservation).*\.cs$',
    '(?i)^local-router/src/Router\.Policies/(RetryPolicyEngine|TimeoutPolicyEngine|FailoverPolicyEngine|PolicyDecision|PolicySnapshot|CircuitBreaker|Deterministic).*\.cs$'
)
$protectedHits = @()
foreach ($file in $changedFiles) {
    foreach ($pattern in $protectedPatterns) {
        if ($file -match $pattern) {
            $protectedHits += $file
        }
    }
}
# Protected-file policy is delta-exact: LR-13/LR-14 may touch their own
# approved files only while the normalized hashes still match the reviewed
# deltas. Every other change to a protected file still fails closed.
. (Join-Path $RepositoryRoot "tests/shared/protected-file-scope.ps1")
$protectedHits = @($protectedHits | Where-Object { -not (Test-Lr13ProtectedFileChangeAuthorized $RepositoryRoot $_) })
if ($protectedHits.Count -gt 0) {
    foreach ($hit in ($protectedHits | Sort-Object -Unique)) {
        Fail "Protected file changed: $hit"
    }
}
else {
    Pass "No protected Direct/Desktop/V4/provider-algorithm files are modified"
}

# 11. Semantic hardening markers (round two).
$configSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Configuration/LocalRouterConfigOperator.cs")
Require-Contains "LocalRouterConfigOperator" $configSource "ConfigMutationGate.Acquire" "mutation lock wraps read/compare/write"
$gateSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Configuration/ConfigMutationGate.cs")
Require-Contains "ConfigMutationGate" $gateSource "MutexPrefix" "cross-process named mutex serialization"
Require-Contains "ConfigMutationGate" $gateSource "SafeHasher.Sha256Hex" "lock identity hashes the config path"

$hostSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Host/RouterHostBootstrap.cs")
Require-Contains "RouterHostBootstrap" $hostSource "CurrentRouterExecutionPolicySource(currentState)" "production execution uses the live policy source"
Require-Contains "RouterHostBootstrap" $hostSource "CurrentState = currentState" "ingress and execution share one published current state"
Require-Contains "RouterHostBootstrap" $hostSource "PassiveHealthSnapshotSource(passiveHealth" "control plane reads the production health tracker"

$featureMiddleware = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Ingress/Middleware/FeatureGateMiddleware.cs")
Require-Contains "FeatureGateMiddleware" $featureMiddleware "RouterDisabled" "live feature disable fails closed with normalized error"
$ingressHandlerSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Ingress/Handlers/ControlPlaneHandlers.cs")
Require-Contains "ControlPlaneHandlers" $ingressHandlerSource "MaxControlPlaneMutationBytes = 64 * 1024" "mutation body hard limit is 64 KiB"
Require-Contains "ControlPlaneHandlers" $ingressHandlerSource "PayloadTooLarge(" "oversized mutation body has a fixed error"

$healthSourceFile = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Health/RouterHealthSnapshotSource.cs")
Require-Contains "RouterHealthSnapshotSource" $healthSourceFile "interface IRouterHealthSnapshotSource" "read-only health snapshot seam exists"
$ingressNonControlSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Ingress") -Recurse -File -Filter "*.cs" | Where-Object { $_.FullName -notlike "*ControlPlane*" } | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
Require-NotContain "Router.Ingress non-control-plane source" $ingressNonControlSource "new PassiveHealthTracker(" "no second health tracker is created for the UI"

$projectionSourceHardened = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Ingress/ControlPlane/ControlPlaneProjections.cs")
Require-Contains "ControlPlaneProjections" $projectionSourceHardened "DimensionTotal" "partial unknown usage totals stay null"
Require-Contains "ControlPlaneProjections" $projectionSourceHardened "CircuitBreakerGapCode" "circuit-breaker gap is explicit"

$logSourceHardened = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Observability/DurableRequestLog.cs")
Require-Contains "DurableRequestLog" $logSourceHardened "newestCandidates" "recent reader keeps bounded top-K candidates"
Require-Contains "DurableRequestLog" $logSourceHardened "DescendingPathComparer" "candidate selection is bounded without full array materialization"

$usageSchema = Get-Content -Raw -LiteralPath (Join-Path $schemaDir "control-plane-usage.v1.schema.json")
Require-Contains "usage schema" $usageSchema '"input_tokens_total": { "type": ["integer", "null"]' "nullable partial totals are versioned"
$breakerSchemaText = Get-Content -Raw -LiteralPath (Join-Path $schemaDir "control-plane-policy.v1.schema.json")
Require-Contains "policy schema" $breakerSchemaText "CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP" "breaker gap is part of the contract"

$errorCodeSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Core/Errors/RouterErrorCode.cs")
foreach ($code in @('ControlPayloadTooLarge', 'ControlMutationBusy', 'RouterDisabled')) {
    Require-Contains "RouterErrorCode" $errorCodeSource $code "fixed allowlist code exists"
}

$testMarkers = @{
    "local-router/tests/Router.Core.Tests/Configuration/LocalRouterConfigOperatorTests.cs" = @(
        "Concurrent_same_generation_feature_mutations_have_exactly_one_winner",
        "Concurrent_feature_and_policy_mutations_have_exactly_one_winner",
        "Concurrent_same_generation_policy_mutations_have_exactly_one_winner",
        "Feature_and_policy_mutations_preserve_unrelated_schema_valid_fields"
    )
    "local-router/tests/Router.Execution.Tests/ControlPlaneProductionE2ETests.cs" = @(
        "Live_policy_mutation_changes_the_running_services_effective_policy_without_restart",
        "Live_feature_disable_fails_closed_and_re_enable_resumes_the_same_host",
        "Live_control_plane_reflects_real_passive_health_and_breaker_gap"
    )
    "local-router/tests/Router.Ingress.Tests/ControlPlaneEndpointsTests.cs" = @(
        "Mutation_body_with_known_oversized_content_length_is_rejected_before_operator",
        "Mutation_body_with_chunked_oversized_content_is_rejected_bounded",
        "Mutation_body_at_the_hard_limit_is_processed_normally",
        "Usage_summary_partial_unknown_dimensions_stay_null_never_zero"
    )
    "local-router/tests/Router.Observability.Tests/DurableRequestLogRecentReadTests.cs" = @(
        "Many_files_never_materialize_an_unbounded_candidate_array"
    )
}
foreach ($file in $testMarkers.Keys) {
    $testSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $file)
    foreach ($marker in $testMarkers[$file]) {
        Require-Contains (Split-Path $file -Leaf) $testSource $marker "hardening test exists"
    }
}

# 12. Commit atomicity (final blocker) and mutation availability truth.
Require-Contains "LocalRouterConfigOperator" $configSource "publicationSink?.Publish(" "runtime publish happens inside the operator mutation gate"
Require-Contains "LocalRouterConfigOperator" $configSource "ComputeGenerationAsync" "next generation is computed before the atomic commit"
Require-Contains "LocalRouterConfigOperator" $configSource "SupportsLivePublication" "live publication capability is explicit"
Require-NotContain "ControlPlaneHandlers" $ingressHandlerSource "PublishIfLive" "HTTP handler no longer manually publishes"
Require-Contains "ControlPlaneHandlers" $ingressHandlerSource "liveMutationAvailable" "mutation availability is computed, not hard-coded"
# HS-1B stage 3 replaced the direct CurrentRouterState binding with the
# composite runtime publication sink. The ownership invariant is unchanged and
# asserted more strictly: the operator publishes through the composite sink,
# that sink publishes the SAME CurrentRouterState, and the control plane is
# given the SAME sink and the SAME single thread-selection store.
Require-Contains "RouterHostBootstrap" $hostSource "RouterRuntimePublicationSink runtimePublicationSink" "host composes the composite runtime publication sink"
Require-Contains "RouterHostBootstrap" $hostSource "WithPublicationSink(runtimePublicationSink)" "host operator publishes through the composite runtime sink"
Require-Contains "RouterHostBootstrap" $hostSource "RuntimePublicationSink = runtimePublicationSink" "control plane proves mutation ownership against the same composite sink"
Require-Contains "RouterHostBootstrap" $hostSource "ThreadSelection = threadSelectionStore" "host shares the one thread-selection store with the control plane"
# Runtime publication observable atomicity: both owners are updated inside ONE
# exclusive section of the process-wide runtime consistency boundary, and the
# capability transition is applied through the boundary-free core method (the
# boundary is already held, so re-acquiring it would be a design error).
$publicationSinkSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Host/RouterRuntimePublicationSink.cs")
Require-Contains "RouterRuntimePublicationSink" $publicationSinkSource "_currentState.Publish(state)" "one publication updates the shared current state"
Require-Contains "RouterRuntimePublicationSink" $publicationSinkSource "_consistencyGate.EnterExclusive()" "the publication runs inside one exclusive runtime consistency section"
Require-Contains "RouterRuntimePublicationSink" $publicationSinkSource "_threadSelection.ApplyPublishedState(" "the same publication closes the single store's effective capability"
Require-Contains "RouterHostBootstrap" $hostSource "RouterRuntimeConsistencyGate runtimeConsistencyGate = new()" "host composes exactly one runtime consistency boundary"
Require-Contains "RouterHostBootstrap" $hostSource "RuntimeConsistencyGate = runtimeConsistencyGate" "the control plane shares the same runtime consistency boundary"

$commitTestMarkers = @{
    "local-router/tests/Router.Core.Tests/Configuration/LocalRouterConfigOperatorTests.cs" = @(
        "Successful_mutation_publishes_inside_the_gate_and_matches_durable_generation",
        "Post_commit_cancellation_still_publishes_the_committed_generation",
        "Persist_and_stale_failures_never_publish_runtime_state"
    )
    "local-router/tests/Router.Ingress.Tests/ControlPlaneEndpointsTests.cs" = @(
        "Concurrent_same_generation_http_mutations_have_exactly_one_winner_and_no_state_split",
        "Mutation_availability_is_false_without_a_live_publication_boundary"
    )
}
foreach ($file in $commitTestMarkers.Keys) {
    $testSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $file)
    foreach ($marker in $commitTestMarkers[$file]) {
        Require-Contains (Split-Path $file -Leaf) $testSource $marker "commit-atomicity test exists"
    }
}

$prereqDocCurrent = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "docs/LOCAL_ROUTER_LR14P_CONTROL_PLANE.md")
Require-Contains "prerequisite doc" $prereqDocCurrent "Offline config mutation (operator without a live publication sink)" "offline mutation does not equal live publication"

Write-Host ""
Write-Host "Local Router LR-14P control-plane validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router LR-14P control-plane validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router LR-14P control-plane validation PASSED" -ForegroundColor Green
exit 0
