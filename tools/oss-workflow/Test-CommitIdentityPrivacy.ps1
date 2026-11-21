#Requires -Version 7.2
<#
.SYNOPSIS
  Read-only pre-push privacy gate for commit identities.

.DESCRIPTION
  Checks the author and committer of every commit in Base..Head, e-mail address
  shapes in their messages, and the effective local Git identity (repository
  config plus GIT_AUTHOR_*/GIT_COMMITTER_* overrides) against
  approved-identities.json. Unknown identities are rejected.

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
    [switch]$Json
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OssWorkflow.psm1') -Force

try {
    $root = Get-OwRepositoryRoot $RepositoryRoot
    $policy = Get-OwApprovedIdentities $PolicyPath
    $head = Resolve-OwCommit $root $HeadRef 'head'
    $base = Resolve-OwCommit $root $BaseRef 'base'
    if (-not (Test-OwAncestor $root $base $head)) {
        $mb = (Invoke-OwGit -Root $root -Arguments @('merge-base', $base, $head) -AllowFailure).Lines
        if ($mb.Count -eq 0) { Stop-OwError 'WRONG_ANCESTRY' 'The base and head share no history.' }
        $base = $mb[0]
    }
    $results = @(Test-OwIdentityPrivacy $root $base $head $policy)
}
catch {
    $code = Get-OwErrorCode $_
    $msg = ConvertTo-OwSafeText ($_.Exception.Message -replace '^OW:[A-Z_]+:\s*', '') $null
    if ($Json) { [ordered]@{ status = 'BLOCKED'; code = $code; message = $msg } | ConvertTo-Json -Depth 5 }
    else { Write-Output "PRIVACY_GATE BLOCKED code=$code :: $msg" }
    exit 2
}

$failures = @($results | Where-Object { -not $_.ok })
$commits = @($results | Where-Object { $_.commit -ne '(local)' } | ForEach-Object { $_.commit } | Sort-Object -Unique).Count
$status = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
if ($Json) {
    [ordered]@{
        status = $status; base = $base; head = $head; commits = $commits; failures = $failures.Count
        results = @($results | ForEach-Object { [ordered]@{ commit = $_.commit; field = $_.field; ok = $_.ok; label = $_.label } })
    } | ConvertTo-Json -Depth 6
}
else {
    foreach ($r in $results) {
        $mark = if ($r.ok) { 'PASS' } else { 'FAIL' }
        Write-Output ("{0}  {1,-14} {2,-10} {3}" -f $mark, $r.commit, $r.field, $r.label)
    }
    Write-Output ("PRIVACY_GATE {0} commits={1} failures={2} base={3} head={4}" -f $status, $commits, $failures.Count, $base.Substring(0, 12), $head.Substring(0, 12))
    if ($failures.Count -gt 0) { Write-Output 'Do not push: fix the commit identities first. Values are withheld on purpose.' }
}
exit $(if ($failures.Count -eq 0) { 0 } else { 1 })
