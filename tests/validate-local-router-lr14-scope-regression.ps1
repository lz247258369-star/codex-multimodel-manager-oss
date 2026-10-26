param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# Regression coverage for the LR-14 scope policy:
#
#   * the scope decision must be made on the *committed* branch delta, so the
#     working-tree noise produced by `dotnet restore`/`build`/`test` (tracked
#     local-router packages.lock.json files) can never become a PR-scope
#     violation;
#   * a Router backend file that is really committed on the branch must still
#     fail closed;
#   * the comparison must work for a branch checkout and for the detached-HEAD
#     pull_request checkout used by GitHub Actions, and must fail closed when no
#     base ref can be resolved at all (never a silent empty-delta PASS).
#   * LR15-G7: the GitHub pull_request checkout can also be GitHub's *trial merge
#     commit* (refs/pull/<n>/merge). A purely base-into-head merge must be
#     reviewed as its second parent (the PR head) instead of being reported as an
#     unregistered commit - while any other merge shape, and any unregistered
#     commit inside the head, still fails closed.
#
# Every scenario runs in a throw-away git repository inside the system temp
# directory. The repository under test is read, never modified.

$ErrorActionPreference = "Stop"

$script:Passes = New-Object System.Collections.Generic.List[string]
$script:Failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { $script:Passes.Add($Message); Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $script:Failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

function Complete-WithSummary([string]$FailureLabel, [string]$PassLabel) {
    Write-Host ""
    Write-Host "LR-14 scope regression summary" -ForegroundColor Cyan
    Write-Host "PASS: $($script:Passes.Count)"
    Write-Host "FAIL: $($script:Failures.Count)"
    if ($script:Failures.Count -gt 0) {
        Write-Host ""
        Write-Host "$FailureLabel ($($script:Failures.Count) failures)" -ForegroundColor Red
        exit 1
    }
    Write-Host $PassLabel -ForegroundColor Green
    exit 0
}

$scopeValidator = Join-Path $PSScriptRoot "validate-local-router-lr14-scope.ps1"
if (-not (Test-Path -LiteralPath $scopeValidator -PathType Leaf)) {
    $scopeValidator = Join-Path $RepositoryRoot "tests/validate-local-router-lr14-scope.ps1"
}
if (-not (Test-Path -LiteralPath $scopeValidator -PathType Leaf)) {
    Fail "LR-14 scope validator is missing: tests/validate-local-router-lr14-scope.ps1"
    Complete-WithSummary "LR-14 scope regression validation FAILED" "LR-14 scope regression validation PASSED"
}

if ($PSVersionTable.PSEdition -eq "Core") {
    $childHost = Join-Path $PSHOME "pwsh.exe"
}
else {
    $childHost = Join-Path $PSHOME "powershell.exe"
}
if (-not (Test-Path -LiteralPath $childHost -PathType Leaf)) {
    Fail "Cannot locate the PowerShell host used to run the scope validator: $childHost"
    Complete-WithSummary "LR-14 scope regression validation FAILED" "LR-14 scope regression validation PASSED"
}

function Invoke-GitResult {
    param([string]$Repo, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $exit = 1
    $output = @()
    try {
        $output = @(& git -C $Repo -c "safe.directory=$Repo" -c "commit.gpgsign=false" -c "core.autocrlf=false" `
                -c "user.name=LR-14 Scope Regression" -c "user.email=lr14-scope-regression@example.invalid" @Arguments 2>&1)
        $exit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{
        ExitCode = $exit
        Output   = @($output | Where-Object { $_ -is [string] } | ForEach-Object { ([string]$_).Trim() })
    }
}

function Invoke-Git {
    param([string]$Repo, [string[]]$Arguments)
    $result = Invoke-GitResult $Repo $Arguments
    if ($result.ExitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $($result.ExitCode) in $Repo : $($result.Output -join ' ')"
    }
    return $result.Output
}

function Write-RepoFile {
    param([string]$Repo, [string]$RelativePath, [string]$Content)
    $full = Join-Path $Repo $RelativePath
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Force -Path $parent) }
    [System.IO.File]::WriteAllText($full, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-RepoFile {
    param([string]$Repo, [string]$RelativePath)
    return [System.IO.File]::ReadAllText((Join-Path $Repo $RelativePath))
}

function Invoke-ScopeValidator {
    param([string]$Repo, [string]$BaseRef = "")
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scopeValidator, "-RepositoryRoot", $Repo)
    if (-not [string]::IsNullOrWhiteSpace($BaseRef)) { $arguments += @("-Base", $BaseRef) }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $exit = 1
    $output = @()
    try {
        $output = @(& $childHost @arguments 2>&1)
        $exit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $exit; Output = @($output | Where-Object { $_ -is [string] }) }
}

function Test-OutputContains {
    param([string[]]$Output, [string]$Needle)
    foreach ($line in $Output) {
        if ($line -like "*$Needle*") { return $true }
    }
    return $false
}

function New-ScenarioRepo {
    param([string]$Repo)
    [void](New-Item -ItemType Directory -Force -Path $Repo)
    Invoke-Git $Repo @("init", "--quiet") | Out-Null
    Invoke-Git $Repo @("symbolic-ref", "HEAD", "refs/heads/main") | Out-Null

    $baseFiles = [ordered]@{
        "installer/scripts/visual-router-runtime.ps1"             = "# Local Router V4 runtime`n"
        "installer/ui/visual-console.xaml"                        = "<Window />`n"
        "installer/scripts/visual-console.ps1"                    = "# Local Router V4 console`n"
        "docs/LOCAL_ROUTER_V4_UI.md"                              = "# Local Router V4 UI`n"
        "local-router/src/Router.Host/packages.lock.json"         = "{`n  `"version`": 1`n}`n"
        "local-router/tests/Router.Core.Tests/packages.lock.json" = "{`n  `"version`": 1`n}`n"
        "local-router/src/Router.Core/RouterPipeline.cs"          = "// base router pipeline`n"
        "tests/fixtures/local-router/v4-ui/control-plane-status.json" = "{ `"status`": `"ok`" }`n"
    }
    foreach ($entry in $baseFiles.GetEnumerator()) {
        Write-RepoFile $Repo $entry.Key $entry.Value
    }
    Invoke-Git $Repo @("add", "--all") | Out-Null
    Invoke-Git $Repo @("commit", "--quiet", "-m", "base") | Out-Null
    $baseSha = @(Invoke-Git $Repo @("rev-parse", "HEAD"))[0]

    # Legal LR-14 V4 delta: presentation files, fixtures and docs only.
    Invoke-Git $Repo @("checkout", "--quiet", "-b", "lr14-ui-slice") | Out-Null
    Write-RepoFile $Repo "docs/LOCAL_ROUTER_V4_UI.md" ((Get-RepoFile $Repo "docs/LOCAL_ROUTER_V4_UI.md") + "## Control Plane`n")
    Write-RepoFile $Repo "installer/ui/visual-console.xaml" ((Get-RepoFile $Repo "installer/ui/visual-console.xaml") + "<!-- lr14 control plane -->`n")
    Write-RepoFile $Repo "tests/fixtures/local-router/v4-ui/control-plane-status.json" "{ `"status`": `"degraded`" }`n"
    Invoke-Git $Repo @("add", "--all") | Out-Null
    Invoke-Git $Repo @("commit", "--quiet", "-m", "feat: LR-14 V4 UI slice") | Out-Null
    $headSha = @(Invoke-Git $Repo @("rev-parse", "HEAD"))[0]

    return [pscustomobject]@{ BaseSha = $baseSha; HeadSha = $headSha }
}

# LR15-G7: builds a repository whose committed history contains an identifiable,
# reviewed slice (the commit that adds the LR-14 gate artifacts) plus the
# gate-baseline follow-up the real PR carries. The slice tip is also the main tip,
# exactly like the repository under test.
function New-ReviewedSliceScenarioRepo {
    param([string]$Repo)
    [void](New-Item -ItemType Directory -Force -Path $Repo)
    Invoke-Git $Repo @("init", "--quiet") | Out-Null
    Invoke-Git $Repo @("symbolic-ref", "HEAD", "refs/heads/main") | Out-Null

    Write-RepoFile $Repo "installer/scripts/visual-router-runtime.ps1" "# Local Router V4 runtime`n"
    Write-RepoFile $Repo "installer/ui/visual-console.xaml" "<Window />`n"
    Write-RepoFile $Repo "installer/scripts/visual-console.ps1" "# Local Router V4 console`n"
    Write-RepoFile $Repo "docs/LOCAL_ROUTER_V4_UI.md" "# Local Router V4 UI`n"
    Write-RepoFile $Repo "local-router/src/Router.Core/RouterPipeline.cs" "// base router pipeline`n"
    Invoke-Git $Repo @("add", "--all") | Out-Null
    Invoke-Git $Repo @("commit", "--quiet", "-m", "base") | Out-Null
    $baseSha = @(Invoke-Git $Repo @("rev-parse", "HEAD"))[0]

    # The reviewed slice: the commit that adds the LR-14 gate artifacts, the
    # authority marker the registry requires, and an LR-14 presentation file (so
    # the slice is not limited to the gate-baseline file set).
    Invoke-Git $Repo @("checkout", "--quiet", "-b", "lr14-slice", $baseSha) | Out-Null
    Write-RepoFile $Repo "tests/validate-local-router-lr14-scope.ps1" "# LR-14 scope gate`n"
    Write-RepoFile $Repo "tests/validate-local-router-lr14-scope-regression.ps1" "# LR-14 scope regression`n"
    Write-RepoFile $Repo "tests/shared/protected-file-scope.ps1" "# protected file scope`n"
    Write-RepoFile $Repo "tests/validate-local-router-v4-ui.ps1" "# LR-14 V4 UI validator`n"
    Write-RepoFile $Repo "installer/ui/visual-console.xaml" "<Window><!-- LR-14 V4 --></Window>`n"
    Invoke-Git $Repo @("add", "--all") | Out-Null
    Invoke-Git $Repo @("commit", "--quiet", "-m", "feat: LR-14 V4 UI slice with its scope gate") | Out-Null
    $sliceTipSha = @(Invoke-Git $Repo @("rev-parse", "HEAD"))[0]

    return [pscustomobject]@{ BaseSha = $baseSha; SliceTipSha = $sliceTipSha }
}

function Add-GateBaselineCommit {
    param([string]$Repo)
    $gate = Get-RepoFile $Repo "tests/validate-local-router-lr14-scope.ps1"
    Write-RepoFile $Repo "tests/validate-local-router-lr14-scope.ps1" ($gate + "# slice applicability`n")
    Invoke-Git $Repo @("add", "--all") | Out-Null
    Invoke-Git $Repo @("commit", "--quiet", "-m", "test(scope): give the LR-14 gate explicit slice applicability") | Out-Null
    return @(Invoke-Git $Repo @("rev-parse", "HEAD"))[0]
}

function New-PullRequestScenario {
    param([string]$Repo, [object]$Scenario)
    Invoke-Git $Repo @("checkout", "--quiet", "-b", "pr-branch", $Scenario.SliceTipSha) | Out-Null
    $headSha = Add-GateBaselineCommit $Repo
    # main is the slice's parent: the PR delta is the slice plus the gate commit,
    # exactly like the real pull request this gate reviews.
    Invoke-Git $Repo @("update-ref", "refs/remotes/origin/main", $Scenario.BaseSha) | Out-Null
    return $headSha
}

function New-TrialMergeCommit {
    param([string]$Repo, [string]$BaseSha, [string]$HeadSha)
    Invoke-Git $Repo @("checkout", "--quiet", "--detach", $BaseSha) | Out-Null
    Invoke-Git $Repo @("merge", "--no-ff", "--quiet", "-m", "Merge $HeadSha into $BaseSha", $HeadSha) | Out-Null
    return @(Invoke-Git $Repo @("rev-parse", "HEAD"))[0]
}

function New-ReversedMergeCommit {
    param([string]$Repo, [string]$BaseSha, [string]$HeadSha)
    Invoke-Git $Repo @("checkout", "--quiet", "--detach", $HeadSha) | Out-Null
    Invoke-Git $Repo @("merge", "--no-ff", "--quiet", "-m", "Merge $BaseSha into $HeadSha", $BaseSha) | Out-Null
    return @(Invoke-Git $Repo @("rev-parse", "HEAD"))[0]
}

function Remove-FileInCurrentCommit {
    param([string]$Repo, [string]$RelativePath)
    [System.IO.File]::Delete((Join-Path $Repo $RelativePath))
    Invoke-Git $Repo @("add", "--all") | Out-Null
    Invoke-Git $Repo @("commit", "--amend", "--no-edit", "--quiet") | Out-Null
    return @(Invoke-Git $Repo @("rev-parse", "HEAD"))[0]
}

# Simulates the CI build step: tracked lockfiles are rewritten in the working
# tree and left uncommitted.
function Add-BuildNoise {
    param([string]$Repo)
    $lockNoise = (Get-RepoFile $Repo "local-router/src/Router.Host/packages.lock.json") + "  // restore/build noise`n"
    Write-RepoFile $Repo "local-router/src/Router.Host/packages.lock.json" $lockNoise
    Write-RepoFile $Repo "local-router/tests/Router.Core.Tests/packages.lock.json" $lockNoise
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("lr14-scope-regression-" + [guid]::NewGuid().ToString("N"))
$tempRepo = Join-Path $tempRoot "pr-branch"
$tempRepoPr = Join-Path $tempRoot "pr-merge-checkout"
$tempRepoNoBase = Join-Path $tempRoot "no-base"
$tempMerge = Join-Path $tempRoot "pr-trial-merge"
$tempMergeUnregistered = Join-Path $tempRoot "pr-trial-merge-unregistered"
$tempMergeReversed = Join-Path $tempRoot "pr-reversed-merge"
$tempMergeDeleted = Join-Path $tempRoot "pr-trial-merge-deleted-file"
$tempMergeModified = Join-Path $tempRoot "pr-trial-merge-modified-file"
$tempSliceUnreachable = Join-Path $tempRoot "pr-slice-unreachable"

try {
    # ---------------------------------------------------- CASE A (legal PR) ---
    $branchScenario = New-ScenarioRepo $tempRepo
    Add-BuildNoise $tempRepo

    $dirty = @(Invoke-Git $tempRepo @("status", "--porcelain"))
    $dirtyLockFiles = @($dirty | Where-Object { $_ -like "*packages.lock.json*" })
    if ($dirtyLockFiles.Count -ge 2) {
        Pass "Case A setup: two tracked packages.lock.json files are dirty in the working tree (restore/build noise)"
    }
    else {
        Fail "Case A setup: expected two dirty packages.lock.json files in the working tree"
    }

    $caseA = Invoke-ScopeValidator $tempRepo
    if ($caseA.ExitCode -eq 0) {
        Pass "Case A: legal LR-14 committed delta PASSES the scope gate while the worktree has dirty lockfiles"
    }
    else {
        Fail "Case A: legal LR-14 committed delta was rejected (exit $($caseA.ExitCode)): $($caseA.Output -join ' | ')"
    }
    if (Test-OutputContains $caseA.Output "LR-14 scope validation PASSED") {
        Pass "Case A: scope gate reported an explicit PASS"
    }
    else {
        Fail "Case A: scope gate did not report an explicit PASS"
    }
    if (Test-OutputContains $caseA.Output "packages.lock.json") {
        Fail "Case A: uncommitted lockfile noise leaked into the PR scope decision"
    }
    else {
        Pass "Case A: uncommitted lockfile noise is not part of the PR scope decision"
    }

    # ------------------------------------------------ CASE B (real backend) ---
    # The working tree is still dirty with the build noise, so a failure here
    # can only come from the committed backend change.
    Write-RepoFile $tempRepo "local-router/src/Router.Core/RouterPipeline.cs" "// committed backend change`n"
    Invoke-Git $tempRepo @("add", "local-router/src/Router.Core/RouterPipeline.cs") | Out-Null
    Invoke-Git $tempRepo @("commit", "--quiet", "-m", "feat: committed Router backend change") | Out-Null
    $backendSha = @(Invoke-Git $tempRepo @("rev-parse", "HEAD"))[0]

    $caseB = Invoke-ScopeValidator $tempRepo
    if ($caseB.ExitCode -ne 0) {
        Pass "Case B: committed Router backend change FAILS the scope gate (exit $($caseB.ExitCode))"
    }
    else {
        Fail "Case B: committed Router backend change was accepted by the scope gate"
    }
    if (Test-OutputContains $caseB.Output "local-router/src/Router.Core/RouterPipeline.cs") {
        Pass "Case B: scope gate names the offending committed backend file"
    }
    else {
        Fail "Case B: scope gate did not report the committed backend file path"
    }
    if (Test-OutputContains $caseB.Output "LR-14 scope validation FAILED") {
        Pass "Case B: scope gate reported an explicit FAILED verdict"
    }
    else {
        Fail "Case B: scope gate did not report an explicit FAILED verdict"
    }

    # --------------------------- CASE C (detached HEAD pull_request checkout) ---
    $prScenario = New-ScenarioRepo $tempRepoPr
    Invoke-Git $tempRepoPr @("checkout", "--quiet", "main") | Out-Null
    Write-RepoFile $tempRepoPr "local-router/src/Router.Host/packages.lock.json" "// unrelated main-side lockfile churn`n"
    Invoke-Git $tempRepoPr @("add", "local-router/src/Router.Host/packages.lock.json") | Out-Null
    Invoke-Git $tempRepoPr @("commit", "--quiet", "-m", "chore: unrelated commit on main") | Out-Null
    $movedMainSha = @(Invoke-Git $tempRepoPr @("rev-parse", "HEAD"))[0]
    Invoke-Git $tempRepoPr @("update-ref", "refs/remotes/origin/main", $movedMainSha) | Out-Null
    Invoke-Git $tempRepoPr @("checkout", "--quiet", "--detach", $prScenario.HeadSha) | Out-Null

    $detached = Invoke-GitResult $tempRepoPr @("symbolic-ref", "--quiet", "HEAD")
    if ($detached.ExitCode -ne 0) {
        Pass "Case C setup: checkout is detached HEAD (GitHub Actions pull_request checkout shape)"
    }
    else {
        Fail "Case C setup: expected a detached HEAD checkout"
    }

    $caseC = Invoke-ScopeValidator $tempRepoPr
    if ($caseC.ExitCode -eq 0) {
        Pass "Case C: detached HEAD with origin/main ahead of the merge base PASSES; delta is measured from $($prScenario.BaseSha.Substring(0, 8))"
    }
    else {
        Fail "Case C: detached HEAD pull_request checkout failed the scope gate (exit $($caseC.ExitCode)): $($caseC.Output -join ' | ')"
    }
    if (Test-OutputContains $caseC.Output "packages.lock.json") {
        Fail "Case C: main-side commits leaked into the PR scope decision"
    }
    else {
        Pass "Case C: main-side commits are excluded from the PR scope decision"
    }

    # ------------------------------------------- CASE D (no base => fail closed) ---
    [void](New-Item -ItemType Directory -Force -Path $tempRepoNoBase)
    Invoke-Git $tempRepoNoBase @("init", "--quiet") | Out-Null
    Invoke-Git $tempRepoNoBase @("symbolic-ref", "HEAD", "refs/heads/feature-without-base") | Out-Null
    Write-RepoFile $tempRepoNoBase "installer/scripts/visual-router-runtime.ps1" "# Local Router V4 runtime`n"
    Invoke-Git $tempRepoNoBase @("add", "--all") | Out-Null
    Invoke-Git $tempRepoNoBase @("commit", "--quiet", "-m", "branch without a resolvable base") | Out-Null

    $caseD = Invoke-ScopeValidator $tempRepoNoBase
    if ($caseD.ExitCode -ne 0) {
        Pass "Case D: unresolvable base ref fails closed (exit $($caseD.ExitCode)) instead of passing on an empty delta"
    }
    else {
        Fail "Case D: unresolvable base ref silently passed the scope gate"
    }
    if (Test-OutputContains $caseD.Output "cannot resolve a committed diff base") {
        Pass "Case D: fail-closed message explains the unresolvable base"
    }
    else {
        Fail "Case D: fail-closed message for the unresolvable base is missing"
    }

    # ------------------- CASE E (GitHub trial merge of a reviewed slice PR) ---
    # actions/checkout checks out refs/pull/<n>/merge, whose synthesized merge
    # commit belongs to no reviewed slice. A purely base-into-head merge must be
    # reviewed as its second parent (the PR head) instead of failing.
    $sliceScenario = New-ReviewedSliceScenarioRepo $tempMerge
    $mergeHeadSha = New-PullRequestScenario $tempMerge $sliceScenario
    $trialMergeSha = New-TrialMergeCommit $tempMerge $sliceScenario.BaseSha $mergeHeadSha
    Invoke-Git $tempMerge @("checkout", "--quiet", "--detach", $trialMergeSha) | Out-Null

    $caseE = Invoke-ScopeValidator $tempMerge "-Base origin/main"
    if ($caseE.ExitCode -eq 0) {
        Pass "Case E: a GitHub trial merge of a reviewed slice PR PASSES (reviewed head $(($mergeHeadSha).Substring(0, 8)))"
    }
    else {
        Fail "Case E: a GitHub trial merge of a reviewed slice PR was rejected (exit $($caseE.ExitCode)): $($caseE.Output -join ' | ')"
    }
    if (Test-OutputContains $caseE.Output "synthetic base-into-head merge") {
        Pass "Case E: the gate reports that the reviewed head is the PR head, not the synthesized merge"
    }
    else {
        Fail "Case E: the gate did not report the reviewed head normalization"
    }
    if (Test-OutputContains $caseE.Output "not covered by any registered reviewed slice") {
        Fail "Case E: the synthesized merge commit was still reported as an unregistered change"
    }
    else {
        Pass "Case E: the synthesized merge commit is never reported as an unregistered change"
    }

    # ------------------- CASE F (trial merge with an unregistered head commit) ---
    $unregisteredScenario = New-ReviewedSliceScenarioRepo $tempMergeUnregistered
    Invoke-Git $tempMergeUnregistered @("checkout", "--quiet", "-b", "pr-branch", $unregisteredScenario.SliceTipSha) | Out-Null
    $unregisteredGateSha = Add-GateBaselineCommit $tempMergeUnregistered
    Write-RepoFile $tempMergeUnregistered "local-router/src/Router.Core/RouterPipeline.cs" "// unreviewed backend change`n"
    Invoke-Git $tempMergeUnregistered @("add", "local-router/src/Router.Core/RouterPipeline.cs") | Out-Null
    Invoke-Git $tempMergeUnregistered @("commit", "--quiet", "-m", "feat: unreviewed backend change") | Out-Null
    $unregisteredHeadSha = @(Invoke-Git $tempMergeUnregistered @("rev-parse", "HEAD"))[0]
    Invoke-Git $tempMergeUnregistered @("update-ref", "refs/remotes/origin/main", $unregisteredScenario.BaseSha) | Out-Null
    $unregisteredMergeSha = New-TrialMergeCommit $tempMergeUnregistered $unregisteredScenario.BaseSha $unregisteredHeadSha
    Invoke-Git $tempMergeUnregistered @("checkout", "--quiet", "--detach", $unregisteredMergeSha) | Out-Null

    $caseF = Invoke-ScopeValidator $tempMergeUnregistered "-Base origin/main"
    if ($caseF.ExitCode -ne 0) {
        Pass "Case F: an unregistered commit inside the PR head still FAILS the gate (exit $($caseF.ExitCode))"
    }
    else {
        Fail "Case F: an unregistered commit inside the PR head was accepted by the gate"
    }
    if (Test-OutputContains $caseF.Output "not covered by any registered reviewed slice") {
        Pass "Case F: the gate names the unregistered commit as unauthorized"
    }
    else {
        Fail "Case F: the gate did not report the unregistered commit"
    }

    # ------------------- CASE G (merge whose first parent is the PR head) ---
    $reversedScenario = New-ReviewedSliceScenarioRepo $tempMergeReversed
    # main advances after the slice, so the author-created merge really has two
    # sides and the first parent is the branch head (not the diff base).
    Invoke-Git $tempMergeReversed @("checkout", "--quiet", "main") | Out-Null
    Write-RepoFile $tempMergeReversed "docs/LOCAL_ROUTER_V4_UI.md" ((Get-RepoFile $tempMergeReversed "docs/LOCAL_ROUTER_V4_UI.md") + "## main-side follow-up`n")
    Invoke-Git $tempMergeReversed @("add", "--all") | Out-Null
    Invoke-Git $tempMergeReversed @("commit", "--quiet", "-m", "chore: main-side follow-up") | Out-Null
    $advancedMainSha = @(Invoke-Git $tempMergeReversed @("rev-parse", "HEAD"))[0]
    Invoke-Git $tempMergeReversed @("update-ref", "refs/remotes/origin/main", $advancedMainSha) | Out-Null
    Invoke-Git $tempMergeReversed @("checkout", "--quiet", "-b", "pr-branch", $reversedScenario.SliceTipSha) | Out-Null
    $reversedHeadSha = Add-GateBaselineCommit $tempMergeReversed
    $reversedMergeSha = New-ReversedMergeCommit $tempMergeReversed $advancedMainSha $reversedHeadSha
    Invoke-Git $tempMergeReversed @("checkout", "--quiet", "--detach", $reversedMergeSha) | Out-Null

    $caseG = Invoke-ScopeValidator $tempMergeReversed "-Base origin/main"
    if ($caseG.ExitCode -ne 0) {
        Pass "Case G: a merge whose first parent is the branch head still FAILS closed"
    }
    else {
        Fail "Case G: an unreviewed merge shape was accepted by the gate"
    }
    if (Test-OutputContains $caseG.Output (($reversedMergeSha).Substring(0, 12))) {
        Pass "Case G: the unreviewed merge commit is named as the unauthorized change"
    }
    else {
        Fail "Case G: the gate did not name the unreviewed merge commit"
    }

    # ------------------- CASE H (LR-14 owned file deleted in the merge) ---
    $deletedScenario = New-ReviewedSliceScenarioRepo $tempMergeDeleted
    $deletedHeadSha = New-PullRequestScenario $tempMergeDeleted $deletedScenario
    $deletedMergeSha = New-TrialMergeCommit $tempMergeDeleted $deletedScenario.BaseSha $deletedHeadSha
    $deletedMergeSha = Remove-FileInCurrentCommit $tempMergeDeleted "installer/ui/visual-console.xaml"
    Invoke-Git $tempMergeDeleted @("checkout", "--quiet", "--detach", $deletedMergeSha) | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $tempMergeDeleted "installer/ui/visual-console.xaml"))) {
        Pass "Case H setup: an LR-14 owned file is deleted from the reviewed tree"
    }
    else {
        Fail "Case H setup: the LR-14 owned file was not deleted"
    }

    $caseH = Invoke-ScopeValidator $tempMergeDeleted "-Base origin/main"
    if ($caseH.ExitCode -ne 0) {
        Pass "Case H: deleting a file owned by the reviewed slice FAILS the gate (exit $($caseH.ExitCode))"
    }
    else {
        Fail "Case H: a deleted reviewed-slice file was accepted by the gate"
    }
    if ((Test-OutputContains $caseH.Output "owned file is missing") -or (Test-OutputContains $caseH.Output "not covered by any registered reviewed slice")) {
        Pass "Case H: the gate reports the missing LR-14 owned file"
    }
    else {
        Fail "Case H: the gate did not report the missing LR-14 owned file"
    }

    # ------------------- CASE I (LR-14 owned file modified by an unreviewed head commit) ---
    $modifiedScenario = New-ReviewedSliceScenarioRepo $tempMergeModified
    Invoke-Git $tempMergeModified @("checkout", "--quiet", "-b", "pr-branch", $modifiedScenario.SliceTipSha) | Out-Null
    $modifiedGateSha = Add-GateBaselineCommit $tempMergeModified
    Write-RepoFile $tempMergeModified "installer/ui/visual-console.xaml" "<Window><!-- modified by an unreviewed commit --></Window>`n"
    Invoke-Git $tempMergeModified @("add", "installer/ui/visual-console.xaml") | Out-Null
    Invoke-Git $tempMergeModified @("commit", "--quiet", "-m", "feat: modify the reviewed V4 presentation file") | Out-Null
    $modifiedHeadSha = @(Invoke-Git $tempMergeModified @("rev-parse", "HEAD"))[0]
    Invoke-Git $tempMergeModified @("update-ref", "refs/remotes/origin/main", $modifiedScenario.BaseSha) | Out-Null
    $modifiedMergeSha = New-TrialMergeCommit $tempMergeModified $modifiedScenario.BaseSha $modifiedHeadSha
    Invoke-Git $tempMergeModified @("checkout", "--quiet", "--detach", $modifiedMergeSha) | Out-Null

    $caseI = Invoke-ScopeValidator $tempMergeModified "-Base origin/main"
    if ($caseI.ExitCode -ne 0) {
        Pass "Case I: modifying a reviewed-slice file in an unreviewed commit FAILS the gate (exit $($caseI.ExitCode))"
    }
    else {
        Fail "Case I: an unreviewed modification of a reviewed-slice file was accepted"
    }

    # ------------------- CASE J (reviewed slice authority removed) ---
    # Deleting the slice's authority artifact must revoke its coverage: the slice
    # commits become unregistered and the delta fails closed.
    $revokedScenario = New-ReviewedSliceScenarioRepo $tempSliceUnreachable
    $revokedHeadSha = New-PullRequestScenario $tempSliceUnreachable $revokedScenario
    $revokedMergeSha = New-TrialMergeCommit $tempSliceUnreachable $revokedScenario.BaseSha $revokedHeadSha
    $revokedMergeSha = Remove-FileInCurrentCommit $tempSliceUnreachable "tests/validate-local-router-lr14-scope-regression.ps1"
    Invoke-Git $tempSliceUnreachable @("checkout", "--quiet", "--detach", $revokedMergeSha) | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $tempSliceUnreachable "tests/validate-local-router-lr14-scope-regression.ps1"))) {
        Pass "Case J setup: the reviewed slice's authority artifact is removed from the tree"
    }
    else {
        Fail "Case J setup: the authority artifact was not removed"
    }

    $caseJ = Invoke-ScopeValidator $tempSliceUnreachable "-Base origin/main"
    if ($caseJ.ExitCode -ne 0) {
        Pass "Case J: removing the reviewed slice's authority FAILS the gate (exit $($caseJ.ExitCode))"
    }
    else {
        Fail "Case J: a delta whose reviewed slice lost its authority was accepted"
    }
    if (Test-OutputContains $caseJ.Output "not covered by any registered reviewed slice") {
        Pass "Case J: the gate reports the slice commits as unregistered once the authority is gone"
    }
    else {
        Fail "Case J: the gate did not report the lost authority"
    }
}
catch {
    Fail "LR-14 scope regression harness error: $($_.Exception.Message)"
}
finally {
    $tempBase = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
    if ($tempRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $tempRoot).StartsWith("lr14-scope-regression-", [System.StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Complete-WithSummary "LR-14 scope regression validation FAILED" "LR-14 scope regression validation PASSED"
