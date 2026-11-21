#Requires -Version 7.2
<#
.SYNOPSIS
  Read-only privacy gate for commit identities.

.DESCRIPTION
  Default (local pre-push) mode: checks the author and committer of every
  commit in Base..Head, e-mail address shapes in their messages, and the
  effective local Git identity (repository config plus GIT_AUTHOR_*/
  GIT_COMMITTER_* overrides) against approved-identities.json. Unknown
  identities are rejected. Run it before every push.

  CI commit-range mode (-CommitRangeFromGitHubEvent, explicit switch only):
  checks exactly the commits a GitHub event introduces, taken from the event
  file (GITHUB_EVENT_NAME / GITHUB_EVENT_PATH):
    pull_request       the pull request's real base.sha..head.sha (never the
                       synthetic merge commit GitHub checks out)
    push               before..after, where after must be the checked-out HEAD
    workflow_dispatch  the commits introduced by HEAD (HEAD^1..HEAD)
    schedule           same as workflow_dispatch
  A missing event, an all-zero before, a commit missing from the checkout, an
  empty range or an unsupported event is BLOCKED, never PASS. The local Git
  identity is NOT evaluated in this mode and is reported as not checked: CI
  history checks never replace the local pre-push gate.

  The gate never prints a name or an e-mail address: results show only the
  approved label or "not-approved". It does not change Git configuration,
  install hooks, read credentials, or push anything.

  Exit codes: 0 PASS, 1 FAIL (do not push), 2 BLOCKED (the check could not run).
#>
param(
    [string]$RepositoryRoot = (Get-Location).Path,
    [string]$BaseRef = 'origin/main',
    [string]$HeadRef = 'HEAD',
    [string]$PolicyPath = (Join-Path $PSScriptRoot 'approved-identities.json'),
    [switch]$CommitRangeFromGitHubEvent,
    [string]$EventName = $env:GITHUB_EVENT_NAME,
    [string]$EventPath = $env:GITHUB_EVENT_PATH,
    [switch]$Json
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OssWorkflow.psm1') -Force

function Resolve-EventCommit([string]$Root, [object]$Value, [string]$Label) {
    $v = [string]$Value
    if ($v -notmatch '^[0-9a-f]{40}$') { Stop-OwError 'MISSING_RANGE_COMMIT' "The event's $Label is not a full commit id." }
    if ($v -match '^0{40}$') { Stop-OwError 'NEW_REF_NO_BASE' "The event's $Label is all zeros (new ref); the range is undefined and the whole history is not trusted instead." }
    $r = Invoke-OwGit -Root $Root -Arguments @('cat-file', '-e', "$v^{commit}") -AllowFailure
    if ($r.Code -ne 0) { Stop-OwError 'MISSING_RANGE_COMMIT' "The event's $Label is not present in this checkout (fetch-depth 0 is required)." }
    return $v
}

$mode = if ($CommitRangeFromGitHubEvent) { 'ci-commit-range' } else { 'local-pre-push' }
try {
    $root = Get-OwRepositoryRoot $RepositoryRoot
    $policy = Get-OwApprovedIdentities $PolicyPath
    $eventLabel = 'n/a'
    if ($CommitRangeFromGitHubEvent) {
        if ([string]::IsNullOrWhiteSpace($EventName) -or [string]::IsNullOrWhiteSpace($EventPath) -or -not (Test-Path -LiteralPath $EventPath -PathType Leaf)) {
            Stop-OwError 'NO_GITHUB_EVENT' 'Commit-range mode needs a GitHub event (GITHUB_EVENT_NAME and GITHUB_EVENT_PATH); use the default mode locally.'
        }
        $event = $null
        try { $event = Get-Content -Raw -LiteralPath $EventPath | ConvertFrom-Json } catch { Stop-OwError 'NO_GITHUB_EVENT' 'The GitHub event file is not valid JSON.' }
        $eventLabel = $EventName
        $checkedOut = Resolve-OwCommit $root 'HEAD' 'HEAD'
        switch ($EventName) {
            'pull_request' {
                if ($event.PSObject.Properties.Name -notcontains 'pull_request') { Stop-OwError 'MISSING_RANGE_COMMIT' 'The pull_request event has no pull_request object.' }
                $base = Resolve-EventCommit $root $event.pull_request.base.sha 'pull_request.base.sha'
                $head = Resolve-EventCommit $root $event.pull_request.head.sha 'pull_request.head.sha'
            }
            'push' {
                $base = Resolve-EventCommit $root $event.before 'before'
                $head = Resolve-EventCommit $root $event.after 'after'
                if ($head -cne $checkedOut) { Stop-OwError 'HEAD_MISMATCH' "The push event's after commit is not the checked-out HEAD." }
            }
            { $_ -in @('workflow_dispatch', 'schedule') } {
                $head = $checkedOut
                $parents = @(Get-OwParents $root $head)
                if ($parents.Count -eq 0) { Stop-OwError 'MISSING_RANGE_COMMIT' 'HEAD is a root commit; there is no introduced range.' }
                $base = $parents[0]
            }
            default { Stop-OwError 'UNSUPPORTED_EVENT' "Commit-range mode does not support the '$EventName' event." }
        }
    }
    else {
        $head = Resolve-OwCommit $root $HeadRef 'head'
        $base = Resolve-OwCommit $root $BaseRef 'base'
    }
    if (-not (Test-OwAncestor $root $base $head)) {
        $mb = (Invoke-OwGit -Root $root -Arguments @('merge-base', $base, $head) -AllowFailure).Lines
        if ($mb.Count -eq 0) { Stop-OwError 'WRONG_ANCESTRY' 'The base and head share no history.' }
        $base = $mb[0]
    }
    $rangeCount = @((Invoke-OwGit -Root $root -Arguments @('rev-list', "$base..$head")).Lines).Count
    if ($CommitRangeFromGitHubEvent -and $rangeCount -eq 0) { Stop-OwError 'EMPTY_RANGE' 'The event introduces no commits; an empty range is never reported as PASS.' }
    $results = @(Test-OwIdentityPrivacy $root $base $head $policy -CommitsOnly:$CommitRangeFromGitHubEvent)
}
catch {
    $code = Get-OwErrorCode $_
    $msg = ConvertTo-OwSafeText ($_.Exception.Message -replace '^OW:[A-Z_]+:\s*', '') $null
    if ($Json) { [ordered]@{ status = 'BLOCKED'; mode = $mode; code = $code; message = $msg } | ConvertTo-Json -Depth 5 }
    else { Write-Output "PRIVACY_GATE BLOCKED mode=$mode code=$code :: $msg" }
    exit 2
}

$failures = @($results | Where-Object { -not $_.ok })
$commits = @($results | Where-Object { $_.commit -ne '(local)' } | ForEach-Object { $_.commit } | Sort-Object -Unique).Count
$status = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
$localNote = if ($CommitRangeFromGitHubEvent) { 'not checked in commit-range mode (the local pre-push gate checks it)' } else { 'checked' }
if ($Json) {
    [ordered]@{
        status = $status; mode = $mode; event = $eventLabel; base = $base; head = $head; commits = $commits; failures = $failures.Count
        local_identity = $localNote
        results = @($results | ForEach-Object { [ordered]@{ commit = $_.commit; field = $_.field; ok = $_.ok; label = $_.label } })
    } | ConvertTo-Json -Depth 6
}
else {
    foreach ($r in $results) {
        $mark = if ($r.ok) { 'PASS' } else { 'FAIL' }
        Write-Output ("{0}  {1,-14} {2,-10} {3}" -f $mark, $r.commit, $r.field, $r.label)
    }
    if ($CommitRangeFromGitHubEvent) { Write-Output "NOTE  local Git identity $localNote" }
    Write-Output ("PRIVACY_GATE {0} commits={1} failures={2} base={3} head={4} mode={5} event={6}" -f $status, $commits, $failures.Count, $base.Substring(0, 12), $head.Substring(0, 12), $mode, $eventLabel)
    if ($failures.Count -gt 0) { Write-Output 'Do not push: fix the commit identities first. Values are withheld on purpose.' }
}
exit $(if ($failures.Count -eq 0) { 0 } else { 1 })
