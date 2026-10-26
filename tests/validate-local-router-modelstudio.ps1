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

$adapterProject = "local-router/src/Router.ProviderAdapters.ModelStudio/Router.ProviderAdapters.ModelStudio.csproj"
$testsProject = "local-router/tests/Router.ProviderAdapters.ModelStudio.Tests/Router.ProviderAdapters.ModelStudio.Tests.csproj"
foreach ($project in @($adapterProject, $testsProject)) {
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $project)) {
        Pass "LR-7 project exists: $project"
    }
    else {
        Fail "LR-7 project missing: $project"
    }
}

$sln = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/LocalRouter.sln")
foreach ($name in @("Router.ProviderAdapters.ModelStudio", "Router.ProviderAdapters.ModelStudio.Tests")) {
    if ($sln.Contains($name)) {
        Pass "LocalRouter.sln includes: $name"
    }
    else {
        Fail "LocalRouter.sln is missing: $name"
    }
}

$source = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.ProviderAdapters.ModelStudio") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$testSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/tests/Router.ProviderAdapters.ModelStudio.Tests") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"

# 1. Exact Manager identity.
if ($source.Contains('ProviderId = "mm_modelstudio"') -and -not ($source -match 'ProviderId = "(?!mm_modelstudio)"')) {
    Pass "Adapter uses the exact Manager identity mm_modelstudio"
}
else {
    Fail "Adapter must use the exact Manager identity mm_modelstudio and no other provider identity"
}
if ($source.Contains('AdapterId = "adapter.provider.mm_modelstudio.responses.v1"') -and $source.Contains('AdapterVersion = "1.0"') -and $source.Contains('ProtocolId = "protocol.openai.responses.v1"')) {
    Pass "Adapter identity/version/protocol are exact (adapter.provider.mm_modelstudio.responses.v1 / 1.0 / protocol.openai.responses.v1)"
}
else {
    Fail "Adapter identity/version/protocol must be exact"
}

# 2. Only CODEX_DASHSCOPE_API_KEY reference; no direct env read; no live HTTP.
foreach ($needle in @('Environment.GetEnvironmentVariable', 'auth.json', '.env', 'HttpClient', 'new SocketsHttpHandler', 'SendAsync', 'GetAsync', 'PostAsync', 'https://')) {
    Require-NotContain "LR-7 adapter source" $source $needle "direct env/secret/file/HTTP usage or hardcoded live endpoint"
}
foreach ($needle in @('OPENROUTER_API_KEY', 'MIMO_API_KEY', 'CODEX_OPENAI_API_KEY')) {
    Require-NotContain "LR-7 adapter source" $source $needle "non-Model-Studio secret reference"
}
if ($source.Contains('CODEX_DASHSCOPE_API_KEY')) {
    Fail "LR-7 adapter source must reference CODEX_DASHSCOPE_API_KEY only via SecretReference, never as a literal"
}
else {
    Pass "LR-7 adapter source has no CODEX_DASHSCOPE_API_KEY literal (SecretReference only)"
}

# 3. No /models discovery or health probe.
foreach ($needle in @('/models', '"models"', 'ModelsAsync', 'health probe', 'HealthProbe', 'ping')) {
    Require-NotContain "LR-7 discovery" $source $needle "model discovery or health probe"
}

# 4. No Chat/Coding Plan conversion.
foreach ($needle in @('chat/completions', 'ChatCompletions', 'CodingPlan', 'wire_api', 'anthropic')) {
    Require-NotContain "LR-7 protocol" $source $needle "Chat/Coding Plan/protocol conversion"
}

# 5. No arbitrary URL interpolation.
foreach ($needle in @('$"https://', '$"http://', 'String.Format', '${')) {
    Require-NotContain "LR-7 endpoint" $source $needle "arbitrary URL interpolation"
}

# 6. Workspace endpoint validator present and strict.
if ($source.Contains('class ModelStudioEndpointValidator') -and $source.Contains('RequiredPath') -and $source.Contains('/compatible-mode/v1')) {
    Pass "Workspace endpoint URL validator exists with strict path template"
}
else {
    Fail "Workspace endpoint URL validator must exist and enforce the /compatible-mode/v1 path"
}
if ($source.Contains('IsAllowedProductionHost') -and $source.Contains('maas.aliyuncs.com')) {
    Pass "Workspace endpoint validator enforces an explicit host allowlist"
}
else {
    Fail "Workspace endpoint validator must enforce an explicit host allowlist"
}

# 7. No LR-7A/LR-7B/other vendor adapters.
foreach ($needle in @('adapter.provider.mm_openai_api', 'adapter.provider.mm_mimo', 'adapter.provider.mm_openrouter', 'adapter.provider.anthropic', 'deepseek_direct', 'qwen_direct')) {
    Require-NotContain "LR-7 scope" $source $needle "other vendor adapter or direct Qwen/DeepSeek provider"
}

# 8. Secret allowlist exact mapping.
$secretAllowlist = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Secrets/EnvironmentSecretAllowlist.cs")
if ($secretAllowlist.Contains('public const string DashScopeApiKey = "CODEX_DASHSCOPE_API_KEY"') -and $secretAllowlist.Contains('["mm_modelstudio"] = DashScopeApiKey')) {
    Pass "EnvironmentSecretAllowlist maps mm_modelstudio exactly to CODEX_DASHSCOPE_API_KEY"
}
else {
    Fail "EnvironmentSecretAllowlist must map mm_modelstudio exactly to CODEX_DASHSCOPE_API_KEY"
}

# 9. Contract Kit reuse (no second suite) and tests exist.
if ($testSource.Contains('ProviderContractSuite') -and $testSource.Contains('ModelStudioContractHarness')) {
    Pass "Model Studio adapter inherits the reusable Provider Contract Suite"
}
else {
    Fail "Model Studio adapter must inherit ProviderContractSuite via its harness"
}
if ($testSource.Contains('ModelStudioEndpointValidatorTests') -and $testSource.Contains('ModelStudioRequestMappingTests')) {
    Pass "Model Studio endpoint validator and request mapping tests exist"
}
else {
    Fail "Model Studio endpoint validator and request mapping tests must exist"
}

# 10. No real secret-shaped values in adapter source or fixtures.
foreach ($needle in @('sk-', 'ghp_', 'github_pat_')) {
    Require-NotContain "LR-7 secrets" ($source + "`n" + $testSource) $needle "real credential format"
}

# 11. Defaults stay disabled.
$defaults = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/config/router.defaults.json") | ConvertFrom-Json
if ($defaults.local_router.enabled -eq $false -and $defaults.mode -eq "direct") {
    Pass "router.defaults.json remains disabled (mode=direct, enabled=false)"
}
else {
    Fail "router.defaults.json must keep mode=direct and local_router.enabled=false"
}

# 12. Protected production files must be untouched by this branch.
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
    '(?i)^skill/codex-multimodel-manager/scripts/launch-controller-model\.ps1$'
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
Write-Host "Local Router Model Studio adapter validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router Model Studio adapter validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router Model Studio adapter validation PASSED" -ForegroundColor Green
exit 0
