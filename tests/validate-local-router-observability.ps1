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
    "local-router/src/Router.Health/Router.Health.csproj",
    "local-router/src/Router.Observability/Router.Observability.csproj",
    "local-router/tests/Router.Observability.Tests/Router.Observability.Tests.csproj"
)
foreach ($project in $projects) {
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $project)) {
        Pass "LR-9 project exists: $project"
    }
    else {
        Fail "LR-9 project missing: $project"
    }
}

$sln = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/LocalRouter.sln")
foreach ($name in @("Router.Health", "Router.Observability", "Router.Observability.Tests")) {
    if ($sln.Contains($name)) {
        Pass "LocalRouter.sln includes: $name"
    }
    else {
        Fail "LocalRouter.sln is missing: $name"
    }
}

$srcDirs = @(
    (Join-Path $RepositoryRoot "local-router/src/Router.Health"),
    (Join-Path $RepositoryRoot "local-router/src/Router.Observability")
)
$source = $srcDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } } | Join-String -Separator "`n"
$recordSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Observability/SafeRequestRecord.cs")
$testsDir = Join-Path $RepositoryRoot "local-router/tests/Router.Observability.Tests"
$testSource = Get-ChildItem -LiteralPath $testsDir -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"

# 1. Core types exist.
foreach ($marker in @('class PassiveHealthTracker', 'record HealthSnapshot', 'record SafeRequestRecord', 'record TraceRecord', 'class TraceBuilder', 'class RedactionBoundary', 'class DurableRequestLog')) {
    if ($source.Contains($marker)) {
        Pass "LR-9 type exists: $marker"
    }
    else {
        Fail "LR-9 type missing: $marker"
    }
}

# 2. Passive health only; no active probe/network in Health or Observability source.
foreach ($needle in @('HttpClient', 'SendAsync', 'GetAsync', 'PostAsync', '/models', 'ModelsAsync', 'HealthProbe', 'ping')) {
    Require-NotContain "LR-9 active probe" $source $needle "active provider health probe/network"
}

# 3. No remote telemetry export.
foreach ($needle in @('OpenTelemetry', 'Sentry', 'Datadog', 'AzureMonitor', 'ApplicationInsights', 'telemetry export')) {
    Require-NotContain "LR-9 telemetry" $source $needle "remote telemetry exporter"
}

# 4. No prompt/content capture and no secret/header fields in the request record.
foreach ($pattern in @('public\s+required\s+string\s+Prompt\b', 'public\s+required\s+string\s+RawBody\b', 'public\s+.*\s+Authorization\b', 'public\s+.*\s+ApiKey\b', 'public\s+.*\s+Cookie\b', 'public\s+.*\s+ToolPayload\b')) {
    if ($recordSource -match $pattern) {
        Fail "SafeRequestRecord exposes forbidden content field: $pattern"
    }
    else {
        Pass "SafeRequestRecord has no forbidden content field: $pattern"
    }
}

# 5. Redaction-by-construction and drop-on-failure.
if ($source.Contains('RedactedRequestRecord') -and $source.Contains('RedactionFailureException')) {
    Pass "Redacted sink types and redaction failure exist"
}
else {
    Fail "Redacted sink types and redaction failure must exist"
}
if ($source.Contains('WriteSafeAsync') -and $source.Contains('RedactionFailureException')) {
    Pass "Redaction failure drops the event before the durable sink"
}
else {
    Fail "Redaction failure must drop the event"
}

# 6. Bounded trace/log and retention/rotation.
if ($source.Contains('MaxTraceEventsPerRequest') -and $source.Contains('Truncated')) {
    Pass "Bounded trace exists"
}
else {
    Fail "Bounded trace is missing"
}
if ($source.Contains('MaxFiles') -and $source.Contains('RetentionAge') -and $source.Contains('PruneLocked')) {
    Pass "Retention and deterministic rotation exist"
}
else {
    Fail "Retention/rotation must exist"
}
if ($source.Contains('RecoverCorruptAsync') -and $source.Contains('quarantine')) {
    Pass "Corrupt-log quarantine/recovery exists"
}
else {
    Fail "Corrupt-log quarantine/recovery must exist"
}
if ($source.Contains('ObservabilityPathPolicy') -and $source.Contains('IsAllowedDirectory')) {
    Pass "Observability path/ACL policy exists"
}
else {
    Fail "Observability path/ACL policy must exist"
}

# 7. Safe status/public health minimal types.
if ($source.Contains('RouterStatusObservabilitySnapshot') -and $source.Contains('LogStateSnapshot')) {
    Pass "Safe authenticated status snapshot types exist"
}
else {
    Fail "Safe authenticated status snapshot types must exist"
}
if ($source.Contains('SafeHealthRecord')) {
    Pass "Safe health record type exists"
}
else {
    Fail "Safe health record type must exist"
}

# 8. No pricing/cost/failover/retry/circuit-breaker engine.
foreach ($needle in @('Price', 'CostEngine', 'Billing', 'FailoverPolicy', 'RetryPolicy', 'CircuitBreaker', 'ExecuteFailover', 'ExecuteRetry')) {
    if ($source.Contains($needle)) {
        Fail "LR-9 scope contains forbidden marker '$needle': LR-10+/LR-11 leak"
    }
    else {
        Pass "LR-9 scope has no '$needle' (LR-10+/LR-11 leak)"
    }
}

# 9. Fixtures exist.
$fixtureRoot = Join-Path $RepositoryRoot "tests/fixtures/local-router/v1/observability"
foreach ($fixture in @("redaction.forbidden-injection.json", "health.snapshot.allowed-fields.json", "request-record.allowed-fields.json")) {
    if (Test-Path -LiteralPath (Join-Path $fixtureRoot $fixture)) {
        Pass "Observability fixture exists: $fixture"
    }
    else {
        Fail "Observability fixture missing: $fixture"
    }
}

# 10. Tests exist for every required area.
foreach ($className in @('PassiveHealthTrackerTests', 'SafeRequestRecordTests', 'TraceBuilderTests', 'DurableRequestLogTests', 'ObservabilityPathPolicyTests', 'ObservabilityFixtureTests')) {
    if ($testSource.Contains($className)) {
        Pass "Observability test class exists: $className"
    }
    else {
        Fail "Observability test class missing: $className"
    }
}

# 11. Defaults stay disabled.
$defaults = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/config/router.defaults.json") | ConvertFrom-Json
if ($defaults.local_router.enabled -eq $false -and $defaults.mode -eq "direct") {
    Pass "router.defaults.json remains disabled (mode=direct, enabled=false)"
}
else {
    Fail "router.defaults.json must keep mode=direct and local_router.enabled=false"
}

# 12. Validator is wired into Development Gate.
$workflow = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot ".github/workflows/ci.yml")
if ($workflow.Contains("tests/validate-local-router-observability.ps1")) {
    Pass "Development Gate workflow runs tests/validate-local-router-observability.ps1"
}
else {
    Fail "Development Gate workflow must run tests/validate-local-router-observability.ps1"
}

# 13. Protected production files are untouched.
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
Write-Host "Local Router health and observability validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router health and observability validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router health and observability validation PASSED" -ForegroundColor Green
exit 0
