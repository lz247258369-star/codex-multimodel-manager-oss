param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) {
    $passes.Add($Message)
    Write-Host "PASS  $Message" -ForegroundColor Green
}

function Fail([string]$Message) {
    $failures.Add($Message)
    Write-Host "FAIL  $Message" -ForegroundColor Red
}

function Require-NotContain([string]$Name, [string]$Text, [string]$Needle, [string]$Description) {
    if ($Text.Contains($Needle)) {
        Fail "$Name contains forbidden marker '$Needle': $Description"
    }
    else {
        Pass "$Name has no '$Needle' ($Description)"
    }
}

Write-Host "Repository: $RepositoryRoot" -ForegroundColor Cyan

$adapterProject = "local-router/src/Router.ProviderAdapters.OpenAI/Router.ProviderAdapters.OpenAI.csproj"
$testsProject = "local-router/tests/Router.ProviderAdapters.OpenAI.Tests/Router.ProviderAdapters.OpenAI.Tests.csproj"
foreach ($project in @($adapterProject, $testsProject)) {
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $project)) {
        Pass "LR-7A project exists: $project"
    }
    else {
        Fail "LR-7A project missing: $project"
    }
}

$sln = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/LocalRouter.sln")
foreach ($name in @("Router.ProviderAdapters.OpenAI", "Router.ProviderAdapters.OpenAI.Tests")) {
    if ($sln.Contains($name)) {
        Pass "LocalRouter.sln includes: $name"
    }
    else {
        Fail "LocalRouter.sln is missing: $name"
    }
}

$adapterDir = Join-Path $RepositoryRoot "local-router/src/Router.ProviderAdapters.OpenAI"
$testsDir = Join-Path $RepositoryRoot "local-router/tests/Router.ProviderAdapters.OpenAI.Tests"
$source = Get-ChildItem -LiteralPath $adapterDir -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$testSource = Get-ChildItem -LiteralPath $testsDir -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"

# 1. Exact Manager identity.
if ($source.Contains('ProviderId = "mm_openai_api"') -and -not ($source -match 'ProviderId = "(?!mm_openai_api)"')) {
    Pass "Adapter uses the exact Manager identity mm_openai_api"
}
else {
    Fail "Adapter must use the exact Manager identity mm_openai_api and no other provider identity"
}
if ($source.Contains('AdapterId = "adapter.provider.mm_openai_api.responses.v1"') -and $source.Contains('AdapterVersion = "1.0"') -and $source.Contains('ProtocolId = "protocol.openai.responses.v1"')) {
    Pass "Adapter identity/version/protocol are exact (adapter.provider.mm_openai_api.responses.v1 / 1.0 / protocol.openai.responses.v1)"
}
else {
    Fail "Adapter identity/version/protocol must be exact"
}

# 2. Only CODEX_OPENAI_API_KEY reference; no direct env read; no live HTTP; no ChatGPT account reuse.
foreach ($needle in @('Environment.GetEnvironmentVariable', 'auth.json', '.env', 'HttpClient', 'new SocketsHttpHandler', 'SendAsync', 'GetAsync', 'PostAsync', 'https://', 'access_token', 'refresh_token', 'session_token', 'account_token')) {
    Require-NotContain "LR-7A adapter source" $source $needle "direct env/secret/file/HTTP usage or ChatGPT account credential reuse"
}
foreach ($needle in @('OPENROUTER_API_KEY', 'MIMO_API_KEY', 'CODEX_DASHSCOPE_API_KEY', 'OPENAI_API_KEY')) {
    Require-NotContain "LR-7A adapter source" $source $needle "non-OpenAI-API secret reference"
}
if ($source.Contains('CODEX_OPENAI_API_KEY')) {
    Fail "LR-7A adapter source must reference CODEX_OPENAI_API_KEY only via SecretReference, never as a literal"
}
else {
    Pass "LR-7A adapter source has no CODEX_OPENAI_API_KEY literal (SecretReference only)"
}
foreach ($needle in @('chatgpt', 'openai_account', 'auth.json', '.env')) {
    if ($source -match [regex]::Escape($needle)) {
        Fail "LR-7A ChatGPT isolation contains forbidden marker '$needle': ChatGPT account/identity or secret-file coupling in adapter source"
    }
    else {
        Pass "LR-7A ChatGPT isolation has no '$needle' (ChatGPT account/identity or secret-file coupling)"
    }
}

# 3. No /models discovery or health probe.
foreach ($needle in @('/models', '"models"', 'ModelsAsync', 'health probe', 'HealthProbe', 'ping')) {
    Require-NotContain "LR-7A discovery" $source $needle "model discovery or health probe"
}

# 4. No Chat Completions / account protocol conversion.
foreach ($needle in @('chat/completions', 'ChatCompletions', 'CodingPlan', 'wire_api', 'anthropic')) {
    Require-NotContain "LR-7A protocol" $source $needle "Chat Completions/account/protocol conversion"
}

# 5. No arbitrary URL interpolation.
foreach ($needle in @('$"https://', '$"http://', 'String.Format', '${')) {
    Require-NotContain "LR-7A endpoint" $source $needle "arbitrary URL interpolation"
}

# 6. OpenAI API endpoint validator present and strict.
if ($source.Contains('class OpenAIEndpointValidator') -and $source.Contains('RequiredPath') -and $source.Contains('"/v1"')) {
    Pass "OpenAI API endpoint URL validator exists with strict /v1 base path"
}
else {
    Fail "OpenAI API endpoint URL validator must exist and enforce the /v1 base path"
}
if ($source.Contains('IsAllowedProductionHost') -and $source.Contains('api.openai.com')) {
    Pass "OpenAI API endpoint validator enforces an explicit host allowlist"
}
else {
    Fail "OpenAI API endpoint validator must enforce an explicit host allowlist"
}
if ($source -match 'chatgpt|chat\.openai\.com|auth\.openai\.com') {
    Fail "OpenAI API endpoint validator must never approve ChatGPT/account hosts"
}
else {
    Pass "OpenAI API endpoint validator never approves ChatGPT/account hosts"
}

# 7. No LR-7B/other vendor adapters.
foreach ($needle in @('adapter.provider.mm_mimo', 'adapter.provider.mm_openrouter', 'adapter.provider.mm_modelstudio', 'adapter.provider.chatgpt', 'adapter.provider.anthropic', 'deepseek_direct', 'qwen_direct')) {
    Require-NotContain "LR-7A scope" $source $needle "other vendor/account adapter or direct provider"
}

# 8. Secret allowlist exact mapping.
$secretAllowlist = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Secrets/EnvironmentSecretAllowlist.cs")
if ($secretAllowlist.Contains('public const string OpenAiApiKey = "CODEX_OPENAI_API_KEY"') -and $secretAllowlist.Contains('["mm_openai_api"] = OpenAiApiKey')) {
    Pass "EnvironmentSecretAllowlist maps mm_openai_api exactly to CODEX_OPENAI_API_KEY"
}
else {
    Fail "EnvironmentSecretAllowlist must map mm_openai_api exactly to CODEX_OPENAI_API_KEY"
}

# 9. chatgpt remains DIRECT_ONLY in the built-in provider table.
$builtInProviders = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Registries/BuiltInProviders.cs")
if ($builtInProviders.Contains('"chatgpt", ProviderAvailability.DirectOnly') -and -not $builtInProviders.Contains('"chatgpt", ProviderAvailability.Planned')) {
    Pass "chatgpt remains DIRECT_ONLY in the built-in provider table"
}
else {
    Fail "chatgpt must remain DIRECT_ONLY"
}
if ($builtInProviders.Contains('"chatgpt"') -and $builtInProviders.Contains('adapter.provider.chatgpt.responses.v1')) {
    Pass "chatgpt keeps its own account placeholder adapter identity"
}
else {
    Fail "chatgpt must keep its account placeholder adapter identity"
}
if ($builtInProviders.Contains('adapter.provider.mm_openai_api') -and $builtInProviders.Contains('"mm_openai_api"')) {
    Pass "mm_openai_api remains a separate identity in the built-in provider table"
}
else {
    Fail "mm_openai_api identity must exist separately from chatgpt"
}

# 10. Contract Kit reuse (no second suite) and tests exist.
if ($testSource.Contains('ProviderContractSuite') -and $testSource.Contains('OpenAIContractHarness')) {
    Pass "OpenAI API adapter inherits the reusable Provider Contract Suite"
}
else {
    Fail "OpenAI API adapter must inherit ProviderContractSuite via its harness"
}
if ($testSource.Contains('OpenAIEndpointValidatorTests') -and $testSource.Contains('OpenAIRequestMappingTests') -and $testSource.Contains('OpenAISecretTests')) {
    Pass "OpenAI endpoint validator, request mapping, and secret tests exist"
}
else {
    Fail "OpenAI endpoint validator, request mapping, and secret tests must exist"
}
if ($testSource.Contains('OpenAIContractTests') -and $testSource.Contains('OpenAIStreamTests') -and $testSource.Contains('OpenAIErrorFixtureTests') -and $testSource.Contains('OpenAIUsageTests')) {
    Pass "OpenAI contract, stream, error, and usage tests exist"
}
else {
    Fail "OpenAI contract, stream, error, and usage tests must exist"
}
if ($testSource.Contains('ChatGPT_account_identity_never_resolves_the_openai_api_adapter') -and $testSource.Contains('ChatGPT_provider_stays_direct_only_in_the_built_in_table')) {
    Pass "ChatGPT account identity isolation tests exist"
}
else {
    Fail "ChatGPT account identity isolation tests must exist"
}

# 11. No real secret-shaped values in adapter source or tests.
foreach ($needle in @('sk-', 'ghp_', 'github_pat_')) {
    Require-NotContain "LR-7A secrets" ($source + "`n" + $testSource) $needle "real credential format"
}

# 12. Defaults stay disabled.
$defaults = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/config/router.defaults.json") | ConvertFrom-Json
if ($defaults.local_router.enabled -eq $false -and $defaults.mode -eq "direct") {
    Pass "router.defaults.json remains disabled (mode=direct, enabled=false)"
}
else {
    Fail "router.defaults.json must keep mode=direct and local_router.enabled=false"
}

# 13. Dedicated validator is wired into the Development Gate workflow.
$workflow = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot ".github/workflows/ci.yml")
if ($workflow.Contains("tests/validate-local-router-openai.ps1")) {
    Pass "Development Gate workflow runs tests/validate-local-router-openai.ps1"
}
else {
    Fail "Development Gate workflow must run tests/validate-local-router-openai.ps1"
}

# 14. Protected production files must be untouched by this branch.
$protectedPatterns = @(
    '(?i)^installer/scripts/launch-controller-model\.ps1$',
    '(?i)^installer/scripts/switch-model\.ps1$',
    '(?i)^installer/scripts/desktop-chat-route\.ps1$',
    '(?i)^installer/scripts/desktop-chat-provider\.ps1$',
    '(?i)^installer/scripts/desktop-controller\.ps1$',
    '(?i)^installer/scripts/_registry\.ps1$',
    '(?i)^installer/scripts/_common\.ps1$',
    '(?i)^installer/scripts/visual-',
    '(?i)^installer/ui/',
    '(?i)^installer/model-catalog\.json$',
    '(?i)^skill/codex-multimodel-manager/scripts/launch-controller-model\.ps1$',
    '(?i)^skill/codex-multimodel-manager/scripts/_common\.ps1$',
    '(?i)^skill/codex-multimodel-manager/scripts/switch-model\.ps1$'
)
$changedFiles = @(& git -C $RepositoryRoot diff --name-only "main...HEAD" 2>$null)
$changedFiles += @(& git -C $RepositoryRoot ls-files --modified)
$changedFiles = @($changedFiles | Where-Object { $_ } | Sort-Object -Unique)
$protectedHits = @()
foreach ($file in $changedFiles) {
    foreach ($pattern in $protectedPatterns) {
        if ($file -match $pattern) {
            $protectedHits += $file
        }
    }
}
. (Join-Path $RepositoryRoot "tests/shared/protected-file-scope.ps1")
$protectedHits = @($protectedHits | Where-Object { -not (Test-Lr13ProtectedFileChangeAuthorized $RepositoryRoot $_) })
if ($protectedHits.Count -gt 0) {
    foreach ($hit in ($protectedHits | Sort-Object -Unique)) {
        Fail "Protected production file changed: $hit"
    }
}
else {
    Pass "No protected Direct/Desktop/V4/catalog files are modified"
}

Write-Host ""
Write-Host "Local Router OpenAI API adapter validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router OpenAI API adapter validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router OpenAI API adapter validation PASSED" -ForegroundColor Green
exit 0
