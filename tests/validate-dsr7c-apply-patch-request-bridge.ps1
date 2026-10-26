param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR7-C-FIX5-B1b-1 - APPLY_PATCH REQUEST TRANSFORM + REPLAY BRIDGE validation.
#
# FIX5-A built the client contract and FIX5-B1a/B1a2 fixed the upstream function
# and tool_choice wire. This gate pins the provider-local request bridge: it is
# DeepSeek-only, it requires the declared compatibility bridge capability plus the
# route tools capability, it never runs for a streaming request, it never mutates
# the canonical request, it appends the Router-owned synthetic function last, it
# replays the two freeform input shapes with a JSON serializer, and every replay
# shape it cannot prove fails closed. The response restore and the SSE bridge are
# explicitly out of scope and must not exist yet.

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

$bridgeSource = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchRequestBridge.cs"
$adapterSource = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekProviderAdapter.cs"
$deepSeekCapabilities = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekCapabilities.cs"
$contractSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ApplyPatchCustomTool.cs"
$baseAdapterSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesCompatibleProviderAdapterBase.cs"
$wireSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderRequestWire.cs"
$codecSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderCodec.cs"
$parserSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ResponsesRequestParser.cs"
$inputSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ResponsesInputItem.cs"
$safeRequestRecord = Read-SourceText "local-router/src/Router.Observability/SafeRequestRecord.cs"
$durableRequestLog = Read-SourceText "local-router/src/Router.Observability/DurableRequestLog.cs"
$failureDiagnostic = Read-SourceText "local-router/src/Router.Observability/SafeFailureDiagnosticLog.cs"
$bridgeTests = Read-SourceText "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchRequestBridgeTests.cs"
$legacyBridgeTests = Read-SourceText "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchBridgeTests.cs"
$validatorSource = Get-Content -Raw -LiteralPath $PSCommandPath

# Comments explain what is deliberately absent, so the "never" checks run on
# code lines only.
$bridgeCode = ($bridgeSource -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(///|//)' }) -join "`n"

# --- 1. DeepSeek-only -------------------------------------------------------
Assert-True ($bridgeSource.Contains("public static class ApplyPatchRequestBridge")) "1: the bridge is a provider-local DeepSeek type"
Assert-True ($bridgeSource.Contains("DeepSeekProviderAdapter.ProviderId")) "1: the bridge requires a direct DeepSeek provider route"
Assert-True ($adapterSource.Contains("ApplyPatchRequestBridge.IsEligible")) "1: only the DeepSeek adapter evaluates bridge eligibility"
Assert-True ($adapterSource.Contains("ApplyPatchRequestBridge.CreateProviderLocalRequest")) "1: only the DeepSeek adapter performs the transform"
$otherProviderAdapters = @(
    @('MiMo', 'MiMoProviderAdapter.cs'),
    @('ModelStudio', 'ModelStudioProviderAdapter.cs'),
    @('OpenRouter', 'OpenRouterProviderAdapter.cs'),
    @('OpenAI', 'OpenAIProviderAdapter.cs'))
foreach ($provider in $otherProviderAdapters) {
    $source = Read-SourceText "local-router/src/Router.ProviderAdapters.$($provider[0])/$($provider[1])"
    Assert-True (-not ($source -match 'ApplyPatchRequestBridge')) "$($provider[0]): the adapter never references the DeepSeek bridge"
    Assert-True (-not ($source -match 'SyntheticFunctionName')) "$($provider[0]): the adapter never emits the synthetic identity"
}
Assert-True ($baseAdapterSource.Contains("invocation.Request.ApplyPatchTool is not null")) "1: the shared base still fails closed on a canonical custom tool"
Assert-True ($baseAdapterSource.Contains("ProviderAdapterResult.Failed(RouterError.UnsupportedCapability())")) "1: the shared fail-closed answer is unsupported_capability"

# --- 2. The capability is required -----------------------------------------
Assert-True ($deepSeekCapabilities.Contains('ApplyPatchCompatBridge = "apply_patch_compat_bridge"')) "2: the provider declares the bridge capability literal"
Assert-True ($contractSource.Contains('CompatBridgeCapability = "apply_patch_compat_bridge"')) "2: the canonical contract declares the same capability"
Assert-True ($bridgeSource.Contains("declaredBridges.Contains(ApplyPatchBridgeContract.CompatBridgeCapability)")) "2: eligibility requires the capability"
Assert-True ($adapterSource.Contains("DeepSeekCapabilities.SupportedCompatibilityBridges")) "2: eligibility evaluates the provider's declared bridge set"
Assert-True ($bridgeTests.Contains("Bridge_requires_the_declared_compatibility_bridge_capability")) "2: a test pins the capability requirement"

# --- 3. The route tools capability is required -----------------------------
Assert-True ($bridgeSource.Contains('RequiredRouteCapability = "tools"')) "3: the bridge names its required route capability"
Assert-True ($bridgeSource.Contains("EffectiveCapabilities.Contains(RequiredRouteCapability)")) "3: eligibility requires the route capability"
Assert-True ($bridgeTests.Contains("Bridge_requires_the_route_tools_capability")) "3: a test pins the route tools requirement"
Assert-True ($legacyBridgeTests.Contains("Canonical_apply_patch_tool_is_not_forwarded_upstream_yet")) "3: an ineligible route still sends nothing upstream"

# --- 4. Streaming eligibility ----------------------------------------------
# B1b-1 originally failed closed on EVERY streaming request. DSR7-C-FIX5-B2
# promotes the eligible streaming path (the same transformer, a different response
# side), so this gate now pins the promotion boundary instead: a streaming
# request still needs the route tools capability AND the route streaming
# capability, and anything else still fails closed before the transport.
Assert-True ($bridgeSource.Contains('RequiredStreamingCapability = "streaming"')) "4: the bridge names the required streaming capability"
Assert-True ($bridgeSource.Contains("!invocation.Request.Stream")) "4: eligibility still decides streaming explicitly"
Assert-True ($bridgeSource.Contains("EffectiveCapabilities.Contains(RequiredStreamingCapability)")) "4: a streaming request requires the route streaming capability"
Assert-True (-not ($bridgeSource -match 'if \(request\.Stream\)')) "4: the single shared transform no longer rejects streaming outright"
Assert-True ($adapterSource.IndexOf("ApplyPatchRequestBridge.IsEligible") -lt $adapterSource.IndexOf("DeepSeekEndpointValidator.Validate")) "4: eligibility is decided before endpoint validation and transport"
Assert-True ($bridgeTests.Contains("Bridge_rejects_streaming_before_any_transport_call")) "4: a test pins the pre-transport rejection for a route that cannot stream"
Assert-True ($bridgeTests.Contains("Bridge_requires_the_route_streaming_capability_for_a_streaming_request")) "4: a test pins the streaming capability requirement"
Assert-True ($bridgeTests.Contains("Streaming_request_reuses_the_same_provider_local_transform")) "4: a test pins the single shared transformer"
Assert-True ($bridgeTests.Contains("Assert.Null(server.LastRequestBody)")) "4: the streaming test proves no request reached the transport"

# --- 5. Immutable, provider-local request transform ------------------------
Assert-True ($bridgeSource.Contains("Value = request with")) "5: the transform returns a new canonical request"
Assert-True ($bridgeSource.Contains("ApplyPatchTool = null,")) "5: the original is cleared only in the clone"
Assert-True ($bridgeTests.Contains("The_transform_is_provider_local_and_never_mutates_the_canonical_request")) "5: a test pins the immutability contract"
Assert-True ($bridgeTests.Contains("Assert.NotSame(request, bridged)")) "5: a test pins that the canonical instance is never reused"

# --- 6 + 7. Synthetic function appended last; ordinary tools preserved -----
Assert-True ($bridgeSource.Contains("tools.AddRange(request.Tools)")) "6: ordinary function tools are copied in order"
Assert-True ($bridgeSource.Contains("tools.Add(new FunctionToolDefinition")) "6: exactly one synthetic function is appended"
Assert-True ($bridgeSource.IndexOf("tools.AddRange(request.Tools)") -lt $bridgeSource.IndexOf("tools.Add(new FunctionToolDefinition")) "6: the synthetic function is appended last"
Assert-True (-not ($bridgeSource -match 'mm_apply_patch_bridge_v1')) "6: the synthetic name is never re-hardcoded in the bridge"
Assert-True (-not ($adapterSource -match 'mm_apply_patch_bridge_v1')) "6: the synthetic name is never re-hardcoded in the adapter"
Assert-True (-not ($bridgeTests -match 'mm_apply_patch_bridge_v1')) "6: the tests reuse the contract constant"
Assert-True ($contractSource.Contains('SyntheticFunctionName = "mm_apply_patch_bridge_v1"')) "6: the canonical contract declares the synthetic name once"
Assert-True ($bridgeSource.Contains("Name = ApplyPatchBridgeContract.SyntheticFunctionName")) "6: the synthetic tool reuses the canonical constant"
Assert-True ($bridgeSource.Contains("patch")) "6: the synthetic schema carries the patch property"
Assert-True ($bridgeSource.Contains('"required":["patch"]')) "6: the synthetic schema requires the patch property"
Assert-True ($bridgeSource.Contains('"additionalProperties":false')) "6: the synthetic schema is closed"
Assert-True ($bridgeTests.Contains("Eligible_request_sends_the_synthetic_function_appended_last")) "6: a test pins the appended-last synthetic function"
Assert-True ($bridgeTests.Contains("Ordinary_function_tools_are_preserved_in_order")) "7: a test pins ordinary tool ordering"

# --- 8. Reserved synthetic name collision ----------------------------------
Assert-True ($bridgeSource.Contains("ApplyPatchBridgeContract.IsReservedSyntheticName(tool.Name)")) "8: a client function may not claim the synthetic name"
Assert-True ($bridgeSource.Contains("ApplyPatchBridgeContract.IsReservedSyntheticName(forgedCall.Name)")) "8: a replayed call may not claim the synthetic name"
Assert-True ($bridgeTests.Contains("Reserved_synthetic_name_collision_fails_closed")) "8: a test pins the definition collision"
Assert-True ($bridgeTests.Contains("Replayed_function_call_may_not_claim_the_reserved_synthetic_name")) "8: a test pins the replay collision"

# --- 9-11. Replay shapes and the call id invariant -------------------------
Assert-True ($inputSource.Contains("public sealed record CustomToolCallInputItem")) "9: the replayed freeform call is a canonical input item"
Assert-True ($inputSource.Contains("public sealed record CustomToolCallOutputInputItem")) "9: the replayed freeform output is a canonical input item"
Assert-True ($bridgeSource.Contains("case CustomToolCallInputItem call:")) "9: the bridge dispatches the replayed freeform call"
Assert-True ($bridgeSource.Contains("case CustomToolCallOutputInputItem output:")) "10: the bridge dispatches the replayed freeform output"
Assert-True ($bridgeSource.Contains("Arguments = SerializeArguments(call.Input)")) "9: the patch is projected into the function arguments"
Assert-True ($bridgeSource.Contains("JsonSerializer.Serialize(new SyntheticArguments { Patch = patch }, CompactJson)")) "9: the arguments use the JSON serializer, never string concatenation"
Assert-True (-not ($bridgeSource -match '\\"patch\\":')) "9: the arguments JSON is never hand-built"
Assert-True ($bridgeSource.Contains("Output = SerializeOutput(output.Output)")) "10: the output is projected into the function call output"
Assert-True ($bridgeSource.Contains("output.ValueKind == JsonValueKind.String")) "10: a string output stays a string"
Assert-True ($bridgeSource.Contains("JsonSerializer.Serialize(output, CompactJson)")) "10: structured output becomes compact JSON"
Assert-True ($bridgeSource.Contains("CallId = call.CallId")) "11: the replayed call keeps its call id"
Assert-True ($bridgeSource.Contains("CallId = output.CallId")) "11: the replayed output keeps its call id"
Assert-True (-not ($bridgeSource -match 'CallId = "')) "11: no call id is ever invented"
Assert-True ($bridgeTests.Contains("Custom_tool_call_replays_as_a_function_call_with_serialized_arguments")) "9: a test pins the call replay"
Assert-True ($bridgeTests.Contains("Custom_tool_call_output_replays_as_a_function_call_output")) "10: a test pins the output replay"
Assert-True ($bridgeTests.Contains("Multiple_replayed_calls_keep_their_original_order_and_pairing")) "11: a test pins ordering across several replayed calls"

# --- 12 + 13. Orphan and duplicate replays fail closed ---------------------
Assert-True ($bridgeSource.Contains("pendingCalls.Add(call.CallId)")) "13: a duplicated call id is rejected"
Assert-True ($bridgeSource.Contains("pendingCalls.Contains(output.CallId)")) "12: an orphan output is rejected"
Assert-True ($bridgeSource.Contains("answeredCalls.Add(output.CallId)")) "13: a duplicated output is rejected"
Assert-True ($bridgeTests.Contains("Orphan_custom_tool_output_fails_closed")) "12: a test pins the orphan rejection"
Assert-True ($bridgeTests.Contains("An_output_before_its_matching_call_fails_closed")) "12: a test pins the ordering rejection"
Assert-True ($bridgeTests.Contains("Duplicate_custom_call_id_fails_closed")) "13: a test pins the duplicate call rejection"
Assert-True ($bridgeTests.Contains("Duplicate_custom_tool_output_fails_closed")) "13: a test pins the duplicate output rejection"
Assert-True ($bridgeTests.Contains("Unknown_freeform_tool_call_fails_closed")) "12: a test pins the unknown freeform tool rejection"
Assert-True ($bridgeTests.Contains("A_malformed_freeform_definition_identity_fails_closed")) "12: a test pins the malformed definition rejection"
Assert-True ($bridgeTests.Contains("Named_tool_choice_for_the_freeform_tool_fails_closed")) "12: a test pins the unrepresentable tool_choice rejection"

# --- 14. Patch size bound ---------------------------------------------------
Assert-True ($bridgeSource.Contains("MaxPatchInputLength = 65_536")) "14: the patch bound is declared once"
Assert-True ($bridgeSource.Contains("call.Input.Length > MaxPatchInputLength")) "14: an oversized patch fails closed"
Assert-True ($bridgeTests.Contains("Oversized_patch_fails_closed")) "14: a test pins the patch bound"

# --- 15. The freeform grammar is never forwarded ---------------------------
Assert-True (-not ($bridgeSource -match 'FormatDefinition')) "15: the grammar definition is never read by the bridge"
Assert-True (-not ($bridgeCode -match 'Description')) "15: the client description is never projected"
Assert-True ($bridgeTests.Contains("The_freeform_grammar_definition_is_never_forwarded")) "15: a test pins that the grammar never reaches the wire"
Assert-True ($bridgeTests.Contains("GrammarSentinel")) "15: the test uses a non-leaking sentinel rather than real grammar content"

# --- 16. Other providers fail closed ---------------------------------------
$otherProviderTests = @(
    @('MiMo', 'MiMoFunctionWireTests.cs'),
    @('ModelStudio', 'ModelStudioFunctionWireTests.cs'),
    @('OpenRouter', 'OpenRouterFunctionWireTests.cs'),
    @('OpenAI', 'OpenAIFunctionWireTests.cs'))
foreach ($provider in $otherProviderTests) {
    $text = Read-SourceText "local-router/tests/Router.ProviderAdapters.$($provider[0]).Tests/$($provider[1])"
    Assert-True ($text.Contains("Canonical_apply_patch_tool_fails_closed_and_never_reaches_the_transport")) "$($provider[0]): a test pins the fail-closed provider"
    Assert-True ($text.Contains("Assert.Null(server.LastRequestBody)")) "$($provider[0]): the fail-closed test proves nothing reached the transport"
}

# --- 17. The Router never executes a patch ---------------------------------
$bridgePathSources = $bridgeSource + $adapterSource
foreach ($forbidden in @('Process.Start', 'System.Diagnostics', 'git apply', 'patch.exe', 'powershell', 'PowerShell', 'cmd.exe', 'bash', 'File.WriteAllText', 'File.WriteAllBytes', 'Directory.CreateDirectory')) {
    Assert-True (-not ($bridgePathSources.Contains($forbidden))) "17: the bridge path never calls $forbidden"
}
Assert-True (-not ($bridgeSource -match 'File\.|Directory\.')) "17: the bridge performs no filesystem operation"
Assert-True ($bridgeSource.Contains("only serializes it into the upstream function arguments")) "17: the bridge documents that it only serializes"

# --- 18. Patch content is never logged -------------------------------------
Assert-True (-not ($safeRequestRecord -match 'Patch|patch')) "18: the redacted request record has no patch field"
Assert-True (-not ($durableRequestLog -match 'Patch|patch')) "18: the durable request log has no patch field"
Assert-True (-not ($failureDiagnostic -match 'Patch|patch')) "18: the failure diagnostic has no patch field"
foreach ($sink in @('ILogger', 'Console.', 'Debug.', 'Trace.')) {
    Assert-True (-not ($bridgeCode.Contains($sink))) "18: the bridge never writes to $sink"
}

# --- 19 + 20. B1a and B1a2 wires are unchanged -----------------------------
Assert-True ($wireSource.Contains('FunctionToolType = "function"')) "19: the B1a function discriminator is unchanged"
Assert-True ($wireSource.Contains("Type = FunctionToolType")) "19: every projected tool still takes the fixed type"
Assert-True ($codecSource.Contains("ResponsesProviderRequestWire.FromCanonical(request)")) "19: the outbound path is still the provider wire projection"
Assert-True ($wireSource.Contains("ResponsesToolChoiceWireConverter")) "20: the B1a2 tool_choice converter is unchanged"
Assert-True ($wireSource.Contains('writer.WriteStringValue("auto")')) "20: auto still projects to the string form"
Assert-True ($wireSource.Contains('writer.WriteString("name", value.FunctionName)')) "20: a named choice still projects to {type:function}"
Assert-True ($bridgeTests.Contains("Preserved_tool_choice_is_never_rewritten")) "20: a test pins that the bridge never rewrites tool_choice"
Assert-True (-not ($bridgeSource -match 'ToolChoice = ')) "20: the bridge never reassigns tool_choice"

# --- 21 + 22. No response restore and no SSE change yet --------------------
Assert-True (-not ($bridgeSource -match 'CanonicalResponsesResponse')) "21: the bridge transforms requests only"
Assert-True (-not ($adapterSource -match 'CustomToolCallResponseItem')) "21: the adapter performs no response restore"
Assert-True (-not ($codecSource -match 'function_call" =>|SyntheticFunctionName')) "21: the response codec performs no synthetic restore"
Assert-True ($parserSource.Contains('"custom_tool_call" => ParseCustomToolCallItem')) "21: only the FIX5-A client replay exists"
Assert-True (-not ($bridgeCode -match 'SseStreamParser|SseWriter|CanonicalEvent|SseStream')) "22: the bridge touches no SSE machinery"
Assert-True (-not ($adapterSource -match 'SseStreamParser|SseWriter|CanonicalEvent')) "22: the adapter touches no SSE machinery"
Assert-True ($baseAdapterSource.Contains("DecodeEventStreamAsync(guard, cancellationToken)")) "22: the streaming decode path is unchanged"

# --- 23. No provider network in this gate ---------------------------------
$httpPrimitives = @(("Invoke-" + "RestMethod"), ("Invoke-" + "WebRequest"))
foreach ($primitive in $httpPrimitives) {
    Assert-True (-not ($validatorSource.Contains($primitive))) "23: this validator issues no $primitive call"
}
Assert-True (-not ($bridgeTests -match 'api\.deepseek\.com')) "23: the bridge tests reference no live endpoint"
Assert-True ($bridgeTests.Contains("FakeProviderServer")) "23: provider coverage uses the fake provider transport only"

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "DSR7-C apply_patch request bridge (FIX5-B1b-1) validation PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "DSR7-C apply_patch request bridge (FIX5-B1b-1) validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
exit 1
