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

# Resolves the reviewed FIX5 identity for the repository under test.
#
# Returns an object with:
#   Mode            "legacy" | "portable" | "unavailable"
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
