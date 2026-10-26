param(
    [Parameter(Mandatory=$true)][string]$ProviderId,
    [Parameter(Mandatory=$true)][string]$ModelId,
    [string]$DisplayName = ""
)

$ErrorActionPreference = "Stop"

# NPG1-CANDIDATE-INTAKE - explicit, fully offline candidate intake.
#
# The formal discovery run only turns a model into a candidate when that model
# is new relative to a previously captured discovery baseline, so a model that
# is already present in the canonical installer/model-catalog.json (and already
# live at the provider) can never enter the review chain. This entry point fills
# that gap in a strictly bounded way:
#
#   * offline by construction: no /models discovery, no /responses probe, no
#     provider request of any kind, and it never dot-sources or launches the
#     discovery, probe or approval entry points;
#   * it only accepts a model that already exists in the canonical catalog under
#     the canonical provider that the given provider id maps to;
#   * it never fabricates a probe result. A canonical catalog status of
#     verified/configured is a repository statement, not a runtime probe
#     outcome, so a new candidate always starts as
#     status=NEW / basic_probe=NOT_RUN / tool_probe=NOT_RUN / approved=false;
#   * it never approves. A live basic probe (basic_probe=PASS) plus the formal
#     approval entry point stay mandatory before any approval record exists.
#
# Every write is additive and fail-closed: other candidate records are
# preserved, a re-run is a no-op, an approved record is never downgraded, and a
# corrupt candidates.json is never rebuilt or overwritten.

. (Join-Path $PSScriptRoot "_registry.ps1")
# Reuse the repository's canonical provider mapping (manager id <-> catalog id)
# instead of duplicating a provider table here.
. (Join-Path $PSScriptRoot "controller-catalog.ps1")

function Get-CanonicalCatalogPath {
    $installerRoot = Split-Path -Parent $PSScriptRoot
    return (Join-Path $installerRoot "model-catalog.json")
}

$canonicalIntakeNotes = "Explicit canonical-catalog intake; live probe required before approval."

# --- 1. The provider must be a configured/enabled manager provider -----------
$providers = Get-ProviderMap
if (-not $providers.Contains($ProviderId)) {
    throw "Provider is not configured or not enabled, refusing candidate intake: $ProviderId"
}

# --- 2. The provider must have a canonical catalog identity ------------------
$catalogProviderId = Convert-ControllerProviderId $ProviderId
if ([string]::IsNullOrWhiteSpace($catalogProviderId)) {
    throw "Provider has no canonical catalog mapping, refusing candidate intake: $ProviderId"
}

# --- 3. The model must already exist in the canonical catalog ----------------
$catalogPath = Get-CanonicalCatalogPath
if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
    throw "Canonical model catalog is missing: $catalogPath"
}
$catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
if ($null -eq $catalog.providers -or [int]$catalog.version -ne 3) {
    throw "Canonical model catalog schema is not the expected v3: $catalogPath"
}

$catalogProvider = @($catalog.providers | Where-Object { [string]$_.id -eq $catalogProviderId }) | Select-Object -First 1
if ($null -eq $catalogProvider) {
    throw "Canonical catalog has no provider entry '$catalogProviderId' for manager provider $ProviderId."
}

$catalogModel = @($catalogProvider.models | Where-Object { [string]$_.id -eq $ModelId }) | Select-Object -First 1
if ($null -eq $catalogModel) {
    # Fail closed either way, but name the real reason: a canonical model that
    # belongs to a different provider is a provider/model mismatch, not an
    # unknown model.
    $otherProviders = New-Object System.Collections.Generic.List[string]
    foreach ($candidateProvider in @($catalog.providers)) {
        if ([string]$candidateProvider.id -eq $catalogProviderId) { continue }
        $match = @($candidateProvider.models | Where-Object { [string]$_.id -eq $ModelId })
        if ($match.Count -gt 0) { $otherProviders.Add([string]$candidateProvider.id) }
    }
    if ($otherProviders.Count -gt 0) {
        throw ("Provider/model mismatch, refusing candidate intake: $ProviderId / $ModelId " +
            "(that model belongs to canonical provider: " + ($otherProviders -join ", ") + ")")
    }
    throw "Model is not in the canonical catalog, refusing candidate intake: $ModelId"
}

# --- 4. Read the existing candidate registry, fail closed when unreadable ----
$candidatesPath = Get-RegistryPath "candidates.json"
$candidates = @()
if (Test-Path -LiteralPath $candidatesPath -PathType Leaf) {
    try {
        $candidates = @(Load-JsonFile $candidatesPath @())
    }
    catch {
        throw ("candidates.json cannot be parsed, refusing to write (fail closed, the " +
            "existing file is left untouched): $candidatesPath`n$($_.Exception.Message)")
    }
}

$key = $ProviderId + "::" + $ModelId
$existing = @($candidates | Where-Object {
        [string]$_.key -eq $key -or
        ([string]$_.provider_id -eq $ProviderId -and [string]$_.model_id -eq $ModelId)
    }) | Select-Object -First 1

if ($null -ne $existing) {
    $existingApproved = $false
    if ($existing.PSObject.Properties["approved"] -and [bool]$existing.approved) { $existingApproved = $true }
    if ($existing.PSObject.Properties["status"] -and [string]$existing.status -eq "APPROVED") { $existingApproved = $true }
    if ($existingApproved) {
        Write-Host "ALREADY_APPROVED" -ForegroundColor Yellow
        Write-Host "Provider: $ProviderId"
        Write-Host "Model:    $ModelId"
        Write-Host "An approved candidate is never downgraded; the registry was not rewritten."
        return
    }
    Write-Host "ALREADY_CANDIDATE" -ForegroundColor Yellow
    Write-Host "Provider: $ProviderId"
    Write-Host "Model:    $ModelId"
    Write-Host "The candidate already exists; nothing was added and the registry was not rewritten."
    return
}

$displayName = $DisplayName
if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = [string]$catalogModel.label }
if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $ModelId }

$entry = [pscustomobject]@{
    key = $key
    provider_id = $ProviderId
    provider_name = [string]$providers[$ProviderId].name
    model_id = $ModelId
    name = $displayName
    first_seen = (Get-Date -Format "o")
    status = "NEW"
    basic_probe = "NOT_RUN"
    tool_probe = "NOT_RUN"
    approved = $false
    notes = $canonicalIntakeNotes
}
$candidates = @($candidates) + @($entry)
Save-JsonFile $candidatesPath $candidates

Write-Host "ADDED" -ForegroundColor Green
Write-Host "Provider:         $ProviderId"
Write-Host "Canonical source: $catalogProviderId"
Write-Host "Model:            $ModelId"
Write-Host "Catalog status:   $([string]$catalogModel.status) (repository statement only, not a probe result)"
Write-Host "Candidate state:  status=NEW basic_probe=NOT_RUN tool_probe=NOT_RUN approved=false"
Write-Host "Registry:         $candidatesPath"
Write-Host "Next step:        run the live basic probe, then the formal approval step (this script never probes or approves)"
