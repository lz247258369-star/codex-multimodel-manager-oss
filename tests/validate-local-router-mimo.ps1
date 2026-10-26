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

$adapterProject = "local-router/src/Router.ProviderAdapters.MiMo/Router.ProviderAdapters.MiMo.csproj"
$testsProject = "local-router/tests/Router.ProviderAdapters.MiMo.Tests/Router.ProviderAdapters.MiMo.Tests.csproj"
foreach ($project in @($adapterProject, $testsProject)) {
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $project)) {
        Pass "LR-7B project exists: $project"
    }
    else {
        Fail "LR-7B project missing: $project"
    }
}

$sln = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/LocalRouter.sln")
foreach ($name in @("Router.ProviderAdapters.MiMo", "Router.ProviderAdapters.MiMo.Tests")) {
    if ($sln.Contains($name)) {
        Pass "LocalRouter.sln includes: $name"
    }
    else {
        Fail "LocalRouter.sln is missing: $name"
    }
}

$adapterDir = Join-Path $RepositoryRoot "local-router/src/Router.ProviderAdapters.MiMo"
$testsDir = Join-Path $RepositoryRoot "local-router/tests/Router.ProviderAdapters.MiMo.Tests"
$source = Get-ChildItem -LiteralPath $adapterDir -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$testSource = Get-ChildItem -LiteralPath $testsDir -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"

# 1. Exact Manager identity.
if ($source.Contains('ProviderId = "mm_mimo"') -and -not ($source -match 'ProviderId = "(?!mm_mimo)"')) {
    Pass "Adapter uses the exact Manager identity mm_mimo"
}
else {
    Fail "Adapter must use the exact Manager identity mm_mimo and no other provider identity"
}
if ($source.Contains('AdapterId = "adapter.provider.mm_mimo.responses.v1"') -and $source.Contains('AdapterVersion = "1.0"') -and $source.Contains('ProtocolId = "protocol.openai.responses.v1"')) {
    Pass "Adapter identity/version/protocol are exact (adapter.provider.mm_mimo.responses.v1 / 1.0 / protocol.openai.responses.v1)"
}
else {
    Fail "Adapter identity/version/protocol must be exact"
}

# 2. Only MIMO_API_KEY reference; no direct env read; no live HTTP.
foreach ($needle in @('Environment.GetEnvironmentVariable', 'auth.json', '.env', 'HttpClient', 'new SocketsHttpHandler', 'SendAsync', 'GetAsync', 'PostAsync', 'https://', 'access_token', 'refresh_token', 'session_token', 'account_token')) {
    Require-NotContain "LR-7B adapter source" $source $needle "direct env/secret/file/HTTP usage"
}
foreach ($needle in @('OPENROUTER_API_KEY', 'CODEX_DASHSCOPE_API_KEY', 'CODEX_OPENAI_API_KEY', 'OPENAI_API_KEY')) {
    Require-NotContain "LR-7B adapter source" $source $needle "non-MiMo secret reference"
}
if ($source.Contains('MIMO_API_KEY')) {
    Fail "LR-7B adapter source must reference MIMO_API_KEY only via SecretReference, never as a literal"
}
else {
    Pass "LR-7B adapter source has no MIMO_API_KEY literal (SecretReference only)"
}
foreach ($needle in @('chatgpt', 'openai_account', 'auth.json', '.env')) {
    if ($source -match [regex]::Escape($needle)) {
        Fail "LR-7B isolation contains forbidden marker '$needle': ChatGPT/account/secret-file coupling in adapter source"
    }
    else {
        Pass "LR-7B isolation has no '$needle' (ChatGPT/account/secret-file coupling)"
    }
}

# 3. No /models discovery or active health probe.
foreach ($needle in @('/models', '"models"', 'ModelsAsync', 'health probe', 'HealthProbe', 'ping')) {
    Require-NotContain "LR-7B discovery" $source $needle "model discovery or health probe"
}

# 4. No Chat Completions / protocol conversion.
foreach ($needle in @('chat/completions', 'ChatCompletions', 'CodingPlan', 'wire_api', 'anthropic')) {
    Require-NotContain "LR-7B protocol" $source $needle "Chat Completions/protocol conversion"
}

# 5. No arbitrary URL interpolation or automatic endpoint selection.
foreach ($needle in @('$"https://', '$"http://', 'String.Format', '${', 'GetEnvironmentVariable')) {
    Require-NotContain "LR-7B endpoint" $source $needle "arbitrary URL interpolation"
}

# 6. MiMo endpoint validator present, strict and explicit.
if ($source.Contains('class MiMoEndpointValidator') -and $source.Contains('RequiredPath') -and $source.Contains('"/v1"')) {
    Pass "MiMo endpoint URL validator exists with strict /v1 base path"
}
else {
    Fail "MiMo endpoint URL validator must exist and enforce the /v1 base path"
}
if ($source.Contains('IsAllowedProductionHost') -and $source.Contains('api.xiaomimimo.com') -and $source.Contains('token-plan-cn.xiaomimimo.com')) {
    Pass "MiMo endpoint validator enforces an explicit host allowlist"
}
else {
    Fail "MiMo endpoint validator must enforce an explicit host allowlist"
}
if ($source -match 'auto\.xiaomimimo|cn-[a-z]+\.xiaomimimo|\{region\}') {
    Fail "MiMo endpoint validator must never allow automatic region/endpoint selection"
}
else {
    Pass "MiMo endpoint validator never auto-selects regions or endpoints"
}

# 7. No LR-8+ leak or other adapter registration.
foreach ($needle in @('CircuitBreaker', 'ExecuteRetry', 'ExecuteFailover', 'RetryEngine', 'FailoverEngine', 'ProtocolConverter', 'ChatCompletions')) {
    Require-NotContain "LR-7B scope" $source $needle "LR-8+/policy/conversion engine leak"
}
foreach ($needle in @('adapter.provider.mm_openrouter', 'adapter.provider.mm_modelstudio', 'adapter.provider.mm_openai_api', 'adapter.provider.chatgpt', 'adapter.provider.anthropic', 'adapter.provider.mimo', 'adapter.provider.xiaomi_mimo', 'deepseek_direct', 'qwen_direct')) {
    Require-NotContain "LR-7B adapter scope" $source $needle "other provider adapter or second MiMo identity"
}

# 8. Secret allowlist exact mapping.
$secretAllowlist = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Secrets/EnvironmentSecretAllowlist.cs")
if ($secretAllowlist.Contains('public const string MimoApiKey = "MIMO_API_KEY"') -and $secretAllowlist.Contains('["mm_mimo"] = MimoApiKey')) {
    Pass "EnvironmentSecretAllowlist maps mm_mimo exactly to MIMO_API_KEY"
}
else {
    Fail "EnvironmentSecretAllowlist must map mm_mimo exactly to MIMO_API_KEY"
}

# 9. Built-in provider table keeps exactly one mm_mimo identity and no aliases.
$builtInProviders = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Registries/BuiltInProviders.cs")
if ($builtInProviders.Contains('"mm_mimo", ProviderAvailability.Planned') -and $builtInProviders.Contains('adapter.provider.mm_mimo.responses.v1')) {
    Pass "mm_mimo remains one exact built-in provider identity"
}
else {
    Fail "BuiltInProviders must keep the exact mm_mimo identity"
}
if ($builtInProviders -match '"(mimo|xiaomi_mimo|mimo_router|mimo_api_v2)", ProviderAvailability') {
    Fail "BuiltInProviders must not define a second MiMo provider identity"
}
else {
    Pass "No second MiMo provider identity exists in BuiltInProviders"
}
if ($builtInProviders.Contains('"chatgpt", ProviderAvailability.DirectOnly')) {
    Pass "chatgpt remains DIRECT_ONLY in the built-in provider table"
}
else {
    Fail "chatgpt must remain DIRECT_ONLY"
}

# 10. Contract Kit reuse (no second suite) and tests exist.
if ($testSource.Contains('ProviderContractSuite') -and $testSource.Contains('MiMoContractHarness')) {
    Pass "MiMo adapter inherits the reusable Provider Contract Suite"
}
else {
    Fail "MiMo adapter must inherit ProviderContractSuite via its harness"
}
if ($testSource.Contains('MiMoEndpointValidatorTests') -and $testSource.Contains('MiMoRequestMappingTests') -and $testSource.Contains('MiMoSecretTests')) {
    Pass "MiMo endpoint validator, request mapping, and secret tests exist"
}
else {
    Fail "MiMo endpoint validator, request mapping, and secret tests must exist"
}
if ($testSource.Contains('MiMoContractTests') -and $testSource.Contains('MiMoStreamTests') -and $testSource.Contains('MiMoErrorFixtureTests') -and $testSource.Contains('MiMoUsageTests')) {
    Pass "MiMo contract, stream, error, and usage tests exist"
}
else {
    Fail "MiMo contract, stream, error, and usage tests must exist"
}
if ($testSource.Contains('MiMoPassiveOutcomeTests') -and $testSource.Contains('MiMoRegistryIsolationTests')) {
    Pass "MiMo passive-health and registry-isolation tests exist"
}
else {
    Fail "MiMo passive-health and registry-isolation tests must exist"
}

# 11. No real secret-shaped values in adapter source or tests.
foreach ($needle in @('sk-', 'ghp_', 'github_pat_')) {
    Require-NotContain "LR-7B secrets" ($source + "`n" + $testSource) $needle "real credential format"
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
if ($workflow.Contains("tests/validate-local-router-mimo.ps1")) {
    Pass "Development Gate workflow runs tests/validate-local-router-mimo.ps1"
}
else {
    Fail "Development Gate workflow must run tests/validate-local-router-mimo.ps1"
}

# 14. Protected Direct/Desktop/V4/catalog files must be untouched by this branch.
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
Write-Host "Local Router Xiaomi MiMo adapter validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router Xiaomi MiMo adapter validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router Xiaomi MiMo adapter validation PASSED" -ForegroundColor Green
exit 0
