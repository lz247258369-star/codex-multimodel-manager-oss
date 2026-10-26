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

$projects = @(
    "local-router/src/Router.Metering/Router.Metering.csproj",
    "local-router/tests/Router.Metering.Tests/Router.Metering.Tests.csproj"
)
foreach ($project in $projects) {
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $project)) {
        Pass "LR-10 project exists: $project"
    }
    else {
        Fail "LR-10 project missing: $project"
    }
}

$sln = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/LocalRouter.sln")
foreach ($name in @("Router.Metering", "Router.Metering.Tests")) {
    if ($sln.Contains($name)) {
        Pass "LocalRouter.sln includes: $name"
    }
    else {
        Fail "LocalRouter.sln is missing: $name"
    }
}

$srcDir = Join-Path $RepositoryRoot "local-router/src/Router.Metering"
$source = Get-ChildItem -LiteralPath $srcDir -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$testsDir = Join-Path $RepositoryRoot "local-router/tests/Router.Metering.Tests"
$testSource = Get-ChildItem -LiteralPath $testsDir -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"

# 1. Typed/versioned core types.
foreach ($marker in @('record UsageRecord', 'record ModelPricing', 'record ProviderPricing', 'record PricingSnapshot', 'record CostEstimate', 'class CostEstimator')) {
    if ($source.Contains($marker)) {
        Pass "LR-10 type exists: $marker"
    }
    else {
        Fail "LR-10 type missing: $marker"
    }
}
if ($source.Contains('SchemaVersion') -and $source.Contains('Estimated')) {
    Pass "Usage and cost types are versioned with explicit estimated flag"
}
else {
    Fail "Usage/cost types must be versioned and carry estimated=true"
}

# 2. Catalog remains source of truth; no second price table.
if ($source.Contains('RouterCatalogProjection') -and $source.Contains('SourceVersion')) {
    Pass "Pricing projection consumes RouterCatalogProjection (catalog remains source of truth)"
}
else {
    Fail "Pricing projection must consume RouterCatalogProjection"
}
foreach ($needle in @('const decimal InputPrice', 'const decimal OutputPrice', 'new Dictionary<string, decimal>')) {
    if ($source.Contains($needle)) {
        Fail "LR-10 source must not define a second canonical price table"
    }
    else {
        Pass "LR-10 has no second canonical price table marker '$needle'"
    }
}

# 3. Decimal money math, no float/double.
if ($source.Contains('decimal') -and $source.Contains('PerMillion')) {
    Pass "Cost math uses decimal and explicit per-1M basis"
}
else {
    Fail "Cost math must use decimal and explicit per-1M basis"
}
if ($source -match '\b(double|float)\s+[A-Za-z_]+\s*=') {
    Fail "Metering source must not use float/double money fields"
}
else {
    Pass "No float/double money arithmetic in metering source"
}

# 4. Unknown price != zero and missing usage stays null.
if ($source.Contains('UnknownPrice') -and $source.Contains('CostEstimateStatus.Unavailable')) {
    Pass "Unknown price and unavailable estimate statuses are explicit"
}
else {
    Fail "Unknown price/unavailable statuses must be explicit"
}
if ($source.Contains('usage is null') -and $source.Contains('Estimated = false')) {
    Pass "Missing usage stays null/estimated=false"
}
else {
    Fail "Missing usage must stay null/estimated=false"
}

# 5. No token guessing.
foreach ($needle in @('tokenizer', 'Tokenizer', 'CharacterCount', 'char.Length', 'AverageToken')) {
    Require-NotContain "LR-10 token guessing" $source $needle "token estimation from characters/model names"
}

# 6. No billing/price fetch/FX/cost routing/budget/policy.
foreach ($needle in @('BillingApi', 'billing API', 'FetchPrice', 'price auto-fetch', 'FxConvert', 'ForeignExchange', 'CostBasedRouting', 'Budget', 'SpendingLimit', 'RetryPolicy', 'FailoverPolicy', 'CircuitBreaker')) {
    Require-NotContain "LR-10 scope" $source $needle "billing/price-fetch/FX/routing/budget/policy leak"
}

# 7. No network/probe.
foreach ($needle in @('HttpClient', 'SendAsync', 'GetAsync', '/models', 'ModelsAsync', 'health probe', 'HealthProbe')) {
    Require-NotContain "LR-10 network" $source $needle "network/price-API/model discovery"
}

# 8. No prompt/secret logging in metering source.
foreach ($needle in @('Prompt', 'RawBody', 'Authorization', 'ApiKey', 'Cookie')) {
    if ($source -match ('public\s+.*\s+' + $needle + '\b')) {
        Fail "LR-10 type exposes forbidden field: $needle"
    }
    else {
        Pass "LR-10 has no forbidden '$needle' field"
    }
}

# 9. Golden pricing fixtures exist.
$fixtureRoot = Join-Path $RepositoryRoot "tests/fixtures/local-router/v1/metering"
foreach ($fixture in @("catalog.v3.metering.json", "usage.missing.json", "cost.complete.json", "cost.unknown-price.json")) {
    if (Test-Path -LiteralPath (Join-Path $fixtureRoot $fixture)) {
        Pass "Metering fixture exists: $fixture"
    }
    else {
        Fail "Metering fixture missing: $fixture"
    }
}

# 10. Tests exist.
if ($testSource.Contains('MeteringTests')) {
    Pass "Metering test class exists"
}
else {
    Fail "Metering test class is missing"
}
foreach ($testName in @('Decimal_cost_math_is_exact', 'Unknown_price_never_becomes_zero', 'Missing_usage_stays_null_and_never_estimated', 'Same_model_under_different_provider_has_different_price', 'Stale_pricing_is_marked_stale_with_amounts_preserved', 'Currency_mismatch_fails_closed')) {
    if ($testSource.Contains($testName)) {
        Pass "Metering test exists: $testName"
    }
    else {
        Fail "Metering test missing: $testName"
    }
}

# 11. Canonical catalog unchanged and defaults disabled.
$canonicalPath = Join-Path $RepositoryRoot "installer/model-catalog.json"
$changedFiles = @(& git -C $RepositoryRoot diff --name-only "main...HEAD" 2>$null)
$changedFiles += @(& git -C $RepositoryRoot ls-files --modified)
# LR15-G3: the metering slice must never silently change prices, but the catalog
# is legitimately changed by the reviewed DSR2 delta (the direct DeepSeek provider
# identity). The check therefore pins the catalog *content* instead of forbidding
# any branch delta: the file must hash exactly to its reviewed, delta-exact
# approved content, and the authorization is revoked when the DSR2 review is
# removed. That is stronger than "absent from the cumulative delta", because an
# unreviewed price change - committed or merely present in the worktree - still
# fails closed.
. (Join-Path $RepositoryRoot "tests/shared/protected-file-scope.ps1")
if (Test-Lr13ProtectedFileChangeAuthorized $RepositoryRoot "installer/model-catalog.json") {
    Pass "Canonical model catalog matches its reviewed, delta-exact approved content"
}
else {
    Fail "Canonical model catalog is not the reviewed approved content (unreviewed price change, or the DSR2 authorization is missing)"
}
$defaults = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/config/router.defaults.json") | ConvertFrom-Json
if ($defaults.local_router.enabled -eq $false -and $defaults.mode -eq "direct") {
    Pass "router.defaults.json remains disabled (mode=direct, enabled=false)"
}
else {
    Fail "router.defaults.json must keep mode=direct and local_router.enabled=false"
}

# 12. Validator wired into Development Gate.
$workflow = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot ".github/workflows/ci.yml")
if ($workflow.Contains("tests/validate-local-router-metering.ps1")) {
    Pass "Development Gate workflow runs tests/validate-local-router-metering.ps1"
}
else {
    Fail "Development Gate workflow must run tests/validate-local-router-metering.ps1"
}

# 13. Protected production files untouched.
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
$protectedHits = @()
foreach ($file in ($changedFiles | Sort-Object -Unique)) {
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
Write-Host "Local Router usage and cost metering validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router usage and cost metering validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router usage and cost metering validation PASSED" -ForegroundColor Green
exit 0
