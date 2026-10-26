param([Parameter(Mandatory = $false)][string]$RepositoryRoot = (Get-Location).Path)

# DSR7-C-FIX5-B1a2 - RESPONSES UPSTREAM TOOL_CHOICE WIRE validation.
# The canonical ToolChoice is semantic and used to leak its own shape upstream
# ({"kind":"auto"}). The provider wire now projects the Responses forms.

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]
function Pass([string]$m) { Write-Host "PASS  $m" -ForegroundColor Green }
function Fail([string]$m) { $failures.Add($m); Write-Host "FAIL  $m" -ForegroundColor Red }
function Assert-True([bool]$c, [string]$m) { if ($c) { Pass $m } else { Fail $m } }
function Read-SourceText([string]$p) { return (Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $p)) }

$wire = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderRequestWire.cs"
$wireCode = ($wire -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(///|//)' }) -join "`n"
$tools = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/Tools.cs"
$codec = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderCodec.cs"
$base = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesCompatibleProviderAdapterBase.cs"
$tests = Read-SourceText "local-router/tests/Router.ProviderAdapters.Tests/ResponsesProviderCodecTests.cs"

# 1 + 2. Canonical contract untouched.
Assert-True ($tools.Contains("public enum ToolChoiceKind")) "1: canonical ToolChoiceKind is unchanged"
Assert-True ($tools.Contains("public required ToolChoiceKind Kind { get; init; }")) "2: canonical ToolChoice is unchanged"
Assert-True (-not ($tools -match 'JsonPropertyName\("type"\)')) "2: no provider discriminator was pushed into the canonical contract"

# 3-6. Exact projection.
Assert-True ($wireCode.Contains("ResponsesToolChoiceWireConverter")) "3: a dedicated tool_choice wire converter exists"
Assert-True ($wireCode.Contains('writer.WriteStringValue("auto")')) "3: Auto projects to the string auto"
Assert-True ($wireCode.Contains('writer.WriteStringValue("none")')) "4: None projects to the string none"
Assert-True ($wireCode.Contains('writer.WriteStringValue("required")')) "5: Required projects to the string required"
Assert-True ($wireCode.Contains('writer.WriteString("type", FunctionToolName)')) "6: a named choice projects to {type:function}"
Assert-True ($wireCode.Contains('writer.WriteString("name", value.FunctionName)')) "6: the function name is projected verbatim"

# 7 + 8. Canonical-only field names never reach the wire.
Assert-True (-not ($wireCode -match 'WriteString\("kind"')) "7: kind is never written upstream"
Assert-True (-not ($wireCode -match 'WriteString\("function_name"')) "8: function_name is never written upstream"

# 9 + 10. Null guarded; invalid named choice fails closed.
Assert-True ($tests.Contains("Absent_tool_choice_is_omitted_and_never_defaulted")) "9: a test pins that null tool_choice is omitted"
Assert-True ($wireCode.Contains('throw new JsonException("A named function tool_choice requires a function name.")')) "10: a named choice without a name fails closed"
Assert-True ($wireCode.Contains('throw new JsonException("Unknown canonical tool_choice kind.")')) "10: an unknown kind fails closed"

# 11. B1a function tool wire preserved.
Assert-True ($wireCode.Contains("Type = FunctionToolType")) "11: the function tool discriminator is still fixed"
Assert-True ($tests.Contains("Function_tool_and_named_tool_choice_are_both_valid_together")) "11: a combined test pins both wires"

# 12-16. The five providers share this codec.
Assert-True ($base.Contains("ResponsesProviderCodec.EncodeRequest(upstreamRequest)")) "12-16: every provider encodes through the shared codec"
Assert-True ($codec.Contains("ResponsesProviderRequestWire.FromCanonical(request)")) "12-16: the projection is the only outbound path"
foreach ($provider in @("DeepSeek", "MiMo", "ModelStudio", "OpenRouter", "OpenAI")) {
    Assert-True (Test-Path -LiteralPath (Join-Path $RepositoryRoot "local-router/tests/Router.ProviderAdapters.$provider.Tests/$($provider)FunctionWireTests.cs") -PathType Leaf) "$provider`: captured outbound-body test present"
}

# 17. apply_patch still fails closed.
Assert-True ($base.Contains("invocation.Request.ApplyPatchTool is not null")) "17: the shared base still fails closed on a canonical custom tool"
Assert-True (-not ($wireCode -match 'ApplyPatch')) "17: the wire DTO carries no apply_patch state"

# 18 + 19. Response path untouched.
Assert-True ($codec.Contains("public static Result<CanonicalResponsesResponse, RouterError> DecodeResponse(byte[] json)")) "18: the response codec is unchanged"
Assert-True (-not ($wireCode -match 'SseStreamParser|CanonicalEvent|response.completed')) "19: the SSE/stream machinery is untouched"

# 20. No live provider traffic in this gate.
$validatorSource = Get-Content -Raw -LiteralPath $PSCommandPath
foreach ($primitive in @(("Invoke-" + "RestMethod"), ("Invoke-" + "WebRequest"))) {
    Assert-True (-not $validatorSource.Contains($primitive)) "20: this validator issues no $primitive call"
}
Assert-True (-not ($tests -match 'api\.deepseek\.com|dashscope|openrouter\.ai|xiaomimimo')) "20: the tests reference no provider endpoint"

Write-Host ""
if ($failures.Count -eq 0) { Write-Host "Responses upstream tool_choice wire validation PASSED" -ForegroundColor Green; exit 0 }
Write-Host "Responses upstream tool_choice wire validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($f in $failures) { Write-Host " - $f" -ForegroundColor Red }
exit 1
