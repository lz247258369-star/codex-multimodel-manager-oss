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
    "local-router/src/Router.ProviderAdapters.Abstractions/Router.ProviderAdapters.Abstractions.csproj",
    "local-router/src/Router.UpstreamHttp/Router.UpstreamHttp.csproj",
    "local-router/src/Router.ProviderAdapters.Responses/Router.ProviderAdapters.Responses.csproj",
    "local-router/tests/Router.FakeProvider/Router.FakeProvider.csproj",
    "local-router/tests/ProviderContractKit/ProviderContractKit.csproj",
    "local-router/tests/Router.ProviderAdapters.Tests/Router.ProviderAdapters.Tests.csproj"
)
foreach ($project in $projects) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $project))) {
        Fail "LR-5 project missing: $project"
    }
}

$sln = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/LocalRouter.sln")
foreach ($name in @("Router.ProviderAdapters.Abstractions", "Router.UpstreamHttp", "Router.ProviderAdapters.Responses", "Router.FakeProvider", "ProviderContractKit", "Router.ProviderAdapters.Tests")) {
    if ($sln.Contains($name)) {
        Pass "LocalRouter.sln includes: $name"
    }
    else {
        Fail "LocalRouter.sln is missing: $name"
    }
}

$abstractionsSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.ProviderAdapters.Abstractions") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$upstreamSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.UpstreamHttp") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$responsesSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.ProviderAdapters.Responses") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$allSource = $abstractionsSource + "`n" + $upstreamSource + "`n" + $responsesSource

# 1. No real provider adapters or vendor hostnames in LR-5 source.
foreach ($needle in @('adapter.provider.mm_openrouter', 'adapter.provider.mm_modelstudio', 'adapter.provider.mm_openai_api', 'adapter.provider.mm_mimo', 'adapter.provider.deepseek', 'adapter.provider.qwen', 'adapter.provider.anthropic', 'openrouter.ai', 'api.openai.com', 'dashscope', 'MIMO_API_KEY', 'OPENROUTER_API_KEY', 'CODEX_DASHSCOPE_API_KEY', 'CODEX_OPENAI_API_KEY')) {
    Require-NotContain "LR-5 providers" $allSource $needle "real vendor adapter or provider identity/URL in LR-5 source"
}

# 2. HttpClient may exist only inside Router.UpstreamHttp.
if ($upstreamSource.Contains('HttpClient')) {
    Pass "HttpClient exists only inside Router.UpstreamHttp"
}
else {
    Fail "HttpClient must be owned by Router.UpstreamHttp"
}
foreach ($needle in @('HttpClient', 'new SocketsHttpHandler')) {
    Require-NotContain "LR-5 adapter source" ($abstractionsSource + "`n" + $responsesSource) $needle "adapters must not create HTTP clients"
}

# 3. No auth.json / .env access.
foreach ($needle in @('auth.json', '.env')) {
    Require-NotContain "LR-5 secrets" $allSource $needle "secret file access"
}

# 4. No LR-6+/LR-11 scope leakage in LR-5 source.
foreach ($needle in @('CircuitBreaker', 'ExecuteRetry', 'ExecuteFailover', 'RetryEngine', 'FailoverEngine', 'ProtocolConverter', 'ChatCompletions', 'wire_api')) {
    Require-NotContain "LR-5 scope" $allSource $needle "LR-6+/LR-11 engine, conversion, or legacy wire mode"
}

# 5. Fake adapter must be TEST-ONLY and never auto-registered.
if ($responsesSource.Contains('TEST-ONLY') -and $responsesSource.Contains('FakeResponsesProviderAdapter')) {
    Pass "Fake adapter is explicitly TEST-ONLY"
}
else {
    Fail "Fake adapter must be explicitly TEST-ONLY"
}
if ($responsesSource.Contains('AddSingleton') -or $responsesSource.Contains('ServiceCollection')) {
    Fail "Fake adapter must never be auto-registered into a service container"
}
else {
    Pass "Fake adapter is not auto-registered"
}

# 6. Fake upstream binds loopback only.
$fakeProviderSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/tests/Router.FakeProvider") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
if ($fakeProviderSource.Contains('IPAddress.Loopback')) {
    Pass "Fake provider binds IPAddress.Loopback"
}
else {
    Fail "Fake provider must bind IPAddress.Loopback"
}
foreach ($needle in @('"0.0.0.0"', 'IPAddress.Any', 'ListenAnyIP')) {
    Require-NotContain "Fake provider binding" $fakeProviderSource $needle "non-loopback bind target"
}

# 7. Network guard exists for LR-5 tests.
$kitSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/tests/ProviderContractKit") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
if ($kitSource.Contains('LoopbackOnlyHandler')) {
    Pass "Provider Contract Kit ships a loopback-only network guard"
}
else {
    Fail "Provider Contract Kit must ship a loopback-only network guard"
}

# 8. Defaults stay disabled.
$defaults = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/config/router.defaults.json") | ConvertFrom-Json
if ($defaults.local_router.enabled -eq $false -and $defaults.mode -eq "direct") {
    Pass "router.defaults.json remains disabled (mode=direct, enabled=false)"
}
else {
    Fail "router.defaults.json must keep mode=direct and local_router.enabled=false"
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
Write-Host "Local Router provider harness validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router provider harness validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router provider harness validation PASSED" -ForegroundColor Green
exit 0
