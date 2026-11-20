#Requires -Version 7.2
<#
.SYNOPSIS
  Tiered local verification (L1-L4) with machine-readable receipts.

.DESCRIPTION
  Classifies the real change set (merge base with -BaseRef .. working tree)
  and runs the matching level:

    L1  fast static checks: git diff --check, PowerShell and JSON parsing of
        changed files, commit identity privacy.
    L2  L1 + build and tests of the affected .NET projects (from the real
        project-reference graph), validators that reference the changed paths,
        the workflow-tool tests when the tools change, and the LR-14 gate.
    L3  L1 + every step of .github/workflows/ci.yml, run locally.
    L4  L3, only on a clean checkout of the -BaseRef tip (main / release).

  The policy sets a minimum level for the change; a lower -Level is refused.
  Unknown paths and cross-module changes require L3. L1/L2 results are partial
  and L3/L4 results are local reproductions: no local receipt is a GitHub CI
  result, and GitHub CI stays required.

  Receipts are written under <git dir>/oss-workflow/receipts. -ReuseReceipt
  reuses an earlier PASS receipt only when its key (commit, tree, uncommitted
  changes, base, environment, tool version, level and planned checks) is
  identical and its self-hash is intact.

  Exit codes: 0 PASS (or -PlanOnly), 1 FAIL, 2 tool error, 3 BLOCKED or
  INCOMPLETE (a check was skipped or could not run; never a PASS).
#>
param(
    [string]$RepositoryRoot = (Get-Location).Path,
    [ValidateSet('auto', 'L1', 'L2', 'L3', 'L4')][string]$Level = 'auto',
    [string]$BaseRef = 'origin/main',
    [switch]$PlanOnly,
    [switch]$ReuseReceipt,
    [string]$ReceiptDirectory
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OssWorkflow.psm1') -Force
$started = [DateTime]::UtcNow

# Failure evidence: explicit FAIL lines first, then other error lines.
function Get-Tail([string[]]$Lines, [string]$Root, [int]$Count = 3) {
    $fail = @($Lines | Where-Object { $_ -match '^\s*FAIL\b' })
    $other = @($Lines | Where-Object { $_ -notmatch '^\s*FAIL\b' -and $_ -match '(?i)\berror\b|failed' })
    return @(@($fail) + @($other) | Select-Object -First $Count | ForEach-Object { ConvertTo-OwSafeText ($_.Trim()) $Root })
}

function New-Check([string]$Id, [string]$Kind, [string]$Command, [scriptblock]$Action, [string]$Condition = $null) {
    return [ordered]@{ id = $Id; kind = $Kind; command = $Command; condition = $Condition; action = $Action }
}

function New-ValidatorCheck([string]$Root, [string]$Script, [string]$Prefix) {
    return (New-Check "${Prefix}:validator:$([IO.Path]::GetFileNameWithoutExtension($Script))" 'validator' "pwsh -File $Script -RepositoryRoot <repo>" {
            if (-not (Test-Path -LiteralPath (Join-Path $Root $Script) -PathType Leaf)) { return [ordered]@{ status = 'BLOCKED'; exit_code = $null; summary = 'validator file is missing'; failures = @() } }
            $r = Invoke-OwPwshFile $Root (Join-Path $Root $Script) @('-RepositoryRoot', $Root)
            $p = @($r.Lines | Where-Object { $_ -match '^\s*PASS\s' }).Count; $f = @($r.Lines | Where-Object { $_ -match '^\s*FAIL\s' }).Count
            [ordered]@{ status = $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }); exit_code = $r.Code; summary = "PASS lines=$p FAIL lines=$f"; failures = @(Get-Tail $r.Lines $Root) }
        }.GetNewClosure())
}

function New-ToolTestsCheck([string]$Root, [string]$Prefix) {
    return (New-Check "${Prefix}:workflow-tools-tests" 'validator' 'pwsh -File tools/oss-workflow/tests/Test-OssWorkflowTools.ps1 -RepositoryRoot <repo>' {
            $t = Join-Path $Root 'tools/oss-workflow/tests/Test-OssWorkflowTools.ps1'
            if (-not (Test-Path -LiteralPath $t -PathType Leaf)) { return [ordered]@{ status = 'BLOCKED'; exit_code = $null; summary = 'tool tests are missing'; failures = @() } }
            $r = Invoke-OwPwshFile $Root $t @('-RepositoryRoot', $Root)
            $sum = @($r.Lines | Where-Object { $_ -match '^OSS_WORKFLOW_TOOLS_SUMMARY' } | Select-Object -Last 1)
            [ordered]@{ status = $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }); exit_code = $r.Code; summary = $(if ($sum) { $sum[0] } else { 'no summary' }); failures = @(Get-Tail $r.Lines $Root) }
        }.GetNewClosure())
}

function New-IdentityCheck([string]$Root, [string]$MergeBase, [string]$Head, [object]$Policy) {
    return (New-Check 'l1:identity-privacy' 'privacy' "identity privacy $($MergeBase.Substring(0, 12))..HEAD + local config" {
            $res = @(Test-OwIdentityPrivacy $Root $MergeBase $Head $Policy)
            $bad = @($res | Where-Object { -not $_.ok })
            [ordered]@{ status = $(if ($bad.Count -eq 0) { 'PASS' } else { 'FAIL' }); exit_code = $bad.Count; summary = "$($res.Count) identity check(s), $($bad.Count) not approved (values withheld)"; failures = @($bad | Select-Object -First 3 | ForEach-Object { "$($_.commit) $($_.field) $($_.label)" }) }
        }.GetNewClosure())
}

function Invoke-Check([object]$Check, [string]$Root) {
    $t0 = [DateTime]::UtcNow
    try { $res = & $Check.action }
    catch { $res = [ordered]@{ status = 'BLOCKED'; exit_code = $null; summary = (ConvertTo-OwSafeText ("check could not run: " + $_.Exception.Message) $Root); failures = @() } }
    return [ordered]@{
        id = $Check.id; kind = $Check.kind; command = $Check.command; condition = $Check.condition
        status = [string]$res.status; exit_code = $res.exit_code
        started_at = $t0.ToString('o'); duration_seconds = [math]::Round(([DateTime]::UtcNow - $t0).TotalSeconds, 2)
        summary = [string]$res.summary; failures = @($res.failures | ForEach-Object { ConvertTo-OwSafeText ([string]$_) $Root })
    }
}

# State that a receipt vouches for; compared at the start and the end of a run.
function Get-StateSnapshot([string]$Root) {
    $h = (Invoke-OwGit -Root $Root -Arguments @('rev-parse', 'HEAD')).Lines[0]
    return [ordered]@{ head = $h; tree = (Get-OwTree $Root $h); worktree = (Get-OwWorktreeState $Root); environment = (Get-OwEnvironment $Root) }
}

function Get-StateDrift([System.Collections.IDictionary]$Before, [System.Collections.IDictionary]$After) {
    $d = [System.Collections.Generic.List[string]]::new()
    if ($Before.head -cne $After.head) { $d.Add('HEAD changed') }
    if ($Before.tree -cne $After.tree) { $d.Add('tree changed') }
    if ([string]$Before.worktree.fingerprint -cne [string]$After.worktree.fingerprint -or [bool]$Before.worktree.clean -ne [bool]$After.worktree.clean) { $d.Add('working tree changed') }
    foreach ($k in $Before.environment.Keys) { if ([string]$Before.environment[$k] -cne [string]$After.environment[$k]) { $d.Add("environment changed: $k") } }
    return @($d)
}

try {
    $root = Get-OwRepositoryRoot $RepositoryRoot
    $head = Resolve-OwCommit $root 'HEAD' 'HEAD'
    $tree = Get-OwTree $root $head
    $baseSha = Resolve-OwCommit $root $BaseRef 'base reference'
    $mb = (Invoke-OwGit -Root $root -Arguments @('merge-base', $baseSha, $head) -AllowFailure).Lines
    if ($mb.Count -ne 1) { Stop-OwError 'WRONG_ANCESTRY' "HEAD shares no history with $BaseRef." }
    $mergeBase = $mb[0]
    $worktree = Get-OwWorktreeState $root
    $changed = @(Get-OwChangedFiles $root $mergeBase)
    $plan = Get-OwVerificationPlan @($changed | ForEach-Object { $_.path }) $root $mergeBase
    $required = $plan.recommended
    $executed = if ($Level -eq 'auto') { $required } else { $Level }
    $receiptDir = if ($ReceiptDirectory) { $ReceiptDirectory } else { Get-OwReceiptDirectory $root }
    $environment = Get-OwEnvironment $root
    $tool = Get-OwToolFingerprint
    $policy = Get-OwApprovedIdentities
}
catch {
    $code = Get-OwErrorCode $_
    Write-Output ("OSS_VERIFY status=BLOCKED code={0} :: {1}" -f $code, (ConvertTo-OwSafeText ($_.Exception.Message -replace '^OW:[A-Z_]+:\s*', '') $null))
    exit 2
}

$blockedReason = $null
if ((Get-OwLevelIndex $executed) -lt (Get-OwLevelIndex $required)) {
    $blockedReason = "requested $executed is below the minimum $required for this change: $($plan.reasons -join '; ')"
}
elseif ($executed -eq 'L4' -and (-not $worktree.clean -or $head -cne $baseSha)) {
    $blockedReason = "L4 runs only on a clean checkout of the $BaseRef tip"
}

# ---------------------------------------------------------------------------
# Planned checks
# ---------------------------------------------------------------------------
$checks = [System.Collections.Generic.List[object]]::new()
$notExecuted = [System.Collections.Generic.List[object]]::new()
$present = @($changed | Where-Object { $_.status -ne 'D' -and (Test-Path -LiteralPath (Join-Path $root $_.path) -PathType Leaf) })

$checks.Add((New-Check 'l1:git-diff-check' 'static' "git diff --check $($mergeBase.Substring(0, 12))" {
            $r = Invoke-OwGit -Root $root -Arguments @('diff', '--check', $mergeBase) -AllowFailure
            [ordered]@{ status = $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }); exit_code = $r.Code; summary = "$($r.Lines.Count) whitespace issue line(s)"; failures = @($r.Lines | Select-Object -First 3) }
        }))
$psChanged = @($present | Where-Object { $_.path -match '\.(ps1|psm1|psd1)$' } | ForEach-Object { $_.path })
$checks.Add((New-Check 'l1:powershell-parse' 'static' "parse $($psChanged.Count) changed PowerShell file(s)" {
            $bad = [System.Collections.Generic.List[string]]::new()
            foreach ($p in $psChanged) {
                $e = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $p), [ref]$null, [ref]$e)
                if ($e.Count -gt 0) { $bad.Add("$p :: $($e[0].Message)") }
            }
            [ordered]@{ status = $(if ($bad.Count -eq 0) { 'PASS' } else { 'FAIL' }); exit_code = $bad.Count; summary = "$($psChanged.Count) file(s), $($bad.Count) with errors"; failures = @($bad | Select-Object -First 3) }
        }))
$jsonChanged = @($present | Where-Object { $_.path -match '\.json$' } | ForEach-Object { $_.path })
$checks.Add((New-Check 'l1:json-parse' 'static' "parse $($jsonChanged.Count) changed JSON file(s)" {
            $bad = [System.Collections.Generic.List[string]]::new()
            foreach ($p in $jsonChanged) { try { $null = Get-Content -Raw -LiteralPath (Join-Path $root $p) | ConvertFrom-Json } catch { $bad.Add($p) } }
            [ordered]@{ status = $(if ($bad.Count -eq 0) { 'PASS' } else { 'FAIL' }); exit_code = $bad.Count; summary = "$($jsonChanged.Count) file(s), $($bad.Count) invalid"; failures = @($bad | Select-Object -First 3) }
        }))
$checks.Add((New-IdentityCheck $root $mergeBase $head $policy))
$selectedValidators = @(Select-OwValidators $root $plan.files)
$toolsChanged = (@($plan.files | Where-Object { $_.module -eq 'workflow-tools' }).Count -gt 0)

if ($executed -eq 'L2') {
    $projects = @($plan.files | Where-Object { $_.project } | ForEach-Object { $_.project } | Sort-Object -Unique)
    $needsDotnet = (@($plan.files | Where-Object { $_.rule -eq 'router-project' }).Count -gt 0)
    if ($needsDotnet) {
        $checks.Add((New-Check 'l2:dotnet-build' 'dotnet' 'dotnet build local-router/LocalRouter.sln --configuration Release' {
                    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { return [ordered]@{ status = 'BLOCKED'; exit_code = $null; summary = 'dotnet is not available'; failures = @() } }
                    $r = Invoke-OwNative $root 'dotnet' @('build', 'local-router/LocalRouter.sln', '--configuration', 'Release') @{ DOTNET_CLI_UI_LANGUAGE = 'en'; DOTNET_NOLOGO = '1' }
                    $w = [regex]::Match(($r.Lines -join "`n"), '(\d+) Warning\(s\)').Groups[1].Value; $e = [regex]::Match(($r.Lines -join "`n"), '(\d+) Error\(s\)').Groups[1].Value
                    [ordered]@{ status = $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }); exit_code = $r.Code; summary = "warnings=$w errors=$e"; failures = @(Get-Tail $r.Lines $root) }
                }))
        foreach ($tp in @(Get-OwAffectedTestProjects $root $projects)) {
            $proj = $tp
            $checks.Add((New-Check "l2:dotnet-test:$([IO.Path]::GetFileNameWithoutExtension($proj))" 'dotnet' "dotnet test $proj --configuration Release --no-build" {
                        if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { return [ordered]@{ status = 'BLOCKED'; exit_code = $null; summary = 'dotnet is not available'; failures = @() } }
                        $r = Invoke-OwNative $root 'dotnet' @('test', $proj, '--configuration', 'Release', '--no-build') @{ DOTNET_CLI_UI_LANGUAGE = 'en'; DOTNET_NOLOGO = '1' }
                        $m = [regex]::Match(($r.Lines -join "`n"), '(Passed|Failed)!\s+-\s+Failed:\s+(\d+),\s+Passed:\s+(\d+),\s+Skipped:\s+(\d+),\s+Total:\s+(\d+)')
                        $summary = if ($m.Success) { "passed=$($m.Groups[3].Value) failed=$($m.Groups[2].Value) skipped=$($m.Groups[4].Value) total=$($m.Groups[5].Value)" } else { 'no test summary found' }
                        $status = if ($r.Code -ne 0) { 'FAIL' } elseif (-not $m.Success) { 'BLOCKED' } elseif ([int]$m.Groups[4].Value -gt 0) { 'SKIP' } else { 'PASS' }
                        [ordered]@{ status = $status; exit_code = $r.Code; summary = $summary; failures = @(Get-Tail $r.Lines $root) }
                    }.GetNewClosure()))
        }
    }
    foreach ($v in $selectedValidators) { $checks.Add((New-ValidatorCheck $root $v 'l2')) }
    if ($toolsChanged) { $checks.Add((New-ToolTestsCheck $root 'l2')) }
    if (@($plan.files | Where-Object { $_.module -eq 'lr14-registration' }).Count -gt 0) {
        $checks.Add((New-Check 'l2:lr14-scope-regression' 'gate' 'pwsh -File tests/validate-local-router-lr14-scope-regression.ps1 -RepositoryRoot <repo>' {
                    $g = Join-Path $root 'tests/validate-local-router-lr14-scope-regression.ps1'
                    if (-not (Test-Path -LiteralPath $g -PathType Leaf)) { return [ordered]@{ status = 'BLOCKED'; exit_code = $null; summary = 'LR-14 regression is missing'; failures = @() } }
                    $r = Invoke-OwPwshFile $root $g @('-RepositoryRoot', $root)
                    $p = @($r.Lines | Where-Object { $_ -match '^\s*PASS\s' }).Count; $f = @($r.Lines | Where-Object { $_ -match '^\s*FAIL\s' }).Count
                    [ordered]@{ status = $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }); exit_code = $r.Code; summary = "PASS lines=$p FAIL lines=$f"; failures = @(Get-Tail $r.Lines $root) }
                }))
    }
    $committed = @((Invoke-OwGit -Root $root -Arguments @('rev-list', "$mergeBase..$head")).Lines).Count
    $checks.Add((New-Check 'l2:lr14-scope' 'gate' 'pwsh -File tests/validate-local-router-lr14-scope.ps1 -RepositoryRoot <repo>' {
                if ($committed -eq 0) { return [ordered]@{ status = 'SKIP'; exit_code = $null; summary = 'no committed delta to review (the gate reviews commits only)'; failures = @() } }
                $g = Join-Path $root 'tests/validate-local-router-lr14-scope.ps1'
                if (-not (Test-Path -LiteralPath $g -PathType Leaf)) { return [ordered]@{ status = 'BLOCKED'; exit_code = $null; summary = 'LR-14 gate is missing'; failures = @() } }
                $r = Invoke-OwPwshFile $root $g @('-RepositoryRoot', $root)
                $p = @($r.Lines | Where-Object { $_ -match '^\s*PASS\s' }).Count; $f = @($r.Lines | Where-Object { $_ -match '^\s*FAIL\s' }).Count
                [ordered]@{ status = $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }); exit_code = $r.Code; summary = "PASS lines=$p FAIL lines=$f"; failures = @(Get-Tail $r.Lines $root) }
            }.GetNewClosure()))
}

if ($executed -in @('L3', 'L4')) {
    $steps = @()
    try { $steps = @(Get-OwWorkflowSteps $root) } catch { $checks.Add((New-Check 'ci:workflow' 'ci-step' 'read .github/workflows/ci.yml' { [ordered]@{ status = 'BLOCKED'; exit_code = $null; summary = 'ci.yml is missing'; failures = @() } })) }
    foreach ($st in $steps) {
        if ($st.uses) { $notExecuted.Add([ordered]@{ item = "ci step $($st.index): $($st.name)"; reason = "GitHub Actions environment step ($(($st.uses -split '@')[0])); runs in GitHub CI only" }); continue }
        if (-not $st.run) { continue }
        $step = $st
        $checks.Add((New-Check ("ci:{0:d2}:{1}" -f $step.index, $step.name) 'ci-step' (ConvertTo-OwSafeText (($step.run -split "`n")[0]) $root) {
                    if ($step.run.Contains('${{')) { return [ordered]@{ status = 'BLOCKED'; exit_code = $null; summary = 'contains a GitHub expression that cannot be evaluated locally'; failures = @() } }
                    if ($step.shell -and $step.shell -ne 'pwsh') { return [ordered]@{ status = 'BLOCKED'; exit_code = $null; summary = "unsupported shell '$($step.shell)'"; failures = @() } }
                    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('oss-verify-' + [guid]::NewGuid().ToString('N'))
                    $null = New-Item -ItemType Directory -Path $tmp
                    try {
                        $file = Join-Path $tmp 'step.ps1'
                        [IO.File]::WriteAllText($file, $step.run + "`nexit `$LASTEXITCODE`n", [Text.UTF8Encoding]::new($false))
                        $r = Invoke-OwPwshFile $root $file @() @{ RUNNER_TEMP = $tmp }
                    }
                    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
                    $p = @($r.Lines | Where-Object { $_ -match '^\s*PASS\s' }).Count; $f = @($r.Lines | Where-Object { $_ -match '^\s*FAIL\s' }).Count
                    [ordered]@{ status = $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }); exit_code = $r.Code; summary = "PASS lines=$p FAIL lines=$f"; failures = @(Get-Tail $r.Lines $root) }
                }.GetNewClosure() $step.condition))
    }
    $notExecuted.Add([ordered]@{ item = 'GitHub step conditions'; reason = 'local runs execute every step even after a failure; GitHub skips later steps after a failure' })
    # A higher level never runs less than L2 would: tests that ci.yml does not
    # run (the workflow-tool tests, validators missing from ci.yml) are added.
    $ciRuns = (@($steps | Where-Object { $_.run } | ForEach-Object { $_.run }) -join "`n")
    if ($toolsChanged -and -not $ciRuns.Contains('tools/oss-workflow/tests/Test-OssWorkflowTools.ps1')) { $checks.Add((New-ToolTestsCheck $root 'l3')) }
    foreach ($v in $selectedValidators) { if (-not $ciRuns.Contains($v)) { $checks.Add((New-ValidatorCheck $root $v 'l3')) } }
}
foreach ($l in $script:OwLevels | Where-Object { (Get-OwLevelIndex $_) -gt (Get-OwLevelIndex $executed) }) {
    $notExecuted.Add([ordered]@{ item = "level $l"; reason = 'not executed in this run' })
}
$notExecuted.Add([ordered]@{ item = 'GitHub Development Gate'; reason = 'never replaced by a local receipt; the PR and main CI runs remain required' })

$keyInputs = [ordered]@{
    schema = $OwReceiptSchema; level = $executed; commit = $head; tree = $tree; merge_base = $mergeBase
    worktree_clean = $worktree.clean; worktree_fingerprint = $worktree.fingerprint
    environment = $environment; tool = $tool.sha256; checks = @($checks | ForEach-Object { $_.id })
}
$receiptKey = Get-OwReceiptKey $keyInputs
$scope = if ($executed -in @('L1', 'L2')) { 'LOCAL-PARTIAL (not a CI result)' } else { 'LOCAL-FULL-REPRODUCTION (GitHub CI still required)' }

if ($PlanOnly) {
    Write-Output "OSS_VERIFY_PLAN required=$required requested=$Level executes=$executed changed_files=$($changed.Count)"
    foreach ($r in $plan.reasons) { Write-Output "  reason: $r" }
    foreach ($f in $plan.files) { Write-Output ("  file: {0} [{1} -> {2}]" -f $f.path, $f.rule, $f.level) }
    if ($blockedReason) { Write-Output "  BLOCKED: $blockedReason" } else { foreach ($c in $checks) { Write-Output "  check: $($c.id)" } }
    exit $(if ($blockedReason) { 3 } else { 0 })
}

$receipt = [ordered]@{
    schema = $OwReceiptSchema
    receipt_sha256 = ''
    tool = $tool
    repository = [ordered]@{ slug = (Get-OwRemoteSlug $root); branch = (Get-OwBranch $root) }
    commit_sha = $head; tree_sha = $tree
    base_ref = $BaseRef; base_sha = $baseSha; merge_base_sha = $mergeBase
    worktree = $worktree
    level_requested = $Level; level_required = $required; level_executed = $executed
    plan = [ordered]@{ reasons = @($plan.reasons); modules = @($plan.modules); files = @($plan.files | ForEach-Object { [ordered]@{ path = $_.path; rule = $_.rule; level = $_.level; module = $_.module } }) }
    receipt_key = $receiptKey
    environment = $environment
    checks = @()
    not_executed = @($notExecuted)
    status = 'PENDING'
    scope = $scope
    ci_equivalent = $false
    note = 'Local evidence only. A local receipt never substitutes for the GitHub Development Gate.'
    reused_from = $null
    started_at = $started.ToString('o')
    finished_at = $null
    duration_seconds = $null
}

if ($blockedReason) {
    $receipt.status = 'BLOCKED'
    $receipt.checks = @([ordered]@{ id = 'policy:minimum-level'; kind = 'policy'; command = "requested $executed"; status = 'BLOCKED'; exit_code = $null; duration_seconds = 0; summary = $blockedReason; failures = @() })
    $receipt.finished_at = [DateTime]::UtcNow.ToString('o'); $receipt.duration_seconds = [math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 2)
    $path = Write-OwReceipt $receipt $receiptDir
    Write-Output "BLOCKED  policy:minimum-level :: $blockedReason"
    Write-Output ("OSS_VERIFY level={0} required={1} status=BLOCKED checks=0 seconds={2} receipt={3}" -f $executed, $required, $receipt.duration_seconds, (ConvertTo-OwSafeText $path $root))
    exit 3
}

$startState = [ordered]@{ head = $head; tree = $tree; worktree = $worktree; environment = $environment }
$identityCheck = @($checks | Where-Object { $_.id -eq 'l1:identity-privacy' })[0]

function Complete-Receipt([System.Collections.Generic.List[object]]$Results) {
    # A receipt may vouch only for a state that did not change while it was produced.
    $drift = @(Get-StateDrift $startState (Get-StateSnapshot $root))
    $message = $null
    if ($drift.Count -gt 0) {
        $Results.Add([ordered]@{ id = 'integrity:state-stable'; kind = 'integrity'; command = 'compare state at start and end'; condition = $null; status = 'BLOCKED'; exit_code = $null
                started_at = [DateTime]::UtcNow.ToString('o'); duration_seconds = 0; summary = ('state changed during verification: ' + ($drift -join ', ')); failures = @() })
        $message = "BLOCKED  integrity:state-stable :: state changed during verification: $($drift -join ', ')"
    }
    $counts = @{ PASS = 0; FAIL = 0; SKIP = 0; BLOCKED = 0 }
    foreach ($r in $Results) { $counts[$r.status]++ }
    $status = if ($counts.FAIL -gt 0) { 'FAIL' } elseif ($counts.BLOCKED -gt 0) { 'BLOCKED' } elseif ($counts.SKIP -gt 0 -or $Results.Count -eq 0) { 'INCOMPLETE' } else { 'PASS' }
    $receipt.checks = @($Results)
    $receipt.status = $status
    $receipt.finished_at = [DateTime]::UtcNow.ToString('o')
    $receipt.duration_seconds = [math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 2)
    return [pscustomobject]@{ Status = $status; Counts = $counts; Path = (Write-OwReceipt $receipt $receiptDir); Message = $message }
}

if ($ReuseReceipt -and -not $environment.reliable) {
    Write-Output 'reuse: refused, the environment could not be determined reliably (SDK, Git or identity policy unavailable); verifying instead'
}
elseif ($ReuseReceipt -and (Test-Path -LiteralPath $receiptDir)) {
    $current = [ordered]@{ commit_sha = $head; tree_sha = $tree; merge_base_sha = $mergeBase; worktree = $worktree; environment = $environment; tool = $tool }
    $candidates = @(Get-ChildItem -LiteralPath $receiptDir -Filter '*.json' -File | Sort-Object Name -Descending)
    $rejected = 0
    foreach ($c in $candidates) {
        $rr = Read-OwReceipt $c.FullName
        if (-not $rr.Intact) { $rejected++; continue }
        $old = $rr.Receipt
        if ($old.receipt_key -cne $receiptKey -or $old.status -cne 'PASS' -or $null -ne $old.reused_from -or $old.environment.reliable -ne $true) { $rejected++; continue }
        if (@(Get-OwReceiptStaleReasons $old $current).Count -gt 0) { $rejected++; continue }
        # Identity privacy is always re-checked live; it is never taken from an old receipt.
        $results = [System.Collections.Generic.List[object]]::new()
        $live = Invoke-Check $identityCheck $root
        $live['reused'] = $false
        $results.Add($live)
        foreach ($oc in $old.checks | Where-Object { $_.id -ne 'l1:identity-privacy' }) { $h = [ordered]@{}; foreach ($p in $oc.PSObject.Properties) { $h[$p.Name] = $p.Value }; $h['reused'] = $true; $results.Add($h) }
        $receipt.reused_from = [ordered]@{ file = $c.Name; receipt_sha256 = $old.receipt_sha256 }
        $done = Complete-Receipt $results
        if ($done.Message) { Write-Output $done.Message }
        Write-Output ("{0,-8} l1:identity-privacy (live) {1}" -f $live.status, $live.summary)
        Write-Output "REUSED  $($c.Name) for $($results.Count - 1) check(s); identity privacy re-checked live"
        Write-Output ("OSS_VERIFY level={0} required={1} status={2} reused=true checks={3} seconds={4} scope={5} receipt={6}" -f $executed, $required, $done.Status, $results.Count, $receipt.duration_seconds, $scope, (ConvertTo-OwSafeText $done.Path $root))
        exit $(switch ($done.Status) { 'PASS' { 0 } 'FAIL' { 1 } default { 3 } })
    }
    Write-Output "reuse: no matching PASS receipt ($rejected receipt(s) rejected: different key, not PASS, stale, altered or from an unreliable environment)"
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($c in $checks) {
    $entry = Invoke-Check $c $root
    $results.Add($entry)
    Write-Output ("{0,-8} {1} ({2}s) {3}" -f $entry.status, $entry.id, $entry.duration_seconds, $entry.summary)
}
$done = Complete-Receipt $results
if ($done.Message) { Write-Output $done.Message }
$counts = $done.Counts
Write-Output ("OSS_VERIFY level={0} required={1} status={2} checks={3} pass={4} fail={5} skip={6} blocked={7} seconds={8} scope={9} receipt={10}" -f $executed, $required, $done.Status, $results.Count, $counts.PASS, $counts.FAIL, $counts.SKIP, $counts.BLOCKED, $receipt.duration_seconds, $scope, (ConvertTo-OwSafeText $done.Path $root))
exit $(switch ($done.Status) { 'PASS' { 0 } 'FAIL' { 1 } default { 3 } })
