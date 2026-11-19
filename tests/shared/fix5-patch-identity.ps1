# Shared FIX5 reviewed-identity resolution.
#
# The FIX5 review is provenance based: the reviewed artifacts are the six
# original FIX5 commits (FIX5-A .. B2) and the approved FIX5 base commit. A pull
# request that is rebuilt from a new main by cherry-picking the same reviewed
# patches keeps the *content* identity but necessarily changes the commit SHAs.
#
# This helper resolves the reviewed identity in two modes and never widens the
# review:
#
#   legacy   - the original FIX5 chain is still an ancestor of HEAD; the
#              original SHAs are used directly and must be exactly the chain.
#   portable - the original SHAs are still readable objects but are no longer
#              ancestors of HEAD. The stable patch-id of every reviewed commit
#              must resolve to exactly one ordered, linear, non-merge equivalent
#              commit inside HEAD's ancestry.
#
# Both modes fail closed: a missing, extra, reordered, duplicated, ambiguous or
# merge-commit candidate is an error, never a pass. The original source SHAs stay
# recorded as review provenance in every mode.

function Get-Fix5GitLines {
    param([string]$RepositoryRoot, [string[]]$Arguments)
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

function Test-Fix5GitAncestor {
    param([string]$RepositoryRoot, [string]$Ancestor, [string]$Descendant)
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

# One pass over the non-merge history of $TipRef produces the stable patch-id of
# every commit ("<patch-id> <commit>" per line). Merge commits are deliberately
# absent, so a merge can never stand in for a reviewed source commit.
function Get-Fix5PatchIdMap {
    param([string]$RepositoryRoot, [string]$TipRef = "HEAD")
    $map = @{}
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(
            & git -C $RepositoryRoot log -p --no-merges --no-color "--pretty=format:commit %H" $TipRef 2>$null |
                & git patch-id --stable 2>$null
        )
    }
    finally {
        $ErrorActionPreference = $previous
    }
    foreach ($line in $lines) {
        if ($null -eq $line) { continue }
        $text = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $parts = $text -split '\s+'
        if ($parts.Count -lt 2) { continue }
        $patchId = $parts[0]
        $commit = $parts[1]
        if (-not $map.ContainsKey($patchId)) {
            $map[$patchId] = New-Object System.Collections.Generic.List[string]
        }
        if (-not $map[$patchId].Contains($commit)) { [void]$map[$patchId].Add($commit) }
    }
    return $map
}

function Get-Fix5PatchIdsForCommit {
    param([hashtable]$PatchIdMap, [string]$Commit)
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($PatchIdMap.Keys)) {
        if ($PatchIdMap[$key].Contains($Commit)) { [void]$found.Add([string]$key) }
    }
    return $found.ToArray()
}

function Test-Fix5NonMergeCommit {
    param([string]$RepositoryRoot, [string]$Commit)
    $parents = @(Get-Fix5GitLines $RepositoryRoot @("rev-list", "--parents", "-n", "1", $Commit))
    if ($parents.Count -ne 1) { return $false }
    $fields = @(([string]$parents[0]) -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return ($fields.Count -eq 2)
}

# Slice-registration bookkeeping: a pull request in the LR-15 stack carries the
# exact Base/Tip registration of its own slice as a gate-file-only commit. Those
# commits sit between the previous slice and this one and are governed by the
# LR-14 gate; they are not FIX5 content. Anything else between the equivalent
# FIX5 base and the reviewed chain is smuggling and fails closed.
$script:Fix5RegistrationFiles = @(
    "tests/validate-local-router-lr14-scope.ps1",
    "tests/validate-local-router-lr14-scope-regression.ps1",
    "tests/shared/protected-file-scope.ps1"
)

function Test-Fix5RegistrationOnlyCommit {
    param([string]$RepositoryRoot, [string]$Commit)
    $files = @(Get-Fix5GitLines $RepositoryRoot @("diff", "--name-only", "--no-renames", "$Commit^", $Commit))
    if ($files.Count -eq 0) { return $false }
    foreach ($file in $files) {
        if ($script:Fix5RegistrationFiles -notcontains $file) { return $false }
    }
    return $true
}

# --- OSS-GENESIS: FIX5 review evidence for the open-source history -------------
# The open-source history has no private FIX5 objects. The private main it was
# imported from (1bc5985cc961) carried the six reviewed patches as the patch-id
# equivalents recorded below (portable mode, validated there before import).
# Genesis evidence is accepted ONLY for the verified genesis root (see
# tests/shared/oss-genesis.ps1) and binds every reviewed file to Git objects:
# the genesis root blob and the HEAD blob must both be the reviewed blob, and the
# file must still be owned by the genesis root (no later commit touched it). The
# caller's chain/base pins must equal the recorded review exactly.
# Without the genesis detector (for example a re-cut private fixture tree that
# predates it) no genesis evidence exists and the original behaviour is kept.
$script:Fix5OssGenesisHelper = Join-Path $PSScriptRoot "oss-genesis.ps1"
if (Test-Path -LiteralPath $script:Fix5OssGenesisHelper -PathType Leaf) { . $script:Fix5OssGenesisHelper }

$script:Fix5GenesisEvidence = [ordered]@{
    Base = "74482284838b438860f73ba7b83bb6dca83ad773"
    # label, original reviewed commit, stable patch-id, equivalent in the source main
    Chain = @(
        @('FIX5-A', '5f9a03ca289d46d33474208bfce94c1e585fae45', '3cd39d3ec4c98689394171764a19ab450f799f1b', '7d40942fcf99943df5ae61debeb9a9a22dea01ab'),
        @('B1a', '1ec68e0bcf06396076a7defe572501a2c77eece3', 'd16dfdae1d5cc28a78c45d3c28932a4f503470fc', 'a5b56f5cc57e6f9ebc2214eaf0f92cb361828806'),
        @('B1a2', '33514098432cf64ca3879bc6fb891ee4cfb3cbee', '1617c1fee1368571dd42081b8ea128203495e3dd', 'ed2c0cfdc5f22d79dc295285c8d95b005844a431'),
        @('B1b-1', 'cf543bc9c814d0bd049351117b8fc7b307593602', 'ca053b6652f86e9373c58ef0acaf0f5cf3f26bf0', '1ed6c35a8e2c4decc4ef42f1184987ba97470283'),
        @('B1b-2', 'd0981d30c4b6162db033803c49da5e98f27a0d59', '389417dc838ea0dd3dc2cfc9b495b7dfd36f2d6a', '8620be13d5e5b870b20be3cebca6d9ee563d92bc'),
        @('B2', 'e702fd4b51295f0e95269eef6de210f5eb744f0a', 'cdfe1a623b3c2e16fab266a73dd3070a8256869e', '558b05392575b835d1896ec184a5f719a915d9f1'))
    # Reviewed blob of every FIX5-registered file and FIX5 surface. Recorded from
    # the private review: identical at the reviewed owner commit, the chain tail,
    # the source main and the genesis root.
    ReviewedBlobs = [ordered]@{
        "local-router/src/Router.ClientAdapters.Responses/ApplyPatchCustomTool.cs" = "5219f62407fc7ac5ba705ab71de756e572ceb544"
        "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderRequestWire.cs" = "aa4a6b17b3276a97ade4f752e3f07cc4d2e357fd"
        "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderCodec.cs" = "b153d3c675c3b61fe64edaadc23c0b1dfc327b9f"
        "local-router/src/Router.ProviderAdapters.Responses/ResponsesCompatibleProviderAdapterBase.cs" = "e832fab9048504d8479b9571fa0e3a56c74b82f3"
        "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekCapabilities.cs" = "cd886bb8c56acbdd8b1dd349e9b8e57dcfd94288"
        "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekProviderAdapter.cs" = "f89b1c746bc2b5a4deb952a2b6f55ecd7ca8fbcb"
        "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchRequestBridge.cs" = "ee0237249c52a3155a055b4145ecc69a8f8c393e"
        "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchResponseBridge.cs" = "e428ef5013a7ffe41a6a32ae494b4d037a9033d1"
        "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchStreamBridge.cs" = "85ff9c31d780ccc7408db8ce677e6c2caca5a957"
    }
    # The reviewed FIX5 range in the source main (equivalent base 92355b7d ..
    # equivalent tail 558b0539, 8 commits). These facts were asserted by the
    # private final-integration gate before import and cannot be re-derived here.
    RangeBase = "92355b7db425357ac38fc15ebd67094c096ab34a"
    RangeTail = "558b05392575b835d1896ec184a5f719a915d9f1"
    RangeCommitCount = 8
    RangeProtectedByteIdentical = $true
    RangeChangedFiles = @(
        ".github/workflows/ci.yml",
        "local-router/src/Router.ClientAdapters.Responses/ApplyPatchCustomTool.cs",
        "local-router/src/Router.ClientAdapters.Responses/CanonicalResponsesRequest.cs",
        "local-router/src/Router.ClientAdapters.Responses/CanonicalResponsesResponse.cs",
        "local-router/src/Router.ClientAdapters.Responses/ResponsesInputItem.cs",
        "local-router/src/Router.ClientAdapters.Responses/ResponsesPolymorphicConverters.cs",
        "local-router/src/Router.ClientAdapters.Responses/ResponsesRequestParser.cs",
        "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchRequestBridge.cs",
        "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchResponseBridge.cs",
        "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchStreamBridge.cs",
        "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekCapabilities.cs",
        "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekProviderAdapter.cs",
        "local-router/src/Router.ProviderAdapters.Responses/ResponsesCompatibleProviderAdapterBase.cs",
        "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderCodec.cs",
        "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderRequestWire.cs",
        "local-router/tests/Router.ClientAdapters.Responses.Tests/ApplyPatchContractTests.cs",
        "local-router/tests/Router.ClientAdapters.Responses.Tests/ResponsesRequestParserTests.cs",
        "local-router/tests/Router.Core.Tests/Host/Dsr7cFailureDiagnosticTests.cs",
        "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchBridgeTests.cs",
        "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchRequestBridgeTests.cs",
        "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchResponseBridgeTests.cs",
        "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchStreamBridgeTests.cs",
        "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekFunctionWireTests.cs",
        "local-router/tests/Router.ProviderAdapters.MiMo.Tests/MiMoFunctionWireTests.cs",
        "local-router/tests/Router.ProviderAdapters.ModelStudio.Tests/ModelStudioFunctionWireTests.cs",
        "local-router/tests/Router.ProviderAdapters.OpenAI.Tests/OpenAIFunctionWireTests.cs",
        "local-router/tests/Router.ProviderAdapters.OpenRouter.Tests/OpenRouterFunctionWireTests.cs",
        "local-router/tests/Router.ProviderAdapters.Tests/ResponsesProviderCodecTests.cs",
        "tests/validate-dsr7c-apply-patch-compat-bridge.ps1",
        "tests/validate-dsr7c-apply-patch-request-bridge.ps1",
        "tests/validate-dsr7c-apply-patch-response-bridge.ps1",
        "tests/validate-dsr7c-apply-patch-stream-bridge.ps1",
        "tests/validate-dsr7c-capability-diagnostic.ps1",
        "tests/validate-dsr7c-safe-custom-tool-identity.ps1",
        "tests/validate-local-router-lr14-scope.ps1",
        "tests/validate-responses-upstream-function-wire.ps1",
        "tests/validate-responses-upstream-tool-choice-wire.ps1")
    RangeChangedFilesSha256 = "d5de1979fef6e298ba892fc00bfcb949d3aee42be24577ddc394554066c9fc25"
}

# Returns the genesis identity object, or $null when this is not the verified
# genesis history (the caller then keeps its original fail-closed result).
function Resolve-Fix5GenesisIdentity {
    param([string]$RepositoryRoot, [string]$Base, [array]$Chain)
    if (-not (Get-Command Get-OssGenesisRoot -CommandType Function -ErrorAction SilentlyContinue)) { return $null }
    $root = Get-OssGenesisRoot $RepositoryRoot
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }

    $errors = New-Object System.Collections.Generic.List[string]
    $evidence = $script:Fix5GenesisEvidence
    if ($Base -cne $evidence.Base) { $errors.Add("genesis: the FIX5 base pin $Base differs from the recorded review $($evidence.Base)") }
    if ($Chain.Count -ne $evidence.Chain.Count) { $errors.Add("genesis: the FIX5 chain pin has $($Chain.Count) member(s); the recorded review has $($evidence.Chain.Count)") }
    for ($index = 0; $index -lt [Math]::Min($Chain.Count, $evidence.Chain.Count); $index++) {
        if ([string]$Chain[$index][0] -cne $evidence.Chain[$index][0] -or [string]$Chain[$index][1] -cne $evidence.Chain[$index][1]) {
            $errors.Add("genesis: FIX5 chain pin $($index + 1) is $($Chain[$index][0]) $($Chain[$index][1]); the recorded review is $($evidence.Chain[$index][0]) $($evidence.Chain[$index][1])")
        }
    }

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($path in $evidence.ReviewedBlobs.Keys) {
        $reviewed = [string]$evidence.ReviewedBlobs[$path]
        $genesisBlob = Get-OssGenesisBlob $RepositoryRoot $root $path
        $headBlob = Get-OssGenesisBlob $RepositoryRoot "HEAD" $path
        $owner = @(Get-OssGenesisGitLines $RepositoryRoot @("log", "-1", "--format=%H", "HEAD", "--", $path))
        $ownerSha = if ($owner.Count -eq 1) { [string]$owner[0] } else { "" }
        $problems = New-Object System.Collections.Generic.List[string]
        if ($genesisBlob -cne $reviewed) { $problems.Add("genesis root blob $genesisBlob is not the reviewed blob $reviewed") }
        if ($headBlob -cne $reviewed) { $problems.Add("HEAD blob $(if ($headBlob) { $headBlob } else { '(missing)' }) is not the reviewed blob $reviewed") }
        if ($ownerSha -cne $root) { $problems.Add("last changed by $(if ($ownerSha) { $ownerSha } else { '(none)' }), not by the verified genesis root") }
        foreach ($problem in $problems) { $errors.Add("genesis: ${path}: $problem") }
        $files.Add([pscustomobject]@{ Path = $path; ReviewedBlob = $reviewed; GenesisBlob = $genesisBlob; HeadBlob = $headBlob; Owner = $ownerSha; Ok = ($problems.Count -eq 0) })
    }

    $mapping = @($evidence.Chain | ForEach-Object { "$($_[0])|$($_[1])|$($_[2])|$($_[3]) (recorded in source main $($script:OssGenesisSourceCommit.Substring(0, 12)))" })
    $identity = [ordered]@{
        Mode             = "genesis"
        EffectiveBase    = $root
        EffectiveTail    = $root
        Equivalents      = @($evidence.Chain | ForEach-Object { [string]$_[3] })
        OriginalPatchIds = @($evidence.Chain | ForEach-Object { [string]$_[2] })
        Mapping          = $mapping
        # Explicit ToArray(): @() over a generic List trips a PowerShell binder fault here.
        Errors           = $errors.ToArray()
        GenesisRoot      = $root
        Files            = $files.ToArray()
    }
    return (New-Object psobject -Property $identity)
}

# Resolves the reviewed FIX5 identity for the repository under test.
#
# Returns an object with:
#   Mode            "legacy" | "portable" | "genesis" | "unavailable"
#   EffectiveBase   the resolved reviewed base (equivalent in portable mode)
#   EffectiveTail   the resolved reviewed chain tail (equivalent in portable mode)
#   Equivalents     resolved chain commits, ordered like the approved chain
#   OriginalPatchIds stable patch-id of each approved chain commit
#   Mapping         "<label>|<original>|<patch-id>|<equivalent>" lines
#   Errors          fail-closed findings (a non-empty list means "do not pass")
function Resolve-Fix5ReviewedIdentity {
    param(
        [string]$RepositoryRoot,
        [string]$Base,
        [array]$Chain
    )

    $members = @()
    foreach ($entry in $Chain) { $members += , [pscustomobject]@{ Label = [string]$entry[0]; Sha = [string]$entry[1] } }
    $legacyTail = $members[$members.Count - 1].Sha

    $errors = New-Object System.Collections.Generic.List[string]
    $emptyResult = [ordered]@{
        Mode             = "unavailable"
        EffectiveBase    = ""
        EffectiveTail    = ""
        Equivalents      = @()
        OriginalPatchIds = @()
        Mapping          = @()
        Errors           = @()
    }

    # Without the original objects (shallow clone) the caller keeps its
    # pre-existing file-surface fallback.
    if (@(Get-Fix5GitLines $RepositoryRoot @("rev-parse", "--verify", "--quiet", "$Base^{commit}")).Count -eq 0) {
        # OSS-GENESIS: only the verified genesis history may present recorded
        # review evidence instead of the private objects; anything else stays
        # "unavailable" exactly as before.
        $genesis = Resolve-Fix5GenesisIdentity -RepositoryRoot $RepositoryRoot -Base $Base -Chain $Chain
        if ($null -ne $genesis) { return $genesis }
        return (New-Object psobject -Property $emptyResult)
    }
    foreach ($member in $members) {
        if (@(Get-Fix5GitLines $RepositoryRoot @("rev-parse", "--verify", "--quiet", "$($member.Sha)^{commit}")).Count -eq 0) {
            return (New-Object psobject -Property $emptyResult)
        }
    }

    if (Test-Fix5GitAncestor $RepositoryRoot $legacyTail "HEAD") {
        $identity = [ordered]@{
            Mode             = "legacy"
            EffectiveBase    = $Base
            EffectiveTail    = $legacyTail
            Equivalents      = @($members | ForEach-Object { $_.Sha })
            OriginalPatchIds = @()
            Mapping          = @($members | ForEach-Object { "$($_.Label)|$($_.Sha)|(legacy: exact SHA)|$($_.Sha)" })
            Errors           = @()
        }
        return (New-Object psobject -Property $identity)
    }

    # Portable mode: the reviewed patches must resolve to one ordered linear
    # equivalent chain inside the current HEAD ancestry.
    $origMap = Get-Fix5PatchIdMap -RepositoryRoot $RepositoryRoot -TipRef $legacyTail
    $curMap = Get-Fix5PatchIdMap -RepositoryRoot $RepositoryRoot -TipRef "HEAD"

    $baseIds = @(Get-Fix5PatchIdsForCommit -PatchIdMap $origMap -Commit $Base)
    if ($baseIds.Count -ne 1) {
        $errors.Add("portable: the approved FIX5 base $($Base.Substring(0, 8)) resolves to $($baseIds.Count) stable patch-id(s) in its own history (expected exactly 1)")
    }

    $originalPatchIds = New-Object System.Collections.Generic.List[string]
    $equivalents = New-Object System.Collections.Generic.List[string]
    foreach ($member in $members) {
        $ids = @(Get-Fix5PatchIdsForCommit -PatchIdMap $origMap -Commit $member.Sha)
        if ($ids.Count -ne 1) {
            $errors.Add("portable: reviewed $($member.Label) $($member.Sha.Substring(0, 8)) resolves to $($ids.Count) stable patch-id(s) in its own history (expected exactly 1)")
            [void]$originalPatchIds.Add("")
            [void]$equivalents.Add("")
            continue
        }
        $patchId = [string]$ids[0]
        [void]$originalPatchIds.Add($patchId)

        $candidates = @()
        if ($curMap.ContainsKey($patchId)) { $candidates = @($curMap[$patchId]) }
        if ($candidates.Count -eq 0) {
            $errors.Add("portable: no commit in HEAD carries the reviewed patch of $($member.Label) ($($member.Sha.Substring(0, 8)), patch-id $patchId)")
            [void]$equivalents.Add("")
            continue
        }
        if ($candidates.Count -gt 1) {
            $errors.Add("portable: ambiguous or duplicated patch-equivalent commits for $($member.Label) (patch-id $patchId matches $($candidates -join ', '))")
            [void]$equivalents.Add("")
            continue
        }
        if (-not (Test-Fix5NonMergeCommit $RepositoryRoot $candidates[0])) {
            $errors.Add("portable: the patch-equivalent commit for $($member.Label) is a merge commit ($($candidates[0])) and can never stand in for a reviewed source commit")
            [void]$equivalents.Add("")
            continue
        }
        [void]$equivalents.Add([string]$candidates[0])
    }

    $baseEquivalents = @()
    if ($baseIds.Count -eq 1 -and $curMap.ContainsKey([string]$baseIds[0])) {
        $baseEquivalents = @($curMap[[string]$baseIds[0]])
    }
    if ($baseEquivalents.Count -ne 1) {
        $errors.Add("portable: the equivalent FIX5 base resolves to $($baseEquivalents.Count) commit(s) in HEAD (expected exactly 1)")
    }
    elseif (-not (Test-Fix5NonMergeCommit $RepositoryRoot $baseEquivalents[0])) {
        $errors.Add("portable: the equivalent FIX5 base is a merge commit ($($baseEquivalents[0]))")
    }

    if ($errors.Count -eq 0) {
        $effectiveBase = [string]$baseEquivalents[0]
        $effectiveTail = [string]$equivalents[$equivalents.Count - 1]

        if (-not (Test-Fix5GitAncestor $RepositoryRoot $effectiveBase $effectiveTail)) {
            $errors.Add("portable: the equivalent FIX5 base is not an ancestor of the equivalent chain tail")
        }
        for ($index = 1; $index -lt $equivalents.Count; $index++) {
            $parent = @(Get-Fix5GitLines $RepositoryRoot @("rev-parse", "--verify", "--quiet", "$($equivalents[$index])^"))
            if ($parent.Count -ne 1 -or $parent[0] -ne $equivalents[$index - 1]) {
                $errors.Add("portable: the equivalent FIX5 chain is not linear at $($members[$index].Label)")
            }
        }
        $firstParent = @(Get-Fix5GitLines $RepositoryRoot @("rev-parse", "--verify", "--quiet", "$($equivalents[0])^"))
        if ($firstParent.Count -ne 1) {
            $errors.Add("portable: the first equivalent FIX5 commit has no resolvable parent")
        }
        else {
            # Only merge commits and gate-file-only slice registrations may sit
            # between the equivalent base and the reviewed chain; any other
            # commit is unreviewed content smuggled into the FIX5 range.
            $smuggled = New-Object System.Collections.Generic.List[string]
            foreach ($between in @(Get-Fix5GitLines $RepositoryRoot @("rev-list", "--no-merges", "$effectiveBase..$($firstParent[0])"))) {
                if (-not (Test-Fix5RegistrationOnlyCommit -RepositoryRoot $RepositoryRoot -Commit $between)) {
                    [void]$smuggled.Add($between)
                }
            }
            if ($smuggled.Count -ne 0) {
                $errors.Add("portable: $($smuggled.Count) unreviewed commit(s) sit between the equivalent FIX5 base and the reviewed chain ($($smuggled -join ', '))")
            }
        }
        if (-not (Test-Fix5GitAncestor $RepositoryRoot $effectiveTail "HEAD")) {
            $errors.Add("portable: the equivalent FIX5 chain tail is not an ancestor of HEAD")
        }
    }

    $mapping = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $members.Count; $index++) {
        $equivalent = if ($equivalents[$index]) { $equivalents[$index] } else { "(unresolved)" }
        $mapping.Add("$($members[$index].Label)|$($members[$index].Sha)|$($originalPatchIds[$index])|$equivalent")
    }

    $resolvedBase = ""
    if ($baseEquivalents.Count -eq 1) { $resolvedBase = [string]$baseEquivalents[0] }
    $resolvedTail = ""
    if ($equivalents[$equivalents.Count - 1]) { $resolvedTail = [string]$equivalents[$equivalents.Count - 1] }

    $identity = [ordered]@{
        Mode             = "portable"
        EffectiveBase    = $resolvedBase
        EffectiveTail    = $resolvedTail
        Equivalents      = @($equivalents)
        OriginalPatchIds = @($originalPatchIds)
        Mapping          = @($mapping)
        Errors           = @($errors)
    }
    return (New-Object psobject -Property $identity)
}
