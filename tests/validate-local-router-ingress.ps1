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

$ingressCsproj = "local-router/src/Router.Ingress/Router.Ingress.csproj"
$adaptersCsproj = "local-router/src/Router.ClientAdapters.Responses/Router.ClientAdapters.Responses.csproj"
$ingressTestsCsproj = "local-router/tests/Router.Ingress.Tests/Router.Ingress.Tests.csproj"
$adaptersTestsCsproj = "local-router/tests/Router.ClientAdapters.Responses.Tests/Router.ClientAdapters.Responses.Tests.csproj"

foreach ($project in @($ingressCsproj, $adaptersCsproj, $ingressTestsCsproj, $adaptersTestsCsproj)) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $project))) {
        Fail "LR-3 project missing: $project"
    }
}

$sln = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/LocalRouter.sln")
foreach ($project in @("Router.Ingress", "Router.ClientAdapters.Responses", "Router.Ingress.Tests", "Router.ClientAdapters.Responses.Tests")) {
    if ($sln.Contains($project)) {
        Pass "LocalRouter.sln includes: $project"
    }
    else {
        Fail "LocalRouter.sln is missing: $project"
    }
}

$ingressSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Ingress") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$nonControlPlaneIngressSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Ingress") -Recurse -File -Filter "*.cs" | Where-Object { $_.Name -notlike "*ControlPlane*" } | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$adapterSource = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.ClientAdapters.Responses") -Recurse -File -Filter "*.cs" | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"

# 1. Exact allowed endpoints.
foreach ($endpoint in @(
    @{ Marker = 'MapPost("/v1/responses"'; Description = "POST /v1/responses" }
    @{ Marker = 'MapGet("/health"'; Description = "GET /health" }
    @{ Marker = 'MapGet("/v1/router/status"'; Description = "GET /v1/router/status" }
    @{ Marker = 'MapGet("/v1/router/control-plane/status"'; Description = "GET /v1/router/control-plane/status" }
    @{ Marker = 'MapGet("/v1/router/control-plane/usage"'; Description = "GET /v1/router/control-plane/usage" }
    @{ Marker = 'MapGet("/v1/router/control-plane/requests"'; Description = "GET /v1/router/control-plane/requests" }
    @{ Marker = 'MapGet("/v1/router/control-plane/policy"'; Description = "GET /v1/router/control-plane/policy" }
    @{ Marker = 'MapPut("/v1/router/control-plane/policy"'; Description = "PUT /v1/router/control-plane/policy" }
    @{ Marker = 'MapPut("/v1/router/control-plane/feature"'; Description = "PUT /v1/router/control-plane/feature" }
)) {
    if ($ingressSource.Contains($endpoint.Marker)) {
        Pass "Ingress registers allowed endpoint: $($endpoint.Description)"
    }
    else {
        Fail "Ingress does not register allowed endpoint: $($endpoint.Description)"
    }
}

foreach ($forbidden in @(
    '/v1/chat/completions',
    '/v1/completions',
    '/v1/models',
    '/v1/responses/{',
    '/admin',
    '/debug',
    '/metrics',
    '/provider/',
    '/routes',
    '/config/'
)) {
    Require-NotContain "Ingress endpoints" $ingressSource $forbidden "forbidden endpoint must not exist"
}

# 2. Loopback-only binding.
if ($ingressSource.Contains('IPAddress.Loopback')) {
    Pass "Ingress binds IPAddress.Loopback"
}
else {
    Fail "Ingress does not bind IPAddress.Loopback"
}
foreach ($needle in @('"0.0.0.0"', '"::"', 'IPAddress.Any', 'IPAddress.IPv6Any', 'ListenLocalhost(')) {
    Require-NotContain "Ingress binding" $ingressSource $needle "non-loopback bind target"
}

# 3. No wildcard CORS.
foreach ($needle in @('AllowAnyOrigin', 'AllowAnyHeader', 'Access-Control-Allow-Origin: *', 'WithOrigins("*")')) {
    Require-NotContain "Ingress CORS" $ingressSource $needle "wildcard browser access"
}

# 4. No provider network / domains / adapters in LR-3 source.
foreach ($needle in @('HttpClient', 'api.openai.com', 'api.deepseek.com', 'openrouter.ai', 'dashscope', 'MIMO_API_KEY', 'CODEX_OPENAI_API_KEY', 'CODEX_DASHSCOPE_API_KEY', 'OPENROUTER_API_KEY')) {
    Require-NotContain "Ingress providers" $ingressSource $needle "real provider call or key reference"
}
foreach ($needle in @('ProviderAdapter', 'RouteResolver', 'ModelRegistry', 'RetryPolicy', 'FailoverPolicy', 'CircuitBreaker', 'Pricing', 'CostEstimate')) {
    Require-NotContain "LR-3 types" $nonControlPlaneIngressSource $needle "LR-4+ leakage outside the LR-14P control-plane surface"
    Require-NotContain "LR-3 adapter types" $adapterSource $needle "LR-4+ leakage"
}

# 5. No auth.json / .env access.
foreach ($needle in @('auth.json', '.env')) {
    Require-NotContain "Ingress secrets" $ingressSource $needle "secret file access"
    Require-NotContain "Adapter secrets" $adapterSource $needle "secret file access"
}

# 6. Defaults stay disabled with loopback host and canonical port.
$defaultsPath = Join-Path $RepositoryRoot "local-router/config/router.defaults.json"
$defaults = Get-Content -Raw -LiteralPath $defaultsPath | ConvertFrom-Json
if ($defaults.local_router.enabled -eq $false -and $defaults.mode -eq "direct") {
    Pass "router.defaults.json remains disabled (mode=direct, enabled=false)"
}
else {
    Fail "router.defaults.json must keep mode=direct and local_router.enabled=false"
}
if ($defaults.local_router.host -eq "127.0.0.1") {
    Pass "router.defaults.json host remains 127.0.0.1"
}
else {
    Fail "router.defaults.json host must remain 127.0.0.1"
}
if ($defaults.local_router.port -eq 47821) {
    Pass "router.defaults.json port remains 47821"
}
else {
    Fail "router.defaults.json port must remain 47821"
}

# 7. Protected production files must be untouched by this branch.
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
Write-Host "Local Router ingress validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router ingress validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router ingress validation PASSED" -ForegroundColor Green
exit 0
