param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path,

    # Optional explicit base ref/SHA. When empty the validator resolves the base
    # branch itself (origin/main, then main).
    [Parameter(Mandatory = $false)]
    [string]$Base = ""
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }
function Assert-True([bool]$Condition, [string]$Message) { if ($Condition) { Pass $Message } else { Fail $Message } }
function Short([string]$Sha) { if ($Sha.Length -gt 12) { return $Sha.Substring(0, 12) } return $Sha }

# Native git stderr (for example the harmless autocrlf notice for the file this
# validator lives in) must never be turned into a terminating error, and must
# never be mistaken for git output.
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

# LR-14 scope is a *committed delta* policy: it reviews what the branch commits
# on top of the merge base with the base branch. The checkout working tree is
# explicitly NOT part of that policy - `dotnet restore`/`build`/`test` rewrite
# tracked local-router packages.lock.json files in the CI worktree, and that
# build noise is not a PR change. Merge-base comparison behaves identically for
# a branch checkout and for the detached-HEAD pull_request merge checkout used
# by GitHub Actions.
$script:BaseCandidates = @("origin/main", "main")

function Resolve-CommittedBase([string]$RequestedBase) {
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($RequestedBase)) { $candidates.Add($RequestedBase.Trim()) }
    foreach ($candidate in $script:BaseCandidates) {
        if (-not $candidates.Contains($candidate)) { $candidates.Add($candidate) }
    }

    foreach ($candidate in $candidates) {
        $resolvedSha = [string]::Empty
        $resolved = @(Get-GitLines @("rev-parse", "--verify", "--quiet", "$candidate^{commit}"))
        if ($resolved.Count -gt 0) { $resolvedSha = $resolved[0] }
        if ([string]::IsNullOrWhiteSpace($resolvedSha)) { continue }

        $mergeBaseSha = [string]::Empty
        $mergeBase = @(Get-GitLines @("merge-base", $resolvedSha, "HEAD"))
        if ($mergeBase.Count -gt 0) { $mergeBaseSha = $mergeBase[0] }
        if ([string]::IsNullOrWhiteSpace($mergeBaseSha)) { continue }

        return [pscustomobject]@{ Name = $candidate; Resolved = $resolvedSha; MergeBase = $mergeBaseSha }
    }
    return $null
}

$headSha = [string]::Empty
$head = @(Get-GitLines @("rev-parse", "HEAD"))
if ($head.Count -gt 0) { $headSha = $head[0] }

# NOTE: the resolved base must not be stored in a variable named $base/$Base -
# that name is the [string] script parameter, and assigning the object to it
# would coerce the object into an empty string.
$baseInfo = Resolve-CommittedBase $Base
if ($null -eq $baseInfo) {
    # Fail closed: an unresolvable base must never degrade into reviewing an
    # empty (or working-tree derived) delta and reporting a false PASS.
    Fail "LR-14 scope cannot resolve a committed diff base (requested '$Base'; tried: $($script:BaseCandidates -join ', ')). The gate reviews committed deltas only and refuses to review the working tree."
    Write-Host ""
    Write-Host "LR-14 scope validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

# --- GitHub pull_request checkout: review the PR head, not a trial merge -------
# actions/checkout checks out refs/pull/<n>/merge for a pull_request event, so HEAD
# can be GitHub's synthesized trial merge of the base branch into the pull request
# head. That commit is created by GitHub (<noreply@github.com>), belongs to no
# reviewed slice, and must never be judged as an unreviewed change of its own.
#
# When the merge is purely base-into-head - its FIRST parent is already contained
# in the resolved diff base - the merge introduces no reviewable content beyond
# its second parent: the reviewed delta is exactly the pull request head, i.e. the
# commits that were actually pushed and reviewed. The gate then measures the delta
# from that head (identical file set, real commit list).
#
# Every other shape keeps failing closed: a merge whose first parent is NOT
# contained in the base (an author-created merge), a missing parent, or an
# unregistered commit inside the head is still reported as an unauthorized change.
$script:ReviewedHeadRef = "HEAD"
$headParentLines = @(Get-GitLines @("log", "-1", "--format=%P", "HEAD"))
$headParents = @()
if ($headParentLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$headParentLines[0])) {
    $headParents = @(([string]$headParentLines[0]) -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
if ($headParents.Count -eq 2) {
    $firstParentResolved = @(Get-GitLines @("rev-parse", "--verify", "--quiet", "$($headParents[0])^{commit}"))
    $secondParentResolved = @(Get-GitLines @("rev-parse", "--verify", "--quiet", "$($headParents[1])^{commit}"))
    if ($firstParentResolved.Count -gt 0 -and $secondParentResolved.Count -gt 0 -and
        (Test-GitAncestor $firstParentResolved[0] $baseInfo.MergeBase)) {
        $script:ReviewedHeadRef = $secondParentResolved[0]
        Write-Host "LR-14 review head: HEAD is a synthetic base-into-head merge (GitHub pull_request checkout); the reviewed head is its second parent $(Short $script:ReviewedHeadRef), not the synthesized merge." -ForegroundColor Cyan
    }
}

$changed = @(Get-GitLines @("diff", "--name-only", "--no-renames", $baseInfo.MergeBase, $script:ReviewedHeadRef) | Sort-Object -Unique)
$reviewedHeadNote = ""
if ($script:ReviewedHeadRef -ne "HEAD") { $reviewedHeadNote = " (reviewed head $(Short $script:ReviewedHeadRef))" }
Write-Host "LR-14 committed delta: $(Short $baseInfo.MergeBase) (merge-base of $($baseInfo.Name) $(Short $baseInfo.Resolved) and HEAD) -> HEAD $(Short $headSha)$reviewedHeadNote : $($changed.Count) file(s)" -ForegroundColor Cyan

# --- LR15-G4A: slice applicability -------------------------------------------
# LR-14 is a historical slice gate. It is applicable only when the reviewed
# delta IS the LR-14 slice itself. For any other (later, independently reviewed)
# slice the gate switches to an explicit N/A mode with evidence: it still
# re-verifies the LR-14 slice's own file range below, and it additionally
# requires every commit of the current delta to belong to a registered reviewed
# slice whose authority artifacts are present. It never silently passes, and it
# still fails closed on unregistered commits, deleted authority, or a deleted
# LR-14 file.
# The slice identity is derived from the repository under test - the LR-14 slice
# is the commit that introduced this validator, and its base is that commit's
# parent - so synthetic fixtures and other clones behave consistently instead of
# depending on repository-specific object names.
$script:Lr14SliceCommit = @(Get-GitLines @("log", "--diff-filter=A", "--format=%H", "-1", "--", "tests/validate-local-router-lr14-scope.ps1")) | Select-Object -First 1
$script:Lr14SliceBase = ""
if (-not [string]::IsNullOrWhiteSpace($script:Lr14SliceCommit)) {
    $script:Lr14SliceBase = @(Get-GitLines @("rev-parse", "--verify", "--quiet", "$($script:Lr14SliceCommit)^")) | Select-Object -First 1
    if ($null -eq $script:Lr14SliceBase) { $script:Lr14SliceBase = "" }
}
$script:SliceIdentityKnown = (-not [string]::IsNullOrWhiteSpace($script:Lr14SliceCommit)) -and (-not [string]::IsNullOrWhiteSpace($script:Lr14SliceBase))

# --- OSS-GENESIS: open-source repository root ----------------------------------
# The open-source history starts at ONE sanitized import commit of the private
# development repository (main 1bc5985cc961). The historical LR-14 slice
# c36c7e58845a..e3d60a8eeffe is not part of this history, so the commit that
# introduced this validator is the root and has no parent. Genesis mode accepts
# exactly that shape and nothing else: a single root commit, which introduced
# this validator, whose tree is byte-for-byte the reviewed import tree pinned
# below. Any other root or a second root keeps the historical fail-closed
# behaviour. The LR-14 slice file list is pinned because its range cannot be
# re-read here. See docs/OSS_GENESIS.md.
$script:OssGenesisTree = "8dd01f4f772e95fbcbb140d3850c8814a4d71f3e"
$script:OssGenesisSourceCommit = "1bc5985cc9614c93f9a46261f9b8e0d9c87a7229"
$script:OssGenesisLr14Slice = "c36c7e58845a8d45947aa71226f59723b8dd1f7f..e3d60a8eeffe0e4a74bc899a93b97aaff222dc0e"
$script:OssGenesisLr14Files = @(
    ".github/workflows/ci.yml",
    "docs/LOCAL_ROUTER_V4_UI.md",
    "installer/scripts/visual-console-entry.ps1",
    "installer/scripts/visual-console.ps1",
    "installer/scripts/visual-router-runtime.ps1",
    "installer/ui/visual-console.xaml",
    "tests/fixtures/local-router/v4-ui/control-plane-policy-configured.json",
    "tests/fixtures/local-router/v4-ui/control-plane-policy.json",
    "tests/fixtures/local-router/v4-ui/control-plane-requests.json",
    "tests/fixtures/local-router/v4-ui/control-plane-status-health-unavailable.json",
    "tests/fixtures/local-router/v4-ui/control-plane-status.json",
    "tests/fixtures/local-router/v4-ui/control-plane-usage-missing.json",
    "tests/fixtures/local-router/v4-ui/control-plane-usage-multi-currency.json",
    "tests/fixtures/local-router/v4-ui/control-plane-usage-partial.json",
    "tests/fixtures/local-router/v4-ui/control-plane-usage.json",
    "tests/fixtures/local-router/v4-ui/fake-control-plane.ps1",
    "tests/fixtures/local-router/v4-ui/router-config-corrupt.json",
    "tests/fixtures/local-router/v4-ui/router-config-disabled.json",
    "tests/fixtures/local-router/v4-ui/router-config-enabled.json",
    "tests/fixtures/local-router/v4-ui/router-config-nonloopback.json",
    "tests/shared/protected-file-scope.ps1",
    "tests/validate-local-router-ingress.ps1",
    "tests/validate-local-router-lr14-scope-regression.ps1",
    "tests/validate-local-router-lr14-scope.ps1",
    "tests/validate-local-router-lr14p-control-plane.ps1",
    "tests/validate-local-router-metering-remediation.ps1",
    "tests/validate-local-router-registries.ps1",
    "tests/validate-local-router-v4-ui.ps1")
$script:OssGenesisMode = $false
if (-not [string]::IsNullOrWhiteSpace($script:Lr14SliceCommit) -and [string]::IsNullOrWhiteSpace($script:Lr14SliceBase)) {
    $genesisRoots = @(Get-GitLines @("rev-list", "--max-parents=0", "HEAD"))
    $genesisTree = ""
    if ($genesisRoots.Count -eq 1) { $genesisTree = [string](@(Get-GitLines @("rev-parse", "--verify", "--quiet", "$($genesisRoots[0])^{tree}")) | Select-Object -First 1) }
    if ($genesisRoots.Count -eq 1 -and $genesisRoots[0] -ceq $script:Lr14SliceCommit -and $genesisTree -ceq $script:OssGenesisTree) {
        $script:OssGenesisMode = $true
        $script:SliceIdentityKnown = $true
        Write-Host "OSS-GENESIS: verified single root $(Short $genesisRoots[0]) with the pinned sanitized import tree $(Short $script:OssGenesisTree) (source $(Short $script:OssGenesisSourceCommit))" -ForegroundColor Cyan
    }
    else {
        Write-Host "OSS-GENESIS: not applicable (roots=$($genesisRoots.Count)); the historical fail-closed behaviour applies" -ForegroundColor Yellow
    }
}

$script:RegisteredSlices = @(
    [pscustomobject]@{
        Name      = "LR-14"
        Base      = $script:Lr14SliceBase
        Tip       = $script:Lr14SliceCommit
        Artifacts = @("tests/validate-local-router-lr14-scope.ps1", "tests/validate-local-router-lr14-scope-regression.ps1")
        Markers   = @{ "tests/validate-local-router-v4-ui.ps1" = "LR-14" }
    },
    [pscustomobject]@{
        Name      = "HS-1B"
        Base      = "e3d60a8eeffe0e4a74bc899a93b97aaff222dc0e"
        Tip       = "7dbc7b6b656b547ded2e465d6a97d5c9a214cb95"
        Artifacts = @(
            "docs/HS1B_ROUTER_THREAD_MODEL_OVERRIDE_DESIGN.md",
            "local-router/tests/Router.ThreadSelection.Tests/Router.ThreadSelection.Tests.csproj")
        Markers   = @{ "docs/HS1B_ROUTER_THREAD_MODEL_OVERRIDE_DESIGN.md" = "HS-1B: GO" }
    }
    [pscustomobject]@{
        Name      = "LR15-PR2"
        Base      = "9a90d9e02d2e71245dfe4b46ddd17b9abe2aceab"
        Tip       = "55539ad028348f89bcafa5ded29794af62adc90c"
        Artifacts = @(
            "tests/validate-local-router-bootstrap.ps1",
            "tests/validate-local-router-hs1b-rb1-scope.ps1")
        Markers   = @{ "tests/validate-local-router-bootstrap.ps1" = "bootstrap" }
    }
    [pscustomobject]@{
        Name      = "LR15-PR3"
        Base      = "311a45a1f858cde90d24eeb8aa70c5b657710d53"
        Tip       = "92355b7db425357ac38fc15ebd67094c096ab34a"
        Artifacts = @(
            "tests/validate-dsr7c-safe-failure-diagnostic.ps1",
            "tests/validate-dsr7c-capability-diagnostic.ps1",
            "tests/validate-dsr7c-safe-tool-type-classifier.ps1",
            "tests/validate-dsr7c-safe-custom-tool-identity.ps1")
        Markers   = @{ "tests/validate-dsr7c-safe-failure-diagnostic.ps1" = "SafeFailureDiagnosticRecord" }
    }
    [pscustomobject]@{
        Name      = "LR15-PR4"
        Base      = "364c4450e4e8476ea2d914b9f8d2178f2b55e14f"
        Tip       = "f0496c4b0b32e55c5a0dcfd421248309594c2d98"
        Artifacts = @(
            "tests/validate-dsr7c-apply-patch-final-integration.ps1",
            "tests/validate-dsr7c-apply-patch-file-authorization.ps1",
            "tests/validate-dsr7c-apply-patch-file-authorization-regression.ps1",
            "tests/shared/fix5-patch-identity.ps1")
        Markers   = @{ "tests/validate-dsr7c-apply-patch-final-integration.ps1" = "apply_patch" }
    }
    # CI / Host reliability stabilization: an independently reviewed, test-only
    # slice. It never touches Router backend or production state files; the
    # authority artifacts are the harness/timing files it changed plus the
    # workflow timeout budget, each pinned by a marker that only exists in this
    # reviewed revision.
    [pscustomobject]@{
        Name      = "CI-HOST-RELIABILITY-FIX1"
        Base      = "e6ec7cfba07ce884dd6cf2cc5402276521f1b79a"
        Tip       = "1fb660c5acd4eb0add626dbc5a86b0e1a2247ed0"
        Artifacts = @(
            ".github/workflows/ci.yml",
            "local-router/tests/ProviderContractKit/ProviderContractSuite.cs",
            "local-router/tests/Router.Core.Tests/Host/Dsr6ProductionStartupTests.cs",
            "local-router/tests/Router.Core.Tests/Host/Dsr7cFailureDiagnosticTests.cs",
            "local-router/tests/Router.Core.Tests/Host/Lr3HostEnabledTests.cs")
        Markers   = @{
            ".github/workflows/ci.yml" = "timeout-minutes: 20"
            "local-router/tests/ProviderContractKit/ProviderContractSuite.cs" = "exactly the Total stage must fire"
            "local-router/tests/Router.Core.Tests/Host/Dsr6ProductionStartupTests.cs" = "DeleteSandboxWithRetryAsync"
            "local-router/tests/Router.Core.Tests/Host/Dsr7cFailureDiagnosticTests.cs" = "durable READY state before shutdown"
            "local-router/tests/Router.Core.Tests/Host/Lr3HostEnabledTests.cs" = "HostTestHarness.WaitUntilReadyStateAsync"
        }
    }
    # CI / Host reliability Fix 2: readiness is published only after the durable
    # owner/runtime READY commit, startup-tail cancellation cleans up (archive,
    # no fabricated STOPPED, exit 130), and the lifecycle allows the
    # STARTING -> STOPPING startup shutdown without opening STARTING -> STOPPED.
    # Independently reviewed, still test/test-contract only: no provider,
    # Desktop, taxonomy or model file is part of this delta.
    [pscustomobject]@{
        Name      = "CI-HOST-RELIABILITY-FIX2"
        Base      = "461ce65cbad35e6e478bacec34ff6f72afd2cba9"
        Tip       = "302d5a11a94cf481aa248e7afb4ae9d995fde7fa"
        Artifacts = @(
            "local-router/src/Router.Host/RouterHostBootstrap.cs",
            "local-router/src/Router.Ingress/ResponsesIngress.cs",
            "local-router/src/Router.Core/Lifecycle/RouterLifecycle.cs",
            "local-router/tests/Router.Core.Tests/Lifecycle/RouterLifecycleTests.cs",
            "local-router/tests/Router.Ingress.Tests/Support/IngressTestServer.cs",
            "local-router/tests/Router.Ingress.Tests/Support/IngressTestServerOptions.cs",
            "local-router/tests/Router.Core.Tests/Fakes/BlockingRuntimeStateFileSystem.cs",
            "local-router/tests/Router.Core.Tests/Host/HostReadinessLifecycleTests.cs",
            "local-router/tests/Router.Ingress.Tests/IngressDeferredReadyTests.cs",
            "tests/validate-local-router-production-startup.ps1")
        Markers   = @{
            "local-router/src/Router.Host/RouterHostBootstrap.cs" = "deferReadyPublication: true"
            "local-router/src/Router.Ingress/ResponsesIngress.cs" = "public bool TryPublishReady()"
            "local-router/src/Router.Core/Lifecycle/RouterLifecycle.cs" = "LifecycleState.Starting => to is LifecycleState.Ready or LifecycleState.Degraded or LifecycleState.Stopping"
            "local-router/tests/Router.Core.Tests/Host/HostReadinessLifecycleTests.cs" = "Startup_tail_cancellation_stops_safely"
            "local-router/tests/Router.Ingress.Tests/IngressDeferredReadyTests.cs" = "Deferred_ingress_reports_starting_until_ready_is_published"
            "tests/validate-local-router-production-startup.ps1" = "FIX2 C: the durable READY commit happens before the public READY publication"
        }
    }
    # CI stability: the V4 UI refresh contract is proven by observed ordering
    # (a real HTTP request held open while the caller had already returned)
    # instead of a wall-clock threshold, with deterministic negative controls.
    # Test-only delta: no production, workflow, provider or model file.
    [pscustomobject]@{
        Name      = "CI-V4-UI-NONBLOCKING-TEST"
        Base      = "a8c309d001ad818d8181795d154b90d288d6bedc"
        Tip       = "4a9db08e9e4cb49929013b165a30f1ecc2f95616"
        Artifacts = @(
            "tests/validate-local-router-v4-ui.ps1",
            "tests/fixtures/local-router/v4-ui/fake-control-plane.ps1")
        Markers   = @{
            "tests/validate-local-router-v4-ui.ps1" = "UI_REFRESH_RETURNED_BEFORE_HTTP_RESPONSE = TRUE"
            "tests/fixtures/local-router/v4-ui/fake-control-plane.ps1" = "Invoke-FakeResponseGate"
        }
    }
    # LR-15 PR5 rebased onto the current main: the two extra Codex Desktop
    # taxonomy types (namespace, tool_search) are recognised as fixed labels and
    # stay fail-closed as unsupported_capability; they are never mapped to a
    # function, never forwarded and never silently dropped. The rebase keeps only
    # the taxonomy feature - the CI timeout and the host/provider stabilization
    # from the original PR are already in main and are deliberately NOT re-added.
    [pscustomobject]@{
        Name      = "LR15-PR5"
        Base      = "f42dcd8c7184f1ce52f18c6a6525f38e10ab295b"
        Tip       = "7514710344f93931969fb82096d5f6ca385c9c15"
        Artifacts = @(
            "local-router/src/Router.Core/Support/SafeToolTypeClassifier.cs",
            "local-router/tests/Router.ClientAdapters.Responses.Tests/ResponsesRequestParserTests.cs",
            "local-router/tests/Router.Core.Tests/Support/SafeToolTypeClassifierTests.cs",
            "tests/validate-dsr7c-safe-tool-type-classifier.ps1")
        Markers   = @{
            "local-router/src/Router.Core/Support/SafeToolTypeClassifier.cs" = 'public const string ToolSearch = "tool_search";'
            "local-router/tests/Router.ClientAdapters.Responses.Tests/ResponsesRequestParserTests.cs" = "Desktop_13_tool_shape_classifies_namespace_at_its_structural_index"
            "local-router/tests/Router.Core.Tests/Support/SafeToolTypeClassifierTests.cs" = 'InlineData("tool_search", SafeToolTypeClassifier.ToolSearch)'
            "tests/validate-dsr7c-safe-tool-type-classifier.ps1" = "13: the two labels still fail closed with unsupported_capability"
        }
    }
    # LR-15 PR6: release package build + provenance verification. Package content
    # is exported with git archive from one commit of a real checkout (the working
    # tree is never copied), only tracked files matching an explicit allow list are
    # packaged, sensitive/excluded paths refuse the build, and -Verify re-reads the
    # packaged bytes. The provenance validator is wired into tests/validate-repo.ps1
    # so the Development Gate CI job executes it; no production Router behaviour and
    # no CI workflow file is touched by this slice.
    [pscustomobject]@{
        Name      = "LR15-PR6"
        Base      = "073ee1f198493ef21748fe01fedbf7e9063129c8"
        Tip       = "fd5131d8f91948c4c1716a10d7878e4fbdf078cf"
        Artifacts = @(
            "installer/scripts/build-release-package.ps1",
            "tests/validate-release-package-provenance.ps1",
            "tests/validate-repo.ps1",
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md")
        Markers   = @{
            "installer/scripts/build-release-package.ps1" = "A release package is a BUILT artifact"
            "tests/validate-release-package-provenance.ps1" = "Release package provenance validation PASSED (A-L)"
            "tests/validate-repo.ps1" = "Release package provenance validation passed (scenarios A-L)"
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md" = "PR6 release package and provenance (implemented)"
        }
    }
    # LR15-PR7: exact ownership-only artifact installation/removal-plan slice.
    # No provider, user-config, lifecycle, upgrade or uninstall execution change.
    [pscustomobject]@{
        Name      = "LR15-PR7"
        Base      = "def6292977778152aa4de9da49aac7222bb720bf"
        Tip       = "0f291525617ff3bb4b31a691c900228b60d66a0b"
        Artifacts = @(
            "installer/scripts/router-install-ownership.psm1",
            "tests/validate-router-install-ownership.ps1",
            "tests/validate-repo.ps1",
            "docs/ROUTER_INSTALL_OWNERSHIP.md",
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md")
        Markers   = @{
            "installer/scripts/router-install-ownership.psm1" = "LR15-PR7: isolated package installation"
            "tests/validate-router-install-ownership.ps1" = "Router install ownership validation PASSED"
            "tests/validate-repo.ps1" = "Router install ownership validation passed"
            "docs/ROUTER_INSTALL_OWNERSHIP.md" = "Install Ownership Manifest v1"
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md" = "PR7 install ownership foundation"
        }
    }
    # LR15-PR8: exact opt-in owned-file uninstall slice. No Host lifecycle
    # implementation, provider, Desktop, upgrade or UI artifacts are included.
    [pscustomobject]@{
        Name      = "LR15-PR8"
        Base      = "aed9d631c50e13c623eb5fdfdc36ed922a8dbfbb"
        Tip       = "aa60acbf1abeab1a48ceaacecbac486f21620f12"
        Artifacts = @(
            "installer/scripts/router-install-ownership.psm1",
            "installer/scripts/router-safe-uninstall.ps1",
            "installer/scripts/router-uninstall-safety.cs",
            "tests/validate-router-safe-uninstall.ps1",
            "tests/validate-repo.ps1",
            "docs/ROUTER_SAFE_UNINSTALL.md",
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md")
        Markers   = @{
            "installer/scripts/router-install-ownership.psm1" = "PR8 adds execution"
            "installer/scripts/router-safe-uninstall.ps1" = "LR15-PR8: loaded privately"
            "installer/scripts/router-uninstall-safety.cs" = "LR15-PR8: Windows handle-based deletion"
            "tests/validate-router-safe-uninstall.ps1" = "Router safe uninstall validation PASSED"
            "tests/validate-repo.ps1" = "Router safe uninstall validation passed"
            "docs/ROUTER_SAFE_UNINSTALL.md" = "Safe uninstall executor"
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md" = "PR8 safe uninstall execution"
        }
    }
    # PR8-FIX1 is limited to partial-move fixture recovery and CI diagnostics.
    # Register its exact commit without extending the original feature range.
    [pscustomobject]@{
        Name      = "LR15-PR8-FIX1"
        Base      = "489510800331db6414dba960ab9b88984f1b6806"
        Tip       = "08c02e2e7dd39fcf3fef2be15838ab14bcb6daf5"
        Artifacts = @("tests/validate-router-safe-uninstall.ps1", "tests/validate-repo.ps1")
        Markers   = @{
            "tests/validate-router-safe-uninstall.ps1" = "FIX1: test-fixture recovery only"
            "tests/validate-repo.ps1" = "FIX1's real filesystem evidence"
        }
    }
    # PR9 is an independent compiled Host artifact/verifier and isolated tests.
    # No production Host, routing, provider, Desktop or lifecycle file changes.
    [pscustomobject]@{
        Name      = "LR15-PR9"
        Base      = "8411ced36545463a489c2742f30f3a7b9797594d"
        Tip       = "ffd48491ea838a86d44dd2be656e89ab7627d444"
        Artifacts = @(
            "installer/scripts/build-router-host-release.ps1",
            "installer/scripts/router-host-release.psm1",
            "tests/validate-router-host-release.ps1",
            "tests/validate-repo.ps1",
            "docs/ROUTER_HOST_RELEASE.md",
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md")
        Markers   = @{
            "installer/scripts/build-router-host-release.ps1" = "LR15-PR9: independent compiled Host release"
            "installer/scripts/router-host-release.psm1" = "LR15-PR9: compiled Host artifact only"
            "tests/validate-router-host-release.ps1" = "Router Host release validation PASSED"
            "tests/validate-repo.ps1" = "Router Host release validation passed"
            "docs/ROUTER_HOST_RELEASE.md" = "Router Host release packaging"
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md" = "PR9 Router Host release packaging"
        }
    }
    # PR10A: exact native startup-only boundary. No stopped lease, installation
    # composition, Provider, Desktop or UI feature is part of this range.
    [pscustomobject]@{
        Name      = "LR15-PR10A"
        Base      = "65a520d4db818ab8efd06d292735485d36329e7c"
        Tip       = "2e03393b7b531d9622a1db8e1134af65f9510cd2"
        Artifacts = @(
            "local-router/src/Router.State/Ownership/WindowsRouterStartupGate.cs",
            "local-router/src/Router.Host/RouterHostBootstrap.cs",
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs",
            "tests/validate-router-host-startup-gate.ps1",
            "tests/validate-repo.ps1",
            "docs/ROUTER_HOST_STARTUP_GATE.md",
            "docs/PR10_LINUX_FAILURE_CLASSIFICATION.md",
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md")
        Markers = @{
            "local-router/src/Router.State/Ownership/WindowsRouterStartupGate.cs" = "PR10A runtime coordination only"
            "local-router/src/Router.Host/RouterHostBootstrap.cs" = "using WindowsRouterStartupGate startupGate"
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs" = "PR10A isolated child-process fixture"
            "tests/validate-router-host-startup-gate.ps1" = "STARTUP_GATE_NATIVE"
            "tests/validate-repo.ps1" = "Router Host startup gate validation passed"
            "docs/ROUTER_HOST_STARTUP_GATE.md" = "LR-15 PR10A"
            "docs/PR10_LINUX_FAILURE_CLASSIFICATION.md" = "PR10 Linux"
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md" = "PR10A Windows Host startup gate"
        }
    }
    # FIX1 only: native share access, real directory attacks and scalar matching.
    [pscustomobject]@{
        Name      = "LR15-PR10A-FIX1"
        Base      = "9ed6983982a3581a80496e00b6e7fb410ec4fec0"
        Tip       = "41ef78c7b6a25fcb16d6e597f151d53b711c4447"
        Artifacts = @(
            "local-router/src/Router.State/Ownership/WindowsRouterStartupGate.cs",
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs",
            "tests/validate-router-host-startup-gate.ps1",
            "docs/ROUTER_HOST_STARTUP_GATE.md")
        Markers = @{
            "local-router/src/Router.State/Ownership/WindowsRouterStartupGate.cs" = "directoryReadAccess = 0x00020081"
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs" = "FIX1: real NTFS attacks"
            "tests/validate-router-host-startup-gate.ps1" = "REPARSE_RUNTIME"
            "docs/ROUTER_HOST_STARTUP_GATE.md" = "FIX1: native directory share access"
        }
    }
    # FIX2: private Host fixtures and fail-closed diagnostics/regression wiring.
    [pscustomobject]@{
        Name      = "LR15-PR10A-FIX2"
        Base      = "29764f8dcfda3a745c351e25480b0c1cc26cb09b"
        Tip       = "5ec96356e117244af322e161a3471b44bdbfe3d6"
        Artifacts = @(
            ".github/workflows/ci.yml",
            "docs/ROUTER_HOST_STARTUP_GATE.md",
            "local-router/src/Router.Host/RouterHostBootstrap.cs",
            "local-router/src/Router.State/Ownership/WindowsRouterStartupGate.cs",
            "local-router/tests/Router.Core.Tests/Fakes/TestPaths.cs",
            "local-router/tests/Router.Core.Tests/Host/HostReadinessLifecycleTests.cs",
            "local-router/tests/Router.Core.Tests/Host/HostTestHarness.cs",
            "local-router/tests/Router.Core.Tests/Host/HostStartupGateSmokeTests.cs",
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs",
            "tests/validate-router-host-startup-gate.ps1")
        Markers = @{
            ".github/workflows/ci.yml" = "PR10A focused Host and native startup regression"
            "docs/ROUTER_HOST_STARTUP_GATE.md" = "FIX2: Host regression diagnosis"
            "local-router/src/Router.Host/RouterHostBootstrap.cs" = "stage={error.FailureStage}"
            "local-router/src/Router.State/Ownership/WindowsRouterStartupGate.cs" = "runtime_parent_acl"
            "local-router/tests/Router.Core.Tests/Fakes/TestPaths.cs" = "CreatePrivateWindowsDirectory"
            "local-router/tests/Router.Core.Tests/Host/HostReadinessLifecycleTests.cs" = "WaitForStartupBarrierAsync"
            "local-router/tests/Router.Core.Tests/Host/HostTestHarness.cs" = "FIX2: a refused/faulted Host"
            "local-router/tests/Router.Core.Tests/Host/HostStartupGateSmokeTests.cs" = "FIX2 focused Windows CI reproduction"
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs" = "FIX2 diagnostic"
            "tests/validate-router-host-startup-gate.ps1" = "FIX2_INHERITED_HOST"
        }
    }
    # FIX3: content-free persistence diagnostics and held-gate Windows I/O
    # regressions; production directory access, sharing and ACL trust stay strict.
    [pscustomobject]@{
        Name      = "LR15-PR10A-FIX3"
        Base      = "bf3c26ce07da1b1240984c69c69178648619e329"
        Tip       = "0f197f2625d90b190c67ac029833b08f47d93576"
        Artifacts = @(
            "docs/ROUTER_HOST_STARTUP_GATE.md",
            "local-router/src/Router.Host/RouterHostBootstrap.cs",
            "local-router/src/Router.State/AtomicFileWriter.cs",
            "local-router/src/Router.State/RouterStateStore.cs",
            "local-router/src/Router.State/StatePersistenceDiagnostic.cs",
            "local-router/src/Router.State/WindowsFileSecurity.cs",
            "local-router/tests/Router.Core.Tests/State/StatePersistenceDiagnosticTests.cs",
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs",
            "tests/validate-router-host-startup-gate.ps1")
        Markers = @{
            "docs/ROUTER_HOST_STARTUP_GATE.md" = "FIX3: exact persistence failure evidence"
            "local-router/src/Router.Host/RouterHostBootstrap.cs" = "phase=stopped_state operation=atomic_write"
            "local-router/src/Router.State/AtomicFileWriter.cs" = "StatePersistenceOperation.MoveFile"
            "local-router/src/Router.State/RouterStateStore.cs" = "StatePersistenceOperation.CopyFile"
            "local-router/src/Router.State/StatePersistenceDiagnostic.cs" = "state_persistence_failed: target="
            "local-router/src/Router.State/WindowsFileSecurity.cs" = "StatePersistenceOperation.VerifyFileSecurity"
            "local-router/tests/Router.Core.Tests/State/StatePersistenceDiagnosticTests.cs" = "Diagnostic_reports_native_sharing_conflict_without_private_details"
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs" = "STOP_WRITE_FAILURE PASS"
            "tests/validate-router-host-startup-gate.ps1" = "STATE_IO_CONTEXT"
        }
    }
    # FIX4: Windows refused every atomic state publication because the runtime
    # directory was pinned with FILE_SHARE_READ only (Windows opens the file's
    # parent directory for the rename), while the reparse primitive could still
    # open that directory with FILE_WRITE_ATTRIBUTES because Windows keeps the
    # metadata-write class outside FILE_SHARE_WRITE. The pin now shares read/write
    # (never delete) and an explicit metadata-write DENY ACE, applied only after
    # this process owns the kernel mutex, refuses the reparse primitive and is
    # restored on release. No refusal path, identity check or ACL check was
    # relaxed.
    [pscustomobject]@{
        Name      = "LR15-PR10A-FIX4"
        Base      = "0946191b6b5f0e563fc8aaf02d0a7ae7a8467b34"
        Tip       = "90ceca8e0a48f4f16edd85df240c0fb505827a66"
        Artifacts = @(
            "docs/ROUTER_HOST_STARTUP_GATE.md",
            "local-router/src/Router.State/Ownership/WindowsRouterStartupGate.cs",
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs",
            "tests/validate-router-host-startup-gate.ps1")
        Markers = @{
            "docs/ROUTER_HOST_STARTUP_GATE.md" = "FIX4: share-write pinning plus an explicit metadata-write guard"
            "local-router/src/Router.State/Ownership/WindowsRouterStartupGate.cs" = "MetadataWriteGuard"
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs" = "DIRECTORY_WRITE_REFUSED generic="
            "tests/validate-router-host-startup-gate.ps1" = "metadata=5"
        }
    }
    # FIX5: the deny fixtures must install a rule Windows actually enforces (a
    # DENY on FILE_READ_ATTRIBUTES alone is not effective, because Windows grants
    # read-attributes implicitly whenever any other access is granted), the gate
    # now fails closed on an effective deny of a right the runtime requires, and
    # the metadata-write guard plus the kernel mutex are installed, restored and
    # released by the same coordination thread so a failed guard cannot deadlock
    # and a second Host can never clean the ACL concurrently.
    [pscustomobject]@{
        Name      = "LR15-PR10A-FIX5"
        Base      = "edb3109dbc0b70b1931af5d274024e044d8d4a8a"
        Tip       = "d483e558991de2fc9d5d564d27de36250f8b24c9"
        Artifacts = @(
            "docs/ROUTER_HOST_STARTUP_GATE.md",
            "local-router/src/Router.State/Ownership/WindowsRouterStartupGate.cs",
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs",
            "tests/validate-router-host-startup-gate.ps1")
        Markers = @{
            "docs/ROUTER_HOST_STARTUP_GATE.md" = "FIX5: effective ACL denial and guard/mutex lifecycle"
            "local-router/src/Router.State/Ownership/WindowsRouterStartupGate.cs" = "Required directory access is denied."
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs" = "GATE_OPEN checked refused="
            "tests/validate-router-host-startup-gate.ps1" = "the ListDirectory denial is effective for the coordination access mask"
        }
    }
    # FIX5 cleanup semantics: a shutdown that cannot restore the runtime directory
    # access control must never report a clean stop. Dispose releases the kernel
    # mutex and every directory handle first and only then raises the fixed
    # `startup_gate_cleanup_failed` coordination exception, which the Host maps to
    # its own non-zero cleanup code with cleanup-specific wording; normal stop (0),
    # startup/config failure and a failed STOPPED write (2) and cancellation (130)
    # keep their meaning.
    [pscustomobject]@{
        Name      = "LR15-PR10A-FIX5-CLEANUP"
        Base      = "5d728d77c0e945e2483fdc500a67ef5adebdadac"
        Tip       = "c1dc92f1e57306ca7bc0af0e3b9c9ac9b95f2888"
        Artifacts = @(
            "docs/ROUTER_HOST_STARTUP_GATE.md",
            "local-router/src/Router.Host/RouterHostBootstrap.cs",
            "local-router/src/Router.State/Ownership/WindowsRouterStartupGate.cs",
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs",
            "tests/validate-router-host-startup-gate.ps1")
        Markers = @{
            "docs/ROUTER_HOST_STARTUP_GATE.md" = "Cleanup-failure exit semantics"
            "local-router/src/Router.Host/RouterHostBootstrap.cs" = "public const int CleanupFailedExitCode = 3;"
            "local-router/src/Router.State/Ownership/WindowsRouterStartupGate.cs" = 'CleanupFailedMessage = "startup_gate_cleanup_failed"'
            "tests/fixtures/local-router/startup-gate/StartupGateProbe.cs" = "DOUBLE_DISPOSE_OK"
            "tests/validate-router-host-startup-gate.ps1" = "the cleanup failure is raised only after the mutex and directory handles are released"
        }
    }
    # PR10B: the Host lifecycle controller and its host-local control channel.
    # No installation binding, stopped lease, Provider, Desktop, V4 or UI feature
    # is part of this range.
    [pscustomobject]@{
        Name      = "LR15-PR10B"
        Base      = "cafca59a865ec11c29324b14f776e85cd1c19c79"
        Tip       = "840dba6c4f20541b19deed0bce072717bbcef34c"
        Artifacts = @(
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md",
            "docs/ROUTER_HOST_LIFECYCLE.md",
            "installer/scripts/router-lifecycle.ps1",
            "local-router/src/Router.Host/RouterHostBootstrap.cs",
            "local-router/src/Router.Host/RouterHostControlChannel.cs",
            "local-router/tests/Router.Core.Tests/Host/HostLifecycleControlTests.cs",
            "tests/validate-repo.ps1",
            "tests/validate-router-host-lifecycle.ps1")
        Markers = @{
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md" = "PR10B Router Host lifecycle controller"
            "docs/ROUTER_HOST_LIFECYCLE.md" = "LR-15 PR10B — Router Host lifecycle controller"
            "installer/scripts/router-lifecycle.ps1" = "Router Host lifecycle controller (Status / Start / Graceful Stop)"
            "local-router/src/Router.Host/RouterHostBootstrap.cs" = "PR10B lifecycle control"
            "local-router/src/Router.Host/RouterHostControlChannel.cs" = "single-shot lifecycle control endpoint"
            "local-router/tests/Router.Core.Tests/Host/HostLifecycleControlTests.cs" = "HostLifecycleControlTests"
            "tests/validate-repo.ps1" = "Router Host lifecycle controller validation passed"
            "tests/validate-router-host-lifecycle.ps1" = "LIFECYCLE_SUMMARY"
        }
    }
    # PR10B FIX1: proof semantics only - status never fabricates a stop, stop
    # proves the exit, the durable state and this owner's archive, and start
    # requires a complete managed READY. No installation binding or lease.
    [pscustomobject]@{
        Name      = "LR15-PR10B-FIX1"
        Base      = "d5180d878473dbc9d560555beed06603d293c523"
        Tip       = "11e6dce889a79d7d666960cdc829076c959af243"
        Artifacts = @(
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md",
            "docs/ROUTER_HOST_LIFECYCLE.md",
            "installer/scripts/router-lifecycle.ps1",
            "local-router/src/Router.Host/RouterHostBootstrap.cs",
            "local-router/src/Router.Host/RouterHostControlChannel.cs",
            "local-router/tests/Router.Core.Tests/Host/HostLifecycleControlTests.cs",
            "tests/validate-router-host-lifecycle.ps1")
        Markers = @{
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md" = "PR10B FIX1 — stop/start proof semantics"
            "docs/ROUTER_HOST_LIFECYCLE.md" = "terminal_state_without_current_stop_proof"
            "installer/scripts/router-lifecycle.ps1" = "stop_incomplete_owner_archive_unproven"
            "local-router/src/Router.Host/RouterHostBootstrap.cs" = "ControlChannelUnavailableExitCode"
            "local-router/src/Router.Host/RouterHostControlChannel.cs" = "control_endpoint_unprotected"
            "local-router/tests/Router.Core.Tests/Host/HostLifecycleControlTests.cs" = "CapabilityProtectionUnverifiableFileSecurity"
            "tests/validate-router-host-lifecycle.ps1" = "STATUS-1"
        }
    }
    # PR10B FIX2: exit-evidence discipline and a real current-user-only
    # capability. No installation binding, lease or contract change.
    [pscustomobject]@{
        Name      = "LR15-PR10B-FIX2"
        Base      = "d8b12fed8af412372552398489172542ee19f85c"
        Tip       = "90f57fa3a368359b17f087ca79e9bf02fb7a062e"
        Artifacts = @(
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md",
            "docs/ROUTER_HOST_LIFECYCLE.md",
            "installer/scripts/router-lifecycle.ps1",
            "local-router/tests/Router.Core.Tests/Host/HostLifecycleControlTests.cs",
            "tests/validate-router-host-lifecycle.ps1")
        Markers = @{
            "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md" = "PR10B FIX2 — exit-evidence and capability-credential discipline"
            "docs/ROUTER_HOST_LIFECYCLE.md" = "control_endpoint_acl_foreign_identity"
            "installer/scripts/router-lifecycle.ps1" = "process_id_absent"
            "local-router/tests/Router.Core.Tests/Host/HostLifecycleControlTests.cs" = "the capability file must not grant access to another identity"
            "tests/validate-router-host-lifecycle.ps1" = "ACL-2: a protected capability that grants Users read is refused"
        }
    }
    # PR10B FIX3: the control listener's accept loop is started without a
    # thread-pool task, so Router.Host keeps no `Task.Run`. No behaviour change.
    [pscustomobject]@{
        Name      = "LR15-PR10B-FIX3"
        Base      = "78cdf3dc286b0d6474c17ad7689057dd36795a01"
        Tip       = "5ca371de0f0775032c6e3d4b50cb8b8fc159fb12"
        Artifacts = @(
            "local-router/src/Router.Host/RouterHostControlChannel.cs")
        Markers = @{
            "local-router/src/Router.Host/RouterHostControlChannel.cs" = "_acceptTask = AcceptLoopAsync();"
        }
    }
    # Product blueprint planning docs (DRAFT, pending owner approval). Documents
    # only: no production, installer, Skill, Router, UI, CI or test behaviour.
    [pscustomobject]@{
        Name      = "PRODUCT-BLUEPRINT-DOCS"
        Base      = "2abc868896f167006ad65eb4ec8c3b7b2eb25477"
        Tip       = "e115b36a796b46d3e397a40a24c205457ac270c9"
        Artifacts = @(
            "CLAUDE.md",
            "docs/MASTER_ROADMAP.md",
            "docs/PRODUCT_VISION.md",
            "docs/PROJECT_STATUS.md")
        Markers = @{
            "CLAUDE.md" = "RegisteredSlices"
            "docs/MASTER_ROADMAP.md" = "V1-10"
            "docs/PRODUCT_VISION.md" = "DIRECT_ONLY"
            "docs/PROJECT_STATUS.md" = "2abc868896f167006ad65eb4ec8c3b7b2eb25477"
        }
    }
    # Product blueprint planning docs, PM acceptance revision 1: confirmed goals
    # G-1..G-5, five status classes, ChatGPT subscription quota as a feasibility
    # study item. Documents only.
    [pscustomobject]@{
        Name      = "PRODUCT-BLUEPRINT-DOCS-REV1"
        Base      = "1c77f5f17f51eb8080405bd84b686aee825b759a"
        Tip       = "5c9906bae50a8a85ebdb9118ee69d95db21c3808"
        Artifacts = @(
            "CLAUDE.md",
            "docs/MASTER_ROADMAP.md",
            "docs/PRODUCT_VISION.md",
            "docs/PROJECT_STATUS.md")
        Markers = @{
            "CLAUDE.md" = "G-1"
            "docs/MASTER_ROADMAP.md" = "V1-11"
            "docs/PRODUCT_VISION.md" = "G-5"
            "docs/PROJECT_STATUS.md" = "mm_openai_api"
        }
    }
    # Product blueprint planning docs, PM acceptance revision 2: ACL-verified
    # worktree rule, M1 feasibility study before the M2 scope freeze, G-6
    # bounded failure, environment-limit classification. Documents only.
    [pscustomobject]@{
        Name      = "PRODUCT-BLUEPRINT-DOCS-REV2"
        Base      = "2fc5614f729584c18af46c701993f24cb69eceaa"
        Tip       = "224ee55955d01fbc9e3ae397c58ff0974975cce1"
        Artifacts = @(
            "CLAUDE.md",
            "docs/MASTER_ROADMAP.md",
            "docs/PRODUCT_VISION.md",
            "docs/PROJECT_STATUS.md")
        Markers = @{
            "CLAUDE.md" = "cmm-wt"
            "docs/MASTER_ROADMAP.md" = "G-6"
            "docs/PRODUCT_VISION.md" = "G-6"
            "docs/PROJECT_STATUS.md" = "6df2cbb"
        }
    }
    # M1 research: ChatGPT subscription quota failover feasibility. One research
    # document only; no production, installer, Skill, Router, UI or CI change.
    [pscustomobject]@{
        Name      = "M1-QUOTA-FAILOVER-RESEARCH"
        Base      = "13ef69e808eaecfe2a46b65f756fa78d8d0e6597"
        Tip       = "8982ce7faeeaf928db442ece135d6858661a874c"
        Artifacts = @(
            "docs/CHATGPT_SUBSCRIPTION_QUOTA_FAILOVER_FEASIBILITY.md")
        Markers = @{
            "docs/CHATGPT_SUBSCRIPTION_QUOTA_FAILOVER_FEASIBILITY.md" = "PARTIALLY_FEASIBLE"
        }
    }
    # M1 research revision 1: reproducible evidence appendix and a sample-scoped
    # Router compatibility finding. One research document only.
    [pscustomobject]@{
        Name      = "M1-QUOTA-FAILOVER-RESEARCH-REV1"
        Base      = "44181a39423aefad6511acd5ef2ba02459a4e7b3"
        Tip       = "f8f86fde33c9678f705ce793c6da1285116c96dd"
        Artifacts = @(
            "docs/CHATGPT_SUBSCRIPTION_QUOTA_FAILOVER_FEASIBILITY.md")
        Markers = @{
            "docs/CHATGPT_SUBSCRIPTION_QUOTA_FAILOVER_FEASIBILITY.md" = "A.8"
        }
    }
    # U3/U6 research: real Codex TUI remote attach validation report plus its offline
    # reproduction fixtures. No production, Router, Desktop, installer or CI change.
    [pscustomobject]@{
        Name      = "CLI-REMOTE-TUI-RESEARCH"
        Base      = "6e811624c540807835e9b73f23e2f3e9cc27d6e4"
        Tip       = "9a975b76fc51e555cb87123dcc20b5c392af18ab"
        Artifacts = @(
            "docs/CLI_REMOTE_TUI_INTEGRATION_VALIDATION.md",
            "tests/fixtures/codex-cli-remote-research/Invoke-RemoteResearch.ps1",
            "tests/fixtures/codex-cli-remote-research/RemoteResearchHarness.cs")
        Markers = @{
            "docs/CLI_REMOTE_TUI_INTEGRATION_VALIDATION.md" = "run9"
            "tests/fixtures/codex-cli-remote-research/Invoke-RemoteResearch.ps1" = "MaxSeconds"
            "tests/fixtures/codex-cli-remote-research/RemoteResearchHarness.cs" = "KILL_ON_JOB_CLOSE"
        }
    }
    # U3/U6 research, second-round safety remediation of the research runner and a narrowed
    # U6 statement. Research runner and report only.
    [pscustomobject]@{
        Name      = "CLI-REMOTE-TUI-RESEARCH-REV1"
        Base      = "a48d88c67056b98d99020579408098d2b5c66ad6"
        Tip       = "76cccad115fbe8ba10d21ebc345dd5b037e8111e"
        Artifacts = @(
            "docs/CLI_REMOTE_TUI_INTEGRATION_VALIDATION.md",
            "tests/fixtures/codex-cli-remote-research/Invoke-RemoteResearch.ps1",
            "tests/fixtures/codex-cli-remote-research/RemoteResearchHarness.cs")
        Markers = @{
            "docs/CLI_REMOTE_TUI_INTEGRATION_VALIDATION.md" = "10.4"
            "tests/fixtures/codex-cli-remote-research/Invoke-RemoteResearch.ps1" = "NETWORK_VIOLATION"
            "tests/fixtures/codex-cli-remote-research/RemoteResearchHarness.cs" = "class ProcessGroup"
        }
    }
    # U3/U6 research, third-round minimal remediation of the five review leftovers; the runner
    # is disabled by default until a dynamic verification is approved. Research runner and report only.
    [pscustomobject]@{
        Name      = "CLI-REMOTE-TUI-RESEARCH-REV2"
        Base      = "a45a79f218aa617f404977ba3f1262d46e973c9d"
        Tip       = "6f30f452644f6db80b451f89bb2e6c9922d9871a"
        Artifacts = @(
            "docs/CLI_REMOTE_TUI_INTEGRATION_VALIDATION.md",
            "tests/fixtures/codex-cli-remote-research/Invoke-RemoteResearch.ps1",
            "tests/fixtures/codex-cli-remote-research/RemoteResearchHarness.cs")
        Markers = @{
            "docs/CLI_REMOTE_TUI_INTEGRATION_VALIDATION.md" = "10.5"
            "tests/fixtures/codex-cli-remote-research/Invoke-RemoteResearch.ps1" = "AllowUnverifiedRunner"
            "tests/fixtures/codex-cli-remote-research/RemoteResearchHarness.cs" = "class JobProcess"
        }
    }
    # HS-1C (V1-10 / Router side of V1-12): Draft PR #88 quota-exhaustion sticky failover
    # rebuilt on main. Router.Configuration/Core/Execution/ThreadSelection plus tests and
    # the contract document only; no protected provider-adapter, installer or UI file changes.
    [pscustomobject]@{
        Name      = "HS1C-V1-INTEGRATION"
        Base      = "60a8eaf2b8f0d957670b1a1b1ba7a18a13ddc441"
        Tip       = "2e9c5b04ab80b4e79df9dca97cf552133c6fa96b"
        Artifacts = @(
            "docs/HS1C_QUOTA_EXHAUSTION_STICKY_FAILOVER.md",
            "local-router/src/Router.Execution/QuotaExhaustionClassifier.cs",
            "local-router/tests/Router.Execution.Tests/Hs1cQuotaFailoverAcceptanceTests.cs")
        Markers = @{
            "docs/HS1C_QUOTA_EXHAUSTION_STICKY_FAILOVER.md" = "quota_fallbacks_exhausted"
            "local-router/src/Router.Execution/QuotaExhaustionClassifier.cs" = "class QuotaExhaustionClassifier"
            "local-router/tests/Router.Execution.Tests/Hs1cQuotaFailoverAcceptanceTests.cs" = "All_fallbacks_exhausted_stops_with_explicit_bounded_failure"
        }
    }
    # CI timeout budget: main CI #332 reached the original
    # 20-minute development-gate limit. Timeout value only.
    [pscustomobject]@{
        Name      = "CI-DEV-GATE-TIMEOUT-35"
        Base      = "c0e80123b004022568d2b1681bd50403f68d3df4"
        Tip       = "4e9fbde3b443965ed25cc0c64f7ce120723bc268"
        Artifacts = @(".github/workflows/ci.yml")
        Markers   = @{
            ".github/workflows/ci.yml" = "timeout-minutes: 35"
        }
    }
    # HS-1C installer config compatibility: the installer Router bootstrap accepts,
    # validates and preserves local_router.thread_selection.quota_failover_enabled.
    # router-codex-cli.ps1 is authorized by a second exact pin; the earlier pin stays.
    [pscustomobject]@{
        Name      = "HS1C-INSTALLER-CONFIG-COMPAT"
        Base      = "072ac4ce96ceffeba82454c8d51d60113c9cf6f6"
        Tip       = "f78da418e3d0f49ba80bd58e5c6ea86edb4deb12"
        Artifacts = @(
            "installer/scripts/router-codex-cli.ps1",
            "tests/shared/protected-file-scope.ps1",
            "tests/validate-local-router-bootstrap.ps1",
            "tests/validate-local-router-hs1b-rb1-scope.ps1",
            "docs/HS1C_QUOTA_EXHAUSTION_STICKY_FAILOVER.md")
        Markers   = @{
            "installer/scripts/router-codex-cli.ps1" = "function Copy-RouterBootstrapQuotaFailoverSetting"
            "tests/shared/protected-file-scope.ps1" = "Hs1cInstallerApprovedRouterCliSha256"
            "tests/validate-local-router-bootstrap.ps1" = "HS1C-CFG E: quota_failover_enabled as"
            "tests/validate-local-router-hs1b-rb1-scope.ps1" = "the earlier reviewed DSR7-B-FIX1 router-codex-cli version is still authorized"
            "docs/HS1C_QUOTA_EXHAUSTION_STICKY_FAILOVER.md" = "HS1C-INSTALLER-CONFIG-COMPAT"
        }
    }
    # OSS-M1-FOUNDATION: open-source foundation on top of the sanitized import root.
    # Licence, community docs, .gitignore, pinned CI actions and the fail-closed
    # LR-14 genesis mode. No product, Provider, routing, installer or UI code.
    [pscustomobject]@{
        Name      = "OSS-M1-FOUNDATION"
        Base      = "22339958afb8fc4e3b4c3c4f5d496363bc2956d8"
        Tip       = "cdf252095bfb990d2c2529452067839dc67cee5a"
        Artifacts = @(
            ".github/workflows/ci.yml",
            ".gitignore",
            "CONTRIBUTING.md",
            "LICENSE",
            "README.md",
            "SECURITY.md",
            "docs/OSS_GENESIS.md",
            "tests/validate-local-router-lr14-scope.ps1",
            "tests/validate-oss-genesis.ps1",
            "tests/validate-repo.ps1")
        Markers   = @{
            ".github/workflows/ci.yml" = "persist-credentials: false"
            ".gitignore" = "# Codex / Router user configuration and local tool state"
            "CONTRIBUTING.md" = "Slice registration (LR-14 scope gate)"
            "LICENSE" = "Version 2.0, January 2004"
            "README.md" = "not affiliated with, endorsed by or sponsored by OpenAI"
            "SECURITY.md" = "Reporting a vulnerability"
            "docs/OSS_GENESIS.md" = "Open-source repository genesis"
            "tests/validate-local-router-lr14-scope.ps1" = "OSS-GENESIS: open-source repository root"
            "tests/validate-oss-genesis.ps1" = "OSS genesis validation PASSED"
            "tests/validate-repo.ps1" = "OSS genesis validation passed"
        }
    }
    # OSS-M1-README-ZH: Chinese open-source section of the README. Documentation only.
    [pscustomobject]@{
        Name      = "OSS-M1-README-ZH"
        Base      = "e6420d897a6becd7954d59a1f2f378696ea0ce80"
        Tip       = "776c0ab8529a4ab3330a6c582e0c5b5e79696ff6"
        Artifacts = @(
            "README.md")
        Markers   = @{
            "README.md" = "## 开源说明"
        }
    }
    # OSS-M1-FIX1: genesis evidence for the history-dependent FIX5 and HS1B-RB1
    # validators (fail-closed, verified genesis root only; private behaviour unchanged),
    # test-only third-party licences and pinned test clocks for the LR-10 metering
    # tests. Tests and docs only; no product, Provider, routing, installer or UI code.
    [pscustomobject]@{
        Name      = "OSS-M1-FIX1"
        Base      = "7673318d64cb76be7801827bef809cbdfca641f4"
        Tip       = "0344c0c292a2b31245d58295fd8cc6c3109019eb"
        Artifacts = @(
            "docs/OSS_GENESIS.md",
            "docs/THIRD_PARTY_LICENSES.md",
            "local-router/tests/Router.Core.Tests/Host/Lr10ProductionMeteringHostTests.cs",
            "local-router/tests/Router.Execution.Tests/Lr10RProductionExecutionMeteringE2ETests.cs",
            "tests/fixtures/oss-genesis/hs1b-rb1-earlier-router-codex-cli.patch",
            "tests/shared/fix5-patch-identity.ps1",
            "tests/shared/oss-genesis.ps1",
            "tests/validate-dsr7c-apply-patch-file-authorization-regression.ps1",
            "tests/validate-dsr7c-apply-patch-file-authorization.ps1",
            "tests/validate-dsr7c-apply-patch-final-integration.ps1",
            "tests/validate-local-router-hs1b-rb1-scope.ps1",
            "tests/validate-oss-genesis.ps1")
        Markers   = @{
            "docs/OSS_GENESIS.md" = "## Other history-dependent validators"
            "docs/THIRD_PARTY_LICENSES.md" = "# Third-party licences"
            "local-router/tests/Router.Core.Tests/Host/Lr10ProductionMeteringHostTests.cs" = "private sealed class PinnedTestClock"
            "local-router/tests/Router.Execution.Tests/Lr10RProductionExecutionMeteringE2ETests.cs" = "Price_older_than_the_freshness_window_is_reported_stale"
            "tests/fixtures/oss-genesis/hs1b-rb1-earlier-router-codex-cli.patch" = "index 62a2e6160becccf409dee176be661ef4950e9762..05664423e8fb111551acf7cc9621f1d54ec7cd92"
            "tests/shared/fix5-patch-identity.ps1" = "# --- OSS-GENESIS: FIX5 review evidence for the open-source history"
            "tests/shared/oss-genesis.ps1" = "function Get-OssGenesisRoot"
            "tests/validate-dsr7c-apply-patch-file-authorization-regression.ps1" = "# --- OSS-GENESIS regression"
            "tests/validate-dsr7c-apply-patch-file-authorization.ps1" = "OSS-GENESIS: the private FIX5 objects are not part of this history"
            "tests/validate-dsr7c-apply-patch-final-integration.ps1" = "OSS-GENESIS: the private FIX5 objects are not part of this history"
            "tests/validate-local-router-hs1b-rb1-scope.ps1" = "OSS-GENESIS: the earlier reviewed router-codex-cli blob"
            "tests/validate-oss-genesis.ps1" = "real_git_histories=7 mocks=0"
        }
    }
    # OSS-M1-FIX2: first public CI fix. The FIX5 regression's forged-root fixture
    # commit gets the explicit test identity and Get-GitLine fails fast on Git errors.
    # Test scaffolding only; no assertion, gate, product or installer change.
    [pscustomobject]@{
        Name      = "OSS-M1-FIX2"
        Base      = "2b99eeaeea67ade923799b2642928154a85e045d"
        Tip       = "5e8791fc43ed6e7701492017a5074fd189ed5195"
        Artifacts = @(
            "tests/validate-dsr7c-apply-patch-file-authorization-regression.ps1")
        Markers   = @{
            "tests/validate-dsr7c-apply-patch-file-authorization-regression.ps1" = "Git's error text is never passed on as an id"
        }
    }
    # OSS-M3-FIX3-CA2026: nine adapter test fixtures build their tool parameter schema with
    # JsonElement.Parse(string) instead of an undisposed JsonDocument (CA2026). Test code only;
    # no assertion, analyzer, warnings-as-errors, product or CI change.
    [pscustomobject]@{
        Name      = "OSS-M3-FIX3-CA2026"
        Base      = "e4e7b5ddf3f4bc9b6a1a6b2d186e8f1b8403e41f"
        Tip       = "d7160d911979bba3639c7d431b9c39f62fbb621a"
        Artifacts = @(
            "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekRequestMappingTests.cs",
            "local-router/tests/Router.ProviderAdapters.MiMo.Tests/MiMoRequestMappingTests.cs",
            "local-router/tests/Router.ProviderAdapters.ModelStudio.Tests/ModelStudioRequestMappingTests.cs",
            "local-router/tests/Router.ProviderAdapters.OpenAI.Tests/OpenAIRequestMappingTests.cs",
            "local-router/tests/Router.ProviderAdapters.OpenRouter.Tests/OpenRouterRequestMappingTests.cs",
            "local-router/tests/Router.ProviderAdapters.Tests/ResponsesProviderCodecTests.cs")
        Markers   = @{
            "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekRequestMappingTests.cs" = "Parameters = JsonElement.Parse(`"`"`"{`"type`":`"object`"}`"`"`"),"
            "local-router/tests/Router.ProviderAdapters.MiMo.Tests/MiMoRequestMappingTests.cs" = "Parameters = JsonElement.Parse(`"`"`"{`"type`":`"object`"}`"`"`"),"
            "local-router/tests/Router.ProviderAdapters.ModelStudio.Tests/ModelStudioRequestMappingTests.cs" = "Parameters = JsonElement.Parse(`"`"`"{`"type`":`"object`"}`"`"`"),"
            "local-router/tests/Router.ProviderAdapters.OpenAI.Tests/OpenAIRequestMappingTests.cs" = "Parameters = JsonElement.Parse(`"`"`"{`"type`":`"object`"}`"`"`"),"
            "local-router/tests/Router.ProviderAdapters.OpenRouter.Tests/OpenRouterRequestMappingTests.cs" = "Parameters = System.Text.Json.JsonElement.Parse(`"`"`"{`"type`":`"object`"}`"`"`"),"
            "local-router/tests/Router.ProviderAdapters.Tests/ResponsesProviderCodecTests.cs" = "JsonElement.Parse(parameterSchema)"
        }
    }
    # OSS-M3-FIX3-SDK-PIN: repository-root global.json identical to local-router/global.json
    # (10.0.400, rollForward disable) so dotnet commands run from the root resolve the pinned
    # SDK, and a fail-closed validate-repo check of the resolved SDK. No ci.yml, analyzer or test change.
    [pscustomobject]@{
        Name      = "OSS-M3-FIX3-SDK-PIN"
        Base      = "38797e2b20cd10f3621654b82112f9d37cb105a1"
        Tip       = "804b202a51b43b2d1c13ce423f8a739faf87cb19"
        Artifacts = @(
            "global.json",
            "tests/validate-repo.ps1")
        Markers   = @{
            "global.json" = "`"rollForward`": `"disable`""
            "tests/validate-repo.ps1" = "dotnet resolves the pinned .NET SDK"
        }
    }
    # OSS-M4-1-WORKFLOW-TOOLS: developer tools under tools/oss-workflow (tiered verification, receipts,
    # LR-14 registration candidates, identity privacy gate, evidence report) with their tests.
    # Tools only; no product, CI workflow, gate logic, registration, analyzer or Git config change.
    [pscustomobject]@{
        Name      = "OSS-M4-1-WORKFLOW-TOOLS"
        Base      = "c192c68069e8a8539c6fdbd4241e951dc4d34147"
        Tip       = "8902b9e700386c387a60b5c999b7df69aa0202f4"
        Artifacts = @(
            "tools/oss-workflow/approved-identities.json",
            "tools/oss-workflow/Invoke-TieredVerification.ps1",
            "tools/oss-workflow/New-EvidenceReport.ps1",
            "tools/oss-workflow/New-Lr14RegistrationCandidate.ps1",
            "tools/oss-workflow/OssWorkflow.psm1",
            "tools/oss-workflow/README.md",
            "tools/oss-workflow/Test-CommitIdentityPrivacy.ps1",
            "tools/oss-workflow/tests/Test-OssWorkflowTools.ps1")
        Markers   = @{
            "tools/oss-workflow/approved-identities.json" = "oss-workflow.approved-identities/v1"
            "tools/oss-workflow/Invoke-TieredVerification.ps1" = "Tiered local verification (L1-L4) with machine-readable receipts."
            "tools/oss-workflow/New-EvidenceReport.ps1" = "Builds a concise acceptance-evidence report (Markdown) from real Git state,"
            "tools/oss-workflow/New-Lr14RegistrationCandidate.ps1" = "Produces a CANDIDATE LR-14 slice registration for human review."
            "tools/oss-workflow/OssWorkflow.psm1" = "function Test-OwRegistrationOnlyChange"
            "tools/oss-workflow/README.md" = "# OSS workflow tools"
            "tools/oss-workflow/Test-CommitIdentityPrivacy.ps1" = "Read-only pre-push privacy gate for commit identities."
            "tools/oss-workflow/tests/Test-OssWorkflowTools.ps1" = "OSS workflow tools validation PASSED"
        }
    }
    # OSS-M4-1-RECEIPT-FAIL-LINES: receipts record explicit FAIL lines before diagnostic noise. Tools only.
    [pscustomobject]@{
        Name      = "OSS-M4-1-RECEIPT-FAIL-LINES"
        Base      = "52af5882e9a6beb6cb43c0b17616751dc413dfd9"
        Tip       = "fc828460a59ab915453034a2df7ab6ae4483052e"
        Artifacts = @(
            "tools/oss-workflow/Invoke-TieredVerification.ps1",
            "tools/oss-workflow/tests/Test-OssWorkflowTools.ps1")
        Markers   = @{
            "tools/oss-workflow/Invoke-TieredVerification.ps1" = "# Failure evidence: explicit FAIL lines first, then other error lines."
            "tools/oss-workflow/tests/Test-OssWorkflowTools.ps1" = "R8 the receipt records the explicit FAIL line before diagnostic noise"
        }
    }
    # OSS-M4-1-FIX1-REUSE-COVERAGE: receipt reuse re-checks identity live, level coverage, strict LR-14
    # append detection for the workflow tools. Tools only; no CI, gate logic or registration change.
    [pscustomobject]@{
        Name      = "OSS-M4-1-FIX1-REUSE-COVERAGE"
        Base      = "9605439ed770be42719d3f522742c8c1f5dd0680"
        Tip       = "8d5cf0608d11ac35e954fa3c4fd867904f3db1c2"
        Artifacts = @(
            "tools/oss-workflow/Invoke-TieredVerification.ps1",
            "tools/oss-workflow/OssWorkflow.psm1",
            "tools/oss-workflow/README.md",
            "tools/oss-workflow/tests/Test-OssWorkflowTools.ps1")
        Markers   = @{
            "tools/oss-workflow/Invoke-TieredVerification.ps1" = "# Identity privacy is always re-checked live; it is never taken from an old receipt."
            "tools/oss-workflow/OssWorkflow.psm1" = "function Test-OwStaticRegistrationStatement"
            "tools/oss-workflow/README.md" = "the identity privacy check is always re-run live"
            "tools/oss-workflow/tests/Test-OssWorkflowTools.ps1" = "U2 after the local identity changes, -ReuseReceipt fails"
        }
    }
    # OSS-M4-1-FIX2-L1-ONLY-REUSE: receipt reuse limited to L1 static checks, history kept, base/merge-base/tool
    # in the drift check for the workflow tools. Tools only; no CI, gate logic or registration change.
    [pscustomobject]@{
        Name      = "OSS-M4-1-FIX2-L1-ONLY-REUSE"
        Base      = "2a43101fe6596b13525d3673e89b6a71ffb75dd4"
        Tip       = "789405a795c57e96fb805661342da67caa65c992"
        Artifacts = @(
            "tools/oss-workflow/Invoke-TieredVerification.ps1",
            "tools/oss-workflow/New-EvidenceReport.ps1",
            "tools/oss-workflow/README.md",
            "tools/oss-workflow/tests/Test-OssWorkflowTools.ps1")
        Markers   = @{
            "tools/oss-workflow/Invoke-TieredVerification.ps1" = "# Runtime checks (L2/L3/L4) are always executed again. An identical earlier"
            "tools/oss-workflow/New-EvidenceReport.ps1" = "历史记录：存在相同的 {0} PASS 收据"
            "tools/oss-workflow/README.md" = "**Reuse applies to L1 static checks only.**"
            "tools/oss-workflow/tests/Test-OssWorkflowTools.ps1" = "N1 L2 with -ReuseReceipt executes every runtime check again"
        }
    }
    # OSS-M4-2-CI-AUTOMATION: additive Development Gate steps (commit identity privacy in commit-range mode,
    # model candidate intake, OSS workflow tools regression) and the read-only weekly mirror-drift workflow.
    # No existing step, trigger, pin, gate logic or registration changed.
    [pscustomobject]@{
        Name      = "OSS-M4-2-CI-AUTOMATION"
        Base      = "d3648a3f5f9b58fb8e28a6b8ce9770406055a67a"
        Tip       = "30f8895327e27266f5204e98836522dfcbac773a"
        Artifacts = @(
            ".github/workflows/ci.yml",
            ".github/workflows/mirror-drift.yml",
            "tools/oss-workflow/New-EvidenceReport.ps1",
            "tools/oss-workflow/OssWorkflow.psm1",
            "tools/oss-workflow/README.md",
            "tools/oss-workflow/Test-CommitIdentityPrivacy.ps1",
            "tools/oss-workflow/Test-MirrorParity.ps1",
            "tools/oss-workflow/tests/Test-OssWorkflowTools.ps1")
        Markers   = @{
            ".github/workflows/ci.yml" = "# OSS-M4-2: additive steps; every step above is unchanged."
            ".github/workflows/mirror-drift.yml" = "name: Weekly Mirror Drift"
            "tools/oss-workflow/New-EvidenceReport.ps1" = "# Redirected output (pipes, CI runners) is written as UTF-8 so the Chinese"
            "tools/oss-workflow/OssWorkflow.psm1" = "-CommitsOnly (CI commit-range mode) only the commits are checked; the local"
            "tools/oss-workflow/README.md" = "### In CI (Development Gate)"
            "tools/oss-workflow/Test-CommitIdentityPrivacy.ps1" = "CI commit-range mode (-CommitRangeFromGitHubEvent, explicit switch only):"
            "tools/oss-workflow/Test-MirrorParity.ps1" = "Read-only locator for drift between the installer and Skill copies that the"
            "tools/oss-workflow/tests/Test-OssWorkflowTools.ps1" = "P1 pull_request checks exactly base.sha..head.sha, never the synthetic merge commit"
        }
    }
    # OSS-M4-2-FIX1-LF-FIXTURES: the workflow-tool tests normalise their here-string fixtures to LF
    # (the runner checks the test file out with CRLF). Test scaffolding only.
    [pscustomobject]@{
        Name      = "OSS-M4-2-FIX1-LF-FIXTURES"
        Base      = "e7c861b06effe98823301214790861b35216ed3e"
        Tip       = "758cff1e4affc923c9d6330a074c1384778311f9"
        Artifacts = @(
            "tools/oss-workflow/tests/Test-OssWorkflowTools.ps1")
        Markers   = @{
            "tools/oss-workflow/tests/Test-OssWorkflowTools.ps1" = "# below is built and edited with LF, so the here-strings are normalised first."
        }
    }
    # OSS-M4-2-HOTFIX1-PRICING-CLOCK: the canonical-pricing Host tests run on the shared pinned test
    # clock and stop the Host in finally before deleting the sandbox. Test code only.
    [pscustomobject]@{
        Name      = "OSS-M4-2-HOTFIX1-PRICING-CLOCK"
        Base      = "8ec8ce9308f1522b3c942650475aa56e1d3ee3ee"
        Tip       = "5165cfbc34cc46340e373e627cab43ca4eddcf0c"
        Artifacts = @(
            "local-router/tests/Router.Core.Tests/Host/HostTestHarness.cs",
            "local-router/tests/Router.Core.Tests/Host/Lr10DefaultPricingHostTests.cs",
            "local-router/tests/Router.Core.Tests/Host/Lr10ProductionMeteringHostTests.cs",
            "local-router/tests/Router.Core.Tests/Host/Lr10ShutdownDrainRaceTests.cs",
            "local-router/tests/Router.Core.Tests/Host/PinnedTestClock.cs")
        Markers   = @{
            "local-router/tests/Router.Core.Tests/Host/HostTestHarness.cs" = "public static async Task StopHostAsync(CancellationTokenSource cts, Task<int>? runTask)"
            "local-router/tests/Router.Core.Tests/Host/Lr10DefaultPricingHostTests.cs" = "clock: new PinnedTestClock(HostTestHarness.CanonicalPricingNow),"
            "local-router/tests/Router.Core.Tests/Host/Lr10ProductionMeteringHostTests.cs" = "clock: new PinnedTestClock(PinnedNow),"
            "local-router/tests/Router.Core.Tests/Host/Lr10ShutdownDrainRaceTests.cs" = "await HostTestHarness.StopHostAsync(cts, runTask);"
            "local-router/tests/Router.Core.Tests/Host/PinnedTestClock.cs" = "internal sealed class PinnedTestClock : Router.Core.Abstractions.IClock"
        }
    }
)

$lr14SliceCommits = if ($script:OssGenesisMode) { @() } elseif ($script:SliceIdentityKnown) { @(Get-GitLines @("rev-list", "$($script:Lr14SliceBase)..$($script:Lr14SliceCommit)")) } else { @() }
$deltaCommits = @(Get-GitLines @("rev-list", "$($baseInfo.MergeBase)..$($script:ReviewedHeadRef)"))
# When the slice cannot be identified (for example a synthetic fixture), keep the
# historical fully-applicable behaviour instead of degrading to N/A.
$isLr14Slice = (-not $script:SliceIdentityKnown) -or (($deltaCommits.Count -gt 0) -and ((($deltaCommits | Sort-Object) -join ",") -eq (($lr14SliceCommits | Sort-Object) -join ",")))

if (-not $isLr14Slice) {
    Write-Host "N/A  LR-14 scope gate is NOT applicable to this delta." -ForegroundColor Yellow
    Write-Host "N/A  reason: the reviewed delta is not the LR-14 slice (its commits are not exactly $(Short $script:Lr14SliceBase)..$(Short $script:Lr14SliceCommit)); the current delta has $($deltaCommits.Count) commit(s). The gate therefore re-verifies the LR-14 slice's own file range and enforces the cross-slice registration rules below instead of judging other slices' files against the LR-14 allowlist." -ForegroundColor Yellow
    Write-Host "N/A  evidence: LR-14 slice = $(Short $script:Lr14SliceBase)..$(Short $script:Lr14SliceCommit) ($($lr14SliceCommits.Count) commit(s)); registered reviewed slices = $((@($script:RegisteredSlices | ForEach-Object { $_.Name })) -join ', ')" -ForegroundColor Yellow

    # 1. The LR-14 slice identity must still be intact and reachable.
    if ($script:OssGenesisMode) {
        Assert-True (@(Get-GitLines @("rev-list", "--max-parents=0", "HEAD")).Count -eq 1) "N/A 1 (OSS-GENESIS): the history has exactly one root commit"
        Assert-True (Test-GitAncestor $script:Lr14SliceCommit "HEAD") "N/A 1 (OSS-GENESIS): the verified genesis root is an ancestor of HEAD"
        Assert-True ($script:OssGenesisLr14Files.Count -eq 28) "N/A 1 (OSS-GENESIS): the historical LR-14 slice $($script:OssGenesisLr14Slice) is pinned with its 28 files"
    }
    else {
        $sliceBaseResolved = @(Get-GitLines @("rev-parse", "--verify", "--quiet", "$($script:Lr14SliceBase)^{commit}"))
        $sliceTipResolved = @(Get-GitLines @("rev-parse", "--verify", "--quiet", "$($script:Lr14SliceCommit)^{commit}"))
        Assert-True ($sliceBaseResolved.Count -gt 0 -and $sliceTipResolved.Count -gt 0) "N/A 1: the LR-14 slice commits are still present"
        Assert-True ($lr14SliceCommits.Count -eq 1) "N/A 1: the LR-14 slice is exactly one committed slice"
        Assert-True (Test-GitAncestor $script:Lr14SliceCommit "HEAD") "N/A 1: the LR-14 slice is still an ancestor of HEAD (historical evidence reachable)"
    }

    # 2. Every commit of the current delta must belong to a registered reviewed
    #    slice whose authority artifacts are present. Unregistered commits fail.
    $unregistered = New-Object System.Collections.Generic.List[string]
    # A gate-baseline commit is admitted only when its ENTIRE file set is inside
    # the declared gate files and all of them still exist. Anything else is
    # unregistered and fails closed.
    $script:GateFiles = @(
        "tests/validate-local-router-lr14-scope.ps1",
        "tests/validate-local-router-lr14-scope-regression.ps1",
        "tests/shared/protected-file-scope.ps1")
    foreach ($commit in $deltaCommits) {
        $covered = $false
        foreach ($slice in $script:RegisteredSlices) {
            # A slice only participates when its range resolves in this repository.
            $sliceTipResolved = @(Get-GitLines @("rev-parse", "--verify", "--quiet", "$($slice.Tip)^{commit}"))
            if ($sliceTipResolved.Count -eq 0) { continue }
            $sliceCommits = @(Get-GitLines @("rev-list", "$($slice.Base)..$($slice.Tip)"))
            if (-not ($sliceCommits -contains $commit)) { continue }
            $missingArtifact = $null
            foreach ($artifact in $slice.Artifacts) {
                if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $artifact) -PathType Leaf)) { $missingArtifact = $artifact; break }
            }
            if ($null -ne $missingArtifact) { continue }
            $missingMarker = $null
            foreach ($markerFile in $slice.Markers.Keys) {
                $markerPath = Join-Path $RepositoryRoot $markerFile
                if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or -not (Get-Content -Raw -LiteralPath $markerPath).Contains($slice.Markers[$markerFile])) { $missingMarker = $markerFile; break }
            }
            if ($null -ne $missingMarker) { continue }
            $covered = $true
            break
        }
        if (-not $covered) {
            $commitFiles = @(Get-GitLines @("diff", "--name-only", "--no-renames", "$commit^", $commit))
            $outsideGate = @($commitFiles | Where-Object { $_ -notin $script:GateFiles })
            $gateFilesPresent = -not (@($script:GateFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $_) -PathType Leaf) }).Count -gt 0)
            if ($commitFiles.Count -gt 0 -and $outsideGate.Count -eq 0 -and $gateFilesPresent) { $covered = $true }
        }
        if (-not $covered) { $unregistered.Add((Short $commit)) }
    }
    if ($unregistered.Count -eq 0) {
        Pass "N/A 2: every commit of this delta belongs to a registered reviewed slice with intact authority artifacts"
    }
    else {
        foreach ($commit in $unregistered) { Fail "N/A 2: commit $commit is not covered by any registered reviewed slice (unauthorized change)" }
    }

    # 3. The LR-14 slice's own files must still exist (a deletion is a change).
    $lr14Files = if ($script:OssGenesisMode) { @($script:OssGenesisLr14Files | Sort-Object -Unique) } else { @(Get-GitLines @("diff", "--name-only", "--no-renames", $script:Lr14SliceBase, $script:Lr14SliceCommit) | Sort-Object -Unique) }
    $deletedLr14Files = @($lr14Files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $_) -PathType Leaf) })
    if ($deletedLr14Files.Count -eq 0) {
        Pass "N/A 3: no file owned by the LR-14 slice has been deleted"
    }
    else {
        foreach ($file in $deletedLr14Files) { Fail "N/A 3: LR-14 owned file is missing: $file" }
    }

    # 4. Re-point the review at the immutable LR-14 slice: the checks below now
    #    verify the historical slice evidence (never another slice's diff).
    $changed = $lr14Files
    Write-Host "N/A  re-verifying the immutable LR-14 slice range $(Short $script:Lr14SliceBase)..$(Short $script:Lr14SliceCommit): $($changed.Count) file(s)" -ForegroundColor Cyan
}

# LR-14 V4 UI is a presentation/integration slice: it may only touch the V4
# presentation files, its own validators/fixtures/docs, the CI wiring, and the
# delta-exact protected-file authorization hook that every other slice already
# uses. It must not add any Router backend surface.
$allowedExact = @(
    "installer/ui/visual-console.xaml",
    "installer/scripts/visual-console.ps1",
    "installer/scripts/visual-console-entry.ps1",
    "installer/scripts/visual-router-runtime.ps1",
    "tests/validate-local-router-v4-ui.ps1",
    "tests/validate-local-router-lr14-scope.ps1",
    "tests/validate-local-router-lr14-scope-regression.ps1",
    "tests/shared/protected-file-scope.ps1",
    "docs/LOCAL_ROUTER_V4_UI.md",
    ".github/workflows/ci.yml",
    # Delta-exact protected-file authorization for the LR-14 approved V4 files.
    # These four validators gained the shared fail-closed hook only; no assertion
    # was weakened (the hook is hash-exact and reverts to a hard failure for any
    # unreviewed change).
    "tests/validate-local-router-ingress.ps1",
    "tests/validate-local-router-registries.ps1",
    "tests/validate-local-router-lr14p-control-plane.ps1",
    "tests/validate-local-router-metering-remediation.ps1"
)
$allowedPrefix = @(
    "tests/fixtures/local-router/v4-ui/"
)

$blocked = @()
foreach ($file in $changed) {
    $ok = $file -in $allowedExact
    if (-not $ok) {
        foreach ($prefix in $allowedPrefix) {
            if ($file.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $ok = $true; break }
        }
    }
    if (-not $ok) { $blocked += $file }
}

if ($blocked.Count -eq 0) {
    Pass "LR-14 diff stays inside V4 presentation/integration/tests/fixtures/docs/CI"
}
else {
    foreach ($file in $blocked) { Fail "LR-14 out-of-scope file changed: $file" }
}

# The LR-14 UI consumes the LR-14P Control Plane; it never evolves the legacy
# status contract and never modifies Router backend code.
$backendRoots = @(
    "local-router/src/",
    "local-router/schemas/",
    "local-router/tests/"
)
$backendHits = @($changed | Where-Object {
        $candidate = $_
        $hit = $false
        foreach ($prefix in $backendRoots) {
            if ($candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $hit = $true; break }
        }
        return $hit
    })
if ($backendHits.Count -eq 0) {
    Pass "No Router backend / schema / backend-test file modified (Control Plane unchanged)"
}
else {
    foreach ($file in $backendHits) { Fail "Protected Router backend file modified: $file" }
}

# Explicitly protected files that must never be touched by this slice.
$protectedExact = @(
    "installer/scripts/launch-controller-model.ps1",
    "skill/codex-multimodel-manager/scripts/launch-controller-model.ps1",
    "installer/scripts/router-codex-cli.ps1",
    "installer/scripts/desktop-router-route.ps1",
    "installer/scripts/desktop-chat-route.ps1",
    "installer/model-catalog.json",
    "docs/LOCAL_ROUTER_LR14P_CONTROL_PLANE.md",
    "docs/LOCAL_ROUTER_RUNTIME_CONTRACTS.md",
    "tests/validate-local-router-status-contract.ps1"
)
$protectedHits = @($changed | Where-Object { $_ -in $protectedExact })
if ($protectedHits.Count -eq 0) {
    Pass "No protected Direct/Desktop/catalog/control-plane-contract file modified"
}
else {
    foreach ($file in $protectedHits) { Fail "Protected file modified by LR-14: $file" }
}

# The legacy /v1/router/status contract must be byte-identical to the base.
$statusContractFiles = @(
    "local-router/schemas/router-status.v1.schema.json",
    "local-router/src/Router.Ingress/Handlers/StatusHandler.cs",
    "local-router/src/Router.Ingress/ControlPlane/RouterStatusSections.cs",
    "local-router/tests/Router.Ingress.Tests/StatusContractEvolutionTests.cs",
    "local-router/tests/Router.Execution.Tests/ControlPlaneProductionE2ETests.cs"
)
foreach ($file in $statusContractFiles) {
    $inDiff = @($changed | Where-Object { $_ -eq $file }).Count -gt 0
    if ($inDiff) {
        Fail "Legacy status/Control Plane contract file touched by LR-14: $file"
    }
}
if (-not ($statusContractFiles | Where-Object { $_ -in $changed })) {
    Pass "Legacy /v1/router/status expansion is fully reverted (backend untouched)"
}

# The UI runtime must not resurrect the removed expansion helpers.
$runtimePath = Join-Path $RepositoryRoot "installer/scripts/visual-router-runtime.ps1"
if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
    $runtime = Get-Content -Raw -LiteralPath $runtimePath -Encoding UTF8
    $forbidden = @(
        "/v1/router/status",
        "RouterStatusSections",
        "UsageAvailable = `$false",
        "CostAvailable = `$false",
        "RecentRequestsAvailable = `$false"
    )
    $found = @()
    foreach ($marker in $forbidden) {
        if ($runtime.Contains($marker)) { $found += $marker }
    }
    if ($found.Count -eq 0) {
        Pass "V4 runtime contains no legacy status expansion marker"
    }
    else {
        foreach ($marker in $found) { Fail "V4 runtime still contains legacy status expansion marker: $marker" }
    }
}
else {
    Fail "LR-14 runtime file is missing: installer/scripts/visual-router-runtime.ps1"
}

# Existing V4 validators must not be weakened by this slice.
$v4Validators = @(
    "tests/validate-visual-console.ps1",
    "tests/validate-visual-console-entrypoint.ps1",
    "tests/validate-model-hierarchy.ps1",
    "tests/validate-model-card-grouping.ps1",
    "tests/validate-v4-crash-diagnostics.ps1",
    "tests/validate-commercial-ui-polish.ps1",
    "tests/validate-motion-design-system.ps1",
    "tests/validate-v4-single-desktop-controls.ps1",
    "tests/validate-visual-console-shortcuts.ps1",
    "tests/validate-windows-taskbar-metadata.ps1",
    "tests/validate-desktop-dynamic-route-ui.ps1"
)
$weakened = @($changed | Where-Object { $_ -in $v4Validators })
if ($weakened.Count -eq 0) {
    Pass "Existing V4 validators are untouched (no weakened assertions)"
}
else {
    foreach ($file in $weakened) { Fail "Existing V4 validator modified: $file" }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "LR-14 scope validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}
Write-Host "LR-14 scope validation PASSED" -ForegroundColor Green
exit 0
