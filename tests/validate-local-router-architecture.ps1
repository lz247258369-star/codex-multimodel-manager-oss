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

function Read-RequiredDocument([string]$RelativePath) {
    $path = Join-Path $RepositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Fail "Required architecture document is missing: $RelativePath"
        return ""
    }
    Pass "Required architecture document exists: $RelativePath"
    return (Get-Content -Raw -LiteralPath $path)
}

function Require-Markers([string]$Name, [string]$Text, [string[]]$Markers) {
    foreach ($marker in $Markers) {
        if ($Text.Contains($marker)) {
            Pass "$Name contains: $marker"
        }
        else {
            Fail "$Name is missing: $marker"
        }
    }
}

Write-Host "Repository: $RepositoryRoot" -ForegroundColor Cyan

$architecture = Read-RequiredDocument "docs/LOCAL_ROUTER_RUNTIME_ARCHITECTURE.md"
$contracts = Read-RequiredDocument "docs/LOCAL_ROUTER_RUNTIME_CONTRACTS.md"
$roadmap = Read-RequiredDocument "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md"
$allDocs = $architecture + "`n" + $contracts + "`n" + $roadmap

Require-Markers "Architecture" $architecture @(
    "## Mission",
    "## Why Router Mode",
    "## Existing Direct Mode",
    "## Target Architecture",
    "## Component boundaries",
    "## Data flow",
    "## Request flow",
    "## Protocol flow",
    "## Security boundary",
    "## Secret boundary",
    "## State machines",
    "## Failure model",
    "## Configuration ownership",
    "## Compatibility",
    "## Migration",
    "## Rollback",
    "## Out of Scope",
    "## Build order",
    "127.0.0.1",
    "47821",
    "POST /v1/responses",
    "GET /health",
    "GET /v1/router/status",
    "Direct Mode [DEFAULT]",
    "Router Mode [DISABLED]",
    "local_router.enabled=false",
    "Cross-model fallback is **OFF by default**",
    "launch-controller-model.ps1",
    "desktop-chat-provider.ps1",
    "desktop-chat-route.ps1"
)

$components = @(
    "Router Core", "Client Ingress", "Route Resolver", "Provider Adapter Registry",
    "Protocol Adapter Registry", "Model Mapping Registry", "Secret Resolver Interface",
    "Router Configuration", "Router Lifecycle", "Health Check", "Request Trace",
    "Request Log", "Usage Metering", "Cost Metering", "Retry Policy", "Timeout Policy",
    "Failover Policy", "Circuit Breaker boundary", "Streaming / SSE handling",
    "Tool-call handling", "Error normalization", "Cancellation", "Request ID / Trace ID",
    "Router state", "Migration / rollback", "Feature flag",
    "Direct Mode compatibility boundary", "Codex CLI adapter", "Codex Desktop adapter",
    "Future client adapter boundary"
)
Require-Markers "Architecture component list" $architecture $components

Require-Markers "Contracts" $contracts @(
    "## IDs and versions",
    "## Canonical entities",
    "### RouterConfig",
    "### ClientDefinition",
    "### ProtocolRoute",
    "### ProviderRoute",
    "### ModelRoute",
    "### RouterRoute",
    "## State entities",
    "## Pricing entities",
    "### ModelPricing",
    "### ProviderPricing",
    "### UsageRecord",
    "### CostEstimate",
    "## API contracts",
    '### `POST /v1/responses`',
    '### `GET /health`',
    '### `GET /v1/router/status`',
    "## Adapter interfaces",
    "## Provider adapter registry",
    "## Protocol adapter registry",
    "## SecretReference contract",
    "## Lifecycle contracts",
    "## Errors",
    "## Retry contract",
    "## Timeout contract",
    "## Idempotency contract",
    "## Cancellation contract",
    "## Failover contract",
    "## Circuit breaker contract",
    "## Streaming and SSE contract",
    "## Reasoning and tool contracts",
    "## Multimodal boundary",
    "## Observability contract",
    "## Health contract",
    "## Configuration, migration, and rollback contracts",
    "## Feature flag and permission contract",
    "## Direct Mode compatibility contract",
    "## Test and fixture contract",
    "## Deferred contracts",
    '"mode": "direct"',
    '"enabled": false',
    "cross_model_fallback = OFF",
    "STOPPED", "STARTING", "READY", "DEGRADED", "STOPPING", "FAILED",
    "UNKNOWN", "HEALTHY", "UNHEALTHY", "DISABLED",
    "RECEIVED", "ROUTED", "UPSTREAM_PENDING", "STREAMING", "COMPLETED", "CANCELLED"
)

Require-Markers "Provider mapping" $contracts @(
    '`chatgpt`', '`mm_openai_api`', '`mm_modelstudio`', '`mm_openrouter`', '`mm_mimo`',
    "DeepSeek/Qwen direct", "Z.ai", "Anthropic", "MiniMax", "SiliconFlow", "ModelScope", "NVIDIA"
)

Require-Markers "Secret reference boundary" $allDocs @(
    "OPENROUTER_API_KEY",
    "CODEX_DASHSCOPE_API_KEY",
    "MIMO_API_KEY",
    "CODEX_LOCAL_ROUTER_TOKEN",
    "SecretReference",
    "secret_missing",
    "secret_scope_violation",
    "rotation",
    "redaction"
)

Require-Markers "V1 and deferred protocol boundary" $allDocs @(
    "OpenAI Responses API semantics",
    "Streaming/SSE",
    "Reasoning",
    "Tool calls/results",
    "Images/multimodal",
    "Usage",
    "Errors",
    "Cancellation",
    "Deferred"
)

$level3Fields = @(
    "Responsibility", "input", "output", "Core entity", "schema", "ID", "version",
    "State machine", "checkpoint", "Provider", "Protocol Adapter", "Error", "retry",
    "timeout", "idempotency", "cancellation", "observability", "permission", "secret",
    "Migration", "feature flag", "rollback", "Unit", "contract", "integration",
    "regression", "golden", "eval", "Release gate", "build order", "PR boundary",
    "out of scope", "Definition of Ready", "Definition of Done"
)
Require-Markers "Level 3 coverage" $allDocs $level3Fields

Require-Markers "Roadmap" $roadmap @(
    "## Build order",
    "## Release gates",
    "## Architecture Definition of Ready",
    "## Architecture Definition of Done"
)

$sliceFields = @(
    "**Goal**", "**Inputs**", "**Outputs**", "**Files**", "**Dependencies**", "**Tests**",
    "**Out of Scope**", "**Definition of Ready**", "**Definition of Done**", "**Rollback**", "**PR Boundary**"
)

$sliceMatches = [regex]::Matches($roadmap, '(?ms)^## (LR-\d+[A-Z]?)\s+([^\r\n]*)\r?\n(.*?)(?=^## LR-\d+[A-Z]?\s|^## Cross-slice|\z)')
if ($sliceMatches.Count -lt 16) {
    Fail "Roadmap must define at least 16 independently reviewable slices; found $($sliceMatches.Count)"
}
else {
    Pass "Roadmap defines $($sliceMatches.Count) independently reviewable slices"
}

foreach ($slice in $sliceMatches) {
    $sliceId = $slice.Groups[1].Value
    $sliceTitle = $slice.Groups[2].Value.Trim()
    $sliceBody = $slice.Groups[3].Value
    foreach ($field in $sliceFields) {
        if (-not $sliceBody.Contains($field)) {
            Fail "$sliceId is missing required field: $field"
        }
    }
    if (-not ($failures | Where-Object { $_ -like "$sliceId is missing required field:*" })) {
        Pass "$sliceId contains all required slice fields"
    }
}

# A provider adapter slice must carry exactly one provider implementation.
$adapterIds = @('mm_openai_api', 'mm_mimo', 'mm_openrouter', 'mm_modelstudio')
foreach ($slice in $sliceMatches) {
    $sliceId = $slice.Groups[1].Value
    $sliceBody = $slice.Groups[3].Value
    if (-not $sliceBody.Contains('**Provider Implementation**')) { continue }
    $markerCount = ([regex]::Matches($sliceBody, [regex]::Escape('**Provider Implementation**'))).Count
    $implemented = @($adapterIds | Where-Object { $sliceBody.Contains('`' + $_ + '`') })
    if ($markerCount -ne 1 -or $implemented.Count -ne 1) {
        Fail "$sliceId must contain exactly one provider implementation (markers=$markerCount, providers=$($implemented -join ','))"
    }
    else {
        Pass "$sliceId implements exactly one provider adapter: $implemented"
    }
}

# LR-7A must exist and implement only mm_openai_api.
$lr7a = @($sliceMatches | Where-Object { $_.Groups[1].Value -eq 'LR-7A' })
if ($lr7a.Count -eq 1 -and $lr7a[0].Groups[3].Value.Contains('`mm_openai_api`') -and -not $lr7a[0].Groups[3].Value.Contains('`mm_mimo`')) {
    Pass 'LR-7A exists and implements only mm_openai_api'
}
else {
    Fail 'LR-7A must exist and implement only mm_openai_api (never mm_mimo)'
}

# LR-7B must exist and implement only mm_mimo.
$lr7b = @($sliceMatches | Where-Object { $_.Groups[1].Value -eq 'LR-7B' })
if ($lr7b.Count -eq 1 -and $lr7b[0].Groups[3].Value.Contains('`mm_mimo`') -and -not $lr7b[0].Groups[3].Value.Contains('`mm_openai_api`')) {
    Pass 'LR-7B exists and implements only mm_mimo'
}
else {
    Fail 'LR-7B must exist and implement only mm_mimo (never mm_openai_api)'
}

# Semantic slice owners must map to the corrected LR numbers.
$semanticOwners = [ordered]@{
    'LR-8'  = 'Protocol Adapter Boundary'
    'LR-9'  = 'Health'
    'LR-10' = 'Usage and Cost'
    'LR-11' = 'Policy, Retry, Failover, and Circuit Breaker'
    'LR-12' = 'Codex CLI'
    'LR-13' = 'Codex Desktop'
    'LR-14' = 'V4 UI'
    'LR-15' = 'Hardening'
}
foreach ($ownerId in $semanticOwners.Keys) {
    $ownerKeyword = $semanticOwners[$ownerId]
    $hit = @($sliceMatches | Where-Object { $_.Groups[1].Value -eq $ownerId })
    if ($hit.Count -eq 1 -and $hit[0].Groups[2].Value -match [regex]::Escape($ownerKeyword)) {
        Pass "$ownerId owns: $($hit[0].Groups[2].Value.Trim())"
    }
    else {
        Fail "$ownerId must own: $ownerKeyword"
    }
}

# Architecture component owners must use the corrected LR numbers.
$componentOwners = @(
    @{ Name = 'Protocol Adapter Registry'; LR = 'LR-8' }
    @{ Name = 'Health Check'; LR = 'LR-9' }
    @{ Name = 'Request Trace'; LR = 'LR-9' }
    @{ Name = 'Request Log'; LR = 'LR-9' }
    @{ Name = 'Usage Metering'; LR = 'LR-10' }
    @{ Name = 'Cost Metering'; LR = 'LR-10' }
    @{ Name = 'Retry Policy'; LR = 'LR-11' }
    @{ Name = 'Timeout Policy'; LR = 'LR-11' }
    @{ Name = 'Failover Policy'; LR = 'LR-11' }
    @{ Name = 'Circuit Breaker boundary'; LR = 'LR-11' }
    @{ Name = 'Codex CLI adapter'; LR = 'LR-12' }
    @{ Name = 'Codex Desktop adapter'; LR = 'LR-13' }
)
foreach ($entry in $componentOwners) {
    $line = @($architecture -split "`n" | Where-Object { $_ -match ('^\|\s*\d+\s*\|\s*' + [regex]::Escape($entry.Name) + '\b') } | Select-Object -First 1)
    if ($line.Count -eq 1 -and $line[0] -match [regex]::Escape($entry.LR)) {
        Pass "Architecture $($entry.Name) is owned by $($entry.LR)"
    }
    else {
        Fail "Architecture $($entry.Name) must be owned by $($entry.LR)"
    }
}

# The old review-state phrase must never appear.
if ($allDocs -match [regex]::Escape('unmerged/unpushed')) {
    Fail 'Architecture docs must not contain unmerged/unpushed'
}
else {
    Pass 'Architecture docs contain no unmerged/unpushed phrase'
}

# Contracts and Roadmap must agree on the implementation substrate.
$substrateMarkers = @(
    'language-neutral pseudotypes',
    'planned implementation substrate',
    'C# + ASP.NET Core',
    'LR-1 ADR must decide and pin the exact SDK, runtime, and package versions'
)
foreach ($marker in $substrateMarkers) {
    if ($contracts.Contains($marker) -and $roadmap.Contains($marker)) {
        Pass "Contracts and Roadmap both contain: $marker"
    }
    else {
        Fail "Contracts and Roadmap must both contain: $marker"
    }
}

# Architecture documentation may name credential environment variables but must
# never contain values that resemble committed credentials or private keys.
$secretPatterns = [ordered]@{
    "OpenAI-style key" = '\bsk-[A-Za-z0-9_-]{20,}\b'
    "GitHub token" = '\b(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}\b'
    "Google API key" = '\bAIza[0-9A-Za-z_-]{30,}\b'
    "private key block" = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
    "inline API key property" = '(?i)["''](?:api[_-]?key|authorization)["'']\s*:\s*["''](?!<|\$|Bearer\s+<)[^"'']{8,}["'']'
}
foreach ($entry in $secretPatterns.GetEnumerator()) {
    if ($allDocs -match $entry.Value) {
        Fail "Architecture docs contain a forbidden credential-shaped value: $($entry.Key)"
    }
    else {
        Pass "Architecture docs contain no $($entry.Key) value"
    }
}

if ($allDocs -match '(?i)bind(?:s|ing)?\s+(?:to\s+)?0\.0\.0\.0' -and
    $allDocs -notmatch '(?i)(reject|rejected|forbid|forbidden|must not|never)[^\r\n]{0,80}0\.0\.0\.0') {
    Fail "Architecture could permit a wildcard network bind"
}
else {
    Pass "Architecture requires loopback-only and does not permit wildcard binding"
}

Write-Host ""
Write-Host "Local Router architecture validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Local Router architecture validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router architecture validation PASSED" -ForegroundColor Green
exit 0
