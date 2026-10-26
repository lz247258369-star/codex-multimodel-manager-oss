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
    "local-router/src/Router.Policies/Router.Policies.csproj",
    "local-router/src/Router.CircuitBreaker/Router.CircuitBreaker.csproj",
    "local-router/tests/Router.Policies.Tests/Router.Policies.Tests.csproj"
)
foreach ($project in $projects) {
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $project)) {
        Pass "LR-11 project exists: $project"
    }
    else {
        Fail "LR-11 project missing: $project"
    }
}

$sln = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/LocalRouter.sln")
foreach ($name in @("Router.Policies", "Router.CircuitBreaker", "Router.Policies.Tests")) {
    if ($sln.Contains($name)) {
        Pass "LocalRouter.sln includes: $name"
    }
    else {
        Fail "LocalRouter.sln is missing: $name"
    }
}

$srcDirs = @(
    (Join-Path $RepositoryRoot "local-router/src/Router.Policies"),
    (Join-Path $RepositoryRoot "local-router/src/Router.CircuitBreaker")
)
$source = $srcDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } } | Join-String -Separator "`n"
$testsDir = Join-Path $RepositoryRoot "local-router/tests/Router.Policies.Tests"
$testSource = Get-ChildItem -LiteralPath $testsDir -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"

# 1. Core types.
foreach ($marker in @('class RetryPolicyEngine', 'class FailoverPolicyEngine', 'record PolicyDecision', 'record PolicySnapshot', 'class DeterministicRandom', 'class DeterministicWeightedSelector', 'class CircuitBreakerStateMachine', 'enum CircuitBreakerState')) {
    if ($source.Contains($marker)) {
        Pass "LR-11 type exists: $marker"
    }
    else {
        Fail "LR-11 type missing: $marker"
    }
}

# 2. Conservative defaults.
if ($source.Contains('Cross-model fallback must remain OFF') -or $source.Contains('AllowCrossModelFallback = false')) {
    Pass "Cross-model fallback is hard-disabled"
}
else {
    Fail "Cross-model fallback must remain OFF"
}
if ($source.Contains('CircuitBreakerPolicy.Disabled') -and $source.Contains('Enabled = false')) {
    Pass "Circuit breaker default is disabled"
}
else {
    Fail "Circuit breaker must default to disabled"
}

# 3. Retry boundaries and bounded loops.
if ($source.Contains('post_output_retry_forbidden') -and $source.Contains('max_attempts_reached')) {
    Pass "Retry engine rejects post-output and max attempts"
}
else {
    Fail "Retry engine must reject post-output and bound attempts"
}
if ($source.Contains('deadline_exhausted') -and $source.Contains('retry_after_exceeds_deadline')) {
    Pass "Retry engine enforces deadline and bounded Retry-After"
}
else {
    Fail "Retry engine must enforce total deadline"
}

# 4. Failover classes and explicit opt-in.
if ($source.Contains('SameModelAlternateEndpoint') -and $source.Contains('SameModelAlternateProvider') -and $source.Contains('CrossModelFallback')) {
    Pass "Failover classes are typed and explicit"
}
else {
    Fail "Failover classes must be typed and explicit"
}
if ($source.Contains('post_output_failover_forbidden') -and $source.Contains('capability_mismatch') -and $source.Contains('provider_not_explicitly_approved')) {
    Pass "Failover rejects post-output/capability mismatch/unapproved provider"
}
else {
    Fail "Failover must require explicit approval and equivalence"
}

# 5. Breaker cancellation/rate-limit safety and concurrency.
if ($source.Contains('"cancelled"') -and $source.Contains('"rate_limited"')) {
    Pass "Breaker ignores client cancellation and rate limits"
}
else {
    Fail "Breaker must not count cancellation/rate limit as hard failure"
}
if ($source.Contains('HalfOpenMaxTrials') -and $source.Contains('TrialsInFlight')) {
    Pass "Breaker half-open concurrency is bounded"
}
else {
    Fail "Breaker half-open concurrency must be bounded"
}

# 6. No cost-based routing/billing/network/discovery.
foreach ($needle in @('CostBasedRouting', 'Budget', 'BillingApi', 'FetchPrice', 'HttpClient', '/models', 'ModelsAsync', 'HealthProbe', 'telemetry export')) {
    Require-NotContain "LR-11 scope" $source $needle "cost routing/billing/network/discovery leak"
}

# 7. Deterministic random and no global Random.
if ($source.Contains('class DeterministicRandom') -and -not $source.Contains('new Random()')) {
    Pass "Policy decisions use a deterministic random source"
}
else {
    Fail "Policy decisions must use deterministic random, never global Random"
}

# 8. Policy fixtures exist.
$fixtureRoot = Join-Path $RepositoryRoot "tests/fixtures/local-router/v1/policy"
foreach ($fixture in @("policy.defaults.json", "decision.retry.json", "decision.breaker-open.json")) {
    if (Test-Path -LiteralPath (Join-Path $fixtureRoot $fixture)) {
        Pass "Policy fixture exists: $fixture"
    }
    else {
        Fail "Policy fixture missing: $fixture"
    }
}

# 9. Tests exist.
foreach ($className in @('RetryPolicyTests', 'TimeoutPolicyTests', 'FailoverPolicyTests', 'CircuitBreakerTests', 'PolicySnapshotTests')) {
    if ($testSource.Contains($className)) {
        Pass "Policy test class exists: $className"
    }
    else {
        Fail "Policy test class missing: $className"
    }
}

if ($testSource.Contains('Deterministic_weighted_choice_is_repeatable')) {
    Pass "Deterministic weighted-choice test exists"
}
else {
    Fail "Deterministic weighted-choice test is missing"
}

# 10. Defaults disabled and validator wired.
$defaults = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/config/router.defaults.json") | ConvertFrom-Json
if ($defaults.local_router.enabled -eq $false -and $defaults.mode -eq "direct") {
    Pass "router.defaults.json remains disabled (mode=direct, enabled=false)"
}
else {
    Fail "router.defaults.json must keep mode=direct and local_router.enabled=false"
}
$workflow = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot ".github/workflows/ci.yml")
if ($workflow.Contains("tests/validate-local-router-policy.ps1")) {
    Pass "Development Gate workflow runs tests/validate-local-router-policy.ps1"
}
else {
    Fail "Development Gate workflow must run tests/validate-local-router-policy.ps1"
}

# 11. Protected files untouched.
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
Write-Host "Local Router policy and failover validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router policy and failover validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router policy and failover validation PASSED" -ForegroundColor Green
exit 0
