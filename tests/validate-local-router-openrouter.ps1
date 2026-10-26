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

$adapterProject = "local-router/src/Router.ProviderAdapters.OpenRouter/Router.ProviderAdapters.OpenRouter.csproj"
$testsProject = "local-router/tests/Router.ProviderAdapters.OpenRouter.Tests/Router.ProviderAdapters.OpenRouter.Tests.csproj"
foreach ($project in @($adapterProject, $testsProject)) {
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $project)) {
        Pass "LR-6 project exists: $project"
    }
    else {
        Fail "LR-6 project missing: $project"
    }
}

$sln = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/LocalRouter.sln")
foreach ($name in @("Router.ProviderAdapters.OpenRouter", "Router.ProviderAdapters.OpenRouter.Tests")) {
    if ($sln.Contains($name)) {
        Pass "LocalRouter.sln includes: $name"
    }
    else {
        Fail "LocalRouter.sln is missing: $name"
    }
}

$source = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.ProviderAdapters.OpenRouter") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$testSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/tests/Router.ProviderAdapters.OpenRouter.Tests") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"

# 1. Exact Manager identity.
if ($source.Contains('ProviderId = "mm_openrouter"') -and -not ($source -match 'ProviderId = "(?!mm_openrouter)"')) {
    Pass "Adapter uses the exact Manager identity mm_openrouter"
}
else {
    Fail "Adapter must use the exact Manager identity mm_openrouter and no other provider identity"
}
if ($source.Contains('AdapterId = "adapter.provider.mm_openrouter.responses.v1"') -and $source.Contains('AdapterVersion = "1.0"') -and $source.Contains('ProtocolId = "protocol.openai.responses.v1"')) {
    Pass "Adapter identity/version/protocol are exact (adapter.provider.mm_openrouter.responses.v1 / 1.0 / protocol.openai.responses.v1)"
}
else {
    Fail "Adapter identity/version/protocol must be exact"
}

# 2. Only OPENROUTER_API_KEY reference; no direct env read; no live calls.
foreach ($needle in @('Environment.GetEnvironmentVariable', 'auth.json', '.env', 'HttpClient', 'new SocketsHttpHandler')) {
    Require-NotContain "LR-6 adapter source" $source $needle "direct env/secret/file/HTTP usage"
}
foreach ($needle in @('MIMO_API_KEY', 'CODEX_DASHSCOPE_API_KEY', 'CODEX_OPENAI_API_KEY')) {
    Require-NotContain "LR-6 adapter source" $source $needle "non-OpenRouter secret reference"
}
if ($source.Contains('OPENROUTER_API_KEY')) {
    Fail "LR-6 adapter source must reference OPENROUTER_API_KEY only via SecretReference, never as a literal"
}
else {
    Pass "LR-6 adapter source has no OPENROUTER_API_KEY literal (SecretReference only)"
}

# 3. No /models discovery or health probe.
foreach ($needle in @('/models', '"models"', 'ModelsAsync', 'health probe', 'HealthProbe', 'ping')) {
    Require-NotContain "LR-6 discovery" $source $needle "model discovery or health probe"
}

# 4. No live OpenRouter hostname in adapter source.
foreach ($needle in @('openrouter.ai', 'https://openrouter')) {
    Require-NotContain "LR-6 live calls" $source $needle "live OpenRouter endpoint"
}

# 5. No LR-7+ vendor adapters.
foreach ($needle in @('adapter.provider.mm_modelstudio', 'adapter.provider.mm_openai_api', 'adapter.provider.mm_mimo', 'adapter.provider.anthropic', 'deepseek_direct', 'qwen_direct')) {
    Require-NotContain "LR-6 scope" $source $needle "LR-7+ vendor adapter"
}

# 6. Contract Kit registration present (no second suite).
if ($testSource.Contains('ProviderContractSuite') -and $testSource.Contains('OpenRouterContractHarness')) {
    Pass "OpenRouter adapter inherits the reusable Provider Contract Suite"
}
else {
    Fail "OpenRouter adapter must inherit ProviderContractSuite via its harness"
}

# 7. Defaults stay disabled.
$defaults = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/config/router.defaults.json") | ConvertFrom-Json
if ($defaults.local_router.enabled -eq $false -and $defaults.mode -eq "direct") {
    Pass "router.defaults.json remains disabled (mode=direct, enabled=false)"
}
else {
    Fail "router.defaults.json must keep mode=direct and local_router.enabled=false"
}

# 8. Protected production files must be untouched by this branch.
$protectedPatterns = @(
    '(?i)^installer/scripts/launch-controller-model\.ps1$',
    '(?i)^installer/scripts/desktop-chat-route\.ps1$',
    '(?i)^installer/scripts/desktop-chat-provider\.ps1$',
    '(?i)^installer/scripts/desktop-controller\.ps1$',
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
Write-Host "Local Router OpenRouter adapter validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router OpenRouter adapter validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router OpenRouter adapter validation PASSED" -ForegroundColor Green
exit 0
