param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR7-C-FIX5 - PROTECTED-FILE AUTHORIZATION review.
#
# The FIX5 chain shipped five files under the protected
# "local-router/src/Router.ProviderAdapters.*" surface (the DeepSeek capability
# declaration, the adapter bridge wiring, and three provider-local bridge files)
# without registering an approved delta, so the protected-file policy treated
# them as unauthorized changes. This validator is the review that justifies the
# registration in tests/shared/protected-file-scope.ps1 ($Fix5ApprovedFiles):
#
#   1. the FIX5 approved commit identity is still present in this tree;
#   2. every registered file still carries its reviewed structural markers;
#   3. the registration is delta-exact (normalized SHA-256) and is revoked when
#      this validator is deleted;
#   4. mutation proofs show both the pin and the marker constraints are load
#      bearing.
#
# Everything here is offline and read-only against the repository: mutation
# proofs run in a throw-away tree under the system temp folder.

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }
function Assert-True([bool]$Condition, [string]$Message) { if ($Condition) { Pass $Message } else { Fail $Message } }

function Get-GitLines([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& git -C $RepositoryRoot @Arguments 2>$null)
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return @($output | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ([string]$_).Trim() })
}

function Test-GitAncestor([string]$Ancestor, [string]$Descendant) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & git -C $RepositoryRoot merge-base --is-ancestor $Ancestor $Descendant 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

. (Join-Path $RepositoryRoot "tests/shared/protected-file-scope.ps1")
. (Join-Path $RepositoryRoot "tests/shared/fix5-patch-identity.ps1")

$script:Fix5Base = "74482284838b438860f73ba7b83bb6dca83ad773"
$script:Fix5Chain = @(
    @('FIX5-A', '5f9a03ca289d46d33474208bfce94c1e585fae45'),
    @('B1a', '1ec68e0bcf06396076a7defe572501a2c77eece3'),
    @('B1a2', '33514098432cf64ca3879bc6fb891ee4cfb3cbee'),
    @('B1b-1', 'cf543bc9c814d0bd049351117b8fc7b307593602'),
    @('B1b-2', 'd0981d30c4b6162db033803c49da5e98f27a0d59'),
    @('B2', 'e702fd4b51295f0e95269eef6de210f5eb744f0a')
)

# The reviewed FIX5 commit that last touched each registered file. This binds the
# authorization to FIX5 commit identity, not merely to a hash value. B2 is the
# last chain commit, so it owns every bridge file it finalised.
$script:Fix5FileOwners = [ordered]@{
    "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderRequestWire.cs"       = "33514098432cf64ca3879bc6fb891ee4cfb3cbee"
    "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderCodec.cs"             = "1ec68e0bcf06396076a7defe572501a2c77eece3"
    "local-router/src/Router.ProviderAdapters.Responses/ResponsesCompatibleProviderAdapterBase.cs" = "5f9a03ca289d46d33474208bfce94c1e585fae45"
    "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekCapabilities.cs"      = "5f9a03ca289d46d33474208bfce94c1e585fae45"
    "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekProviderAdapter.cs"   = "e702fd4b51295f0e95269eef6de210f5eb744f0a"
    "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchRequestBridge.cs"   = "e702fd4b51295f0e95269eef6de210f5eb744f0a"
    "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchResponseBridge.cs"  = "e702fd4b51295f0e95269eef6de210f5eb744f0a"
    "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchStreamBridge.cs"    = "e702fd4b51295f0e95269eef6de210f5eb744f0a"
}

# Reviewed structural markers. These are the file-level assertions the earlier
# behavioural coverage could not provide.
$script:Fix5FileMarkers = [ordered]@{
    "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderRequestWire.cs" = @(
        'internal sealed record ResponsesProviderRequestWire',
        'internal sealed record ResponsesFunctionToolWire',
        'public const string FunctionToolType = "function";',
        'internal sealed class ResponsesToolChoiceWireConverter')
    "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderCodec.cs" = @(
        'ResponsesProviderRequestWire.FromCanonical(request)')
    "local-router/src/Router.ProviderAdapters.Responses/ResponsesCompatibleProviderAdapterBase.cs" = @(
        'invocation.Request.ApplyPatchTool is not null',
        'ResponsesProviderCodec.EncodeRequest(upstreamRequest)')
    "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekCapabilities.cs" = @(
        'public const string ApplyPatchCompatBridge = "apply_patch_compat_bridge";',
        'public static CapabilitySet SupportedCompatibilityBridges { get; }')
    "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekProviderAdapter.cs" = @(
        'ApplyPatchRequestBridge.IsEligible(',
        'ApplyPatchRequestBridge.CreateProviderLocalRequest(',
        'ApplyPatchResponseBridge.Apply(result, bridgeIsActive)',
        'ApplyPatchStreamBridge.Apply(')
    "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchRequestBridge.cs" = @(
        'public static class ApplyPatchRequestBridge',
        'public const string RequiredRouteCapability = "tools";',
        'public static bool IsEligible(',
        'public static Result<CanonicalResponsesRequest, RouterError> CreateProviderLocalRequest(')
    "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchResponseBridge.cs" = @(
        'public static class ApplyPatchResponseBridge',
        'public static ProviderAdapterResult Apply(',
        'public static Result<CanonicalResponsesResponse, RouterError> Restore(',
        'public static bool TryDecodePatch(')
    "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchStreamBridge.cs" = @(
        'public static class ApplyPatchStreamBridge',
        'public const string OutputItemDoneEvent = "response.output_item.done";',
        'public const string CompletedEvent = "response.completed";',
        'public const int MaxSyntheticCallsPerResponse = 4;')
}

function Get-Fix5FileMarkerErrors([string]$RelativePath, [string]$Text) {
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $script:Fix5FileMarkers.Contains($RelativePath)) { $errors.Add("no marker set for $RelativePath") ; return $errors.ToArray() }
    foreach ($marker in $script:Fix5FileMarkers[$RelativePath]) {
        if (-not $Text.Contains($marker)) { $errors.Add("missing reviewed marker in $RelativePath") }
    }
    return $errors.ToArray()
}

# --- 1. FIX5 approved commit identity ---------------------------------------
# LR15-G8F: the approved identity is "original SHA + stable patch-id + exact
# file/content proof". The original SHAs stay the recorded provenance; a pull
# request rebuilt from a new main by cherry-picking the same reviewed patches is
# accepted only when every reviewed patch resolves to exactly one ordered,
# linear, non-merge equivalent commit inside HEAD's ancestry.
$chainTail = $script:Fix5Chain[$script:Fix5Chain.Count - 1][1]
$script:Fix5Identity = Resolve-Fix5ReviewedIdentity -RepositoryRoot $RepositoryRoot -Base $script:Fix5Base -Chain $script:Fix5Chain
if ($script:Fix5Identity.Mode -ne "genesis") {
    foreach ($entry in $script:Fix5Chain) {
        $resolved = @(Get-GitLines @("rev-parse", "--verify", "--quiet", "$($entry[1])^{commit}"))
        Assert-True ($resolved.Count -gt 0) "1: $($entry[0]) commit $($entry[1].Substring(0, 8)) is present"
    }
}
if ($script:Fix5Identity.Mode -eq "genesis") {
    # OSS-GENESIS: the private FIX5 objects are not part of this history. The
    # recorded review (original SHAs, stable patch-ids, source-main equivalents)
    # is accepted only for the verified genesis root and is bound to its objects.
    Write-Host "NOTE  OSS-GENESIS: the FIX5 review is the recorded evidence bound to the verified genesis root $($script:Fix5Identity.GenesisRoot.Substring(0, 12))" -ForegroundColor Yellow
    Assert-True ($script:Fix5Identity.Errors.Count -eq 0) "1 (OSS-GENESIS): the FIX5 base/chain pins equal the recorded review and every reviewed FIX5 file is the reviewed blob at the verified genesis root"
    foreach ($fix5Error in $script:Fix5Identity.Errors) { Fail "1: $fix5Error" }
    foreach ($mappingLine in $script:Fix5Identity.Mapping) {
        $mappingParts = $mappingLine -split '\|'
        Write-Host "      fix5 identity: $($mappingParts[0])  $(([string]$mappingParts[1]).Substring(0, 8)) -> patch-id $($mappingParts[2]) -> $($mappingParts[3])" -ForegroundColor Cyan
    }
}
elseif ($script:Fix5Identity.Mode -eq "legacy") {
    Assert-True (Test-GitAncestor $chainTail "HEAD") "1: the approved FIX5 chain tail is an ancestor of HEAD"
}
elseif ($script:Fix5Identity.Mode -eq "portable") {
    Write-Host "NOTE  the original FIX5 chain is not an ancestor of HEAD; the reviewed identity is resolved through stable patch-ids (portable cherry-pick construction)." -ForegroundColor Yellow
    Assert-True ($script:Fix5Identity.Errors.Count -eq 0) "1: every reviewed FIX5 patch resolves to exactly one ordered, linear, non-merge equivalent commit"
    foreach ($fix5Error in $script:Fix5Identity.Errors) { Fail "1: $fix5Error" }
    if ($script:Fix5Identity.Errors.Count -eq 0) {
        Assert-True (Test-GitAncestor $script:Fix5Identity.EffectiveTail "HEAD") "1: the equivalent FIX5 chain tail is an ancestor of HEAD"
    }
    foreach ($mappingLine in $script:Fix5Identity.Mapping) {
        $mappingParts = $mappingLine -split '\|'
        Write-Host "      fix5 identity: $($mappingParts[0])  $(([string]$mappingParts[1]).Substring(0, 8)) -> patch-id $($mappingParts[2]) -> $($mappingParts[3])" -ForegroundColor Cyan
    }
}
else {
    Fail "1: the FIX5 reviewed chain objects are not readable in this clone"
}

# --- 2. Registered files are still the reviewed FIX5 content ----------------
$script:Fix5Genesis = ($script:Fix5Identity.Mode -eq "genesis")
if (-not $script:Fix5Genesis) {
    $script:Fix5OriginalPatchIdMap = Get-Fix5PatchIdMap -RepositoryRoot $RepositoryRoot -TipRef $chainTail
    $script:Fix5CurrentPatchIdMap = Get-Fix5PatchIdMap -RepositoryRoot $RepositoryRoot -TipRef "HEAD"
}
foreach ($relativePath in $script:Fix5FileOwners.Keys) {
    $approvedOwner = [string]$script:Fix5FileOwners[$relativePath]
    $owner = @(Get-GitLines @("log", "-1", "--format=%H", "--", $relativePath))
    if ($script:Fix5Genesis) {
        # OSS-GENESIS: ownership by the reviewed patch is replaced by ownership by
        # the verified genesis root plus the reviewed blob at root and HEAD.
        $evidence = @($script:Fix5Identity.Files | Where-Object { $_.Path -ceq $relativePath })
        if ($evidence.Count -eq 1) {
            Write-Host ("      owner: {0} | reviewed blob {1} | genesis {2} | HEAD {3} | owner {4}" -f (Split-Path $relativePath -Leaf), $evidence[0].ReviewedBlob.Substring(0, 8), `
                    $(if ($evidence[0].GenesisBlob) { $evidence[0].GenesisBlob.Substring(0, 8) } else { 'missing' }), $(if ($evidence[0].HeadBlob) { $evidence[0].HeadBlob.Substring(0, 8) } else { 'missing' }), `
                    $(if ($evidence[0].Owner) { $evidence[0].Owner.Substring(0, 8) } else { 'none' })) -ForegroundColor Cyan
        }
        Assert-True ($evidence.Count -eq 1 -and $evidence[0].Ok) "2 (OSS-GENESIS): $(Split-Path $relativePath -Leaf) is still the reviewed FIX5 blob, owned by the verified genesis root"
    }
    elseif ($owner.Count -ne 1) {
        Fail "2: $(Split-Path $relativePath -Leaf) has no single current owner commit"
    }
    else {
        $currentOwner = [string]$owner[0]
        $approvedIds = @(Get-Fix5PatchIdsForCommit -PatchIdMap $script:Fix5OriginalPatchIdMap -Commit $approvedOwner)
        $currentIds = @(Get-Fix5PatchIdsForCommit -PatchIdMap $script:Fix5CurrentPatchIdMap -Commit $currentOwner)
        $approvedPatchId = if ($approvedIds.Count -eq 1) { [string]$approvedIds[0] } else { "" }
        $currentPatchId = if ($currentIds.Count -eq 1) { [string]$currentIds[0] } else { "" }
        $currentIsSourceCommit = Test-Fix5NonMergeCommit $RepositoryRoot $currentOwner
        $currentAuthorized = Test-Lr13ProtectedFileChangeAuthorized $RepositoryRoot $relativePath
        $approvedPatchLabel = if ($approvedPatchId) { $approvedPatchId } else { "unresolved" }
        $currentPatchLabel = if ($currentPatchId) { $currentPatchId } else { "unresolved" }
        Write-Host ("      owner: {0} | original {1} (patch-id {2}) | current {3} (patch-id {4}) | non-merge {5} | normalized sha256 {6}" -f `
                (Split-Path $relativePath -Leaf), $approvedOwner.Substring(0, 8), $approvedPatchLabel, `
                $currentOwner.Substring(0, 8), $currentPatchLabel, $currentIsSourceCommit, $currentAuthorized) -ForegroundColor Cyan
        Assert-True ($approvedPatchId -ne "" -and $currentPatchId -ne "" -and $approvedPatchId -eq $currentPatchId -and $currentIsSourceCommit) "2: $(Split-Path $relativePath -Leaf) is still owned by its reviewed FIX5 patch"
    }

    $path = Join-Path $RepositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Fail "2: missing registered FIX5 file: $relativePath"
        continue
    }
    $markerErrors = @(Get-Fix5FileMarkerErrors $relativePath (Get-Content -Raw -LiteralPath $path))
    if ($markerErrors.Count -eq 0) {
        Pass "2: $(Split-Path $relativePath -Leaf) carries every reviewed marker"
    }
    else {
        foreach ($markerError in $markerErrors) { Fail "2: $markerError" }
    }
}

# --- 3. Delta-exact authorization -------------------------------------------
foreach ($relativePath in $script:Fix5FileOwners.Keys) {
    Assert-True (Test-Lr13ProtectedFileChangeAuthorized $RepositoryRoot $relativePath) "3: protected-file policy authorizes the registered FIX5 delta for $(Split-Path $relativePath -Leaf)"
}
# The registration must not authorize anything outside its own five files.
Assert-True (-not (Test-Lr13ProtectedFileChangeAuthorized $RepositoryRoot "installer/scripts/switch-model.ps1")) "3: the FIX5 registration does not widen any unrelated protected file"
    Assert-True ($script:Fix5ApprovedFiles.Count -eq $script:Fix5FileOwners.Count) "3: the FIX5 registration covers exactly the reviewed files"

# --- 4. Mutation proofs ------------------------------------------------------
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fix5-file-auth-" + [guid]::NewGuid().ToString("N"))
try {
    foreach ($relativePath in $script:Fix5FileOwners.Keys) {
        $destination = Join-Path $tempRoot $relativePath
        New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot $relativePath) -Destination $destination
    }

    # 4a. Without the review the authorization is revoked for every file.
    $revoked = @($script:Fix5FileOwners.Keys | Where-Object { -not (Test-Lr13ProtectedFileChangeAuthorized $tempRoot $_) })
    Assert-True ($revoked.Count -eq $script:Fix5FileOwners.Count) "4a: deleting the FIX5 file-authorization review revokes every registration (fail closed)"

    # 4b. With the review present and the files untouched the delta is authorized.
    $tempValidatorDir = Join-Path $tempRoot "tests"
    New-Item -ItemType Directory -Force -Path $tempValidatorDir | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $tempValidatorDir "validate-dsr7c-apply-patch-file-authorization.ps1")
    $authorized = @($script:Fix5FileOwners.Keys | Where-Object { Test-Lr13ProtectedFileChangeAuthorized $tempRoot $_ })
    Assert-True ($authorized.Count -eq $script:Fix5FileOwners.Count) "4b: the reviewed FIX5 delta is authorized once its review is present"

    # 4c. An unauthorized future mutation of a registered file fails closed.
    $mutatedRelative = "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchResponseBridge.cs"
    $mutatedPath = Join-Path $tempRoot $mutatedRelative
    $original = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $mutatedRelative)
    [System.IO.File]::WriteAllText($mutatedPath, ($original + "`n// UNAUTHORIZED FIX5 MUTATION MARKER`n"), [System.Text.UTF8Encoding]::new($false))
    Assert-True (-not (Test-Lr13ProtectedFileChangeAuthorized $tempRoot $mutatedRelative)) "4c: an unauthorized future mutation of a registered FIX5 file fails the delta-exact gate"

    # 4d. The marker constraints are not vacuous.
    $withoutRestore = $original.Replace('public static Result<CanonicalResponsesResponse, RouterError> Restore(', 'public static Result<CanonicalResponsesResponse, RouterError> RestoreRenamed(')
    Assert-True (@(Get-Fix5FileMarkerErrors $mutatedRelative $withoutRestore).Count -gt 0) "4d: the reviewed marker constraints reject a file with a bridge entry point removed"
}
finally {
    $tempBase = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
    if ($tempRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $tempRoot).StartsWith("fix5-file-auth-", [System.StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- 5. The review must stay wired into the gate -----------------------------
$ciText = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot ".github/workflows/ci.yml")
Assert-True ($ciText.Contains("./tests/validate-dsr7c-apply-patch-file-authorization.ps1")) "5: Development Gate runs this FIX5 file-authorization review"

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "DSR7-C FIX5 protected-file authorization validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}
Write-Host "DSR7-C FIX5 protected-file authorization validation PASSED" -ForegroundColor Green
exit 0
