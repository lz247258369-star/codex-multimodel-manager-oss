param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# HS1B-RB1 scope policy - "Local Router bootstrap gate".
#
# This gate adds the Initialize bootstrap to installer/scripts/router-codex-cli.ps1.
# That file is protected by the earlier Local Router slices, so the change is
# authorized only through the shared delta-exact hook:
#
#   * the module must match an approved normalized SHA-256, and
#   * the reviewed structural markers of the bootstrap delta must still be
#     present in that same file, and
#   * this scope validator must exist, so deleting the review revokes the
#     authorization instead of silently widening it.
#
# A string-presence check alone is never sufficient, and every other change to
# router-codex-cli.ps1 fails the gate until a new delta is reviewed.
#
# HS1B-RB1-FIX1 (same gate, reviewed follow-up delta): the Doctor bootstrap
# ladder counted the route projections with @($routeConfig.X).Count, which
# reports 1 for $null and therefore printed a fabricated 1/1/1 for a config with
# no routes at all. The counts now go through one null-safe helper. The reviewed
# delta is reporting-only, and the regression coverage for it is part of the
# boundaries this validator keeps pinned below.
#
# DSR7-B-FIX1 (same gate, reviewed follow-up delta): the bootstrap generates a
# dedicated control-plane client (own client id and auth scope, registered
# additively next to the execution client) plus a guard that refuses to generate
# two clients with the same auth scope. The new client owns no model route and
# receives no second credential. The markers of that reviewed delta are asserted
# below, and a mutation proof shows the constraints are not vacuous.
#
# HS1C-INSTALLER-CONFIG-COMPAT (same gate, second independent pin): the bootstrap
# accepts, validates and preserves the optional HS-1C setting
# local_router.thread_selection.quota_failover_enabled. The DSR7-B-FIX1 pin is
# kept; the HS-1C version is authorized by its own exact hash plus its reviewed
# markers, and the proofs below show that the earlier version stays authorized,
# that any further change on top of the HS-1C version is rejected, and that no
# other protected file gains an approval.

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

. (Join-Path $RepositoryRoot "tests/shared/protected-file-scope.ps1")

$modulePath = Join-Path $RepositoryRoot "installer/scripts/router-codex-cli.ps1"
$bootstrapValidator = Join-Path $RepositoryRoot "tests/validate-local-router-bootstrap.ps1"
$ciWorkflow = Join-Path $RepositoryRoot ".github/workflows/ci.yml"
$fixtureRoot = Join-Path $RepositoryRoot "tests/fixtures/local-router/v1/bootstrap"
$acceptanceTest = Join-Path $RepositoryRoot "local-router/tests/Router.Core.Tests/Configuration/BootstrapConfigFixtureTests.cs"
$selfPath = Join-Path $RepositoryRoot "tests/validate-local-router-hs1b-rb1-scope.ps1"

$requiredFiles = [ordered]@{
    $modulePath = "router-codex-cli.ps1"
    $bootstrapValidator = "tests/validate-local-router-bootstrap.ps1"
    $selfPath = "tests/validate-local-router-hs1b-rb1-scope.ps1"
    $ciWorkflow = ".github/workflows/ci.yml"
    $acceptanceTest = "local-router/tests/Router.Core.Tests/Configuration/BootstrapConfigFixtureTests.cs"
    (Join-Path $fixtureRoot "router-config.expected.json") = "tests/fixtures/local-router/v1/bootstrap/router-config.expected.json"
    (Join-Path $fixtureRoot "approved-models.fixture.json") = "tests/fixtures/local-router/v1/bootstrap/approved-models.fixture.json"
    (Join-Path $fixtureRoot "env.references.json") = "tests/fixtures/local-router/v1/bootstrap/env.references.json"
}
foreach ($entry in $requiredFiles.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Key -PathType Leaf)) {
        Fail "Missing HS1B-RB1 artifact: $($entry.Value)"
    }
}

# --- Delta-exact authorization of the protected module -----------------------
$scopeErrors = @(Get-RouterCliScopeErrors $RepositoryRoot)
if ($scopeErrors.Count -eq 0) {
    Pass "router-codex-cli.ps1 matches the approved HS1B-RB1 bootstrap delta (golden normalized sha256)"
}
else {
    foreach ($scopeError in $scopeErrors) { Fail "HS1B-RB1 scope: $scopeError" }
}

$authorized = Test-Lr13ProtectedFileChangeAuthorized $RepositoryRoot "installer/scripts/router-codex-cli.ps1"
if ($authorized) {
    Pass "Protected-file policy authorizes the exact approved HS1B-RB1 router-codex-cli delta"
}
else {
    Fail "Protected-file policy rejected the approved HS1B-RB1 router-codex-cli delta"
}

# --- DSR7-B-FIX1 reviewed delta markers --------------------------------------
# The re-pinned hash above is only justified while the reviewed control-plane
# additions are still present and still additive. The helper is reused by the
# mutation proof below so the constraints cannot silently become vacuous.
function Get-ControlPlaneDeltaErrors([string]$Text) {
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $Text.Contains('$script:Lr12ControlPlaneClientId = "client.control_plane"')) { $errors.Add("missing control-plane client id") }
    if (-not $Text.Contains('$script:Lr12ControlPlaneClientAuthScope = "router:control-plane"')) { $errors.Add("missing control-plane auth scope") }
    if (-not $Text.Contains('function New-RouterBootstrapControlPlaneClientEntry')) { $errors.Add("missing control-plane client entry builder") }
    if (-not $Text.Contains('$clients.Add((New-RouterBootstrapControlPlaneClientEntry))')) { $errors.Add("control-plane client is not registered additively") }
    if (-not $Text.Contains('Router bootstrap would generate duplicate client auth scopes.')) { $errors.Add("missing duplicate auth-scope guard") }

    $entry = [regex]::Match($Text, "(?ms)function New-RouterBootstrapControlPlaneClientEntry.*?\r?\n\}")
    if (-not $entry.Success) {
        $errors.Add("control-plane client entry builder is not delimited")
    }
    else {
        # Field names only: "Router" itself must not be mistaken for route ownership.
        if ($entry.Value -match '(?i)\b(route_id|routes|allowed_route_ids|model_route_id|provider_route_id|protocol_route_id)\b') { $errors.Add("control-plane client entry declares route ownership") }
        if ($entry.Value -match '(?i)\b(token|secret|env_key|bearer|api_key)\b') { $errors.Add("control-plane client entry declares a credential") }
    }
    return $errors.ToArray()
}

$controlPlaneErrors = @(Get-ControlPlaneDeltaErrors (Get-Content -Raw -LiteralPath $modulePath))
if ($controlPlaneErrors.Count -eq 0) {
    Pass "DSR7-B-FIX1: the reviewed control-plane delta markers are present and additive"
}
else {
    foreach ($controlPlaneError in $controlPlaneErrors) { Fail "DSR7-B-FIX1 delta: $controlPlaneError" }
}

# --- HS1C-INSTALLER-CONFIG-COMPAT: second, independent exact pin -------------
# The earlier DSR7-B-FIX1 pin must stay approved and unchanged; the new pin is a
# separate exact hash for the reviewed HS-1C installer version, and that
# version must carry the reviewed HS-1C markers.
if ($script:Hs1bRb1ApprovedRouterCliSha256 -eq "95c9f82c3e2e0ea29fe8560b3ca7b1e0114ec705130fd068b889d3b1079c9468") {
    Pass "HS1C-INSTALLER: the earlier DSR7-B-FIX1 router-codex-cli pin is kept unchanged"
}
else {
    Fail "HS1C-INSTALLER: the earlier DSR7-B-FIX1 router-codex-cli pin was changed or removed"
}
if ($script:Hs1cInstallerApprovedRouterCliSha256 -match '^[0-9a-f]{64}$' -and $script:Hs1cInstallerApprovedRouterCliSha256 -ne $script:Hs1bRb1ApprovedRouterCliSha256) {
    Pass "HS1C-INSTALLER: the HS-1C pin is a separate full-length exact SHA-256"
}
else {
    Fail "HS1C-INSTALLER: the HS-1C pin is not a separate full-length exact SHA-256"
}
if ((Get-NormalizedFileSha256 $modulePath) -eq $script:Hs1cInstallerApprovedRouterCliSha256) {
    Pass "HS1C-INSTALLER: router-codex-cli.ps1 is exactly the reviewed HS-1C installer version"
}
else {
    Fail "HS1C-INSTALLER: router-codex-cli.ps1 is not the reviewed HS-1C installer version"
}
$hs1cDeltaErrors = @(Get-RouterCliHs1cInstallerDeltaErrors (Get-Content -Raw -LiteralPath $modulePath))
if ($hs1cDeltaErrors.Count -eq 0) {
    Pass "HS1C-INSTALLER: the reviewed quota_failover_enabled installer markers are present"
}
else {
    foreach ($hs1cDeltaError in $hs1cDeltaErrors) { Fail "HS1C-INSTALLER delta: $hs1cDeltaError" }
}

# Raw git blob bytes (no PowerShell re-encoding) for the earlier-version proof.
function Save-GitBlob([string]$Spec, [string]$Destination) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new("git")
    foreach ($argument in @("-C", $RepositoryRoot, "cat-file", "blob", $Spec)) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stream = [System.IO.File]::Create($Destination)
    try { $process.StandardOutput.BaseStream.CopyTo($stream) } finally { $stream.Dispose() }
    [void]$process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return ($process.ExitCode -eq 0)
}

# --- Fail-closed proofs ------------------------------------------------------
# Every scenario runs against a throw-away directory tree in the system temp
# folder. The repository under test is read, never modified.
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("hs1b-rb1-scope-" + [guid]::NewGuid().ToString("N"))
try {
    $tempModuleDir = Join-Path $tempRoot "installer/scripts"
    New-Item -ItemType Directory -Force -Path $tempModuleDir | Out-Null
    $tempModule = Join-Path $tempModuleDir "router-codex-cli.ps1"
    Copy-Item -LiteralPath $modulePath -Destination $tempModule

    # 1. Without the scope validator the authorization must be revoked.
    if (-not (Test-Lr13ProtectedFileChangeAuthorized $tempRoot "installer/scripts/router-codex-cli.ps1")) {
        Pass "Deleting tests/validate-local-router-hs1b-rb1-scope.ps1 revokes the authorization (fail closed)"
    }
    else {
        Fail "Missing HS1B-RB1 scope validator still authorized the router-codex-cli delta"
    }

    # 2. With the scope validator present and the module unchanged the
    #    authorization holds, so the pin is file-exact rather than repo-bound.
    $tempValidatorDir = Join-Path $tempRoot "tests"
    New-Item -ItemType Directory -Force -Path $tempValidatorDir | Out-Null
    Copy-Item -LiteralPath $selfPath -Destination (Join-Path $tempValidatorDir "validate-local-router-hs1b-rb1-scope.ps1")
    if (Test-Lr13ProtectedFileChangeAuthorized $tempRoot "installer/scripts/router-codex-cli.ps1") {
        Pass "The approved HS1B-RB1 delta is authorized once its scope validator is present"
    }
    else {
        Fail "The approved HS1B-RB1 delta was rejected although the scope validator is present"
    }

    # 3. A future unauthorized mutation anywhere in the module must fail.
    $original = Get-Content -Raw -LiteralPath $modulePath
    [System.IO.File]::WriteAllText(
        $tempModule,
        ($original + "`n# UNAUTHORIZED HS1B-RB1 MUTATION MARKER`n"),
        [System.Text.UTF8Encoding]::new($false))
    if (-not (Test-Lr13ProtectedFileChangeAuthorized $tempRoot "installer/scripts/router-codex-cli.ps1")) {
        Pass "An unauthorized future router-codex-cli mutation fails the HS1B-RB1 scope gate"
    }
    else {
        Fail "An unauthorized future router-codex-cli mutation was not detected"
    }
    if (@(Get-RouterCliScopeErrors $tempRoot $tempModule).Count -gt 0) {
        Pass "The mutated module is rejected with an explicit scope error"
    }
    else {
        Fail "The mutated module produced no scope error"
    }

    # 4. The DSR7-B-FIX1 content constraints must not be vacuous: a copy without
    #    the reviewed duplicate auth-scope guard has to be reported.
    $noGuardText = $original.Replace('Router bootstrap would generate duplicate client auth scopes.', 'duplicate scope check disabled')
    if (@(Get-ControlPlaneDeltaErrors $noGuardText).Count -gt 0) {
        Pass "The DSR7-B-FIX1 content constraints reject a module without the duplicate auth-scope guard"
    }
    else {
        Fail "The DSR7-B-FIX1 content constraints accepted a module without the duplicate auth-scope guard"
    }

    # 5. HS1C-INSTALLER: a one-token change inside the reviewed HS-1C delta (the
    #    strict boolean check weakened) is neither authorized nor scope-clean,
    #    and the HS-1C marker constraints themselves are not vacuous.
    $weakenedText = $original.Replace('if (-not (Test-RouterBootstrapBoolean $quotaFailover)) {', 'if ($null -eq $quotaFailover) {')
    if ($weakenedText -ne $original) {
        [System.IO.File]::WriteAllText($tempModule, $weakenedText, [System.Text.UTF8Encoding]::new($false))
        if (-not (Test-Lr13ProtectedFileChangeAuthorized $tempRoot "installer/scripts/router-codex-cli.ps1")) {
            Pass "HS1C-INSTALLER: a weakened boolean check on top of the HS-1C version is not authorized"
        }
        else {
            Fail "HS1C-INSTALLER: a weakened boolean check on top of the HS-1C version was authorized"
        }
        if (@(Get-RouterCliScopeErrors $tempRoot $tempModule).Count -gt 0) {
            Pass "HS1C-INSTALLER: the weakened module is rejected with an explicit scope error"
        }
        else {
            Fail "HS1C-INSTALLER: the weakened module produced no scope error"
        }
    }
    else {
        Fail "HS1C-INSTALLER: the strict boolean check to mutate was not found in the module"
    }
    $noCopyHelperText = $original.Replace('function Copy-RouterBootstrapQuotaFailoverSetting(', 'function Skip-RouterBootstrapQuotaFailoverSetting(')
    if ($noCopyHelperText -ne $original -and
        @(Get-RouterCliHs1cInstallerDeltaErrors $noCopyHelperText).Count -gt 0 -and
        @(Get-RouterCliHs1cInstallerDeltaErrors ($original + "`n# quota_failover_enabled = `$true`n")).Count -gt 0) {
        Pass "HS1C-INSTALLER: the HS-1C content constraints reject a missing copy helper and any self-enabling assignment"
    }
    else {
        Fail "HS1C-INSTALLER: the HS-1C content constraints are vacuous"
    }

    # 6. The earlier reviewed version (main before HS-1C) stays authorized by
    #    its own unchanged pin, so the HS-1C pin added an approval, not a swap.
    $earlierSpec = "072ac4ce96ceffeba82454c8d51d60113c9cf6f6:installer/scripts/router-codex-cli.ps1"
    if (Save-GitBlob $earlierSpec $tempModule) {
        if ((Get-NormalizedFileSha256 $tempModule) -eq $script:Hs1bRb1ApprovedRouterCliSha256 -and
            (Test-Lr13ProtectedFileChangeAuthorized $tempRoot "installer/scripts/router-codex-cli.ps1")) {
            Pass "HS1C-INSTALLER: the earlier reviewed DSR7-B-FIX1 router-codex-cli version is still authorized by its own pin"
        }
        else {
            Fail "HS1C-INSTALLER: the earlier reviewed DSR7-B-FIX1 router-codex-cli version is no longer authorized"
        }
    }
    else {
        Fail "HS1C-INSTALLER: the earlier reviewed router-codex-cli blob is not available (fetch-depth 0 required)"
    }

    # 7. The HS-1C pin widens no other protected file.
    if (-not (Test-Lr13ProtectedFileChangeAuthorized $RepositoryRoot "installer/scripts/switch-model.ps1") -and
        -not (Test-Lr13ProtectedFileChangeAuthorized $RepositoryRoot "installer/scripts/launch-controller-model.ps1")) {
        Pass "HS1C-INSTALLER: the HS-1C pin does not authorize any other protected file"
    }
    else {
        Fail "HS1C-INSTALLER: the HS-1C pin widened the protected-file policy"
    }
}
finally {
    $tempBase = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
    if ($tempRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $tempRoot).StartsWith("hs1b-rb1-scope-", [System.StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- The gate must stay wired and its acceptance must stay honest ------------
$ciText = Get-Content -Raw -LiteralPath $ciWorkflow
if ($ciText.Contains("./tests/validate-local-router-bootstrap.ps1")) {
    Pass "CI runs tests/validate-local-router-bootstrap.ps1"
}
else {
    Fail "CI does not run tests/validate-local-router-bootstrap.ps1"
}
if ($ciText.Contains("./tests/validate-local-router-hs1b-rb1-scope.ps1")) {
    Pass "CI runs tests/validate-local-router-hs1b-rb1-scope.ps1"
}
else {
    Fail "CI does not run tests/validate-local-router-hs1b-rb1-scope.ps1"
}

$bootstrapText = Get-Content -Raw -LiteralPath $bootstrapValidator
$requiredAssertions = [ordered]@{
    "Get-RouterBootstrapComparableJson" = "the golden-fixture canonical comparison"
    "Golden: generated bootstrap config equals" = "the golden fixture acceptance"
    "the token value appears in no file under CODEX_HOME" = "the secret non-disclosure sweep"
    "the direct DeepSeek provider route is generated from its own approval" = "the DSR2 direct DeepSeek bootstrap route"
    "CLIENT_MODEL_SLUG_COLLISION" = "the DSR2 single-active-client-slug ownership gate"
    "no mm_openai_api provider route is fabricated" = "the honest OpenAI API capability gap"
    "an unapproved canonical model gets no route" = "the approved-model boundary"
    "a client slug claimed by two enabled routes fails closed" = "the client-slug ownership boundary"
    "a provider without its upstream secret reference gets no provider route" = "the missing-secret-reference boundary"
    # HS1B-RB1-FIX1 regression coverage for the null-safe route count projection.
    "FIX1 A: JSON null route arrays project as 0/0/0" = "the null route array count"
    "FIX1 B: empty route arrays project as 0/0/0" = "the empty route array count"
    "FIX1 D: multiple entities project the exact count" = "the exact multi-entity route count"
    "FIX1 E: Doctor no longer prints a fabricated provider route count" = "the no-approval Doctor count regression"
    # HS1C-INSTALLER-CONFIG-COMPAT regression coverage for quota_failover_enabled.
    "HS1C-CFG: a fresh Initialize never adds quota_failover_enabled" = "the HS-1C default-off Initialize"
    "HS1C-CFG A: a legacy config without quota_failover_enabled stays without it" = "the HS-1C legacy-config compatibility"
    "HS1C-CFG B: explicit quota_failover_enabled=false is preserved as false" = "the HS-1C explicit false"
    "HS1C-CFG C: re-Initialize leaves the HS-1C config bytes unchanged" = "the HS-1C re-Initialize idempotency"
    "HS1C-CFG D: quota_failover_enabled=true survives a real rewrite of a full config" = "the HS-1C preservation on rewrite"
    'the string "true"' = "the HS-1C string-value rejection"
    "config bytes are untouched after rejecting" = "the HS-1C no-partial-write guarantee"
}
$missingAssertions = @()
foreach ($assertion in $requiredAssertions.GetEnumerator()) {
    if (-not $bootstrapText.Contains($assertion.Key)) { $missingAssertions += $assertion.Value }
}
if ($missingAssertions.Count -eq 0) {
    Pass "The bootstrap validator still asserts the reviewed HS1B-RB1 boundaries ($($requiredAssertions.Count))"
}
else {
    foreach ($missing in $missingAssertions) {
        Fail "The bootstrap validator no longer asserts $missing"
    }
}

$acceptanceText = Get-Content -Raw -LiteralPath $acceptanceTest
if ($acceptanceText.Contains("LoadGoldenAsync") -and $acceptanceText.Contains("RouterExecutionApprovedModelValidator")) {
    Pass "The schema-v1 acceptance test still loads the golden fixture through Router.Configuration"
}
else {
    Fail "The bootstrap acceptance test no longer loads the golden fixture through Router.Configuration"
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "HS1B-RB1 scope validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}
Write-Host "HS1B-RB1 scope validation PASSED" -ForegroundColor Green
exit 0
