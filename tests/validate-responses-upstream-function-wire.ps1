param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR7-C-FIX5-B1a - RESPONSES UPSTREAM FUNCTION WIRE validation.
#
# Pre-existing gap: the outbound provider body was the canonical request
# serialized directly, and the canonical FunctionToolDefinition carries no
# provider discriminator, so every ordinary function tool went upstream without
# the Responses-required "type":"function". This validator pins the fix.

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

$wireSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderRequestWire.cs"
$codecSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderCodec.cs"
$baseSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesCompatibleProviderAdapterBase.cs"
$toolsSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/Tools.cs"
$codecTests = Read-SourceText "local-router/tests/Router.ProviderAdapters.Tests/ResponsesProviderCodecTests.cs"

# 1. The canonical contract is untouched.
Assert-True (-not ($toolsSource -match 'JsonPropertyName\("type"\)')) "1: FunctionToolDefinition gained no provider discriminator"
Assert-True ($toolsSource.Contains("public required string Name { get; init; }")) "1: the canonical function tool shape is unchanged"

# 2. The provider-wire DTO exists.
Assert-True ($wireSource.Contains("internal sealed record ResponsesFunctionToolWire")) "2: a provider-wire function tool DTO exists"
Assert-True ($wireSource.Contains("internal sealed record ResponsesProviderRequestWire")) "2: a provider-wire request DTO exists"

# 3. The discriminator is fixed by the Router, never client-supplied.
Assert-True ($wireSource.Contains('FunctionToolType = "function"')) "3: the wire function type literal is fixed"
Assert-True ($wireSource.Contains("Type = FunctionToolType")) "3: every projected tool takes the fixed type"
Assert-True (-not ($wireSource -match 'Type = tool\.Name|Type = request\.')) "3: the type is never derived from a request value"

# 4 + 5. EncodeRequest uses the projection; no direct canonical serialization remains.
Assert-True ($codecSource.Contains("ResponsesProviderRequestWire.FromCanonical(request)")) "4: EncodeRequest projects through the provider wire"
Assert-True (-not ($codecSource -match 'SerializeToUtf8Bytes\(request, ResponsesJson\.Options\)')) "5: the outbound body is no longer the canonical request"
Assert-True ($baseSource.Contains("ResponsesProviderCodec.EncodeRequest(upstreamRequest)")) "5: the shared base still encodes through the codec"

# 6. Route model mapping preserved.
Assert-True ($baseSource.Contains("Model = invocation.Route.ModelRoute.UpstreamModelId")) "6: the upstream model still comes only from the resolved route"
Assert-True (-not ($wireSource -match 'UpstreamModelId\s*=')) "6: the wire DTO never sets the model from anything but the projected request"

# 7. apply_patch still fails closed in the shared base.
Assert-True ($baseSource.Contains("invocation.Request.ApplyPatchTool is not null")) "7: the shared base still fails closed on a canonical custom tool"
Assert-True (-not ($wireSource -match 'ApplyPatch')) "7: the wire DTO carries no apply_patch state"

# 8-12. Five-provider structural coverage.
foreach ($provider in @(
        @('DeepSeek', 'DeepSeekFunctionWireTests.cs'),
        @('MiMo', 'MiMoFunctionWireTests.cs'),
        @('ModelStudio', 'ModelStudioFunctionWireTests.cs'),
        @('OpenRouter', 'OpenRouterFunctionWireTests.cs'),
        @('OpenAI', 'OpenAIFunctionWireTests.cs'))) {
    $path = "local-router/tests/Router.ProviderAdapters.$($provider[0]).Tests/$($provider[1])"
    Assert-True (Test-Path -LiteralPath (Join-Path $RepositoryRoot $path) -PathType Leaf) "$($provider[0]): an outbound-wire test exists"
    $text = Read-SourceText $path
    Assert-True ($text.Contains('tools[0].GetProperty("type").GetString()')) "$($provider[0]): the test asserts the type structurally"
    Assert-True ($text.Contains("JsonDocument.Parse(server.LastRequestBody!)")) "$($provider[0]): the test parses the captured body"
}

Assert-True ($codecTests.Contains("Multiple_tools_keep_their_order_and_each_carries_the_type")) "13: multiple tools keep their order"
Assert-True ($codecTests.Contains("Strict_false_is_preserved")) "14: strict is preserved"
Assert-True ($codecTests.Contains('Assert.Equal("object", tool.GetProperty("parameters").GetProperty("type").GetString())')) "15: parameters are preserved"
Assert-True ($codecTests.Contains("Non_tool_fields_are_projected_unchanged")) "16: ordinary request fields are preserved"
Assert-True ($codecSource.Contains("DecodeResponse")) "17: the response codec still exists (unchanged path)"

# 18. Response/stream machinery untouched by this gate.
Assert-True (-not ($wireSource -match 'DecodeResponse|SseStreamParser|CanonicalEvent')) "18: the wire DTO touches no response or SSE code"
Assert-True ($codecSource.Contains("public static Result<CanonicalResponsesResponse, RouterError> DecodeResponse(byte[] json)")) "18: the decode entry point is unchanged"

# 19. No secret-shaped field in the wire DTO.
# Comments explain what is deliberately absent, so the checks run on code lines.
$wireCode = ($wireSource -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(///|//)' }) -join "`n"
foreach ($forbidden in @('Authorization', 'ApiKey', 'Secret', 'Token', 'Cookie', 'ProxyAuth', 'Endpoint')) {
    Assert-True (-not ($wireCode -match ("(?i)\b" + $forbidden + "\b"))) "19: the wire DTO declares no $forbidden"
}

# 20. No logging schema change.
$safeRequestRecord = Read-SourceText "local-router/src/Router.Observability/SafeRequestRecord.cs"
Assert-True (-not ($safeRequestRecord -match 'FunctionTool|function_tool|ToolType')) "20: the redacted request record gained no tool-schema field"

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "Responses upstream function wire validation PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "Responses upstream function wire validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
exit 1
