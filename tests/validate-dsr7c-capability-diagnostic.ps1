param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR7-C-FIX1 - UNSUPPORTED CAPABILITY DIAGNOSTIC contract validation.
#
# The Responses parser fail-closes with unsupported_capability (HTTP 422) for
# deferred capabilities, but the error used to carry param = null, so an
# operator could see the code and not the field. This validator pins the fixed
# contract:
#
#   1. the legacy single-argument RouterError.UnsupportedCapability(requestId)
#      still produces param = null (byte/semantic compatible);
#   2. the explicit diagnostic helper exists and threads a safe field path;
#   3. every parser capability gate returns a SAFE path (static field name or
#      indexed path), never a request value;
#   4. no diagnostic path can carry a request value, tool name, prompt, URL or
#      identifier;
#   5. the ingress tests assert the HTTP 422 envelope carries code + param +
#      request_id;
#   6. the rejected request never reaches the response service (provider
#      attempt = 0);
#   7. the durable redacted request log schema gained no param/body/tool field;
#   8. nothing in this gate issues a real provider request.

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

$errorSource = Read-SourceText "local-router/src/Router.Core/Errors/RouterError.cs"
$parserSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ResponsesRequestParser.cs"
$coreTests = Read-SourceText "local-router/tests/Router.Core.Tests/Errors/RouterErrorTests.cs"
$parserTests = Read-SourceText "local-router/tests/Router.ClientAdapters.Responses.Tests/ResponsesRequestParserTests.cs"
$ingressTests = Read-SourceText "local-router/tests/Router.Ingress.Tests/IngressParsingCapabilityTests.cs"
$logSource = Read-SourceText "local-router/src/Router.Observability/SafeRequestRecord.cs"
$validatorSource = Get-Content -Raw -LiteralPath $PSCommandPath

# --- 1. Legacy semantics unchanged ------------------------------------------
Assert-True ($errorSource.Contains("public static RouterError UnsupportedCapability(string? requestId = null)")) "1: the legacy single-argument UnsupportedCapability(requestId) signature is unchanged"
Assert-True ($errorSource -match 'UnsupportedCapability\(string\? requestId = null\)\s*\r?\n\s*=> Create\(RouterErrorCode\.UnsupportedCapability, "The route cannot preserve the required semantics\.", null, requestId\);') "1: the legacy call still passes param=null"

# --- 2. Diagnostic helper ---------------------------------------------------
Assert-True ($errorSource.Contains("public static RouterError UnsupportedCapabilityAt(string capabilityParam, string? requestId = null)")) "2: the explicit diagnostic helper exists"
Assert-True ($errorSource -match 'UnsupportedCapabilityAt\(string capabilityParam, string\? requestId = null\)\s*\r?\n\s*=> Create\(RouterErrorCode\.UnsupportedCapability, "The route cannot preserve the required semantics\.", capabilityParam, requestId\);') "2: the helper threads the safe path and keeps code/message/retryable identical"
Assert-True (-not ($errorSource -match 'UnsupportedCapability\(string\? param')) "2: the legacy overload was not repurposed as a param overload"

# --- 3. Parser gates carry safe paths ---------------------------------------
$expectedPaths = [ordered]@{
    'UnsupportedCapabilityAt("background", requestId)' = "background"
    'UnsupportedCapabilityAt("store", requestId)' = "store"
    'UnsupportedCapabilityAt("previous_response_id", requestId)' = "previous_response_id"
    'UnsupportedCapabilityAt("modalities", requestId)' = "modalities"
    'UnsupportedCapabilityAt("tool_choice.type", requestId)' = "tool_choice.type"
    'UnsupportedCapabilityAt($"{param}.type", requestId)' = "tools[index].type / input[item].content[part].type"
    'UnsupportedCapabilityAt($"input[{index}].type", requestId)' = "input[index].type"
}
foreach ($entry in $expectedPaths.GetEnumerator()) {
    Assert-True ($parserSource.Contains($entry.Key)) "3: parser capability gate present for $($entry.Value)"
}
$parserDiagnostics = [regex]::Matches($parserSource, 'UnsupportedCapabilityAt\((?<arg>[^;]*?),\s*requestId\)')
# DSR7-C-FIX5-A added one more unclassified gate (an unbridgeable replayed custom
# tool call); the invariant is that every such gate names a safe field path.
Assert-True ($parserDiagnostics.Count -eq 9) "3: every unclassified parser capability gate uses the diagnostic helper (9 gates, found $($parserDiagnostics.Count))"
Assert-True ($parserSource.Contains("UnsupportedCapabilityAtClassified(")) "3: the tool-type gate uses the classified variant (DSR7-C-FIX3)"
Assert-True (-not ($parserSource -match 'RouterError\.UnsupportedCapability\(requestId\)')) "3: no parser gate still drops the field path"

# --- 4. No request value can reach the diagnostic ---------------------------
$unsafeArguments = @()
foreach ($match in $parserDiagnostics) {
    $argument = $match.Groups["arg"].Value
    $safe = ($argument -match '^"[\w\.]+"$') -or
            ($argument -eq '$"{param}.type"') -or
            ($argument -eq '$"input[{index}].type"')
    if (-not $safe) { $unsafeArguments += $argument }
}
Assert-True ($unsafeArguments.Count -eq 0) "4: every diagnostic argument is a safe field path, never a request value"
Assert-True (-not ($parserSource -match 'UnsupportedCapabilityAt\(type')) "4: the rejected tool/part type value is never passed as the diagnostic"
Assert-True (-not ($parserSource -match 'UnsupportedCapabilityAt\([^)]*property\.Name')) "4: a caller-supplied property name is never passed as the diagnostic"

# --- 5. HTTP 422 envelope contract in the ingress tests ---------------------
Assert-True ($ingressTests.Contains("Assert.Equal(HttpStatusCode.UnprocessableEntity, response.StatusCode)")) "5: the ingress test still pins HTTP 422"
Assert-True ($ingressTests.Contains('Assert.Contains("\"code\":\"" + expectedCode + "\"", responseBody, StringComparison.Ordinal)')) "5: the ingress test pins error.code"
Assert-True ($ingressTests.Contains('Assert.Contains("\"param\":\"" + expectedParam + "\"", responseBody, StringComparison.Ordinal)')) "5: the ingress test pins error.param"
Assert-True ($ingressTests.Contains('Assert.Contains("\"request_id\":\"req_", responseBody, StringComparison.Ordinal)')) "5: the ingress test pins error.request_id"
Assert-True ($parserTests.Contains('Assert.Equal("tools[0].type", error.Param)')) "5: the parser tests pin the safe path for a rejected tool"
Assert-True ($parserTests.Contains('Assert.Equal("tools[1].type", error.Param)')) "5: the parser tests pin the real array index, not a hard-coded [0]"
Assert-True ($parserTests.Contains('Assert.Equal("input[1].type", error.Param)')) "5: the parser tests pin the real input index"
Assert-True ($parserTests.Contains('Assert.Equal("input[0].content[1].type", error.Param)')) "5: the parser tests pin the indexed multimodal content path"
Assert-True ($coreTests.Contains('RouterError.UnsupportedCapabilityAt("tools[0].type", "req_456")')) "5: the core tests pin the diagnostic helper serialization"

# --- 6. The rejected request never reaches the service ----------------------
Assert-True ($ingressTests.Contains("Assert.Empty(service.Calls)")) "6: the ingress tests prove the response service was never invoked (provider attempt = 0)"
Assert-True ($ingressTests.Contains("Assert.DoesNotContain(`"web_search`", responseBody, StringComparison.Ordinal)")) "6: the ingress tests prove the rejected tool type value is never echoed"
Assert-True ($ingressTests.Contains("Assert.DoesNotContain(`"never_log_me`", responseBody, StringComparison.Ordinal)")) "6: the ingress tests prove the tool name is never echoed"
Assert-True ($ingressTests.Contains("Assert.DoesNotContain(`"DO_NOT_LEAK_12345`", responseBody, StringComparison.Ordinal)")) "6: the ingress tests prove prompt/argument content is never echoed"

# --- 7. Durable log schema is untouched -------------------------------------
Assert-True (-not ($logSource -match 'public[^\r\n]*\bParam\b')) "7: the redacted record still has no param field"
Assert-True (-not ($logSource -match 'public[^\r\n]*\bBody\b|\bRequestBody\b')) "7: the redacted record still has no request body field"
Assert-True ($logSource.Contains("public string? ErrorCode { get; init; }")) "7: the redacted record still carries only error_code"
Assert-True (-not ($logSource -match 'Tool(Name|Type|Arguments)')) "7: the redacted record still has no tool fields"

# --- 8. No provider request anywhere in this gate ---------------------------
$httpPrimitives = @(("Invoke-" + "RestMethod"), ("Invoke-" + "WebRequest"))
foreach ($primitive in $httpPrimitives) {
    Assert-True (-not $validatorSource.Contains($primitive)) "8: this validator issues no $primitive call"
    Assert-True (-not $parserTests.Contains($primitive)) "8: the parser tests issue no $primitive call"
}
Assert-True (-not ($ingressTests -match 'api\.deepseek\.com|dashscope|openrouter\.ai|xiaomimimo')) "8: the ingress tests reference no provider endpoint"
Assert-True (-not ($ingressTests -match 'probe-model\.ps1|discover-models\.ps1')) "8: no live probe or discovery entry point is involved"

# --- Capability support must not widen --------------------------------------
Assert-True ($parserSource.Contains('if (MultimodalPartTypes.Contains(type))')) "The multimodal rejection is still fail-closed"
Assert-True ($parserSource.Contains('if (!string.Equals(type, "function", StringComparison.Ordinal))')) "Non-function tools are still rejected"
Assert-True ($parserSource.Contains('m is "image" or "audio" or "video"')) "Non-text modalities are still rejected"

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "DSR7-C capability diagnostic validation PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "DSR7-C capability diagnostic validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
exit 1
