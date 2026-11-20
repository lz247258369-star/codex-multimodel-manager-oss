#Requires -Version 7.2
<#
.SYNOPSIS
  Produces a CANDIDATE LR-14 slice registration for human review.

.DESCRIPTION
  Reads the real commit range Base..Tip and its diff and proposes the data of a
  registration entry: Base, Tip, Artifacts and Markers. It never edits the
  LR-14 gate, never commits, and never approves anything. The reviewer appends
  the entry through the normal two-commit registration, which the LR-14 gate
  and the pull-request review then check.

  Base, when omitted, is inferred by walking the first-parent chain back from
  Tip and stopping at the first commit that is a registration (touches only the
  gate files), a merge, the root, or the merge base with -BaseRef.

  Artifacts are the files changed in Base..Tip that exist at Tip. Each Marker is
  a line ADDED in the range that occurs exactly once in the file at Tip; when no
  such line exists the marker is left empty for the reviewer (never invented).
  Explicit -Artifact / -Marker values are validated against the same range.

  Exit codes: 0 candidate produced, 2 refused (code printed: INVALID_REVISION,
  WRONG_ANCESTRY, DIRTY_WORKTREE, OUT_OF_RANGE_FILE, MISSING_ARTIFACT,
  WRONG_MARKER, DUPLICATE_NAME, ...).
#>
param(
    [string]$RepositoryRoot = (Get-Location).Path,
    [string]$Tip = 'HEAD',
    [string]$Base,
    [string]$BaseRef = 'origin/main',
    [string]$Name,
    [string[]]$Artifact,
    # "relative/path=marker text" (in-process calls; repeat for several files)
    [string[]]$Marker,
    # JSON object {"relative/path": "marker text"}; works with pwsh -File
    [string]$MarkersFile,
    [string]$OutFile
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OssWorkflow.psm1') -Force

function ConvertTo-PsLiteral([string]$Value) { return '"' + $Value.Replace('`', '``').Replace('"', '`"').Replace('$', '`$') + '"' }

try {
    $root = Get-OwRepositoryRoot $RepositoryRoot
    $registry = Get-OwLr14Registry $root
    $gateHashBefore = Get-OwSha256File $registry.GatePath
    $worktree = Get-OwWorktreeState $root
    if (-not $worktree.clean) { Stop-OwError 'DIRTY_WORKTREE' "The working tree has $($worktree.entries) uncommitted change(s); candidates are generated from committed history only." }

    $tipSha = Resolve-OwCommit $root $Tip 'tip'
    $warnings = [System.Collections.Generic.List[string]]::new()
    $baseInferred = $false; $baseReason = 'given'
    if ($Base) {
        $baseSha = Resolve-OwCommit $root $Base 'base'
    }
    else {
        $baseInferred = $true
        $parents = @(Get-OwParents $root $tipSha)
        if ($parents.Count -eq 0) { Stop-OwError 'WRONG_ANCESTRY' 'The tip is a root commit; there is no range to register.' }
        $mergeBase = $null
        $baseRefSha = $null
        try { $baseRefSha = Resolve-OwCommit $root $BaseRef 'base reference' } catch { $warnings.Add("base reference '$BaseRef' is not available; merge-base stop not applied") }
        if ($baseRefSha) {
            $mb = (Invoke-OwGit -Root $root -Arguments @('merge-base', $baseRefSha, $tipSha) -AllowFailure).Lines
            if ($mb.Count -eq 1 -and $mb[0] -cne $tipSha) { $mergeBase = $mb[0] }
        }
        $cur = $parents[0]
        while ($true) {
            $curParents = @(Get-OwParents $root $cur)
            $files = @(Get-OwCommitFiles $root $cur)
            $gateOnly = ($files.Count -gt 0 -and @($files | Where-Object { $_ -notin $registry.GateFiles }).Count -eq 0)
            if ($gateOnly) { $baseReason = 'nearest registration commit (touches only gate files)'; break }
            if ($curParents.Count -gt 1) { $baseReason = 'nearest merge commit'; break }
            if ($curParents.Count -eq 0) { $baseReason = 'root commit'; break }
            if ($mergeBase -and $cur -ceq $mergeBase) { $baseReason = "merge base with $BaseRef"; break }
            $cur = $curParents[0]
        }
        $baseSha = $cur
    }
    if ($baseSha -ceq $tipSha -or -not (Test-OwAncestor $root $baseSha $tipSha)) {
        Stop-OwError 'WRONG_ANCESTRY' 'The base must be a proper ancestor of the tip.'
    }

    if ($Name) {
        if ($Name -cnotmatch '^[A-Z0-9][A-Z0-9-]{2,63}$') { Stop-OwError 'INVALID_NAME' 'Slice names use upper-case letters, digits and hyphens.' }
        if (@($registry.Slices | Where-Object { $_.Name -ceq $Name }).Count -gt 0) { Stop-OwError 'DUPLICATE_NAME' "A slice named '$Name' is already registered." }
    }
    $existing = @($registry.Slices | Where-Object { $_.Base -ceq $baseSha -and $_.Tip -ceq $tipSha })
    if ($existing.Count -gt 0) { $warnings.Add("this exact range is already registered as $($existing[0].Name)") }

    $commits = @((Invoke-OwGit -Root $root -Arguments @('log', '--format=%H %s', "$baseSha..$tipSha")).Lines | ForEach-Object {
            [ordered]@{ sha = $_.Substring(0, 40); subject = (ConvertTo-OwSafeText $_.Substring(41) $root) } })
    $merges = @((Invoke-OwGit -Root $root -Arguments @('rev-list', '--merges', "$baseSha..$tipSha")).Lines)
    if ($merges.Count -gt 0) { $warnings.Add("the range contains $($merges.Count) merge commit(s)") }

    $diff = @{}
    foreach ($line in (Invoke-OwGit -Root $root -Arguments @('diff', '--name-status', '--no-renames', $baseSha, $tipSha)).Lines) {
        $p = $line -split "`t"; if ($p.Count -ge 2) { $diff[$p[1]] = $p[0].Substring(0, 1) }
    }
    $deleted = @($diff.Keys | Where-Object { $diff[$_] -eq 'D' } | Sort-Object)
    $present = @($diff.Keys | Where-Object { $diff[$_] -ne 'D' } | Sort-Object)
    $touchedGate = @($present | Where-Object { $_ -in $registry.GateFiles })
    if ($touchedGate.Count -gt 0) { $warnings.Add("the implementation range changes gate file(s): $($touchedGate -join ', ')") }

    if ($Artifact) {
        foreach ($a in $Artifact) {
            if (-not $diff.ContainsKey($a)) { Stop-OwError 'OUT_OF_RANGE_FILE' "'$a' is not changed in the range Base..Tip." }
            if ($diff[$a] -eq 'D') { Stop-OwError 'MISSING_ARTIFACT' "'$a' is deleted in the range and does not exist at the tip." }
        }
        $artifacts = @($Artifact | Sort-Object -Unique)
    }
    else { $artifacts = $present }
    foreach ($a in $artifacts) {
        if ((Invoke-OwGit -Root $root -Arguments @('cat-file', '-e', "${tipSha}:$a") -AllowFailure).Code -ne 0) { Stop-OwError 'MISSING_ARTIFACT' "'$a' does not exist at the tip." }
    }

    $explicit = @{}
    foreach ($m in @($Marker)) {
        if (-not $m) { continue }
        $i = $m.IndexOf('=')
        if ($i -lt 1) { Stop-OwError 'WRONG_MARKER' 'Markers are given as "path=text".' }
        $explicit[$m.Substring(0, $i)] = $m.Substring($i + 1)
    }
    if ($MarkersFile) {
        if (-not (Test-Path -LiteralPath $MarkersFile -PathType Leaf)) { Stop-OwError 'WRONG_MARKER' 'The markers file does not exist.' }
        $mf = $null
        try { $mf = Get-Content -Raw -LiteralPath $MarkersFile | ConvertFrom-Json } catch { Stop-OwError 'WRONG_MARKER' 'The markers file is not valid JSON.' }
        foreach ($p in $mf.PSObject.Properties) {
            if ($p.Value -isnot [string] -or [string]::IsNullOrEmpty($p.Value)) { Stop-OwError 'WRONG_MARKER' "The marker for '$($p.Name)' must be a non-empty string." }
            $explicit[$p.Name] = [string]$p.Value
        }
    }
    foreach ($k in $explicit.Keys) { if ($k -notin $artifacts) { Stop-OwError 'OUT_OF_RANGE_FILE' "A marker is given for '$k', which is not an artifact of this range." } }

    $markers = [ordered]@{}
    $details = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $artifacts) {
        $content = (Invoke-OwGit -Root $root -Arguments @('show', "${tipSha}:$a")).Lines -join "`n"
        $added = @((Invoke-OwGit -Root $root -Arguments @('diff', '-U0', '--no-renames', $baseSha, $tipSha, '--', $a)).Lines |
                Where-Object { $_.StartsWith('+') -and -not $_.StartsWith('+++') } | ForEach-Object { $_.Substring(1).Trim() })
        if ($explicit.ContainsKey($a)) {
            $text = $explicit[$a]
            $count = ([regex]::Matches($content, [regex]::Escape($text))).Count
            if ($count -eq 0) { Stop-OwError 'WRONG_MARKER' "The marker for '$a' does not occur in the file at the tip." }
            $inAdded = (@($added | Where-Object { $_.Contains($text) }).Count -gt 0)
            if (-not $inAdded) { $warnings.Add("the marker for '$a' is pre-existing content, not a line added in this range") }
            $markers[$a] = $text
            $details.Add([ordered]@{ path = $a; marker = $text; source = 'given'; occurrences_at_tip = $count; in_added_lines = $inAdded })
            continue
        }
        $chosen = $null
        foreach ($line in $added) {
            if ($line.Length -lt 12 -or $line.Length -gt 200 -or $line -notmatch '[A-Za-z]') { continue }
            if (([regex]::Matches($content, [regex]::Escape($line))).Count -eq 1) { $chosen = $line; break }
        }
        if ($chosen) {
            $lineNo = [array]::IndexOf(@($content -split "`n" | ForEach-Object { $_.Trim() }), $chosen) + 1
            $markers[$a] = $chosen
            $details.Add([ordered]@{ path = $a; marker = $chosen; source = 'added-line'; tip_line = $lineNo; occurrences_at_tip = 1; in_added_lines = $true })
        }
        else {
            $markers[$a] = $null
            $details.Add([ordered]@{ path = $a; marker = $null; source = 'none'; note = 'no added line is unique in the file; the reviewer must choose a marker' })
            $warnings.Add("no mechanical marker for '$a'")
        }
    }

    $preview = $null
    if (@($markers.Values | Where-Object { $null -eq $_ }).Count -eq 0) {
        $sb = [System.Text.StringBuilder]::new()
        $null = $sb.AppendLine('    [pscustomobject]@{')
        $null = $sb.AppendLine('        Name      = ' + (ConvertTo-PsLiteral $(if ($Name) { $Name } else { '<NAME>' })))
        $null = $sb.AppendLine("        Base      = `"$baseSha`"")
        $null = $sb.AppendLine("        Tip       = `"$tipSha`"")
        $null = $sb.AppendLine('        Artifacts = @(')
        for ($i = 0; $i -lt $artifacts.Count; $i++) { $null = $sb.AppendLine('            ' + (ConvertTo-PsLiteral $artifacts[$i]) + $(if ($i -lt $artifacts.Count - 1) { ',' } else { ')' })) }
        $null = $sb.AppendLine('        Markers   = @{')
        foreach ($a in $artifacts) { $null = $sb.AppendLine('            ' + (ConvertTo-PsLiteral $a) + ' = ' + (ConvertTo-PsLiteral $markers[$a])) }
        $null = $sb.AppendLine('        }')
        $null = $sb.Append('    }')
        $preview = $sb.ToString()
    }

    $gateHashAfter = Get-OwSha256File $registry.GatePath
    if ($gateHashAfter -cne $gateHashBefore) { Stop-OwError 'INTERNAL_ERROR' 'The LR-14 gate file changed during candidate generation.' }
    $candidate = [ordered]@{
        schema = 'oss-workflow.lr14-candidate/v1'
        status = 'CANDIDATE_NOT_REGISTERED'
        approval = 'none: review, then append through the normal two-commit LR-14 registration'
        name = $(if ($Name) { $Name } else { $null })
        base = $baseSha; tip = $tipSha
        base_inferred = $baseInferred; base_reason = $baseReason
        commits = @($commits)
        artifacts = @($artifacts)
        markers = $markers
        marker_details = @($details)
        deleted_files = @($deleted)
        warnings = @($warnings)
        gate_file_sha256 = $gateHashBefore
        registry_unparsed_entries = $registry.Unparsed
        entry_preview = $preview
    }
    $json = $candidate | ConvertTo-Json -Depth 10
    if ($OutFile) { [System.IO.File]::WriteAllText($OutFile, $json, [System.Text.UTF8Encoding]::new($false)) } else { Write-Output $json }
    exit 0
}
catch {
    $code = Get-OwErrorCode $_
    $msg = ConvertTo-OwSafeText ($_.Exception.Message -replace '^OW:[A-Z_]+:\s*', '') $null
    Write-Output "LR14_CANDIDATE REFUSED code=$code :: $msg"
    exit 2
}
