param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR7-C-FIX4 - SAFE CUSTOM TOOL IDENTITY contract validation.
#
# A rejected `custom` tool is still request content, so only a FIXED identity
# label may be stored. This validator pins the contract:
#
#    1. the identity classifier is a fixed mapping
#    2. only the exact literal apply_patch is recognized
#    3. everything else is unknown_custom
#    4. no path can return the raw name (no fold/trim/contains/regex/hash)
#    5. the internal identity is JSON-ignored
#    6. the HTTP error JSON still has no identity field
#    7. the identity reaches RequestExecutionResult
#    8. the identified diagnostic is exactly the seven v3 fields
#    9. v1 diagnostics remain the five-field shape
#   10. v2 diagnostics remain the six-field shape
#   11. a duplicate/missing/non-string name fails safe
#   12. secret-shaped names never leak
#   13. the provider attempt count stays zero
#   14. the durable request log schema is untouched
#   15. the control plane schema is untouched
#   16. retention is still 64 files

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

$identitySource = Read-SourceText "local-router/src/Router.Core/Support/SafeCustomToolIdentityClassifier.cs"
$extractionSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/SafeCustomToolDiagnostics.cs"
$errorSource = Read-SourceText "local-router/src/Router.Core/Errors/RouterError.cs"
$parserSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ResponsesRequestParser.cs"
$observerSource = Read-SourceText "local-router/src/Router.Ingress/IngressRequestObserver.cs"
$pipelineSource = Read-SourceText "local-router/src/Router.Ingress/Handlers/RequestPipeline.cs"
$responsesHandlerSource = Read-SourceText "local-router/src/Router.Ingress/Handlers/ResponsesHandler.cs"
$recordSource = Read-SourceText "local-router/src/Router.Observability/SafeFailureDiagnosticRecord.cs"
$logSource = Read-SourceText "local-router/src/Router.Observability/SafeFailureDiagnosticLog.cs"
$productionObserverSource = Read-SourceText "local-router/src/Router.Host/ProductionCompletionObserver.cs"
$safeRequestRecord = Read-SourceText "local-router/src/Router.Observability/SafeRequestRecord.cs"
$identityTests = Read-SourceText "local-router/tests/Router.Core.Tests/Support/SafeCustomToolIdentityClassifierTests.cs"
$parserTests = Read-SourceText "local-router/tests/Router.ClientAdapters.Responses.Tests/ResponsesRequestParserTests.cs"
$observabilityTests = Read-SourceText "local-router/tests/Router.Observability.Tests/SafeFailureDiagnosticTests.cs"
$hostTests = Read-SourceText "local-router/tests/Router.Core.Tests/Host/Dsr7cFailureDiagnosticTests.cs"
$ingressTests = Read-SourceText "local-router/tests/Router.Ingress.Tests/IngressParsingCapabilityTests.cs"
$validatorSource = Get-Content -Raw -LiteralPath $PSCommandPath

# --- 1 + 2 + 3. Fixed mapping -----------------------------------------------
Assert-True ($identitySource.Contains('ApplyPatch = "apply_patch"')) "1: the recognized identity literal is declared"
Assert-True ($identitySource.Contains('UnknownCustom = "unknown_custom"')) "1: the fixed fallback identity is declared"
Assert-True ($identitySource.Contains("string.Equals(rawName, ApplyPatch, StringComparison.Ordinal)")) "2: only an exact ordinal apply_patch is recognized"
Assert-True ($identitySource.Contains("? ApplyPatch : UnknownCustom")) "3: every other input collapses to unknown_custom"
Assert-True ($identityTests.Contains('Assert.Equal(2, SafeCustomToolIdentityClassifier.Identities.Count)')) "3: the identity taxonomy size is pinned"

# --- 4. No raw-name escape path ---------------------------------------------
# Comments explain which transformations are deliberately absent, so the checks
# run against code lines only.
$identityCode = ($identitySource -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(///|//)' }) -join "`n"
Assert-True (-not ($identityCode -match 'return\s+rawName')) "4: the classifier never returns the raw name"
Assert-True (-not ($identityCode -match 'ToLower|ToUpper|\bTrim\b')) "4: the classifier never folds or trims the raw name"
Assert-True (-not ($identityCode -match 'rawName\.(Contains|StartsWith|EndsWith)')) "4: the classifier never substring-matches the raw name"
Assert-True (-not ($identityCode -match 'RegularExpressions|Regex\.|\bRegex\b')) "4: the classifier uses no regex capture"
Assert-True (-not ($identityCode -match 'Sha256|GetHashCode|HashData')) "4: the classifier never hashes the raw name"
Assert-True (-not ($identityCode -match 'Substring')) "4: the classifier never truncates the raw name"
Assert-True ($identityCode.Contains("string.Equals(rawName, ApplyPatch, StringComparison.Ordinal)")) "4: the only accepted comparison is an exact ordinal equality"

# --- 5 + 6. HTTP envelope unchanged -----------------------------------------
Assert-True ($errorSource.Contains("public string? SafeDiagnosticIdentity { get; init; }")) "5: the internal identity property exists"
Assert-True (([regex]::Matches($errorSource, '\[JsonIgnore\]')).Count -ge 2) "5: both internal diagnostic properties are JSON-ignored"
Assert-True ($errorSource.Contains("public static RouterError UnsupportedCapabilityAtClassifiedWithIdentity(")) "5: the identity-carrying helper is a distinct signature"
Assert-True ($errorSource.Contains("public static RouterError UnsupportedCapabilityAt(string capabilityParam, string? requestId = null)")) "6: the FIX1 helper is untouched"
Assert-True ($errorSource.Contains("public static RouterError UnsupportedCapabilityAtClassified(")) "6: the FIX3 helper is untouched"
Assert-True ($identityTests.Contains("Everything_else_collapses_to_unknown_custom")) "6: tests cover the collapse behaviour"

# --- 7. Identity reaches the internal result --------------------------------
Assert-True ($observerSource.Contains("public string? ErrorDiagnosticIdentity { get; init; }")) "7: RequestExecutionResult carries the identity"
Assert-True ($pipelineSource.Contains("string? errorDiagnosticIdentity = null")) "7: RequestPipeline.Result accepts the identity"
Assert-True ($pipelineSource.Contains("ErrorDiagnosticIdentity = errorDiagnosticIdentity,")) "7: RequestPipeline.Result assigns the identity"
Assert-True ($responsesHandlerSource.Contains("errorDiagnosticIdentity: error.SafeDiagnosticIdentity")) "7: FailAsync passes error.SafeDiagnosticIdentity"
# DSR7-C-FIX5-A accepts custom/apply_patch, so the end-to-end identity path is
# now pinned by the reject an unknown custom tool still takes (schema v3 is
# produced by the observer for a classified rejection).
Assert-True ($observabilityTests.Contains("Identified_log_writes_v3_and_never_leaks_an_unknown_name")) "7: a test pins the end-to-end identity write path"
Assert-True ($hostTests.Contains("Accepted_custom_apply_patch_tool_writes_no_diagnostic")) "7: a host test pins that an accepted apply_patch tool writes no capability diagnostic"

# --- 8 + 9 + 10. Exact schemas per version ----------------------------------
Assert-True ($recordSource.Contains("ClassifiedIdentitySchemaVersion = 3")) "8: the identified schema version is 3"
Assert-True ($recordSource.Contains("public string? SafeIdentity { get; init; }")) "8: the record carries the identity"
Assert-True ($observabilityTests.Contains("Identified_record_json_contains_exactly_the_seven_allowed_fields")) "8: a test pins the seven-field v3 JSON"
Assert-True ($observabilityTests.Contains("ExpectedIdentifiedRecordFields")) "8: the v3 field set is asserted exactly"
Assert-True ($observabilityTests.Contains("ExpectedRecordFields")) "9: the v1 five-field shape is still pinned"
Assert-True ($hostTests.Contains('Assert.Equal(1, document.RootElement.GetProperty("schema_version").GetInt32())')) "9: the v1 schema version is still asserted end to end"
Assert-True ($observabilityTests.Contains("Classified_record_json_contains_exactly_the_six_allowed_fields")) "10: the v2 shape is still pinned"
Assert-True ($recordSource.Contains("safeIdentity is not null") -and $recordSource.Contains("safeClass is null ? CurrentSchemaVersion : ClassifiedSchemaVersion")) "10: the version is derived from what the record carries, so v1/v2 stay v1/v2"
Assert-True (-not ($logSource -match 'Migrate|Rewrite|Repair')) "10: existing v1/v2 files are never migrated or rewritten"

# --- 11. Duplicate / malformed name fails safe ------------------------------
Assert-True ($extractionSource.Contains("nameCount > 1")) "11: a duplicate name is detected"
Assert-True ($extractionSource.Contains("return SafeCustomToolIdentityClassifier.UnknownCustom;")) "11: every malformed shape collapses to unknown_custom"
Assert-True ($extractionSource.Contains("nameKind != JsonValueKind.String")) "11: a non-string name is rejected"
Assert-True ($parserTests.Contains("Malformed_or_duplicate_custom_name_is_unknown_custom")) "11: tests cover missing/null/number/object/array/duplicate names"
Assert-True ($parserTests.Contains('{"type":"custom","name":"SUPER_SECRET_TOOL_NAME","name":"apply_patch"}')) "11: the duplicate case where a later value would match is covered"
Assert-True (-not $extractionSource.Contains("GetString()!")) "11: the extraction helper never assumes a value is present"

# --- 12. Secret-shaped names never leak -------------------------------------
Assert-True ($identityTests.Contains('InlineData("SUPER_SECRET_TOOL_NAME")')) "12: the identity tests cover a secret-shaped name"
Assert-True ($identityTests.Contains('InlineData("sk-test-DO_NOT_LEAK")')) "12: the identity tests cover an API-key-shaped name"
Assert-True ($identityTests.Contains('InlineData("https://secret.example/private")')) "12: the identity tests cover a URL-shaped name"
Assert-True ($identityTests.Contains("Assert.DoesNotContain(rawName, identity, StringComparison.Ordinal)")) "12: the tests assert the raw name is never echoed"
Assert-True ($parserTests.Contains('Assert.DoesNotContain(name, serialized, StringComparison.Ordinal)')) "12: the parser tests assert a rejected custom name never reaches the error"

# --- 13. Provider attempt stays zero ----------------------------------------
Assert-True ($ingressTests.Contains("Assert.Empty(service.Calls)")) "13: the ingress tests still prove the provider service is never invoked"
Assert-True ($parserSource.Contains('if (!string.Equals(type, "function", StringComparison.Ordinal))')) "13: custom tools are still rejected, never forwarded"
# DSR7-C-FIX5-A deliberately introduces exactly one apply_patch-specific canonical
# tool type; a generic custom-tool pass-through still does not exist.
Assert-True ($parserSource.Contains("ApplyPatchCustomToolDefinition")) "13: the only canonical custom tool is the apply_patch-specific type"
Assert-True (-not ($parserSource -match 'GenericCustomTool|AnyCustomTool')) "13: no generic custom-tool pass-through exists"

# --- 14 + 15. Other schemas untouched ---------------------------------------
Assert-True (-not ($safeRequestRecord -match 'SafeIdentity|safe_identity|SafeClass')) "14: the redacted request record gained no diagnostic field"
Assert-True (-not ($logSource -match 'DurableRequestLog\s+\w+')) "14: the diagnostic log stays independent of the durable request log"
Assert-True (-not ($productionObserverSource -match 'ControlPlane')) "15: the production observer adds nothing to the control plane"

# --- 16. Retention unchanged ------------------------------------------------
Assert-True ($logSource.Contains("MaxRetainedFiles = 64")) "16: retention is still 64 files"
Assert-True ($logSource.Contains("MaxFileBytes = 4096")) "16: the per-file ceiling is still 4096 bytes"
Assert-True ($logSource.Contains("TryWriteIdentified")) "16: the classified identity writer exists"
Assert-True ($productionObserverSource.Contains("SafeCustomToolIdentityClassifier.IsKnownIdentity(result.ErrorDiagnosticIdentity)")) "16: the observer requires a known identity before writing v3"

# --- No provider network ----------------------------------------------------
$httpPrimitives = @(("Invoke-" + "RestMethod"), ("Invoke-" + "WebRequest"))
foreach ($primitive in $httpPrimitives) {
    Assert-True (-not $validatorSource.Contains($primitive)) "No provider request: this validator issues no $primitive call"
}
Assert-True (-not ($hostTests -match 'api\.deepseek\.com|dashscope|openrouter\.ai|xiaomimimo')) "No provider request: host tests reference no provider endpoint"
Assert-True (-not ($hostTests -match 'probe-model\.ps1|discover-models\.ps1')) "No provider request: no live probe or discovery entry point is involved"

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "DSR7-C safe custom tool identity validation PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "DSR7-C safe custom tool identity validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
exit 1
