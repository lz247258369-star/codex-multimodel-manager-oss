param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR7-C-FIX5-A - APPLY_PATCH CLIENT CONTRACT + CANONICAL MODEL validation.
#
# FIX5-A only builds the *client-side* contract: the canonical apply_patch custom
# tool, strict parsing, the reserved synthetic name, the replayed custom item
# shapes, and the DeepSeek-only bridge capability declaration. The upstream
# synthetic-function transform, the response bridge and the streaming bridge are
# FIX5-B; until they exist every provider path must fail closed.

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

$contractSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ApplyPatchCustomTool.cs"
$parserSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ResponsesRequestParser.cs"
$requestSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/CanonicalResponsesRequest.cs"
$inputSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ResponsesInputItem.cs"
$responseSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/CanonicalResponsesResponse.cs"
$converterSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ResponsesPolymorphicConverters.cs"
$deepSeekCapabilities = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekCapabilities.cs"
$baseAdapterSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesCompatibleProviderAdapterBase.cs"
$parserTests = Read-SourceText "local-router/tests/Router.ClientAdapters.Responses.Tests/ApplyPatchContractTests.cs"
$deepSeekTests = Read-SourceText "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchBridgeTests.cs"
$logSource = Read-SourceText "local-router/src/Router.Observability/SafeFailureDiagnosticLog.cs"
$safeRequestRecord = Read-SourceText "local-router/src/Router.Observability/SafeRequestRecord.cs"
$validatorSource = Get-Content -Raw -LiteralPath $PSCommandPath

# --- 1. Only the exact custom/apply_patch identity is accepted ---------------
Assert-True ($contractSource.Contains('ApplyPatchToolName = "apply_patch"')) "1: the accepted custom tool name is the exact literal apply_patch"
Assert-True ($contractSource.Contains('ClientToolType = "custom"')) "1: the accepted client tool type is custom"
Assert-True ($contractSource.Contains('RequiredFormatType = "grammar"')) "1: the required format.type is grammar"
Assert-True ($contractSource.Contains('RequiredFormatSyntax = "lark"')) "1: the required format.syntax is lark"
Assert-True ($parserSource.Contains("ParseApplyPatchCustomTool")) "1: the parser owns a dedicated apply_patch shape validator"
Assert-True ($parserTests.Contains("Valid_apply_patch_tool_becomes_a_distinct_canonical_type")) "1: a test pins the accepted shape"

# --- 2. Unknown custom tools stay rejected (FIX4 preserved) -----------------
Assert-True ($parserSource.Contains("SafeCustomToolDiagnostics.ClassifyRejectedCustomToolIdentity(tool)")) "2: the FIX4 identity extraction still decides rejections"
Assert-True ($parserSource.Contains("UnsupportedCapabilityAtClassifiedWithIdentity(")) "2: an unknown custom keeps the classified fail-closed error"
Assert-True ($parserTests.Contains("Unknown_custom_name_keeps_the_fix4_fail_closed_diagnostic")) "2: a test pins unknown-custom rejection"
Assert-True ($parserTests.Contains("Malformed_custom_identity_still_fails_closed_as_unknown_custom")) "2: a test pins the malformed-identity rejection"

# --- 3. Reserved synthetic name collision -----------------------------------
Assert-True ($contractSource.Contains('SyntheticFunctionName = "mm_apply_patch_bridge_v1"')) "3: the reserved synthetic name is declared once"
Assert-True ($contractSource.Contains("public static bool IsReservedSyntheticName")) "3: an exact reserved-name predicate exists"
Assert-True ($parserSource.Contains("IsReservedSyntheticName(name)")) "3: the parser rejects a client function using the reserved name"
Assert-True ($parserTests.Contains("Reserved_synthetic_name_is_rejected_on_a_client_function")) "3: a test pins the reserved-name collision"

# --- 4. Router never executes a patch --------------------------------------
$bridgeSources = $contractSource + $parserSource + $responseSource + $baseAdapterSource
foreach ($forbidden in @('Process.Start', 'git apply', 'patch.exe', 'File.WriteAllText', 'File.WriteAllBytes', 'Directory.CreateDirectory', 'apply_patch.exe')) {
    Assert-True (-not $bridgeSources.Contains($forbidden)) "4: the bridge path never calls $forbidden"
}
Assert-True (-not ($baseAdapterSource -match 'File\.|Directory\.|Process\.Start')) "4: the shared provider base performs no filesystem or process execution"

# --- 5. DeepSeek-only capability and fail-closed everywhere else ------------
Assert-True ($deepSeekCapabilities.Contains('ApplyPatchCompatBridge = "apply_patch_compat_bridge"')) "5: DeepSeek declares the explicit bridge capability"
Assert-True ($deepSeekCapabilities.Contains("SupportedCompatibilityBridges")) "5: the bridge capability is declared as its own set, not as plain tools"
Assert-True ($baseAdapterSource.Contains("invocation.Request.ApplyPatchTool is not null")) "5: the shared base fails closed on a canonical custom tool"
Assert-True ($baseAdapterSource.Contains("ProviderAdapterResult.Failed(RouterError.UnsupportedCapability())")) "5: the fail-closed answer is unsupported_capability"
Assert-True ($baseAdapterSource.Contains("The provider compatibility bridge that turns it into a Router-owned")) "5: the code documents that the transform is FIX5-B"
Assert-True ($deepSeekTests.Contains("Canonical_apply_patch_tool_is_not_forwarded_upstream_yet")) "5: a DeepSeek test proves nothing is sent upstream yet"
Assert-True ($deepSeekTests.Contains("Assert.Null(server.LastRequestBody)")) "5: the DeepSeek test proves no request reached the transport"

# --- 6. The custom definition is never serialized on the canonical wire -----
Assert-True ($requestSource.Contains("[JsonIgnore]")) "6: the canonical custom tool is JSON-ignored"
Assert-True ($requestSource.Contains("public ApplyPatchCustomToolDefinition? ApplyPatchTool { get; init; }")) "6: the canonical request carries a distinct apply_patch slot"
Assert-True ($parserTests.Contains("Custom_apply_patch_tool_never_serializes_on_the_canonical_wire")) "6: a test pins that no custom definition is serialized"
Assert-True ($parserSource.Contains("Tools = tools ?? []")) "6: ordinary function tools keep their own collection"
Assert-True ($parserTests.Contains("Ordinary_function_tools_are_unchanged_next_to_apply_patch")) "6: a test pins ordinary function tools alongside apply_patch"

# --- 7. Replay contract -----------------------------------------------------
Assert-True ($inputSource.Contains("public sealed record CustomToolCallInputItem")) "7: the replayed custom tool call is a canonical input item"
Assert-True ($inputSource.Contains("public sealed record CustomToolCallOutputInputItem")) "7: the replayed custom tool call output is a canonical input item"
Assert-True ($parserSource.Contains('"custom_tool_call" => ParseCustomToolCallItem')) "7: the parser dispatches the replayed custom tool call"
Assert-True ($parserSource.Contains('"custom_tool_call_output" => ParseCustomToolCallOutputItem')) "7: the parser dispatches the replayed custom tool call output"
Assert-True ($parserSource.Contains("customCallIds")) "7: the call-id pairing is tracked structurally"
Assert-True ($parserSource.Contains("custom tool call output has no matching custom tool call")) "7: an orphan output fails closed"
Assert-True ($parserTests.Contains("Custom_tool_call_output_requires_a_matching_custom_tool_call")) "7: a test pins the pairing and the orphan rejection"
Assert-True ($parserTests.Contains("Custom_tool_call_replay_parses_and_preserves_the_call_id")) "7: a test pins the call-id preservation"

# --- 8. Canonical response item --------------------------------------------
Assert-True ($responseSource.Contains("public sealed record CustomToolCallResponseItem")) "8: the canonical response has a custom tool call item"
Assert-True ($converterSource.Contains('case "custom_tool_call":')) "8: the polymorphic converter supports custom_tool_call"
Assert-True ($converterSource.Contains("CustomToolCallResponseItem")) "8: the converter materializes the custom tool call item"
Assert-True ($parserTests.Contains("Custom_tool_call_response_item_round_trips_through_the_canonical_json")) "8: a test pins serialization and deserialization"

# --- 9. No patch content in observability ----------------------------------
Assert-True (-not ($safeRequestRecord -match 'Patch|patch')) "9: the redacted request record has no patch field"
Assert-True (-not ($logSource -match 'Patch|patch')) "9: the diagnostic log has no patch field"
Assert-True ($contractSource.Contains("never logged")) "9: the contract documents that grammar/patch content is never logged"

# --- 10. FIX5-B scope discipline -------------------------------------------
Assert-True (-not ($parserSource -match 'mm_apply_patch_bridge_v1"\)')) "10: the parser never emits the synthetic function identity"
Assert-True (-not ($baseAdapterSource -match 'SyntheticFunctionName')) "10: the shared base performs no synthetic transform yet"
Assert-True (-not ($deepSeekCapabilities -match 'SupportedRequestSemantics[\s\S]{0,200}apply_patch_compat_bridge')) "10: the bridge capability does not widen ordinary request semantics"

# --- 11. No provider network in this gate ----------------------------------
$httpPrimitives = @(("Invoke-" + "RestMethod"), ("Invoke-" + "WebRequest"))
foreach ($primitive in $httpPrimitives) {
    Assert-True (-not $validatorSource.Contains($primitive)) "11: this validator issues no $primitive call"
}
Assert-True (-not ($deepSeekTests -match 'api\.deepseek\.com')) "11: the DeepSeek tests reference no live endpoint"
Assert-True ($deepSeekTests.Contains("FakeProviderServer")) "11: provider coverage uses the fake provider transport only"

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "DSR7-C apply_patch compat bridge (FIX5-A) validation PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "DSR7-C apply_patch compat bridge (FIX5-A) validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
exit 1
