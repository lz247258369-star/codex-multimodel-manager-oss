param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
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

function Require-Contains([string]$Name, [string]$Text, [string]$Needle, [string]$Description) {
    if ($Text.Contains($Needle)) {
        Pass "$Name contains '$Needle' ($Description)"
    }
    else {
        Fail "$Name is missing '$Needle' ($Description)"
    }
}

function Require-NotContains([string]$Name, [string]$Text, [string]$Needle, [string]$Description) {
    if ($Text.Contains($Needle)) {
        Fail "$Name contains forbidden marker '$Needle' ($Description)"
    }
    else {
        Pass "$Name has no '$Needle' ($Description)"
    }
}

Write-Host "Repository: $RepositoryRoot" -ForegroundColor Cyan

$ingressDir = Join-Path $RepositoryRoot "local-router/src/Router.Ingress"
$hostDir = Join-Path $RepositoryRoot "local-router/src/Router.Host"
$meteringDir = Join-Path $RepositoryRoot "local-router/src/Router.Metering"

$ingressSource = Get-ChildItem -LiteralPath $ingressDir -Recurse -File -Filter "*.cs" |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
    ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$hostSource = Get-ChildItem -LiteralPath $hostDir -Recurse -File -Filter "*.cs" |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
    ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"
$meteringSource = Get-ChildItem -LiteralPath $meteringDir -Recurse -File -Filter "*.cs" |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
    ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName } | Join-String -Separator "`n"

$ingressCsproj = Get-Content -Raw -LiteralPath (Join-Path $ingressDir "Router.Ingress.csproj")
$hostCsproj = Get-Content -Raw -LiteralPath (Join-Path $hostDir "Router.Host.csproj")

# 1. Typed ingress-safe completion seam.
Require-Contains "Router.Ingress" $ingressSource "record RequestUsageCompletion" "typed usage completion record"
Require-Contains "Router.Ingress" $ingressSource "OnUsageCompletedAsync" "production completion observer seam"
Require-Contains "Router.Ingress" $ingressSource "ResponsesExecutionMetadata" "execution-carried identity contract flows through ingress"
Require-Contains "Router.Ingress" $ingressSource "ToIdentity(execution)" "identity is a pure projection of the authoritative execution result"
Require-NotContains "Router.Ingress" $ingressSource "IRequestUsageIdentityResolver" "config identity resolver seam is removed from ingress"
Require-NotContains "Router.Ingress" $ingressSource "UsageIdentityResolver" "no resolver override is wired through IngressServices"
Require-NotContains "Router.Ingress" $ingressSource "Resolve(clientId" "ingress never looks up identity from client/model strings"
Require-NotContains "Router.Ingress" $ingressSource "Task.Run" "ingress must never fire a per-request background task"

# 1b. ResponsesServiceResult.Execution is the single authoritative identity
# contract; no duplicate ResponsesExecutionMetadata type may exist.
$metadataFile = Join-Path $RepositoryRoot "local-router/src/Router.ClientAdapters.Responses/ResponsesExecutionMetadata.cs"
if (Test-Path -LiteralPath $metadataFile) {
    Pass "Authoritative ResponsesExecutionMetadata.cs exists"
}
else {
    Fail "Missing authoritative ResponsesExecutionMetadata.cs"
}
$serviceContractSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.ClientAdapters.Responses/IResponsesService.cs")
Require-NotContains "IResponsesService.cs" $serviceContractSource "record ResponsesExecutionMetadata" "no inline duplicate execution metadata in the service contract"
$metadataSource = if (Test-Path -LiteralPath $metadataFile) { Get-Content -Raw -LiteralPath $metadataFile } else { "" }
Require-Contains "ResponsesExecutionMetadata.cs" $metadataSource "record ResponsesExecutionMetadata" "the authoritative metadata record is defined once in its own file"
$executionMetadataCount = ([regex]::Matches(($hostSource + $ingressSource + $serviceContractSource + $metadataSource + $meteringSource), "record ResponsesExecutionMetadata")).Count
if ($executionMetadataCount -eq 1) {
    Pass "Exactly one ResponsesExecutionMetadata definition exists across Router production source"
}
else {
    Fail "Expected exactly one ResponsesExecutionMetadata definition, found $executionMetadataCount"
}

# 2. Ingress composes the production Metering/Observability instances only for
# the LR-14P control-plane read surface; it never constructs its own estimator,
# store, log, or catalog.
Require-Contains "Router.Ingress.csproj" $ingressCsproj "Router.Metering" "control-plane reads the production metering instance (LR-14P)"
Require-Contains "Router.Ingress.csproj" $ingressCsproj "Router.Observability" "control-plane reads the production durable log instance (LR-14P)"
Require-NotContains "Router.Ingress" $ingressSource "new CostEstimator" "ingress must not construct cost estimator"
Require-NotContains "Router.Ingress" $ingressSource "model-catalog.json" "ingress must not read the catalog"

# 3. Host composition wires production observer and meter.
Require-Contains "Router.Host.csproj" $hostCsproj "Router.Metering" "host references metering"
Require-Contains "Router.Host.csproj" $hostCsproj "Router.Observability" "host references observability"
Require-Contains "Router.Host.csproj" $hostCsproj "Router.CatalogProjection" "host references catalog projection"
Require-Contains "Router.Host" $hostSource "RouterExecutionServiceFactory.Create" "default enabled host path builds the production execution service"
Require-NotContains "Router.Host" $hostSource "new FakeResponsesService(" "host production default never constructs the fake service"
Require-Contains "Router.Host" $hostSource "ProductionCompletionObserver" "host production observer type"
Require-Contains "Router.Host" $hostSource "observer: observability.Observer" "host passes non-null observer to ingress"
Require-Contains "Router.Host" $hostSource "RequestMeteringService" "host composes metering recorder"
Require-NotContains "Router.Host" $hostSource "ConfigurationUsageIdentityResolver" "config-inferred identity resolver is removed from host"
Require-NotContains "Router.Host" $hostSource "usageIdentityResolver" "host never wires a diagnostic resolver into production ingress"

# 3d. Production execution -> metering integration is covered by real E2E
# assertions (loopback fake upstream only; never a paid or external provider).
$productionE2E = Join-Path $RepositoryRoot "local-router/tests/Router.Execution.Tests/Lr10RProductionExecutionMeteringE2ETests.cs"
if (Test-Path -LiteralPath $productionE2E) {
    $productionE2ESource = Get-Content -Raw -LiteralPath $productionE2E
    Pass "LR-10R production execution metering E2E file exists"
    foreach ($needle in @(
        "Non_stream_real_execution_attributes_authoritative_usage_and_cost",
        "Streaming_real_execution_binds_terminal_usage_to_pre_stream_identity_exactly_once",
        "Interrupted_stream_without_final_usage_never_fabricates_zero_usage_or_cost",
        "Retried_real_execution_records_one_logical_request_with_final_usage",
        "Same_model_failover_metering_uses_only_the_final_successful_execution_identity")) {
        Require-Contains "LR-10R E2E" $productionE2ESource $needle "production metering integration assertion '$needle'"
    }
}
else {
    Fail "Missing LR-10R production execution metering E2E file"
}

# 3b. Canonical catalog is packaged into Router.Host output/publish as one link.
Require-Contains "Router.Host.csproj" $hostCsproj "installer\model-catalog.json" "host links the canonical catalog source"
Require-Contains "Router.Host.csproj" $hostCsproj "Link>model-catalog.json" "host catalog link keeps the canonical output name"
Require-Contains "Router.Host.csproj" $hostCsproj "CopyToOutputDirectory>PreserveNewest" "host copies catalog to output"
Require-Contains "Router.Host.csproj" $hostCsproj "CopyToPublishDirectory>PreserveNewest" "host copies catalog to publish output"

# 3c. Completion boundary is a bounded dispatcher with a shutdown drain.
Require-Contains "Router.Host" $hostSource "Channel.CreateBounded" "host completion observer uses a bounded queue"
Require-Contains "Router.Host" $hostSource "SingleReader = true" "host completion queue has one background consumer"
Require-Contains "Router.Host" $hostSource "DrainAsync" "host completion observer drains on shutdown"
Require-Contains "Router.Host" $hostSource "DefaultShutdownDrainTimeout" "shutdown drain has a hard timeout"
Require-NotContains "Router.Host" $hostSource "Task.Run" "host completion path creates no task per request"

# 4. Bounded safe metering store/service.
Require-Contains "Router.Metering" $meteringSource "class RequestMeteringService" "metering recorder service"
Require-Contains "Router.Metering" $meteringSource "class RequestMeteringStore" "bounded metering store"
Require-Contains "Router.Metering" $meteringSource "DefaultCapacity = 500" "bounded default capacity"
Require-Contains "Router.Metering" $meteringSource "MaxCapacity = 1000" "hard capacity ceiling"
Require-Contains "Router.Metering" $meteringSource "record RequestMeteringRecord" "versioned metering record"
Require-Contains "Router.Metering" $meteringSource "UsageNormalizer.Normalize" "normalizer invoked in production recorder"
Require-Contains "Router.Metering" $meteringSource "CostEstimator.Estimate" "cost estimator invoked in production recorder"
Require-Contains "Router.Metering" $meteringSource "IdentityUnavailable" "identity absence is explicit"
Require-Contains "Router.Metering" $meteringSource "UsageMissing" "usage absence is explicit"

# 5. No content/secret/path members in metering records.
foreach ($needle in @('Prompt','RawBody','Authorization','ApiKey','Cookie','HttpClient','FilePath','DirectoryPath')) {
    if ($meteringSource -match ('public\s+.*\s+' + $needle + '\b')) {
        Fail "RequestMetering types expose forbidden field: $needle"
    }
    else {
        Pass "RequestMetering types expose no '$needle' field"
    }
}

# 6. Endpoint surface: exact allowlist. The three original routes, the six
# LR-14P control-plane routes, and the ten additive HS-1B thread-selection
# routes. Every expected route must exist and no route outside the list may be
# mapped, so the surface can never drift silently.
$ingressEndpointSource = Get-Content -Raw -LiteralPath (Join-Path $ingressDir "ResponsesIngress.cs")
$expectedEndpoints = @(
    @{ Method = "Get"; Path = "/health" }
    @{ Method = "Get"; Path = "/v1/router/status" }
    @{ Method = "Get"; Path = "/v1/router/control-plane/status" }
    @{ Method = "Get"; Path = "/v1/router/control-plane/usage" }
    @{ Method = "Get"; Path = "/v1/router/control-plane/requests" }
    @{ Method = "Get"; Path = "/v1/router/control-plane/policy" }
    @{ Method = "Put"; Path = "/v1/router/control-plane/policy" }
    @{ Method = "Put"; Path = "/v1/router/control-plane/feature" }
    @{ Method = "Get"; Path = "/v1/router/control-plane/thread-selection-feature" }
    @{ Method = "Put"; Path = "/v1/router/control-plane/thread-selection-feature" }
    @{ Method = "Get"; Path = "/v1/router/control-plane/threads" }
    @{ Method = "Delete"; Path = "/v1/router/control-plane/threads/selections" }
    @{ Method = "Post"; Path = "/v1/router/control-plane/threads/capture" }
    @{ Method = "Get"; Path = "/v1/router/control-plane/threads/capture/{token}" }
    @{ Method = "Delete"; Path = "/v1/router/control-plane/threads/capture/{token}" }
    @{ Method = "Get"; Path = "/v1/router/control-plane/threads/{threadRef}/selection" }
    @{ Method = "Put"; Path = "/v1/router/control-plane/threads/{threadRef}/selection" }
    @{ Method = "Delete"; Path = "/v1/router/control-plane/threads/{threadRef}/selection" }
    @{ Method = "Post"; Path = "/v1/responses" }
)
$missingEndpoints = @()
foreach ($endpoint in $expectedEndpoints) {
    $marker = 'app.Map' + $endpoint.Method + '("' + $endpoint.Path + '"'
    if (-not $ingressEndpointSource.Contains($marker)) {
        $missingEndpoints += ('{0} {1}' -f $endpoint.Method.ToUpperInvariant(), $endpoint.Path)
    }
}
if ($missingEndpoints.Count -eq 0) {
    Pass "Endpoint surface contains every expected route ($($expectedEndpoints.Count))"
}
else {
    foreach ($missing in $missingEndpoints) {
        Fail "Endpoint surface is missing: $missing"
    }
}

$mappedCount = ([regex]::Matches($ingressEndpointSource, 'app\.Map(?:Get|Post|Put|Delete)\(')).Count
if ($mappedCount -eq $expectedEndpoints.Count) {
    Pass "Endpoint surface maps no route outside the expected set"
}
else {
    Fail "Endpoint surface changed: expected $($expectedEndpoints.Count) mapped routes, found $mappedCount"
}

# 7. Protected files untouched by this remediation.
$changedFiles = @(& git -C $RepositoryRoot diff --name-only "main...HEAD" 2>$null)
$changedFiles += @(& git -C $RepositoryRoot ls-files --modified)
$changedFiles = @($changedFiles | Where-Object { $_ } | Sort-Object -Unique)
$protectedPatterns = @(
    '(?i)^installer/scripts/(router-codex-cli|desktop-router-route|desktop-chat-route|visual-)',
    '(?i)^installer/ui/',
    '(?i)^installer/model-catalog\.json$',
    '(?i)^local-router/src/Router\.ProviderAdapters\.',
    '(?i)^local-router/src/Router\.ProtocolAdapters\.',
    '(?i)^local-router/src/Router\.Policies/',
    '(?i)^local-router/src/Router\.CircuitBreaker/'
)
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
if ($protectedHits.Count -eq 0) {
    Pass "No protected provider/protocol/policy/V4/LR-12/LR-13 file modified"
}
else {
    foreach ($file in ($protectedHits | Sort-Object -Unique)) {
        Fail "Protected file modified: $file"
    }
}

Write-Host ""
Write-Host "Local Router metering remediation validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"
if ($failures.Count -gt 0) {
    Write-Host "Local Router metering remediation validation FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "Local Router metering remediation validation PASSED" -ForegroundColor Green
exit 0
