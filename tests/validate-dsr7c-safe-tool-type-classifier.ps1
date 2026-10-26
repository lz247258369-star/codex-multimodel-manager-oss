param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR7-C-FIX3 - SAFE TOOL TYPE CLASSIFIER contract validation.
#
# A rejected non-function tool type is request content, so it may never be
# stored. The Router instead maps it onto a FIXED taxonomy label and records
# only that label in the local diagnostic. This validator pins the contract:
#
#    1. the classifier is a closed fixed mapping
#    2. anything unknown collapses to unknown_non_function
#    3. no path can echo, truncate, hash or prefix the raw value
#    4. the internal class is JSON-ignored on the error envelope
#    5. the HTTP error JSON still has no class field
#    6. the internal class reaches RequestExecutionResult
#    7. the classified diagnostic is exactly the six v2 fields
#    8. only the tools[n].type path can carry a class
#    9. secret-shaped unknown types never leak
#   10. the durable request log schema is untouched
#   11. retention is still 64 files
#   12. nothing here issues a provider request
#   13. FIX6-B1 adds namespace/tool_search as exact, fixed labels only

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

$classifierSource = Read-SourceText "local-router/src/Router.Core/Support/SafeToolTypeClassifier.cs"
$errorSource = Read-SourceText "local-router/src/Router.Core/Errors/RouterError.cs"
$parserSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ResponsesRequestParser.cs"
$observerSource = Read-SourceText "local-router/src/Router.Ingress/IngressRequestObserver.cs"
$pipelineSource = Read-SourceText "local-router/src/Router.Ingress/Handlers/RequestPipeline.cs"
$responsesHandlerSource = Read-SourceText "local-router/src/Router.Ingress/Handlers/ResponsesHandler.cs"
$recordSource = Read-SourceText "local-router/src/Router.Observability/SafeFailureDiagnosticRecord.cs"
$logSource = Read-SourceText "local-router/src/Router.Observability/SafeFailureDiagnosticLog.cs"
$pathSource = Read-SourceText "local-router/src/Router.Observability/SafeFailureDiagnosticPath.cs"
$productionObserverSource = Read-SourceText "local-router/src/Router.Host/ProductionCompletionObserver.cs"
$safeRequestRecord = Read-SourceText "local-router/src/Router.Observability/SafeRequestRecord.cs"
$classifierTests = Read-SourceText "local-router/tests/Router.Core.Tests/Support/SafeToolTypeClassifierTests.cs"
$coreErrorTests = Read-SourceText "local-router/tests/Router.Core.Tests/Errors/RouterErrorTests.cs"
$parserTests = Read-SourceText "local-router/tests/Router.ClientAdapters.Responses.Tests/ResponsesRequestParserTests.cs"
$observabilityTests = Read-SourceText "local-router/tests/Router.Observability.Tests/SafeFailureDiagnosticTests.cs"
$hostTests = Read-SourceText "local-router/tests/Router.Core.Tests/Host/Dsr7cFailureDiagnosticTests.cs"
$validatorSource = Get-Content -Raw -LiteralPath $PSCommandPath

# --- 1. Fixed mapping -------------------------------------------------------
# DSR7-C-FIX6-B1: namespace/tool_search are appended to the fixed label set; the
# original twelve labels are unchanged.
foreach ($label in @("shell", "local_shell", "apply_patch", "custom", "mcp", "web_search", "web_search_preview", "file_search", "computer", "computer_use_preview", "code_interpreter", "image_generation", "namespace", "tool_search")) {
    Assert-True ($classifierSource.Contains(('"' + $label + '"'))) "1: fixed mapping declares the literal label $label"
}
Assert-True ($classifierSource.Contains('UnknownNonFunction = "unknown_non_function"')) "1: the fixed fallback label is declared"
Assert-True ($classifierSource.Contains("Dictionary<string, string> FixedMap")) "1: the mapping is a closed dictionary, not a rule engine"
Assert-True (-not ($classifierSource -match 'RegularExpressions|Regex')) "1: the classifier uses no regex capture that could echo input"

# --- 2 + 3. Unknown collapses; raw value can never escape -------------------
Assert-True ($classifierSource.Contains("? label") -and $classifierSource.Contains(": UnknownNonFunction")) "2: any unknown input collapses to the fixed fallback"
Assert-True (-not ($classifierSource -match 'return\s+rawToolType')) "3: the classifier never returns the raw value"
Assert-True (-not ($classifierSource -match 'ToLower|ToUpper')) "3: the classifier never normalizes the raw value into a label"
Assert-True (-not ($classifierSource -match 'Substring|\[\.\.')) "3: the classifier never truncates the raw value"
Assert-True (-not ($classifierSource -match 'Sha256|GetHashCode|HashData')) "3: the classifier never hashes the raw value"
Assert-True (-not ($classifierSource -match '\+\s*rawToolType|rawToolType\s*\+')) "3: the classifier never prefixes the raw value"
Assert-True ($classifierSource.Contains("public static bool IsKnownLabel")) "3: the emitted label can be re-validated against the allowlist"

# --- 4 + 5. HTTP envelope stays byte-semantic -------------------------------
Assert-True ($errorSource.Contains("[JsonIgnore]")) "4: the internal class property is JSON-ignored"
Assert-True ($errorSource.Contains("public string? SafeDiagnosticClass { get; init; }")) "4: the internal class property exists"
Assert-True ($errorSource.Contains("with { SafeDiagnosticClass = safeDiagnosticClass }")) "4: only the new classified helper sets it"
Assert-True ($errorSource.Contains("public static RouterError UnsupportedCapabilityAt(string capabilityParam, string? requestId = null)")) "4: the legacy two-argument helper is untouched"
Assert-True ($errorSource.Contains("public static RouterError UnsupportedCapabilityAtClassified(")) "4: the classified helper is a distinct signature (no reinterpretation)"
Assert-True ($coreErrorTests.Contains("Internal_diagnostic_class_is_never_serialized")) "5: a test pins that the class never serializes"
Assert-True ($coreErrorTests.Contains('Assert.DoesNotContain("safe_class", json, StringComparison.Ordinal)')) "5: the test asserts the envelope has no safe_class"
Assert-True ($coreErrorTests.Contains('Assert.DoesNotContain("local_shell", json, StringComparison.Ordinal)')) "5: the test asserts the label value never leaks"

# --- 6. The class reaches the internal result -------------------------------
Assert-True ($observerSource.Contains("public string? ErrorDiagnosticClass { get; init; }")) "6: RequestExecutionResult carries the class"
Assert-True ($pipelineSource.Contains("string? errorDiagnosticClass = null")) "6: RequestPipeline.Result accepts the class"
Assert-True ($pipelineSource.Contains("ErrorDiagnosticClass = errorDiagnosticClass,")) "6: RequestPipeline.Result assigns the class"
Assert-True ($responsesHandlerSource.Contains("errorDiagnosticClass: error.SafeDiagnosticClass")) "6: FailAsync passes error.SafeDiagnosticClass"
Assert-True (-not ($responsesHandlerSource -match 'CancelAsync[\s\S]{0,400}errorDiagnosticClass')) "6: cancel/success paths never invent a class"

# --- 7. Exact v2 record -----------------------------------------------------
Assert-True ($recordSource.Contains("ClassifiedSchemaVersion = 2")) "7: the classified schema version is 2"
Assert-True ($recordSource.Contains("public string? SafeClass { get; init; }")) "7: the record carries the fixed class"
# DSR7-C-FIX4 added a third tier (schema v3 for a rejected custom identity); the
# v1/v2 derivation below it is unchanged.
Assert-True ($recordSource.Contains("safeClass is null ? CurrentSchemaVersion : ClassifiedSchemaVersion")) "7: the version is implied by what the record carries, so a v1 file stays valid"
Assert-True ($observabilityTests.Contains("Classified_record_json_contains_exactly_the_six_allowed_fields")) "7: a test pins the six-field v2 JSON"
Assert-True ($observabilityTests.Contains('ExpectedClassifiedRecordFields')) "7: the test asserts the exact field set"
Assert-True (-not ($logSource -match 'Migrate|Rewrite|Repair')) "7: existing v1 files are never migrated or rewritten"

# --- 8. Only the tool-type path carries a class -----------------------------
Assert-True ($recordSource.Contains("SafeFailureDiagnosticPath.IsToolTypePath(safeParam)")) "8: the record requires the tools[n].type shape for a class"
Assert-True ($pathSource.Contains("public static bool IsToolTypePath")) "8: the tool-type path predicate exists"
Assert-True ($productionObserverSource.Contains("SafeFailureDiagnosticPath.IsToolTypePath(result.ErrorParam)")) "8: the observer routes only tool-type paths to the classified writer"
Assert-True ($productionObserverSource.Contains("SafeToolTypeClassifier.IsKnownLabel(result.ErrorDiagnosticClass)")) "8: the observer requires a known label before writing a class"
Assert-True ($productionObserverSource.Contains("_failureDiagnosticLog.TryWrite(result.RequestId, result.ErrorCode, result.ErrorParam)")) "8: non-tool failures keep the unclassified writer"
Assert-True ($observabilityTests.Contains("Classified_record_only_accepts_the_tool_type_path")) "8: a test pins that other paths cannot carry a class"
Assert-True ($hostTests.Contains("Non_tool_capability_failure_writes_the_unclassified_v1_diagnostic")) "8: an end-to-end test pins the v1 shape for a non-tool failure"

# --- 9. Secret-shaped unknowns never leak -----------------------------------
Assert-True ($classifierTests.Contains('InlineData("SUPER_SECRET_TOOL_TYPE")')) "9: classifier tests cover a secret-shaped unknown"
Assert-True ($classifierTests.Contains('InlineData("sk-test-DO_NOT_LEAK")')) "9: classifier tests cover an API-key-shaped unknown"
Assert-True ($classifierTests.Contains('InlineData("https://secret.example/private")')) "9: classifier tests cover a URL-shaped unknown"
Assert-True ($classifierTests.Contains("Assert.DoesNotContain(rawType, label, StringComparison.Ordinal)")) "9: classifier tests assert the raw value is never echoed"
Assert-True ($parserTests.Contains("Unknown_secret_shaped_tool_type_is_classified_without_leaking_it")) "9: parser tests pin the classified-but-not-leaked behaviour"
Assert-True ($observabilityTests.Contains("Classified_record_rejects_any_non_allowlisted_class")) "9: a record test drops any non-allowlisted class"

# --- 10. Durable request log untouched -------------------------------------
Assert-True (-not ($safeRequestRecord -match 'SafeClass|safe_class|ErrorDiagnosticClass')) "10: the redacted request record gained no class field"
Assert-True (-not ($logSource -match 'DurableRequestLog\s+\w+')) "10: the diagnostic log stays independent of the durable request log"
Assert-True ($hostTests.Contains("Assert.Equal(ExpectedDiagnosticFields, fields)")) "10: the v1 field set is still pinned"

# --- 11. Retention and atomicity unchanged ---------------------------------
Assert-True ($logSource.Contains("MaxRetainedFiles = 64")) "11: retention is still 64 files"
Assert-True ($logSource.Contains("MaxFileBytes = 4096")) "11: the per-file ceiling is still 4096 bytes"
Assert-True ($logSource.Contains("CreateTempPath") -and $logSource.Contains("MoveFile")) "11: writes are still atomic (temp + move)"
Assert-True ($observabilityTests.Contains("Retention_keeps_only_the_newest_64_files")) "11: a test pins the bounded retention"

# --- 12. No provider network ------------------------------------------------
$httpPrimitives = @(("Invoke-" + "RestMethod"), ("Invoke-" + "WebRequest"))
foreach ($primitive in $httpPrimitives) {
    Assert-True (-not $validatorSource.Contains($primitive)) "12: this validator issues no $primitive call"
}
Assert-True (-not ($hostTests -match 'api\.deepseek\.com|dashscope|openrouter\.ai|xiaomimimo')) "12: host tests reference no provider endpoint"
Assert-True (-not ($hostTests -match 'probe-model\.ps1|discover-models\.ps1')) "12: no live probe or discovery entry point is involved"

# --- 13. FIX6-B1 taxonomy recognition ---------------------------------------
# The two extra real Desktop types are recognised as EXACT fixed labels. They
# stay rejected: they are never mapped to a function, never silently dropped and
# never forwarded upstream.
Assert-True ($classifierSource.Contains('public const string Namespace = "namespace";')) "13: namespace is a declared fixed label"
Assert-True ($classifierSource.Contains('public const string ToolSearch = "tool_search";')) "13: tool_search is a declared fixed label"
Assert-True ($classifierSource.Contains('[Namespace] = Namespace,')) "13: namespace is wired into the closed FixedMap"
Assert-True ($classifierSource.Contains('[ToolSearch] = ToolSearch,')) "13: tool_search is wired into the closed FixedMap"
Assert-True (-not ($classifierSource -match '"namespace"\s*=>|"tool_search"\s*=>')) "13: neither label is remapped onto another type"
Assert-True ($parserSource.Contains('string safeClass = SafeToolTypeClassifier.Classify(type);')) "13: the parser still classifies, never accepts, an unknown non-function type"
Assert-True (-not ($parserSource -match '"namespace"|"tool_search"')) "13: the parser gains no special-case acceptance of the new labels"
Assert-True ($parserSource.Contains('return RouterError.UnsupportedCapabilityAtClassified(')) "13: the two labels still fail closed with unsupported_capability"

# The synthetic regression fixtures are hand-built from type/index only; the raw
# FIX6-A capture is never copied into the repository.
Assert-True ($classifierTests.Contains('InlineData("namespace", SafeToolTypeClassifier.Namespace)')) "13: classifier tests pin the exact namespace label"
Assert-True ($classifierTests.Contains('InlineData("tool_search", SafeToolTypeClassifier.ToolSearch)')) "13: classifier tests pin the exact tool_search label"
Assert-True ($classifierTests.Contains('InlineData("Namespace")')) "13: classifier tests pin a wrong-case namespace as unknown"
Assert-True ($classifierTests.Contains('InlineData("TOOL_SEARCH")')) "13: classifier tests pin a wrong-case tool_search as unknown"
Assert-True ($classifierTests.Contains('InlineData("tool_search ")')) "13: classifier tests pin a padded tool_search as unknown"
Assert-True ($parserTests.Contains('Desktop_13_tool_shape_classifies_namespace_at_its_structural_index')) "13: the 13-tool shape pins namespace at its real index"
Assert-True ($parserTests.Contains('Desktop_13_tool_shape_classifies_tool_search_at_its_structural_index')) "13: the 13-tool shape pins tool_search at its real index"
Assert-True ($parserTests.Contains('Desktop_15_tool_shape_classifies_namespace_at_its_structural_index')) "13: the 15-tool shape pins namespace at its real index"
Assert-True ($parserTests.Contains('Desktop_15_tool_shape_keeps_web_search_classification_unchanged')) "13: the 15-tool shape keeps web_search unchanged"
Assert-True ($parserTests.Contains('Desktop_namespace_and_tool_search_do_not_depend_on_a_fixed_index')) "13: a test proves the classification never depends on a fixed index"
Assert-True ($parserTests.Contains('Desktop_namespace_and_tool_search_stay_rejected_without_leaking')) "13: a test proves both labels stay rejected without leaking"
Assert-True ($parserTests.Contains('Desktop_function_and_custom_behaviour_is_unchanged')) "13: a test pins the unchanged function/custom behaviour"
Assert-True (-not ($parserTests -match 'codex_desktop_tool_taxonomy|capture_type')) "13: no captured Desktop taxonomy payload is checked into the tests"

# --- Fail-closed behaviour is unchanged -------------------------------------
Assert-True ($parserSource.Contains('if (!string.Equals(type, "function", StringComparison.Ordinal))')) "Non-function tools are still rejected"
Assert-True ($parserSource.Contains("UnsupportedCapabilityAtClassified(")) "The rejection carries the fixed class"
Assert-True ($classifierTests.Contains('Assert.Equal(15, SafeToolTypeClassifier.Labels.Count)')) "The taxonomy size is pinned at 15"

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "DSR7-C safe tool type classifier validation PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "DSR7-C safe tool type classifier validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
exit 1
