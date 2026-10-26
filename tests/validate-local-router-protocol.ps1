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
    "local-router/src/Router.ProtocolAdapters.Abstractions/Router.ProtocolAdapters.Abstractions.csproj",
    "local-router/src/Router.ProtocolAdapters.Responses/Router.ProtocolAdapters.Responses.csproj",
    "local-router/tests/Router.ProtocolAdapters.Tests/Router.ProtocolAdapters.Tests.csproj"
)
foreach ($project in $projects) {
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $project)) {
        Pass "LR-8 project exists: $project"
    }
    else {
        Fail "LR-8 project missing: $project"
    }
}

$sln = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/LocalRouter.sln")
foreach ($name in @("Router.ProtocolAdapters.Abstractions", "Router.ProtocolAdapters.Responses", "Router.ProtocolAdapters.Tests")) {
    if ($sln.Contains($name)) {
        Pass "LocalRouter.sln includes: $name"
    }
    else {
        Fail "LocalRouter.sln is missing: $name"
    }
}

$srcDirs = @(
    (Join-Path $RepositoryRoot "local-router/src/Router.ProtocolAdapters.Abstractions"),
    (Join-Path $RepositoryRoot "local-router/src/Router.ProtocolAdapters.Responses")
)
$source = $srcDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } } | Join-String -Separator "`n"
$testsDir = Join-Path $RepositoryRoot "local-router/tests/Router.ProtocolAdapters.Tests"
$testSource = Get-ChildItem -LiteralPath $testsDir -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$placeholderFile = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.ProtocolAdapters.Responses/FutureProtocolPlaceholders.cs")

# 1. Exact protocol identity and lossless policy.
if ($source.Contains('CanonicalProtocolId = "protocol.openai.responses.v1"') -and $source.Contains('UpstreamProtocolId = "protocol.openai.responses.v1"')) {
    Pass "Responses protocol adapter uses exact canonical/upstream protocol.openai.responses.v1"
}
else {
    Fail "Responses protocol adapter must use exact protocol.openai.responses.v1"
}
if ($source.Contains('AdapterVersion = "1.0"') -and $source.Contains('AdapterId = "adapter.protocol.responses-compatible.v1"')) {
    Pass "Protocol adapter identity/version are exact (adapter.protocol.responses-compatible.v1 / 1.0)"
}
else {
    Fail "Protocol adapter identity/version must be exact"
}
if ($source.Contains('LOSSLESS_ONLY') -and $source.Contains('LosslessOnly')) {
    Pass "Protocol loss policy is LOSSLESS_ONLY"
}
else {
    Fail "Protocol loss policy must be LOSSLESS_ONLY (lossy/best-effort forbidden)"
}

# 2. Semantic-loss detector and fail-closed behavior exist.
if ($source.Contains('class SemanticLossDetector') -or $source.Contains('static class SemanticLossDetector')) {
    Pass "Semantic Loss Detector exists"
}
else {
    Fail "Semantic Loss Detector is missing"
}
if ($source.Contains('semantic_loss') -and $source.Contains('SemanticLoss')) {
    Pass "Semantic loss has a typed error path"
}
else {
    Fail "Semantic loss must fail closed with a typed semantic_loss error"
}

# 3. Registry is versioned and immutable.
if ($source.Contains('class ProtocolAdapterRegistry') -and $source.Contains('ExactKey')) {
    Pass "Immutable ProtocolAdapterRegistry with exact key exists"
}
else {
    Fail "Immutable ProtocolAdapterRegistry with exact key is missing"
}
foreach ($marker in @('duplicate protocol adapter identity', 'PlaceholderUnavailable', 'AdapterVersionMismatch')) {
    if ($source.Contains($marker)) {
        Pass "Protocol registry handles: $marker"
    }
    else {
        Fail "Protocol registry must handle: $marker"
    }
}

# 4. Anthropic is placeholder only (never implemented).
if ($placeholderFile.Contains('protocol.anthropic.messages.v1') -and $placeholderFile.Contains('Eligible = false') -and $placeholderFile.Contains('CapabilitySet.Empty')) {
    Pass "Anthropic Messages exists only as an unusable placeholder"
}
else {
    Fail "Anthropic Messages must be an unusable placeholder only"
}
$nonPlaceholderSource = $source.Replace($placeholderFile, "")
foreach ($needle in @('MapAnthropic', 'anthropic_request', 'anthropic_response', 'Claude', 'MessagesAdapter')) {
    Require-NotContain "LR-8 Anthropic implementation" $nonPlaceholderSource $needle "Anthropic conversion implementation"
}

# 5. Chat Completions and legacy wire mode are forbidden.
foreach ($needle in @('chat/completions', 'ChatCompletions', 'chat_completions', 'wire_api')) {
    Require-NotContain "LR-8 Chat Completions" $source $needle "Chat Completions/legacy wire implementation"
}

# 6. No provider-specific conversion or branching in the protocol layer.
foreach ($needle in @('mm_openrouter', 'mm_modelstudio', 'mm_openai_api', 'mm_mimo', 'openrouter.ai', 'dashscope', 'api.openai.com', 'xiaomimimo')) {
    Require-NotContain "LR-8 provider isolation" $source $needle "provider-specific conversion/branching"
}

# 7. No secret/network access in the protocol layer.
foreach ($needle in @('Environment.GetEnvironmentVariable', 'HttpClient', 'SecretHandle', 'Authorization', 'auth.json', '.env', 'SendAsync', 'https://')) {
    Require-NotContain "LR-8 secret/network" $source $needle "secret/HTTP access in protocol adapter"
}

# 8. No LR-9+ engine leak.
foreach ($needle in @('HealthProbe', 'health probe', 'UsageEngine', 'CostEngine', 'TraceEngine', 'RequestLog', 'RetryEngine', 'FailoverEngine', 'CircuitBreaker')) {
    Require-NotContain "LR-8 scope" $source $needle "LR-9+ engine leak"
}

# 9. Capability matrix documentation exists and is explicit.
$matrix = Join-Path $RepositoryRoot "docs/LOCAL_ROUTER_PROTOCOL_CAPABILITY_MATRIX.md"
if (Test-Path -LiteralPath $matrix) {
    Pass "Protocol capability matrix document exists"
    $matrixText = Get-Content -Raw -LiteralPath $matrix
    foreach ($marker in @('protocol.openai.responses.v1', 'SUPPORTED', 'UNSUPPORTED', 'PLACEHOLDER', 'protocol.anthropic.messages.v1')) {
        if ($matrixText.Contains($marker)) {
            Pass "Capability matrix contains: $marker"
        }
        else {
            Fail "Capability matrix is missing: $marker"
        }
    }
}
else {
    Fail "Protocol capability matrix document is missing"
}

# 10. Golden fixtures exist.
$goldenRoot = Join-Path $RepositoryRoot "tests/fixtures/local-router/v1/protocol/responses/golden"
$goldenFiles = @(
    "request.text.json", "request.instructions.json", "request.reasoning.json",
    "request.tools.json", "request.tool-result.json", "request.multimodal-rejected.json",
    "request.background-rejected.json", "response.text.json", "response.usage.json",
    "stream.text.sse", "stream.reasoning.sse", "stream.tools.sse", "stream.error.sse",
    "error.semantic-loss.json"
)
foreach ($goldenFile in $goldenFiles) {
    if (Test-Path -LiteralPath (Join-Path $goldenRoot $goldenFile)) {
        Pass "Golden fixture exists: $goldenFile"
    }
    else {
        Fail "Golden fixture missing: $goldenFile"
    }
}

# 11. Conformance suite and tests exist.
if ($testSource.Contains('ProtocolAdapterContractSuite') -and $testSource.Contains('ResponsesProtocolContractTests')) {
    Pass "Reusable ProtocolContractSuite is inherited by the Responses adapter"
}
else {
    Fail "Reusable ProtocolContractSuite and Responses contract tests must exist"
}
if ($testSource.Contains('SemanticLossDetectorTests') -and $testSource.Contains('ProtocolAdapterRegistryTests') -and $testSource.Contains('ProtocolGoldenFixtureTests')) {
    Pass "Semantic-loss, registry, and golden fixture tests exist"
}
else {
    Fail "Semantic-loss, registry, and golden fixture tests must exist"
}
if ($testSource.Contains('CanonicalEventVocabularyTests') -and $testSource.Contains('ResponsesProtocolAdapterTests')) {
    Pass "Canonical event vocabulary and Responses protocol adapter tests exist"
}
else {
    Fail "Canonical event vocabulary and Responses protocol adapter tests must exist"
}

# 12. Defaults stay disabled.
$defaults = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/config/router.defaults.json") | ConvertFrom-Json
if ($defaults.local_router.enabled -eq $false -and $defaults.mode -eq "direct") {
    Pass "router.defaults.json remains disabled (mode=direct, enabled=false)"
}
else {
    Fail "router.defaults.json must keep mode=direct and local_router.enabled=false"
}

# 13. Validator is wired into the Development Gate workflow.
$workflow = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot ".github/workflows/ci.yml")
if ($workflow.Contains("tests/validate-local-router-protocol.ps1")) {
    Pass "Development Gate workflow runs tests/validate-local-router-protocol.ps1"
}
else {
    Fail "Development Gate workflow must run tests/validate-local-router-protocol.ps1"
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
Write-Host "Local Router protocol adapter boundary validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router protocol adapter boundary validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router protocol adapter boundary validation PASSED" -ForegroundColor Green
exit 0
