param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR7-C-FIX5-B1b-2 - DEEPSEEK NON-STREAM APPLY_PATCH RESPONSE RESTORE validation.
#
# B1b-1 built the request half of the DeepSeek apply_patch bridge. This gate pins
# the return half: the DeepSeek provider compatibility layer restores the
# Router-owned synthetic function call into the freeform custom_tool_call the
# client expects - only for an attempt that really enabled the bridge, only for
# the exact reserved name, only from a strictly decoded one-property arguments
# object, and never partially. A reserved identity without an active bridge is a
# synthetic injection and fails closed. The generic Responses codec, the generic
# providers and the SSE path are deliberately untouched.

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

$bridgeSource = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchResponseBridge.cs"
$requestBridgeSource = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchRequestBridge.cs"
$adapterSource = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekProviderAdapter.cs"
$contractSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ApplyPatchCustomTool.cs"
$responseSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/CanonicalResponsesResponse.cs"
$codecSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderCodec.cs"
$baseAdapterSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesCompatibleProviderAdapterBase.cs"
$sseSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/SseStreamParser.cs"
$safeRequestRecord = Read-SourceText "local-router/src/Router.Observability/SafeRequestRecord.cs"
$durableRequestLog = Read-SourceText "local-router/src/Router.Observability/DurableRequestLog.cs"
$failureDiagnostic = Read-SourceText "local-router/src/Router.Observability/SafeFailureDiagnosticLog.cs"
$bridgeTests = Read-SourceText "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchResponseBridgeTests.cs"
$validatorSource = Get-Content -Raw -LiteralPath $PSCommandPath

# Comments explain what is deliberately absent, so the "never" checks run on
# code lines only.
$bridgeCode = ($bridgeSource -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(///|//)' }) -join "`n"

# --- 1. DeepSeek provider-local restore ------------------------------------
Assert-True ($bridgeSource.Contains("public static class ApplyPatchResponseBridge")) "1: the restore is a dedicated provider-local bridge type"
Assert-True ($adapterSource.Contains("ApplyPatchResponseBridge.Apply(result, bridgeIsActive)")) "1: only the DeepSeek adapter invokes the restore"
Assert-True (-not ($codecSource -match 'ApplyPatchResponseBridge')) "1: the generic Responses codec never invokes the restore"
$otherProviderAdapters = @(
    @('MiMo', 'MiMoProviderAdapter.cs'),
    @('ModelStudio', 'ModelStudioProviderAdapter.cs'),
    @('OpenRouter', 'OpenRouterProviderAdapter.cs'),
    @('OpenAI', 'OpenAIProviderAdapter.cs'))
foreach ($provider in $otherProviderAdapters) {
    $source = Read-SourceText "local-router/src/Router.ProviderAdapters.$($provider[0])/$($provider[1])"
    Assert-True (-not ($source -match 'ApplyPatchResponseBridge|CustomToolCallResponseItem')) "$($provider[0]): the adapter never restores freeform calls"
}

# --- 2. An active bridge is required ---------------------------------------
Assert-True ($bridgeSource.Contains("if (!bridgeIsActive")) "2: the restore requires an active bridge"
Assert-True ($adapterSource.Contains("bridgeIsActive = true;")) "2: the adapter marks the bridge active only for a bridged attempt"
Assert-True ($adapterSource.Contains("bool bridgeIsActive = false;")) "2: the bridge starts inactive for every attempt"
Assert-True ($adapterSource.IndexOf("bridgeIsActive = true;") -lt $adapterSource.IndexOf("ApplyPatchResponseBridge.Apply")) "2: the flag is set before the response is restored"
Assert-True ($bridgeTests.Contains("Synthetic_injection_without_an_active_bridge_fails_closed")) "2: a test pins the injection defence"

# --- 3. Exact synthetic name match only ------------------------------------
Assert-True ($bridgeSource.Contains("ApplyPatchBridgeContract.IsReservedSyntheticName(call.Name)")) "3: the candidate check reuses the reserved-name predicate"
Assert-True (-not ($bridgeCode -match 'Trim\(|ToLower|ToUpper|StartsWith|Contains\(|Regex')) "3: no trim/case folding/prefix/contains/regex matching exists"
Assert-True ($bridgeTests.Contains("Non_exact_synthetic_names_stay_ordinary_function_calls")) "3: a test pins the exact-match boundary"
Assert-True ($bridgeTests.Contains("MM_APPLY_PATCH_BRIDGE_V1")) "3: a test pins the case-variant boundary"

# --- 4-7. Strict argument decoder ------------------------------------------
Assert-True ($bridgeSource.Contains("root.EnumerateObject()")) "4: the decoder enumerates properties"
Assert-True (-not ($bridgeCode -match 'TryGetProperty')) "4: the decoder never probes a property by name"
Assert-True ($bridgeSource.Contains("propertyCount > 1")) "4: more than one property is rejected"
Assert-True ($bridgeSource.Contains("propertyCount == 1")) "4: exactly one property is required"
Assert-True ($bridgeSource.Contains("property.Value.ValueKind != JsonValueKind.String")) "5: a non-string patch value is rejected"
Assert-True ($bridgeSource.Contains("catch (JsonException)")) "5: malformed JSON is rejected"
Assert-True ($bridgeTests.Contains('{"patch":"a","patch":"b"}')) "6: a duplicate patch key is covered"
Assert-True ($bridgeTests.Contains('{"patch":"x","extra":"y"}')) "7: an extra property is covered"
Assert-True ($bridgeTests.Contains('{"patch":null}')) "5: a null patch is covered"
Assert-True ($bridgeTests.Contains('{"patch":123}')) "5: a numeric patch is covered"
Assert-True ($bridgeTests.Contains('{"patch":[]}')) "5: an array patch is covered"
Assert-True ($bridgeTests.Contains('{"patch":{}}')) "5: an object patch is covered"
Assert-True ($bridgeTests.Contains("Malformed_arguments_fail_closed")) "4: a test pins the strict decoder matrix"

# --- 8. Patch bound reused from B1b-1 -------------------------------------
Assert-True ($bridgeSource.Contains("ApplyPatchRequestBridge.MaxPatchInputLength")) "8: the restore reuses the B1b-1 bound"
Assert-True (-not ($bridgeCode -match '65_536|65536|MaxPatchLength')) "8: no second length limit is introduced"
Assert-True ($bridgeTests.Contains("Patch_at_the_bound_is_restored_and_one_over_fails_closed")) "8: a test pins the bound exactly"
Assert-True ($bridgeTests.Contains("ApplyPatchRequestBridge.MaxPatchInputLength + 1")) "8: the over-bound case is derived from the shared constant"

# --- 9-12. Restored shape --------------------------------------------------
Assert-True ($bridgeSource.Contains("Id = call.Id")) "9: the upstream item id is preserved verbatim"
Assert-True ($bridgeSource.Contains("CallId = call.CallId")) "10: the call id is preserved verbatim"
Assert-True ($bridgeSource.Contains("string.IsNullOrWhiteSpace(call.CallId)")) "10: an empty call id fails closed"
Assert-True (-not ($bridgeCode -match 'CallId = "')) "10: no call id is ever invented"
Assert-True ($bridgeSource.Contains("Name = ApplyPatchBridgeContract.ApplyPatchToolName")) "11: the restored name is the canonical freeform tool name"
Assert-True ($bridgeSource.Contains("Type = ApplyPatchBridgeContract.ClientToolCallType")) "12: the restored type is custom_tool_call"
Assert-True ($contractSource.Contains('ClientToolCallType = "custom_tool_call"')) "12: the canonical contract declares the restored type"
Assert-True ($responseSource.Contains("public sealed record CustomToolCallResponseItem")) "12: the canonical response already models the restored item"
Assert-True ($bridgeTests.Contains("Restored_call_keeps_the_upstream_item_id_and_call_id")) "9-10: a test pins id and call id preservation"
Assert-True ($bridgeTests.Contains("Active_bridge_restores_the_synthetic_call_into_a_custom_tool_call")) "11-12: a test pins the restored name and type"

# --- 13-16. Whole-response contract ---------------------------------------
Assert-True ($bridgeSource.Contains("item is not FunctionCallResponseItem call")) "13: only function call items are candidates"
Assert-True ($bridgeSource.Contains("output.Add(item);")) "13: ordinary output items are carried through"
Assert-True ($bridgeTests.Contains("Ordinary_function_calls_are_preserved_next_to_a_synthetic_call")) "13: a test pins ordinary function calls"
Assert-True ($bridgeTests.Contains("Mixed_output_order_is_preserved")) "14: a test pins the mixed output order"
Assert-True ($bridgeTests.Contains('["reasoning", "message", "function_call", "custom_tool_call", "message"]')) "14: the pinned order is the upstream order"
Assert-True ($bridgeTests.Contains("Multiple_synthetic_calls_are_restored_in_order")) "15: a test pins several synthetic calls"
Assert-True ($bridgeSource.Contains("var output = new List<ResponseOutputItem>(response.Output.Count);")) "16: the restore builds a temporary output list"
Assert-True ($bridgeSource.Contains("Value = restoredCount == 0 ? response : response with { Output = output },")) "16: the temporary list only becomes the result after full validation"
Assert-True ($bridgeTests.Contains("One_malformed_synthetic_call_rejects_the_whole_response")) "16: a test pins the all-or-nothing rule"
Assert-True ($bridgeTests.Contains("An_ambiguous_patch_never_degrades_into_an_ordinary_function_call")) "16: a test pins that a bad synthetic call is never passed through"

# --- 17. Synthetic injection ----------------------------------------------
Assert-True ($bridgeTests.Contains("Synthetic_injection_without_an_active_bridge_fails_closed_end_to_end")) "17: the injection defence is pinned end to end"
Assert-True ($bridgeSource.Contains("ProviderAdapterErrors.InvalidResponse()")) "17: the fail-closed answer is the provider invalid_response error"

# --- 18-19. Preserved response fields and usage ---------------------------
Assert-True (-not ($bridgeCode -match 'Usage')) "19: the restore never rewrites usage"
Assert-True (-not ($bridgeCode -match 'Status =|Model =|ObjectType =|CreatedAt =')) "18: the restore never rewrites response-level fields"
Assert-True ($bridgeTests.Contains("Response_metadata_and_usage_are_preserved")) "18-19: a test pins metadata and usage"
Assert-True ($bridgeTests.Contains("ReasoningTokens = 3")) "19: the test covers the nested usage details"
Assert-True ($bridgeTests.Contains("CachedTokens = 5")) "19: the test covers cached tokens"

# --- 20. Patch content is never logged ------------------------------------
Assert-True (-not ($safeRequestRecord -match 'Patch|patch')) "20: the redacted request record has no patch field"
Assert-True (-not ($durableRequestLog -match 'Patch|patch')) "20: the durable request log has no patch field"
Assert-True (-not ($failureDiagnostic -match 'Patch|patch')) "20: the failure diagnostic has no patch field"
Assert-True (-not ($bridgeCode -match 'ILogger|Console\.|Debug\.|Trace\.|Log\(')) "20: the restore writes to no log sink"
Assert-True ($bridgeTests.Contains("PATCH_RESPONSE_DO_NOT_LOG_82731")) "20: the decoy patch sentinel is used in the fixtures"
Assert-True ($bridgeTests.Contains("Error_message_never_carries_the_patch_or_the_raw_arguments")) "20: a test pins the content-free error"

# --- 21. The Router never executes a patch --------------------------------
$bridgePathSources = $bridgeSource + $adapterSource
foreach ($forbidden in @('Process.Start', 'System.Diagnostics', 'git apply', 'patch.exe', 'powershell', 'PowerShell', 'cmd.exe', 'bash', 'File.WriteAllText', 'File.WriteAllBytes', 'Directory.CreateDirectory', 'CreateDirectory')) {
    Assert-True (-not ($bridgePathSources.Contains($forbidden))) "21: the restore path never calls $forbidden"
}
Assert-True (-not ($bridgeCode -match 'File\.|Directory\.')) "21: the restore performs no filesystem operation"
Assert-True ($bridgeSource.Contains("pure data transformation")) "21: the restore documents that it only converts data"

# --- 22. Generic providers unchanged --------------------------------------
foreach ($provider in $otherProviderAdapters) {
    $source = Read-SourceText "local-router/src/Router.ProviderAdapters.$($provider[0])/$($provider[1])"
    Assert-True (-not ($source -match 'SyntheticFunctionName|IsReservedSyntheticName')) "$($provider[0]): the adapter has no synthetic restore behaviour"
}
foreach ($provider in @(
        @('MiMo', 'MiMoFunctionWireTests.cs'),
        @('ModelStudio', 'ModelStudioFunctionWireTests.cs'),
        @('OpenRouter', 'OpenRouterFunctionWireTests.cs'),
        @('OpenAI', 'OpenAIFunctionWireTests.cs'))) {
    $text = Read-SourceText "local-router/tests/Router.ProviderAdapters.$($provider[0]).Tests/$($provider[1])"
    Assert-True ($text.Contains("Canonical_apply_patch_tool_fails_closed_and_never_reaches_the_transport")) "$($provider[0]): the B1b-1 fail-closed test is still present"
}

# --- 23. Generic response codec boundary preserved ------------------------
Assert-True ($codecSource.Contains("public static Result<CanonicalResponsesResponse, RouterError> DecodeResponse(byte[] json)")) "23: the generic decode entry point is unchanged"
Assert-True ($codecSource.Contains("JsonSerializer.Deserialize<CanonicalResponsesResponse>(json, ResponsesJson.Options)")) "23: the codec still decodes the canonical model directly"
Assert-True (-not ($codecSource -match 'ApplyPatch|SyntheticFunctionName|CustomToolCallResponseItem')) "23: the codec never restores a freeform call itself"
Assert-True ($baseAdapterSource.Contains("ResponsesProviderCodec.DecodeResponse(body)")) "23: the shared base still decodes through the generic codec"
Assert-True ($baseAdapterSource.Contains("invocation.Request.ApplyPatchTool is not null")) "23: the shared base still fails closed on a canonical custom tool"

# --- 24. SSE unchanged ----------------------------------------------------
Assert-True (-not ($bridgeCode -match 'SseStreamParser|SseWriter|CanonicalEvent|SseStream')) "24: the restore touches no SSE machinery"
Assert-True (-not ($adapterSource -match 'SseStreamParser|SseWriter|CanonicalEvent')) "24: the adapter touches no SSE machinery"
Assert-True (-not ($sseSource -match 'ApplyPatch|SyntheticFunctionName')) "24: the SSE parser has no apply_patch awareness"
Assert-True (-not ($requestBridgeSource -match 'SseStreamParser|SseWriter')) "24: the B1b-1 request bridge still touches no SSE machinery"

# --- 25. No provider network in this gate --------------------------------
$httpPrimitives = @(("Invoke-" + "RestMethod"), ("Invoke-" + "WebRequest"))
foreach ($primitive in $httpPrimitives) {
    Assert-True (-not ($validatorSource.Contains($primitive))) "25: this validator issues no $primitive call"
}
Assert-True (-not ($bridgeTests -match 'api\.deepseek\.com')) "25: the restore tests reference no live endpoint"
Assert-True ($bridgeTests.Contains("FakeProviderServer")) "25: provider coverage uses the fake provider transport only"

# --- 26. B1b-1 remains PASS -----------------------------------------------
$requestBridgeValidator = Join-Path $RepositoryRoot "tests/validate-dsr7c-apply-patch-request-bridge.ps1"
Assert-True (Test-Path -LiteralPath $requestBridgeValidator -PathType Leaf) "26: the B1b-1 validator is still present"
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$requestBridgeOutput = @(& pwsh -NoProfile -File $requestBridgeValidator -RepositoryRoot $RepositoryRoot 2>&1)
$requestBridgeExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction
Assert-True ($requestBridgeExit -eq 0) "26: the B1b-1 request bridge validator still passes (exit $requestBridgeExit)"
if ($requestBridgeExit -ne 0) {
    foreach ($line in $requestBridgeOutput | Where-Object { $_ -match '^FAIL' }) { Write-Host "      B1b-1: $line" -ForegroundColor Red }
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "DSR7-C apply_patch response bridge (FIX5-B1b-2) validation PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "DSR7-C apply_patch response bridge (FIX5-B1b-2) validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
exit 1
