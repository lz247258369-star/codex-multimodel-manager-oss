param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# LR15-G8F: FIX5 reviewed-identity portability regression.
#
# The FIX5 gate must accept the reviewed patches in a pull request that was
# rebuilt from a new main by cherry-picking them (identical stable patch-ids,
# different commit SHAs) and keep failing closed for everything else.
#
# Every case is built in a throw-away clone under the system temp folder: the
# repository under test is only read. The clone is re-cut exactly like a stacked
# LR-15 slice (PR2 17 members, PR3 3 members, then the FIX5 members), because
# the reviewed identity depends on that construction.
#
# Cases (each asserts a validator exit code):
#   A legacy original cumulative chain                                  PASS
#   B exact cherry-picked FIX5 chain (portable)                         PASS
#   C cherry-picked member with one extra line                          FAIL
#   D reviewed file modified after the cherry-picked chain              FAIL
#   E same commit message, different patch                              FAIL
#   F missing one FIX5 member                                           FAIL
#   G duplicated patch-equivalent commit                                FAIL
#   H wrong chain order                                                 FAIL
#   I merge/conflict fixture is deterministic (stable conflict) and a
#     merge commit can never become a portability candidate            stable FAIL
#   J file-authorization validator deleted (authorization revoked)       FAIL
#   K reviewed marker removed                                           FAIL
#   L unauthorized extra protected file                                 FAIL
#   M wrong original source pin                                         FAIL
#   N PR4 portable construction (9 members)                             PASS

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }
function Assert-True([bool]$Condition, [string]$Message) { if ($Condition) { Pass $Message } else { Fail $Message } }

# Scaffolding must never degrade into a misleading result: a fixture that could
# not be built aborts the whole regression run instead of reporting PASS/FAIL.
function Require-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "setup failure: $Message" }
}

function New-CaseBranch([string]$Name, [string]$Parent) {
    # Work-tree noise from a previous case is discarded; the portable validator
    # copies are placed only after a case has finished cherry-picking, because
    # the reviewed members themselves modify those files.
    $result = Invoke-Git $script:FixtureRoot @("checkout", "-q", "-f", "-B", $Name, $Parent)
    Require-True ($result.Code -eq 0) "case $Name could not start from $Parent"
    # A force checkout keeps untracked leftovers; the reviewed members create
    # these files, so an untracked copy would block the cherry-pick.
    foreach ($relative in @(
            "tests/validate-dsr7c-apply-patch-final-integration.ps1",
            "tests/validate-dsr7c-apply-patch-file-authorization.ps1",
            "tests/shared/fix5-patch-identity.ps1")) {
        if (Test-Path -LiteralPath (Join-Path $script:FixtureRoot $relative) -PathType Leaf) {
            if (-not (Test-Path -LiteralPath (Join-Path $script:FixtureRoot ".git") -PathType Container)) { throw "setup failure: fixture lost its git directory" }
            Remove-Item -LiteralPath (Join-Path $script:FixtureRoot $relative) -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-Git([string]$Root, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& git -C $Root @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ Code = $code; Output = @($output | ForEach-Object { ([string]$_).Trim() }) }
}

function Get-GitLine([string]$Root, [string[]]$Arguments) {
    $result = Invoke-Git $Root $Arguments
    if ($result.Output.Count -eq 0) { return "" }
    return [string]$result.Output[0]
}

function Get-ValidatorExitCode([string]$Root, [string]$ScriptName) {
    return (Get-ValidatorExitCodeFrom -Root $Root -ScriptPath (Join-Path $Root $ScriptName))
}

function Get-ValidatorExitCodeFrom([string]$Root, [string]$ScriptPath) {
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { $pwsh = "pwsh" }
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { return 127 }
    & $pwsh -NoProfile -File $ScriptPath -RepositoryRoot $Root 2>&1 | Out-Null
    return $LASTEXITCODE
}

function Copy-PortableValidators([string]$Root) {
    foreach ($relative in @(
            "tests/validate-dsr7c-apply-patch-final-integration.ps1",
            "tests/validate-dsr7c-apply-patch-file-authorization.ps1",
            "tests/shared/fix5-patch-identity.ps1")) {
        $source = Join-Path $RepositoryRoot $relative
        $destination = Join-Path $Root $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

function Cherry-Pick-All([string]$Root, [string[]]$Commits) {
    foreach ($commit in $Commits) {
        $result = Invoke-Git $Root @("-c", "user.name=fix5-regression", "-c", "user.email=fix5-regression@local", "cherry-pick", "-x", $commit)
        if ($result.Code -ne 0) {
            $script:LastCherryPickError = "$commit :: $((@($result.Output) | Select-Object -First 3) -join ' | ')"
            Invoke-Git $Root @("cherry-pick", "--abort") | Out-Null
            return $false
        }
    }
    return $true
}

function Commit-All([string]$Root, [string]$Message) {
    Invoke-Git $Root @("add", "-A") | Out-Null
    $result = Invoke-Git $Root @("-c", "user.name=fix5-regression", "-c", "user.email=fix5-regression@local", "commit", "-q", "-m", $Message)
    return ($result.Code -eq 0)
}

$script:Fix5Base = "74482284838b438860f73ba7b83bb6dca83ad773"
$script:Fix5Chain = @(
    @('FIX5-A', '5f9a03ca289d46d33474208bfce94c1e585fae45'),
    @('B1a', '1ec68e0bcf06396076a7defe572501a2c77eece3'),
    @('B1a2', '33514098432cf64ca3879bc6fb891ee4cfb3cbee'),
    @('B1b-1', 'cf543bc9c814d0bd049351117b8fc7b307593602'),
    @('B1b-2', 'd0981d30c4b6162db033803c49da5e98f27a0d59'),
    @('B2', 'e702fd4b51295f0e95269eef6de210f5eb744f0a')
)
$script:Pr2Members = @('3205c7a', '84c1079', 'a5dfd10', 'd3fa0e6', 'a354e0a', '852018b', 'd59dcdc', '24bdddb', '1da7752', '91c81d3', 'bf3fe21', 'a84f2da', '6cf7f37', 'eacf052', '9473114', 'c1bb6f7', 'cbe4ea8')
$script:Pr3Members = @('d3ab39c', 'aad4104', '7448228')
$script:Fix5Members = @($script:Fix5Chain | ForEach-Object { $_[1] })
$script:Fix5RegistrationMember = @('66faa73', '37593c9')
$script:Pr4Tail = @('66faa73', '37593c9', '2af2c19')

# LR15-PR4 corrective: the fixture must never follow a moving main. PR2/PR3 are
# re-cut onto the frozen pre-PR2 milestone (the PR1 merge commit), which exists
# independently of whatever main has since merged. If that object is not
# readable the fixture fails closed; it never falls back to a moving ref.
$script:RecutBase = "9a90d9e02d2e71245dfe4b46ddd17b9abe2aceab"
$script:FinalIntegrationValidator = "tests/validate-dsr7c-apply-patch-final-integration.ps1"
$script:FileAuthorizationValidator = "tests/validate-dsr7c-apply-patch-file-authorization.ps1"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fix5-portability-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    # ---- base fixture: a stacked PR re-cut from main (PR2 17, PR3 3) --------
    $fixture = Join-Path $tempRoot "fixture"
    $clone = Invoke-Git $RepositoryRoot @("clone", "--quiet", "--no-hardlinks", "--local", $RepositoryRoot, $fixture)
    if ($clone.Code -ne 0) { Fail "setup: unable to clone the repository under test"; throw "clone failed" }
    $script:FixtureRoot = $fixture

    # The frozen fixture milestone must be readable; a moving ref is never used.
    $recutMilestone = Invoke-Git $fixture @("cat-file", "-e", "$($script:RecutBase)^{commit}")
    Require-True ($recutMilestone.Code -eq 0) "the frozen pre-PR2 fixture milestone $($script:RecutBase) is not readable in this clone (fail-closed; no fallback to a moving ref)"
    New-CaseBranch "recut" $script:RecutBase
    Require-True (Cherry-Pick-All $fixture ($script:Pr2Members + $script:Pr3Members)) "PR2 (17) and PR3 (3) must apply cleanly onto main"
    Pass "setup: the re-cut base reproduces the stacked LR-15 construction (PR2 17 + PR3 3)"

    # ---- A: legacy original cumulative chain -------------------------------
    Require-True ((Invoke-Git $fixture @("checkout", "-q", "-f", "--detach", "cbe4ea8")).Code -eq 0) "case A could not check out the original cumulative tip"
    Copy-PortableValidators $fixture
    $legacyFinal = Get-ValidatorExitCode $fixture $script:FinalIntegrationValidator
    $legacyAuth = Get-ValidatorExitCode $fixture $script:FileAuthorizationValidator
    Assert-True ($legacyFinal -eq 0) "A: legacy original cumulative chain passes the FIX5 final-integration gate"
    Assert-True ($legacyAuth -eq 0) "A: legacy original cumulative chain passes the FIX5 file-authorization gate"
    Require-True ((Invoke-Git $fixture @("checkout", "-q", "-f", "recut")).Code -eq 0) "case A could not return to the re-cut base"

    # ---- B: exact cherry-picked chain plus its registration (portable) -----
    New-CaseBranch "caseB" "recut"
    Require-True (Cherry-Pick-All $fixture ($script:Fix5Members + $script:Fix5RegistrationMember)) "the six reviewed patches plus the FIX5 registration must cherry-pick cleanly onto the re-cut base"
    Copy-PortableValidators $fixture
    Assert-True ((Get-ValidatorExitCode $fixture $script:FinalIntegrationValidator) -eq 0) "B: an exact cherry-picked chain passes the FIX5 final-integration gate"
    Assert-True ((Get-ValidatorExitCode $fixture $script:FileAuthorizationValidator) -eq 0) "B: an exact cherry-picked chain passes the FIX5 file-authorization gate"

    # ---- C: one cherry-picked commit gains an extra line -------------------
    New-CaseBranch "caseC" "recut"
    Invoke-Git $fixture @("-c", "user.name=fix5-regression", "-c", "user.email=fix5-regression@local", "cherry-pick", "-n", $script:Fix5Members[0]) | Out-Null
    $target = Join-Path $fixture "local-router/src/Router.ClientAdapters.Responses/ApplyPatchCustomTool.cs"
    [System.IO.File]::AppendAllText($target, "`n// unreviewed extra line`n")
    Require-True (Commit-All $fixture "feat: add apply_patch client contract and canonical model") "case C could not commit the altered member"
    Require-True (Cherry-Pick-All $fixture $script:Fix5Members[1..5]) "case C could not apply the remaining reviewed patches"
    Copy-PortableValidators $fixture
    Assert-True ((Get-ValidatorExitCode $fixture $script:FinalIntegrationValidator) -ne 0) "C: an extra line inside a cherry-picked commit fails the gate"

    # ---- D: reviewed file modified after the chain -------------------------
    New-CaseBranch "caseD" "caseB"
    [System.IO.File]::AppendAllText((Join-Path $fixture "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchResponseBridge.cs"), "`n// post-review mutation`n")
    Require-True (Commit-All $fixture "test: mutate a reviewed file after the chain") "case D could not commit the post-review mutation"
    Copy-PortableValidators $fixture
    Assert-True ((Get-ValidatorExitCode $fixture $script:FileAuthorizationValidator) -ne 0) "D: a reviewed file modified after the chain fails the file-authorization gate"

    # ---- E: same commit message, different patch ---------------------------
    New-CaseBranch "caseE" "recut"
    Invoke-Git $fixture @("-c", "user.name=fix5-regression", "-c", "user.email=fix5-regression@local", "cherry-pick", "-n", $script:Fix5Members[0]) | Out-Null
    $original = [System.IO.File]::ReadAllText($target)
    [System.IO.File]::WriteAllText($target, $original.Replace('ApplyPatchToolName = "apply_patch"', 'ApplyPatchToolName = "apply_patch_v2"'))
    Require-True (Commit-All $fixture "feat: add apply_patch client contract and canonical model") "case E could not commit the altered member"
    Require-True (Cherry-Pick-All $fixture $script:Fix5Members[1..5]) "case E could not apply the remaining reviewed patches"
    Copy-PortableValidators $fixture
    Assert-True ((Get-ValidatorExitCode $fixture $script:FinalIntegrationValidator) -ne 0) "E: an identical commit message with a different patch fails the gate"

    # ---- F: missing one FIX5 member ----------------------------------------
    New-CaseBranch "caseF" "recut"
    Require-True (Cherry-Pick-All $fixture $script:Fix5Members[0..4]) "case F could not apply the reviewed chain ($script:LastCherryPickError)"
    # The last reviewed member is missing: an empty commit reuses its message, so
    # a message-only match can never stand in for the reviewed patch.
    Require-True ((Invoke-Git $fixture @("-c", "user.name=fix5-regression", "-c", "user.email=fix5-regression@local", "commit", "-q", "--allow-empty", "-m", "test: add FIX5 apply_patch final integration gate")).Code -eq 0) "case F could not create the message-only stand-in"
    Copy-PortableValidators $fixture
    Assert-True ((Get-ValidatorExitCode $fixture $script:FinalIntegrationValidator) -ne 0) "F: a chain missing one reviewed member fails the gate"

    # ---- G: duplicated patch-equivalent commit -----------------------------
    New-CaseBranch "caseG" "recut"
    Require-True (Cherry-Pick-All $fixture $script:Fix5Members) "case G could not apply the reviewed chain"
    $chainCopies = @(Invoke-Git $fixture @("rev-list", "--reverse", "recut..HEAD")).Output
    Require-True ($chainCopies.Count -eq $script:Fix5Members.Count) "case G could not resolve the six chain copies"
    foreach ($copy in @($chainCopies[($chainCopies.Count - 1)..0])) {
        Require-True ((Invoke-Git $fixture @("-c", "user.name=fix5-regression", "-c", "user.email=fix5-regression@local", "revert", "--no-edit", $copy)).Code -eq 0) "case G could not undo $copy"
    }
    Require-True (Cherry-Pick-All $fixture $script:Fix5Members) "case G could not re-apply the reviewed patches"
    Copy-PortableValidators $fixture
    Assert-True ((Get-ValidatorExitCode $fixture $script:FinalIntegrationValidator) -ne 0) "G: a duplicated patch-equivalent commit fails the gate as ambiguous"

    # ---- H: wrong chain order ---------------------------------------------
    # Every reviewed member appends its own step to the same ci.yml step list, so
    # physically re-ordering the members cannot be cherry-picked without a
    # semantic merge resolution (which this round forbids). The order guard is
    # therefore exercised on the gate's own reviewed chain: permuting the
    # approved order must fail closed even though every patch is present.
    New-CaseBranch "caseH" "caseB"
    Copy-PortableValidators $fixture
    $ordered = Join-Path $fixture $script:FinalIntegrationValidator
    $orderedLines = [System.IO.File]::ReadAllLines($ordered)
    for ($index = 0; $index -lt $orderedLines.Count; $index++) {
        if ($orderedLines[$index] -match "'B1b-1', 'cf543bc9") {
            $orderedLines[$index] = $orderedLines[$index].Replace('B1b-1', 'B1b-2').Replace('cf543bc9c814d0bd049351117b8fc7b307593602', 'd0981d30c4b6162db033803c49da5e98f27a0d59')
        }
        elseif ($orderedLines[$index] -match "'B1b-2', 'd0981d30") {
            $orderedLines[$index] = $orderedLines[$index].Replace('B1b-2', 'B1b-1').Replace('d0981d30c4b6162db033803c49da5e98f27a0d59', 'cf543bc9c814d0bd049351117b8fc7b307593602')
        }
    }
    [System.IO.File]::WriteAllLines($ordered, $orderedLines)
    Assert-True ((Get-ValidatorExitCode $fixture $script:FinalIntegrationValidator) -ne 0) "H: a reviewed chain consumed in the wrong order fails the gate"

    # ---- I: merge/conflict behaviour is deterministic -----------------------
    # The gate must never treat an unmergeable slice as reviewable, and a merge
    # commit must never become a portability candidate. Both properties are
    # proven without depending on the reviewed files happening to conflict: two
    # side branches change the SAME line of a DEDICATED probe file with
    # different content, so the merge conflicts on every attempt.
    $probeRelative = "tests/fixtures/lr15-g8f-conflict-probe.txt"
    $conflictStable = $true
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        New-CaseBranch "caseI-a-$attempt" "recut"
        Set-Content -LiteralPath (Join-Path $fixture $probeRelative) -Value "probe side a`n" -Encoding utf8
        Require-True (Commit-All $fixture "fixture: deterministic probe side a") "case I could not commit probe side a (attempt $attempt)"
        New-CaseBranch "caseI-b-$attempt" "recut"
        Set-Content -LiteralPath (Join-Path $fixture $probeRelative) -Value "probe side b`n" -Encoding utf8
        Require-True (Commit-All $fixture "fixture: deterministic probe side b") "case I could not commit probe side b (attempt $attempt)"
        New-CaseBranch "caseI-m-$attempt" "caseI-a-$attempt"
        $probeMerge = Invoke-Git $fixture @("-c", "user.name=fix5-regression", "-c", "user.email=fix5-regression@local", "merge", "--no-ff", "--no-edit", "caseI-b-$attempt")
        if ($probeMerge.Code -eq 0) { $conflictStable = $false }
        Invoke-Git $fixture @("merge", "--abort") | Out-Null
    }
    Assert-True $conflictStable "I: the dedicated probe fixture conflicts deterministically on every attempt (3/3)"

    # A merge commit is never a portability candidate, even when the merge is
    # clean and carries an equivalent-looking change set.
    New-CaseBranch "caseI-clean" "recut"
    New-CaseBranch "caseI-clean-side" "recut"
    Set-Content -LiteralPath (Join-Path $fixture $probeRelative) -Value "clean probe`n" -Encoding utf8
    Require-True (Commit-All $fixture "fixture: clean probe") "case I could not commit the clean probe"
    Require-True ((Invoke-Git $fixture @("checkout", "-q", "-f", "caseI-clean")).Code -eq 0) "case I could not return to the clean line"
    $cleanMerge = Invoke-Git $fixture @("-c", "user.name=fix5-regression", "-c", "user.email=fix5-regression@local", "merge", "--no-ff", "--no-edit", "caseI-clean-side")
    Require-True ($cleanMerge.Code -eq 0) "case I could not create the clean merge commit"
    . (Join-Path $RepositoryRoot "tests/shared/fix5-patch-identity.ps1")
    $candidateMap = Get-Fix5PatchIdMap -RepositoryRoot $fixture -TipRef "HEAD"
    $mergeCommit = [string](@(Invoke-Git $fixture @("rev-parse", "HEAD")).Output)[0]
    $mergeIsCandidate = $false
    foreach ($key in @($candidateMap.Keys)) {
        if ($candidateMap[$key].Contains($mergeCommit)) { $mergeIsCandidate = $true }
    }
    Assert-True (-not $mergeIsCandidate) "I: a merge commit is never a portability candidate (resolver-level)"

    # ---- J: deleting the file-authorization review revokes it -------------
    New-CaseBranch "caseJ" "caseB"
    Require-True ((Invoke-Git $fixture @("rm", "-q", $script:FileAuthorizationValidator)).Code -eq 0) "case J could not delete the review"
    Require-True (Commit-All $fixture "test: delete the FIX5 file-authorization review") "case J could not commit the deletion"
    # The review is run from the repository copy against the fixture tree, which
    # no longer contains it: the shared policy must revoke the authorization.
    Assert-True ((Get-ValidatorExitCodeFrom -Root $fixture -ScriptPath (Join-Path $RepositoryRoot $script:FileAuthorizationValidator)) -ne 0) "J: deleting the FIX5 file-authorization review revokes the authorization"

    # ---- K: reviewed marker removed ---------------------------------------
    New-CaseBranch "caseK" "caseB"
    $markerFile = Join-Path $fixture "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchStreamBridge.cs"
    [System.IO.File]::WriteAllText($markerFile, ([System.IO.File]::ReadAllText($markerFile)).Replace('public static class ApplyPatchStreamBridge', 'public static class ApplyPatchStreamBridgeRenamed'))
    Require-True (Commit-All $fixture "test: remove a reviewed marker") "case K could not commit the marker removal"
    Copy-PortableValidators $fixture
    Assert-True ((Get-ValidatorExitCode $fixture $script:FileAuthorizationValidator) -ne 0) "K: removing a reviewed marker fails the gate"

    # ---- L: unauthorized extra protected file -----------------------------
    New-CaseBranch "caseL" "caseB"
    $extraRelative = "local-router/src/Router.ProviderAdapters.DeepSeek/UnauthorizedExtraBridge.cs"
    [System.IO.File]::WriteAllText((Join-Path $fixture $extraRelative), "// unauthorized`n")
    Require-True (Commit-All $fixture "test: add an unauthorized protected file") "case L could not commit the extra protected file"
    Copy-PortableValidators $fixture
    $hookProbe = & pwsh -NoProfile -Command ". (Join-Path '$fixture' 'tests/shared/protected-file-scope.ps1'); if (Test-Lr13ProtectedFileChangeAuthorized '$fixture' '$extraRelative') { 'AUTHORIZED' } else { 'REVOKED' }"
    Assert-True (@($hookProbe) -contains "REVOKED") "L: an unauthorized extra protected file is not authorized by the FIX5 registration"

    # ---- M: wrong original source pin --------------------------------------
    New-CaseBranch "caseM" "caseB"
    Copy-PortableValidators $fixture
    $pinned = Join-Path $fixture $script:FinalIntegrationValidator
    [System.IO.File]::WriteAllText($pinned, ([System.IO.File]::ReadAllText($pinned)).Replace("'B1b-2', 'd0981d30c4b6162db033803c49da5e98f27a0d59'", "'B1b-2', '1ec68e0bcf06396076a7defe572501a2c77eece3'"))
    Assert-True ((Get-ValidatorExitCode $fixture $script:FinalIntegrationValidator) -ne 0) "M: a wrong original source pin fails the gate"

    # ---- N: PR4 portable construction (9 members) -------------------------
    New-CaseBranch "caseN" "recut"
    Require-True (Cherry-Pick-All $fixture ($script:Fix5Members + $script:Pr4Tail)) "the nine PR4 members must cherry-pick cleanly onto the re-cut base"
    Copy-PortableValidators $fixture
    $portableFinal = Get-ValidatorExitCode $fixture $script:FinalIntegrationValidator
    $portableAuth = Get-ValidatorExitCode $fixture $script:FileAuthorizationValidator
    Assert-True ($portableFinal -eq 0) "N: the PR4 portable construction passes the FIX5 final-integration gate"
    Assert-True ($portableAuth -eq 0) "N: the PR4 portable construction passes the FIX5 file-authorization gate"
}
finally {
    $tempBase = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
    if ($tempRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $tempRoot).StartsWith("fix5-portability-", [System.StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "FIX5 reviewed-identity portability regression FAILED ($($failures.Count) failures)" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "FIX5 reviewed-identity portability regression PASSED" -ForegroundColor Green
exit 0
