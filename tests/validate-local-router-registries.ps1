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

function Read-SourceText([string]$RelativePath) {
    $path = Join-Path $RepositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Fail "Missing expected file: $RelativePath"
        return ""
    }
    Pass "Expected file exists: $RelativePath"
    return (Get-Content -Raw -LiteralPath $path)
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

$projects = @(
    "local-router/src/Router.CatalogProjection/Router.CatalogProjection.csproj",
    "local-router/src/Router.Registries/Router.Registries.csproj",
    "local-router/src/Router.Routing/Router.Routing.csproj",
    "local-router/tests/Router.TestSupport/Router.TestSupport.csproj",
    "local-router/tests/Router.CatalogProjection.Tests/Router.CatalogProjection.Tests.csproj",
    "local-router/tests/Router.Registries.Tests/Router.Registries.Tests.csproj",
    "local-router/tests/Router.Routing.Tests/Router.Routing.Tests.csproj"
)
foreach ($project in $projects) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $project))) {
        Fail "LR-4 project missing: $project"
    }
}

$sln = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/LocalRouter.sln")
foreach ($name in @("Router.CatalogProjection", "Router.Registries", "Router.Routing", "Router.TestSupport", "Router.CatalogProjection.Tests", "Router.Registries.Tests", "Router.Routing.Tests")) {
    if ($sln.Contains($name)) {
        Pass "LocalRouter.sln includes: $name"
    }
    else {
        Fail "LocalRouter.sln is missing: $name"
    }
}

$projectionSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.CatalogProjection") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$registriesSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Registries") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$routingSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Routing") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$allSource = $projectionSource + "`n" + $registriesSource + "`n" + $routingSource

# 1. No provider network code or credentials.
foreach ($needle in @('HttpClient', 'api.openai.com', 'api.deepseek.com', 'openrouter.ai', 'dashscope.aliyuncs.com', 'https://api', 'MIMO_API_KEY', 'CODEX_OPENAI_API_KEY', 'CODEX_DASHSCOPE_API_KEY', 'OPENROUTER_API_KEY')) {
    Require-NotContain "LR-4 providers" $allSource $needle "real provider call, URL, or raw key usage in LR-4 source"
}

# 2. No auth.json / .env access.
foreach ($needle in @('auth.json', '.env')) {
    Require-NotContain "LR-4 secrets" $allSource $needle "secret file access"
}

# 3. No LR-5+ scope leakage in LR-4 source.
foreach ($needle in @('CircuitBreaker', 'ExecuteRetry', 'ExecuteFailover', 'RetryEngine', 'FailoverEngine', 'ProtocolConverter', 'AnthropicClient', 'ChatCompletions', 'wire_api')) {
    Require-NotContain "LR-4 scope" $allSource $needle "LR-5+ engine, conversion, or legacy wire mode"
}

# 4. Placeholder providers must never be eligible by default.
$builtIns = Read-SourceText "local-router/src/Router.Registries/BuiltInProviders.cs"
if ($builtIns.Contains('HasEligibleAdapter = false')) {
    Pass "Built-in providers default to no eligible adapter"
}
else {
    Fail "Built-in provider table must default HasEligibleAdapter=false"
}
if ($builtIns.Contains('ProviderAvailability.Eligible')) {
    Fail "Built-in provider table must never contain an Eligible provider by default"
}
else {
    Pass "Built-in provider table contains no Eligible provider by default"
}

# 5. Canonical Responses is the only eligible protocol family.
if ($registriesSource.Contains('IsEligibleProtocol = true') -and $registriesSource.Contains('protocol.anthropic.messages.v1')) {
    Pass "Canonical Responses is eligible; Anthropic remains a placeholder"
}
else {
    Fail "Protocol registry must mark only canonical Responses eligible and Anthropic as placeholder"
}

# 6. Defaults stay disabled with loopback host and canonical port.
$defaults = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/config/router.defaults.json") | ConvertFrom-Json
if ($defaults.local_router.enabled -eq $false -and $defaults.mode -eq "direct") {
    Pass "router.defaults.json remains disabled (mode=direct, enabled=false)"
}
else {
    Fail "router.defaults.json must keep mode=direct and local_router.enabled=false"
}

# 7. No second canonical catalog source inside local-router. Build output and
#    object directories legitimately carry the MSBuild Content link copy of the
#    canonical installer/model-catalog.json, so they are excluded here; only a
#    tracked/extra source file would violate the single-source rule.
$secondCatalog = @(
    Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router") -Recurse -File -Filter "model-catalog.json" |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }
)
if ($secondCatalog.Count -eq 0) {
    Pass "No second canonical model catalog exists under local-router"
}
else {
    foreach ($hit in $secondCatalog) {
        Fail "Second canonical catalog source must not exist under local-router: $($hit.FullName)"
    }
}

# 8. LR-4 fixtures exist.
foreach ($fixture in @(
    "tests/fixtures/local-router/v1/catalog/catalog.v3.representative.json",
    "tests/fixtures/local-router/v1/catalog/catalog.v3.unsupported-version.json",
    "tests/fixtures/local-router/v1/catalog/catalog.v3.unknown-provider.json",
    "tests/fixtures/local-router/v1/catalog/catalog.v3.duplicate-model.json",
    "tests/fixtures/local-router/v1/routing/golden/resolved.openrouter-glm53.json",
    "tests/fixtures/local-router/v1/routing/golden/weighted-selection.json"
)) {
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $fixture)) {
        Pass "LR-4 fixture exists: $fixture"
    }
    else {
        Fail "LR-4 fixture missing: $fixture"
    }
}

# 9. Protected production files must be untouched by this branch.
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
# Protected-file policy is delta-exact: LR-13/LR-14 may touch their own
# approved files only while the normalized hashes still match the reviewed
# deltas. Every other change to a protected file still fails closed.
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
Write-Host "Local Router registries validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router registries validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router registries validation PASSED" -ForegroundColor Green
exit 0
