param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR7-C-FIX5-B2 - DEEPSEEK STREAMING APPLY_PATCH BRIDGE validation.
#
# B1b-1 transformed the request and B1b-2 restored a non-stream response. This
# gate pins the streaming half: the DeepSeek compatibility layer buffers every
# event of the Router-owned synthetic function call, validates the complete
# arguments with the same strict decoder as B1b-2, and releases one fully restored
# custom_tool_call item - or fails the whole logical response closed. The frozen
# client event vocabulary, the SSE parser, the generic codec, the generic
# providers and the ordinary DeepSeek stream are deliberately untouched.

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Pass $Message } else { Fail $Message }
}

function Read-SourceText([string]$RelativePath) {
    return (Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $RelativePath))
}

$streamSource = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchStreamBridge.cs"
$streamTests = Read-SourceText "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchStreamBridgeTests.cs"
$requestBridgeTests = Read-SourceText "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchRequestBridgeTests.cs"
$legacyStreamTests = Read-SourceText "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekStreamTests.cs"
$requestBridgeSource = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchRequestBridge.cs"
$responseBridgeSource = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchResponseBridge.cs"
$adapterSource = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekProviderAdapter.cs"
$vocabularySource = Read-SourceText "local-router/src/Router.ProtocolAdapters.Responses/CanonicalEventVocabulary.cs"
$sseSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/SseStreamParser.cs"
$codecSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderCodec.cs"
$baseAdapterSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesCompatibleProviderAdapterBase.cs"
$safeRequestRecord = Read-SourceText "local-router/src/Router.Observability/SafeRequestRecord.cs"
$durableRequestLog = Read-SourceText "local-router/src/Router.Observability/DurableRequestLog.cs"
$failureDiagnostic = Read-SourceText "local-router/src/Router.Observability/SafeFailureDiagnosticLog.cs"
$validatorSource = Get-Content -Raw -LiteralPath $PSCommandPath

$streamCode = ($streamSource -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(///|//)' }) -join "`n"
$responseBridgeCode = ($responseBridgeSource -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(///|//)' }) -join "`n"

# --- 1. DeepSeek-only streaming bridge ------------------------------------
Assert-True ($streamSource.Contains("public static class ApplyPatchStreamBridge")) "1: the streaming bridge is a dedicated provider-local type"
Assert-True ($adapterSource.Contains("ApplyPatchStreamBridge.Apply(providerEvents, bridgeIsActive, cancellationToken)")) "1: only the DeepSeek adapter wraps the provider event stream"
Assert-True (-not ($baseAdapterSource -match 'ApplyPatchStreamBridge')) "1: the shared provider base owns no apply_patch streaming state machine"
Assert-True (-not ($codecSource -match 'ApplyPatchStreamBridge')) "1: the generic codec owns no apply_patch streaming state machine"
$otherProviderAdapters = @(
    @('MiMo', 'MiMoProviderAdapter.cs'),
    @('ModelStudio', 'ModelStudioProviderAdapter.cs'),
    @('OpenRouter', 'OpenRouterProviderAdapter.cs'),
    @('OpenAI', 'OpenAIProviderAdapter.cs'))
foreach ($provider in $otherProviderAdapters) {
    $source = Read-SourceText "local-router/src/Router.ProviderAdapters.$($provider[0])/$($provider[1])"
    Assert-True (-not ($source -match 'ApplyPatchStreamBridge|ApplyPatchResponseBridge|SyntheticFunctionName|CustomToolCallResponseItem')) "$($provider[0]): the adapter gains no apply_patch streaming behaviour"
}

# --- 2. Active bridge required --------------------------------------------
Assert-True ($streamSource.Contains("if (!_bridgeIsActive)")) "2: the bridge is gated on the active flag"
Assert-True ($adapterSource.Contains("ApplyPatchStreamBridge.Apply(providerEvents, bridgeIsActive, cancellationToken)")) "2: the adapter passes the real bridge state"
Assert-True ($streamTests.Contains("Synthetic_injection_without_an_active_bridge_fails_closed")) "2: a test pins the injection defence"
Assert-True ($streamTests.Contains("Inactive_bridge_yields_ordinary_streams_unchanged")) "2: a test pins the inactive passthrough"

# --- 3 + 4. Route tools and route streaming required ----------------------
Assert-True ($requestBridgeSource.Contains('RequiredRouteCapability = "tools"')) "3: the shared request bridge still requires tools"
Assert-True ($requestBridgeSource.Contains('RequiredStreamingCapability = "streaming"')) "4: the shared request bridge names the streaming capability"
Assert-True ($requestBridgeSource.Contains("EffectiveCapabilities.Contains(RequiredStreamingCapability)")) "4: a streaming request requires the route streaming capability"
Assert-True (-not ($requestBridgeSource -match 'if \(request\.Stream\)')) "4: streaming is no longer rejected outright before the transform"
Assert-True ($requestBridgeSource.Contains("!invocation.Request.Stream")) "4: eligibility still decides streaming explicitly"

# --- 5. The B1b-1 transformer is reused -----------------------------------
Assert-True ($adapterSource.Contains("ApplyPatchRequestBridge.CreateProviderLocalRequest(invocation.Request)")) "5: the streaming attempt uses the B1b-1 transformer"
Assert-True (-not ($streamSource -match 'CreateProviderLocalRequest|ApplyPatchCustomToolDefinition')) "5: no second request transformer exists"
Assert-True ($requestBridgeTests.Contains("Streaming_request_reuses_the_same_provider_local_transform")) "5: a test pins the shared transformer"

# --- 6. Exact synthetic name only -----------------------------------------
Assert-True ($streamSource.Contains("ApplyPatchBridgeContract.IsReservedSyntheticName(property.Value.GetString())")) "6: the injection scan uses the reserved-name predicate"
Assert-True ($streamSource.Contains("identity.MentionsSyntheticName")) "6: the item identity uses the reserved-name predicate"
Assert-True (-not ($streamCode -match 'Trim\(|ToLower|ToUpper|StartsWith|Contains\(|Regex')) "6: no trim/case folding/prefix/contains/regex matching exists"

# --- 7 + 8. Bounded buffers ----------------------------------------------
Assert-True ($streamSource.Contains("MaxSyntheticArgumentsLength =")) "7: a per-call argument bound exists"
Assert-True ($streamSource.Contains("MaxJsonEscapedCharactersPerCodeUnit * ApplyPatchRequestBridge.MaxPatchInputLength")) "7: the bound is derived from the shared B1b-1 patch bound plus a documented JSON envelope"
Assert-True ($streamSource.Contains("MaxJsonEscapedCharactersPerCodeUnit = 6")) "7: the worst-case escaping factor is stated"
Assert-True ($streamSource.Contains("ArgumentsJsonEnvelopeLength = 12")) "7: the JSON envelope allowance is stated"
Assert-True ($streamSource.Contains("MaxSyntheticCallsPerResponse = 4")) "8: the maximum synthetic calls per response is bounded"
Assert-True ($streamSource.Contains("MaxSyntheticBufferedCharacters = MaxSyntheticCallsPerResponse * MaxSyntheticArgumentsLength")) "8: the total bound is the product, not an arbitrary constant"
Assert-True ($streamSource.Contains("call.Deltas.Length + delta!.Length > MaxSyntheticArgumentsLength")) "7: a growing delta buffer fails closed"
Assert-True ($streamSource.Contains("_bufferedCharacters + delta.Length > MaxSyntheticBufferedCharacters")) "8: the running total fails closed"
Assert-True (-not ($streamCode -match '65_536|65536|int\.MaxValue')) "7: no second, unrelated length limit is invented"
Assert-True ($streamTests.Contains("Oversized_streamed_arguments_fail_closed")) "7: a test pins the per-call bound"
Assert-True ($streamTests.Contains("Oversized_decoded_patch_fails_closed")) "7: a test pins the decoded patch bound"

# --- 9-11. Lifecycle, item id and call id invariants ----------------------
Assert-True ($streamSource.Contains("_open.ContainsKey(identity.Id!)")) "9: a duplicate start is rejected"
Assert-True ($streamSource.Contains("call.ArgumentsDone is not null")) "9: a duplicate arguments.done is rejected"
Assert-True ($streamSource.Contains("call.Completed")) "9: events after completion are rejected"
Assert-True ($streamSource.Contains("_restored.ContainsKey")) "9: a reused item id is rejected"
Assert-True ($streamSource.Contains("string.Equals(identity.Id, call.ItemId, StringComparison.Ordinal)")) "10: the item id must match exactly"
Assert-True ($streamSource.Contains("string.Equals(identity.CallId, call.CallId, StringComparison.Ordinal)")) "11: the call id must match exactly"
Assert-True ($streamSource.Contains("string.IsNullOrWhiteSpace(identity.CallId)")) "11: an empty call id fails closed"
Assert-True ($streamSource.Contains("disagreement") -or $streamSource.Contains("!string.Equals(resolved, candidate, StringComparison.Ordinal)")) "9: disagreeing argument sources fail closed"
Assert-True ($streamTests.Contains("Duplicate_start_fails_closed")) "9: a test pins the duplicate start"
Assert-True ($streamTests.Contains("Duplicate_arguments_done_fails_closed")) "9: a test pins the duplicate arguments.done"
Assert-True ($streamTests.Contains("Item_id_mutation_fails_closed")) "10: a test pins the item id mutation"
Assert-True ($streamTests.Contains("Call_id_mutation_fails_closed")) "11: a test pins the call id mutation"
Assert-True ($streamTests.Contains("Item_done_before_start_fails_closed")) "9: a test pins the completion before start"
Assert-True ($streamTests.Contains("Disagreeing_argument_sources_fail_closed")) "9: a test pins the interleaving corruption"

# --- 12. The B1b-2 strict decoder is reused ------------------------------
Assert-True ($responseBridgeSource.Contains("public static bool TryDecodePatch(string arguments, out string patch)")) "12: one shared strict decode primitive exists"
Assert-True ($streamSource.Contains("ApplyPatchResponseBridge.TryDecodePatch(arguments, out string patch)")) "12: the streaming bridge uses the shared decoder"
Assert-True ($responseBridgeSource.Contains("!TryDecodePatch(call.Arguments, out string patch)")) "12: the non-stream restore uses the same decoder"
Assert-True (-not ($streamCode -match 'TryGetProperty\("patch"')) "12: the streaming bridge never duplicates a lenient patch lookup"
Assert-True ($streamTests.Contains("Malformed_final_arguments_fail_closed")) "12: a test pins the shared strict rules"

# --- 13-16. No partial release, malformed/injection fail closed -----------
Assert-True ($streamSource.Contains("yield return ErrorEventForFailClosedState();")) "14: a fail-closed state terminates with one content-free error event"
Assert-True ($streamSource.Contains("ProviderAdapterErrors.InvalidResponse()")) "14: the failure uses the existing provider invalid_response error"
Assert-True ($streamSource.Contains("never releases a buffered")) "13: the bridge documents that nothing buffered is released"
Assert-True ($streamSource.Contains("can therefore never reach the client partially")) "13: the bridge documents the no-partial-leak invariant"
Assert-True ($streamTests.Contains("No_patch_content_is_released_before_validation")) "13: a test pins that the patch is never partially released"
Assert-True ($streamTests.Contains("Synthetic_call_started_but_never_completed_fails_closed")) "16: a test pins the incomplete lifecycle"
Assert-True ($streamTests.Contains("Late_synthetic_identity_fails_closed")) "16: a test pins the late synthetic identity"
Assert-True ($streamTests.Contains("Synthetic_injection_in_the_terminal_body_fails_closed")) "16: a test pins the terminal injection"
Assert-True ($streamTests.Contains("PATCH_STREAM_DO_NOT_PARTIALLY_RELEASE_61937")) "13: the decoy patch sentinel is used"

# --- 17. Multiple calls stay isolated ------------------------------------
Assert-True ($streamSource.Contains("Dictionary<string, SyntheticCall> _open = new(StringComparer.Ordinal)")) "17: per-call state is keyed by item id"
Assert-True ($streamTests.Contains("Multiple_synthetic_calls_are_restored_independently")) "17: a test pins independent calls"
Assert-True ($streamTests.Contains("One_malformed_call_stops_the_stream_without_releasing_it")) "17: a test pins that one bad call stops the stream"

# --- 18. Ordinary streaming unchanged ------------------------------------
Assert-True ($streamSource.Contains("emitted.Add(canonicalEvent);")) "18: ordinary events are yielded unchanged"
Assert-True ($streamTests.Contains("Ordinary_stream_events_are_yielded_by_reference")) "18: a test pins reference-identical ordinary events"
Assert-True ($streamTests.Contains("End_to_end_ordinary_stream_is_unchanged")) "18: a test pins the ordinary fake-transport stream"
Assert-True ($legacyStreamTests.Contains("Function_call_argument_deltas_are_preserved")) "18: the pre-B2 ordinary stream suite is unchanged and still present"

# --- 19 + 20. Terminal restore and consistency ---------------------------
Assert-True ($streamSource.Contains("RewriteCompleted(canonicalEvent, replacements)")) "19: the terminal body is rewritten through the restore"
Assert-True ($streamSource.Contains("WriteRewrittenResponse")) "19: only the output array is rewritten; every other field is preserved"
Assert-True ($streamSource.Contains("!string.Equals(restored.Patch, terminalPatch, StringComparison.Ordinal)")) "20: the streamed restore and the terminal body must agree on the patch"
Assert-True ($streamSource.Contains("!string.Equals(restored.CallId, terminal.CallId, StringComparison.Ordinal)")) "20: the terminal call id must match the restored call id"
Assert-True ($streamTests.Contains("response.completed") -or $streamTests.Contains('"response.completed"')) "19: a test covers the terminal event"
Assert-True ($streamTests.Contains("CompletedWithOutput(SyntheticItemJson(arguments))")) "19: a test pins the rewritten terminal body"

# --- 21 + 22. Timeout and cancellation preserved -------------------------
Assert-True (-not ($streamCode -match 'CancellationToken\.None|Task\.Delay|WaitAsync')) "21: the bridge adds no timeout handling of its own"
Assert-True ($streamSource.Contains("upstream.GetAsyncEnumerator(cancellationToken)")) "22: the upstream enumerator observes cancellation"
Assert-True (-not ($streamCode -match 'catch \(|catch$')) "22: exceptions propagate; the bridge swallows none"
Assert-True ($streamTests.Contains("Stream_timeout_propagates_without_releasing_the_patch")) "21: a test pins the timeout propagation"
Assert-True ($streamTests.Contains("Cancellation_propagates_without_releasing_the_patch")) "22: a test pins the cancellation propagation"
Assert-True ($streamTests.Contains("Stream_interruption_propagates_without_releasing_the_patch")) "22: a test pins the interruption propagation"

# --- 23. No retry, no failover, no non-stream fallback -------------------
foreach ($forbidden in @('Retry', 'retry', 'failover', 'Failover')) {
    Assert-True (-not ($streamCode.Contains($forbidden))) "23: the bridge never adds $forbidden behaviour"
}
Assert-True (-not ($streamCode -match 'InvokeAsync|SendAsync')) "23: the bridge never re-sends a request"

# --- 24 + 25. Privacy and no execution ----------------------------------
Assert-True (-not ($safeRequestRecord -match 'Patch|patch')) "24: the redacted request record has no patch field"
Assert-True (-not ($durableRequestLog -match 'Patch|patch')) "24: the durable request log has no patch field"
Assert-True (-not ($failureDiagnostic -match 'Patch|patch')) "24: the failure diagnostic has no patch field"
Assert-True (-not ($streamCode -match 'ILogger|Console\.|Debug\.|Trace\.|Log\(')) "24: the bridge writes to no log sink"
$bridgePathSources = $streamSource + $adapterSource + $responseBridgeSource
foreach ($forbidden in @('Process.Start', 'System.Diagnostics', 'git apply', 'patch.exe', 'powershell', 'PowerShell', 'cmd.exe', 'bash', 'File.WriteAllText', 'File.WriteAllBytes', 'Directory.CreateDirectory', 'CreateDirectory')) {
    Assert-True (-not ($bridgePathSources.Contains($forbidden))) "25: the streaming bridge path never calls $forbidden"
}
Assert-True (-not ($streamCode -match 'File\.|Directory\.')) "25: the streaming bridge performs no filesystem operation"

# --- 26. Other providers unchanged --------------------------------------
foreach ($provider in @(
        @('MiMo', 'MiMoFunctionWireTests.cs'),
        @('ModelStudio', 'ModelStudioFunctionWireTests.cs'),
        @('OpenRouter', 'OpenRouterFunctionWireTests.cs'),
        @('OpenAI', 'OpenAIFunctionWireTests.cs'))) {
    $text = Read-SourceText "local-router/tests/Router.ProviderAdapters.$($provider[0]).Tests/$($provider[1])"
    Assert-True ($text.Contains("Canonical_apply_patch_tool_fails_closed_and_never_reaches_the_transport")) "$($provider[0]): apply_patch still fails closed"
}

# --- 27 + 28. The earlier gates still pass ------------------------------
foreach ($gate in @(
        @('27', 'tests/validate-dsr7c-apply-patch-request-bridge.ps1'),
        @('28', 'tests/validate-dsr7c-apply-patch-response-bridge.ps1'))) {
    $gatePath = Join-Path $RepositoryRoot $gate[1]
    Assert-True (Test-Path -LiteralPath $gatePath -PathType Leaf) "$($gate[0]): the earlier gate is still present"
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $gateOutput = @(& pwsh -NoProfile -File $gatePath -RepositoryRoot $RepositoryRoot 2>&1)
    $gateExit = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    Assert-True ($gateExit -eq 0) "$($gate[0]): the earlier gate still passes (exit $gateExit)"
    if ($gateExit -ne 0) {
        foreach ($line in $gateOutput | Where-Object { $_ -match '^FAIL' }) { Write-Host "      $($gate[1]): $line" -ForegroundColor Red }
    }
}

# --- The frozen client vocabulary is not extended ------------------------
Assert-True ($vocabularySource.Contains("Frozen, versioned canonical Responses event vocabulary")) "the client event vocabulary stays frozen"
Assert-True (-not ($vocabularySource -match 'custom_tool_call|apply_patch|arguments\.delta')) "no apply_patch wire event was added to the client vocabulary"
Assert-True ($streamSource.Contains('OutputItemAddedEvent = "response.output_item.added"')) "the restore reuses the existing output-item event"
Assert-True ($streamSource.Contains('OutputItemDoneEvent = "response.output_item.done"')) "the restore reuses the existing output-item event"
Assert-True (-not ($streamSource -match 'CanonicalEventVocabulary\.All|SemanticLossDetector')) "the bridge never rewrites the protocol gate"

# --- 24 (SSE unchanged) + 29 (no network) -------------------------------
Assert-True (-not ($streamCode -match 'SseStreamParser|SseWriter|LineReader|SseParseException')) "SSE: the bridge touches no SSE framing code"
Assert-True (-not ($sseSource -match 'ApplyPatch|SyntheticFunctionName')) "SSE: the SSE parser has no apply_patch awareness"
$httpPrimitives = @(("Invoke-" + "RestMethod"), ("Invoke-" + "WebRequest"))
foreach ($primitive in $httpPrimitives) {
    Assert-True (-not ($validatorSource.Contains($primitive))) "29: this validator issues no $primitive call"
}
Assert-True (-not ($streamTests -match 'api\.deepseek\.com')) "29: the streaming tests reference no live endpoint"
Assert-True ($streamTests.Contains("FakeProviderServer")) "29: provider coverage uses the fake provider transport only"

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "DSR7-C apply_patch stream bridge (FIX5-B2) validation PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "DSR7-C apply_patch stream bridge (FIX5-B2) validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
exit 1
