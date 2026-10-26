param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR7-C-FIX2 - LOCAL SAFE FAILURE DIAGNOSTIC contract validation.
#
# A client surface can swallow the HTTP error envelope's param field, so the
# Router also records the failing capability field path locally. This validator
# pins the contract that makes that safe:
#
#   1. RouterError.Param reaches RequestExecutionResult.ErrorParam
#   2. only the failure path supplies it (FailAsync)
#   3. the existing redacted request log schema is unchanged
#   4. only the exact allowlisted safe field paths are accepted
#   5. only unsupported_capability is ever diagnosed
#   6. the diagnostic record holds exactly five fields
#   7. no body/prompt/header/token/key/tool-value field exists anywhere
#   8. retention is bounded
#   9. a diagnostic write failure cannot change request semantics
#  10. nothing in this gate issues a provider request

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

$observerSource = Read-SourceText "local-router/src/Router.Ingress/IngressRequestObserver.cs"
$pipelineSource = Read-SourceText "local-router/src/Router.Ingress/Handlers/RequestPipeline.cs"
$responsesHandlerSource = Read-SourceText "local-router/src/Router.Ingress/Handlers/ResponsesHandler.cs"
$productionObserverSource = Read-SourceText "local-router/src/Router.Host/ProductionCompletionObserver.cs"
$hostSource = Read-SourceText "local-router/src/Router.Host/RouterHostBootstrap.cs"
$pathSource = Read-SourceText "local-router/src/Router.Observability/SafeFailureDiagnosticPath.cs"
$recordSource = Read-SourceText "local-router/src/Router.Observability/SafeFailureDiagnosticRecord.cs"
$logSource = Read-SourceText "local-router/src/Router.Observability/SafeFailureDiagnosticLog.cs"
$safeRequestRecord = Read-SourceText "local-router/src/Router.Observability/SafeRequestRecord.cs"
$observabilityTests = Read-SourceText "local-router/tests/Router.Observability.Tests/SafeFailureDiagnosticTests.cs"
$hostTests = Read-SourceText "local-router/tests/Router.Core.Tests/Host/Dsr7cFailureDiagnosticTests.cs"
$ingressTests = Read-SourceText "local-router/tests/Router.Ingress.Tests/IngressParsingCapabilityTests.cs"
$validatorSource = Get-Content -Raw -LiteralPath $PSCommandPath

# --- 1. RouterError.Param reaches RequestExecutionResult ---------------------
Assert-True ($observerSource.Contains("public string? ErrorParam { get; init; }")) "1: RequestExecutionResult exposes ErrorParam"
Assert-True ($pipelineSource.Contains("string? errorParam = null")) "1: RequestPipeline.Result accepts an optional errorParam"
Assert-True ($pipelineSource.Contains("ErrorParam = errorParam,")) "1: RequestPipeline.Result assigns ErrorParam"
Assert-True ($responsesHandlerSource.Contains("errorParam: error.Param")) "1: ResponsesHandler.FailAsync passes error.Param"

# --- 2. Fail path only ------------------------------------------------------
$failCount = ([regex]::Matches($responsesHandlerSource, 'errorParam: error\.Param')).Count
Assert-True ($failCount -eq 1) "2: exactly one call site supplies the diagnostic param (found $failCount)"
Assert-True (-not ($responsesHandlerSource -match 'CancelAsync[\s\S]{0,400}errorParam:')) "2: the cancel path never synthesizes an error param"
Assert-True ($responsesHandlerSource.Contains("RequestState.Failed, HttpStatusMapper.ToStatusCode(error), error.Code")) "2: the existing failure result shape is unchanged"

# --- 3. Existing redacted log schema unchanged ------------------------------
Assert-True (-not ($safeRequestRecord -match 'ErrorParam|SafeParam|safe_param|error_param')) "3: SafeRequestRecord/RedactedRequestRecord gained no param field"
Assert-True (-not ($logSource -match 'DurableRequestLog\s+\w+')) "3: the diagnostic log holds no DurableRequestLog dependency field"
Assert-True (-not ($productionObserverSource -match 'SafeFailureDiagnosticLog[\s\S]{0,200}DurableRequestLog')) "3: the two sinks are never composed into one payload"
Assert-True ($hostSource.Contains('"diagnostics"')) "3: diagnostics live in their own Router-owned directory"
Assert-True ($hostSource.Contains("SafeFailureDiagnosticLog(")) "3: the host composes the diagnostic log"
Assert-True ($hostSource.Contains("probe.FailureDiagnosticLog = failureDiagnosticLog")) "3: the host probe exposes the diagnostic log for tests"

# --- 4. Strict safe path allowlist ------------------------------------------
foreach ($allowed in @('"background"', '"store"', '"modalities"', '"previous_response_id"', '"tool_choice.type"')) {
    Assert-True ($pathSource.Contains($allowed)) "4: static safe path allowed: $allowed"
}
Assert-True ($pathSource.Contains('tools\[(?<index>[0-9]{1,6})\]\.type')) "4: tools[index].type pattern is allowlisted"
Assert-True ($pathSource.Contains('input\[(?<index>[0-9]{1,6})\]\.type')) "4: input[index].type pattern is allowlisted"
Assert-True ($pathSource.Contains('input\[(?<index>[0-9]{1,6})\]\.content\[(?<part>[0-9]{1,6})\]\.type')) "4: input[i].content[j].type pattern is allowlisted"
Assert-True ($pathSource.Contains("public static bool IsSafe(string? candidate)")) "4: the validator is fail-closed and non-throwing"
Assert-True ($pathSource.Contains("MaxLength = 64")) "4: an overlong path can never be accepted"
Assert-True ($pathSource.Contains("c is not ((>= 'a' and <= 'z')")) "4: characters outside the grammar are rejected before matching"
Assert-True ($observerSource -notmatch 'SafeFailureDiagnosticPath') "4: the ingress result type performs no path policy of its own"

# --- 5. Only unsupported_capability is diagnosed ----------------------------
Assert-True ($recordSource.Contains('UnsupportedCapabilityCode = "unsupported_capability"')) "5: the only diagnosable code is unsupported_capability"
Assert-True ($recordSource.Contains("!string.Equals(errorCode, UnsupportedCapabilityCode, StringComparison.Ordinal)")) "5: any other error code is dropped by the record factory"
Assert-True ($productionObserverSource.Contains("result.State != RequestState.Failed")) "5: only failed requests are considered"
Assert-True ($productionObserverSource.Contains("SafeFailureDiagnosticPath.IsSafe(result.ErrorParam)")) "5: the observer re-checks the safe path before writing"
Assert-True ($productionObserverSource.Contains("SafeFailureDiagnosticLog? failureDiagnosticLog = null")) "5: the observer's diagnostic sink is optional (existing tests unaffected)"

# --- 6. Exact five-field record --------------------------------------------
foreach ($field in @("SchemaVersion", "RequestId", "ErrorCode", "SafeParam", "CompletedAt")) {
    Assert-True ($recordSource.Contains("public required string $field") -or $recordSource.Contains("public required int $field")) "6: record declares $field"
}
Assert-True ($recordSource.Contains("ObservabilityJson.Options")) "6: the record serializes through the canonical observability JSON options"
Assert-True (([regex]::Matches($recordSource, "public required").Count) -eq 5) "6: the record declares exactly five required fields"

# --- 7. No content-bearing field anywhere ----------------------------------
# Only declared members count here: the source comments deliberately explain
# which request values are never stored.
$diagnosticSources = $pathSource + $recordSource + $logSource
$declaredMembers = [regex]::Matches($diagnosticSources, '(?m)^\s*public\s+[^\r\n=]*\b(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*(\{|=>|;|=)')
foreach ($forbidden in @("Prompt", "Instructions", "RequestBody", "Body", "Headers", "Token", "ApiKey", "Authorization", "ToolName", "Arguments", "Content")) {
    $hit = @($declaredMembers | Where-Object { $_.Groups["name"].Value -match ("(?i)" + [regex]::Escape($forbidden)) })
    Assert-True ($hit.Count -eq 0) "7: diagnostic sources declare no $forbidden member"
}
Assert-True (-not ($recordSource -match "TraceId|ClientId|ProviderId|ModelId")) "7: the record carries no correlation or identity fields"
Assert-True ($logSource.Contains("MaxFileBytes = 4096")) "7: a diagnostic file has a strict small size ceiling"

# --- 8. Bounded retention ---------------------------------------------------
Assert-True ($logSource.Contains("MaxRetainedFiles = 64")) "8: retention is bounded to 64 files"
Assert-True ($logSource.Contains("OrderByDescending")) "8: pruning removes the oldest files first"
Assert-True ($logSource.Contains('FilePrefix') -and $logSource.Contains('*.json')) "8: only Router-owned diagnostic files are enumerated or pruned"

# --- 9. Write failure cannot change request semantics -----------------------
Assert-True ($logSource.Contains("catch (Exception)")) "9: the diagnostic sink swallows I/O failures"
Assert-True ($logSource.Contains("return false;")) "9: a failed write reports false instead of throwing"
Assert-True ($hostTests.Contains("Unwritable_diagnostics_path_never_changes_request_semantics")) "9: a test pins that a blocked diagnostics path leaves HTTP semantics intact"
Assert-True ($hostTests.Contains("Assert.Equal(HttpStatusCode.UnprocessableEntity, response.StatusCode)")) "9: the blocked-path test still expects the 422 contract"
Assert-True ($observabilityTests.Contains("Write_failure_is_non_fatal_and_isolated")) "9: a test pins non-fatal write failure"

# --- 10. No provider request anywhere in this gate --------------------------
$httpPrimitives = @(("Invoke-" + "RestMethod"), ("Invoke-" + "WebRequest"))
foreach ($primitive in $httpPrimitives) {
    Assert-True (-not $validatorSource.Contains($primitive)) "10: this validator issues no $primitive call"
}
Assert-True (-not ($hostTests -match 'api\.deepseek\.com|dashscope|openrouter\.ai|xiaomimimo')) "10: host tests reference no provider endpoint"
Assert-True (-not ($hostTests -match 'probe-model\.ps1|discover-models\.ps1')) "10: no live probe or discovery entry point is involved"

# --- Evidence that the behaviour is actually tested --------------------------
Assert-True ($ingressTests.Contains('Assert.Equal("tools[0].type", result.ErrorParam)')) "Ingress test pins the failure path param"
Assert-True ($ingressTests.Contains("Assert.Null(result.ErrorParam)")) "Ingress test pins that success carries no param"
Assert-True ($hostTests.Contains("Unsupported_capability_writes_exactly_one_safe_diagnostic")) "Host test writes the diagnostic end to end"
Assert-True ($hostTests.Contains("Unsupported_parameter_writes_no_diagnostic")) "Host test proves other errors write nothing"
Assert-True ($hostTests.Contains("PROMPT_DO_NOT_LEAK_123")) "Host test data carries the prompt decoy"
Assert-True ($hostTests.Contains("LeakDecoys")) "Host test asserts no decoy value reaches the file"
Assert-True ($observabilityTests.Contains("Retention_keeps_only_the_newest_64_files")) "Observability test pins bounded retention"

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "DSR7-C safe failure diagnostic validation PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "DSR7-C safe failure diagnostic validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
exit 1
