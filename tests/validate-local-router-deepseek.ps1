param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR1 validation - direct DeepSeek official provider adapter.
#
# Static, offline checks only: the C# test projects own the behavioral coverage
# (identity, endpoint validator, secret, request mapping, responses, streaming,
# error mapping, registry collision, unsupported protocol, cancellation). This
# validator proves the reviewed wiring is present and that the adapter carries no
# live-provider escape hatch.

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Pass $Message } else { Fail $Message }
}

function Read-FileText([string]$RelativePath) {
    $path = Join-Path $RepositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Fail "Missing required file: $RelativePath"
        return ""
    }
    return (Get-Content -Raw -LiteralPath $path)
}

$adapterRoot = "local-router/src/Router.ProviderAdapters.DeepSeek"
$testsRoot = "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests"

# --- Project layout ----------------------------------------------------------
foreach ($path in @(
        "$adapterRoot/Router.ProviderAdapters.DeepSeek.csproj",
        "$adapterRoot/DeepSeekCapabilities.cs",
        "$adapterRoot/DeepSeekEndpointValidator.cs",
        "$adapterRoot/DeepSeekProviderAdapter.cs",
        "$testsRoot/Router.ProviderAdapters.DeepSeek.Tests.csproj")) {
    Assert-True (Test-Path -LiteralPath (Join-Path $RepositoryRoot $path) -PathType Leaf) "Required DSR1 file exists: $path"
}
foreach ($name in @(
        "DeepSeekIdentityTests.cs",
        "DeepSeekEndpointValidatorTests.cs",
        "DeepSeekSecretTests.cs",
        "DeepSeekRequestMappingTests.cs",
        "DeepSeekResponsesTests.cs",
        "DeepSeekStreamTests.cs",
        "DeepSeekErrorFixtureTests.cs",
        "DeepSeekRegistryIsolationTests.cs",
        "DeepSeekCancellationTests.cs")) {
    Assert-True (Test-Path -LiteralPath (Join-Path $RepositoryRoot "$testsRoot/$name") -PathType Leaf) "Required DeepSeek test file exists: $name"
}

$adapterSource = Read-FileText "$adapterRoot/DeepSeekProviderAdapter.cs"
$capabilitiesSource = Read-FileText "$adapterRoot/DeepSeekCapabilities.cs"
$validatorSource = Read-FileText "$adapterRoot/DeepSeekEndpointValidator.cs"
$testsSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot $testsRoot) -File -Filter "*.cs" |
    ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"

# --- Exact identity ----------------------------------------------------------
Assert-True ($adapterSource.Contains('public const string AdapterId = "adapter.provider.deepseek.responses.v1"')) "Adapter id is exactly adapter.provider.deepseek.responses.v1"
Assert-True ($adapterSource.Contains('public const string AdapterVersion = "1.0"')) "Adapter version is exactly 1.0"
Assert-True ($adapterSource.Contains('public const string ProviderId = "deepseek"')) "Provider id is exactly deepseek"
Assert-True ($adapterSource.Contains('public const string ProtocolId = "protocol.openai.responses.v1"')) "Protocol id is exactly protocol.openai.responses.v1"
Assert-True ($capabilitiesSource.Contains('public const string UpstreamPath = "/responses"')) "Upstream path is exactly /responses"
Assert-True ($capabilitiesSource.Contains('public const string BaseUrlReference = "provider-config:deepseek.base_url"')) "Base URL reference is exactly provider-config:deepseek.base_url"
foreach ($alias in @("mm_deepseek", "deepseek_official", "mm_deepseek_api")) {
    Assert-True (-not $adapterSource.Contains($alias)) "Adapter declares no alias provider identity ($alias)"
}
Assert-True (-not $validatorSource.Contains('"deepseek_direct"')) "Adapter does not reuse the reserved placeholder identity"

# --- Endpoint contract -------------------------------------------------------
Assert-True ($validatorSource.Contains('private const string ProductionHost = "api.deepseek.com"')) "Endpoint validator pins the exact production host"
Assert-True ($validatorSource.Contains("UriSchemeHttps")) "Endpoint validator requires HTTPS"
Assert-True ($validatorSource.Contains('public const string RequiredPath = "/"')) "Endpoint validator accepts only the provider root base path"
Assert-True ($validatorSource.Contains("IsAllowedProductionHost(uri.Host)")) "Endpoint validator fails closed on unapproved hosts"
Assert-True ($validatorSource.Contains("string.IsNullOrEmpty(uri.UserInfo)")) "Endpoint validator rejects userinfo"
Assert-True ($validatorSource.Contains("string.IsNullOrEmpty(uri.Query)")) "Endpoint validator rejects query strings"
Assert-True ($validatorSource.Contains("RedirectPolicy.SameOriginOnly")) "Endpoint validator keeps same-origin redirect policy"

$executionEndpointsSource = Read-FileText "local-router/src/Router.Execution/RouterExecutionEndpoints.cs"
Assert-True ($executionEndpointsSource.Contains('public const string DeepSeekBaseUrlReference = "provider-config:deepseek.base_url"')) "Execution endpoint declares the DeepSeek base URL reference"
Assert-True ($executionEndpointsSource.Contains('[DeepSeekBaseUrlReference] = "https://api.deepseek.com"')) "Execution endpoint approves exactly https://api.deepseek.com"

$endpointContractTestSource = Read-FileText "local-router/tests/Router.Execution.Tests/RouterExecutionEndpointContractTests.cs"
Assert-True ($endpointContractTestSource.Contains('"https://api.deepseek.com/responses"')) "Final endpoint contract locks https://api.deepseek.com/responses"
Assert-True ($endpointContractTestSource.Contains('RouterExecutionEndpoints.DeepSeekBaseUrlReference')) "Final endpoint contract uses the DeepSeek base URL reference"

# --- Secret contract ---------------------------------------------------------
$allowlistSource = Read-FileText "local-router/src/Router.Secrets/EnvironmentSecretAllowlist.cs"
Assert-True ($allowlistSource.Contains('public const string DeepSeekApiKey = "DEEPSEEK_API_KEY"')) "Allowlist declares DEEPSEEK_API_KEY"
Assert-True ($allowlistSource.Contains('["deepseek"] = DeepSeekApiKey')) "Allowlist maps deepseek -> DEEPSEEK_API_KEY exactly once"
foreach ($other in @("mm_mimo", "mm_openrouter", "mm_openai_api", "mm_modelstudio")) {
    Assert-True (-not $allowlistSource.Contains(('["' + $other + '"] = DeepSeekApiKey'))) "Allowlist does not map $other to DEEPSEEK_API_KEY"
}

# --- Production execution composition ---------------------------------------
$defaultsSource = Read-FileText "local-router/src/Router.Execution/RouterExecutionDefaults.cs"
Assert-True ($defaultsSource.Contains("new DeepSeekProviderAdapter()")) "Production composition registers new DeepSeekProviderAdapter()"
$executionProjectSource = Read-FileText "local-router/src/Router.Execution/Router.Execution.csproj"
Assert-True ($executionProjectSource.Contains("Router.ProviderAdapters.DeepSeek.csproj")) "Router.Execution references the DeepSeek adapter project"

$solutionSource = Read-FileText "local-router/LocalRouter.sln"
Assert-True ($solutionSource.Contains("src\Router.ProviderAdapters.DeepSeek\Router.ProviderAdapters.DeepSeek.csproj")) "LocalRouter.sln includes the DeepSeek adapter project"
Assert-True ($solutionSource.Contains("tests\Router.ProviderAdapters.DeepSeek.Tests\Router.ProviderAdapters.DeepSeek.Tests.csproj")) "LocalRouter.sln includes the DeepSeek test project"

# --- Config / schema provider identity --------------------------------------
$configValidatorSource = Read-FileText "local-router/src/Router.Configuration/RouterConfigValidator.cs"
Assert-True ($configValidatorSource.Contains('"deepseek"')) "Config validator explicitly accepts deepseek"
Assert-True ($configValidatorSource.Contains("KnownProviderIds")) "Config validator keeps the positive provider allowlist"
$builtInSource = Read-FileText "local-router/src/Router.Registries/BuiltInProviders.cs"
Assert-True ($builtInSource.Contains('Add(table, "deepseek", ProviderAvailability.Planned, "adapter.provider.deepseek.responses.v1")')) "Built-in identity table declares deepseek with the exact adapter id"
Assert-True ($builtInSource.Contains('Add(table, "deepseek_direct", ProviderAvailability.Placeholder')) "Reserved placeholder identity is preserved, not reused"

$routerConfigSchema = Read-FileText "local-router/schemas/router-config.v1.schema.json"
$deepSeekEnumCount = ([regex]::Matches($routerConfigSchema, '"enum": \["chatgpt", "mm_openai_api", "mm_modelstudio", "mm_openrouter", "mm_mimo", "deepseek"\]')).Count
Assert-True ($deepSeekEnumCount -eq 2) "Router config schema accepts deepseek in provider_routes and model_routes exactly"

$unknownProviderFixture = Read-FileText "tests/fixtures/local-router/v1/config/invalid/bad-provider.json"
Assert-True ($unknownProviderFixture.Contains('"mm_mystery"')) "Unknown-provider fixture still uses an unapproved provider id"
Assert-True (-not $unknownProviderFixture.Contains('"deepseek"')) "Unknown-provider fixture does not accidentally become approved"

# --- No live-provider escape hatch ------------------------------------------
$allDsrSource = $adapterSource + "`n" + $capabilitiesSource + "`n" + $validatorSource
foreach ($forbidden in @("experimental_bearer_token", "Invoke-RestMethod", "Invoke-WebRequest", "HttpClient", "api.xiaomimimo.com", "openrouter.ai", "dashscope")) {
    Assert-True (-not $allDsrSource.Contains($forbidden)) "Adapter source contains no $forbidden"
}
Assert-True (-not $allDsrSource.Contains("deepseek-v4-flash")) "Adapter never hardcodes the legacy client slug alias"
Assert-True (-not ($adapterSource -match 'switch\s*\(')) "Adapter contains no model-name switch or alias table"
Assert-True (-not $adapterSource.Contains("fallback")) "Adapter contains no cross-provider fallback logic"
Assert-True ($testsSource.Contains("deepseek-flash")) "Tests cover the official deepseek-flash upstream id"
Assert-True ($testsSource.Contains("deepseek-v4-pro")) "Tests cover the official deepseek-v4-pro upstream id"

# --- Canonical Responses max_output_tokens contract --------------------------
# This is a public protocol capability, never a DeepSeek-only special case: the
# guard proves the canonical contract keeps supporting it so it can never be
# silently demoted back to UnsupportedParameter.
$canonicalRequestSource = Read-FileText "local-router/src/Router.ClientAdapters.Responses/CanonicalResponsesRequest.cs"
$canonicalParserSource = Read-FileText "local-router/src/Router.ClientAdapters.Responses/ResponsesRequestParser.cs"
$canonicalParserTests = Read-FileText "local-router/tests/Router.ClientAdapters.Responses.Tests/ResponsesRequestParserTests.cs"
$canonicalSerializationTests = Read-FileText "local-router/tests/Router.ClientAdapters.Responses.Tests/CanonicalSerializationTests.cs"
$deepSeekMappingTests = Read-FileText "$testsRoot/DeepSeekRequestMappingTests.cs"

Assert-True ($canonicalRequestSource.Contains("public int? MaxOutputTokens { get; init; }")) "Canonical Responses request declares MaxOutputTokens"
Assert-True ($canonicalRequestSource.Contains('[JsonPropertyName("max_output_tokens")]')) "Canonical request pins the exact max_output_tokens wire name"
Assert-True ($canonicalParserSource.Contains('case "max_output_tokens":')) "Canonical parser handles max_output_tokens explicitly"
Assert-True ($canonicalParserSource.Contains("ParseMaxOutputTokens")) "Canonical parser validates max_output_tokens instead of rejecting it"
Assert-True ($canonicalParserSource.Contains("max_output_tokens must be greater than zero")) "Canonical parser rejects zero and negative budgets"
Assert-True ($canonicalParserSource.Contains('"max_output_tokens",')) "Canonical parser lists max_output_tokens as a supported root field"
Assert-True (-not $canonicalParserSource.Contains('UnsupportedParameter("max_output_tokens"')) "Canonical parser never reports max_output_tokens as an unsupported parameter"
Assert-True ($canonicalParserSource.Contains("return RouterError.UnsupportedParameter(property.Name, requestId);")) "Canonical parser still fails closed on genuinely unknown root fields"
Assert-True ($canonicalParserTests.Contains("Max_output_tokens_positive_integer_is_parsed")) "Canonical parser tests cover a valid integer budget"
Assert-True ($canonicalParserTests.Contains("Max_output_tokens_invalid_values_fail_closed")) "Canonical parser tests cover invalid budgets"
Assert-True ($canonicalParserTests.Contains("Neighbouring_unknown_field_still_fails_closed")) "Canonical parser tests prove unknown neighbours still fail closed"
Assert-True ($canonicalSerializationTests.Contains("Request_max_output_tokens_round_trips_as_an_integer")) "Canonical serialization tests cover the integer round trip"
Assert-True ($canonicalSerializationTests.Contains("Absent_max_output_tokens_is_not_invented")) "Canonical serialization tests prove no default is invented"
Assert-True ($deepSeekMappingTests.Contains("Max_output_tokens_is_passed_through_unchanged")) "DeepSeek mapping tests cover upstream pass-through"
Assert-True ($deepSeekMappingTests.Contains('InlineData("deepseek-flash")')) "Pass-through is covered for deepseek-flash"
Assert-True ($deepSeekMappingTests.Contains('InlineData("deepseek-v4-pro")')) "Pass-through is covered for deepseek-v4-pro"
Assert-True ($deepSeekMappingTests.Contains("Absent_max_output_tokens_is_not_added_upstream")) "DeepSeek tests prove an absent budget is not added upstream"

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Local Router DeepSeek adapter validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}
Write-Host "Local Router DeepSeek adapter validation PASSED" -ForegroundColor Green
exit 0
