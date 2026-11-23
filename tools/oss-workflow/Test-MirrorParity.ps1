#Requires -Version 7.2
<#
.SYNOPSIS
  Read-only locator for drift between the installer and Skill copies that the
  repository already declares as mirrors.

.DESCRIPTION
  The mirror pairs and their comparison rules are not declared here: they are
  read (PowerShell AST, nothing executed) from the existing parity validators,
  which remain the authority:

    tests/validate-stealth-registry.ps1  $shared names; installer/skill paths;
                                          byte-identical (SHA-256)
    tests/validate-health-check.ps1      $installerHealth / $skillHealth;
                                          identical after CRLF->LF and TrimEnd
    tests/validate-profile-v2.ps1        $installerMigration / $skillMigration;
                                          identical text

  For every pair it reports IDENTICAL or DRIFT with the first differing line
  (or byte offset when only line endings or encoding differ). Text is compared
  ordinally (case-sensitive), so it never accepts a difference a validator
  would reject. It never fixes, syncs, commits or pushes anything.

  Exit codes: 0 no drift, 1 drift, 2 BLOCKED (the mirror rules could not be read).
#>
param([string]$RepositoryRoot = (Get-Location).Path)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OssWorkflow.psm1') -Force

function Get-ValidatorAst([string]$Root, [string]$Relative) {
    $path = Join-Path $Root $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-OwError 'MIRROR_RULES_UNREADABLE' "$Relative is missing." }
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if ($errors.Count -gt 0) { Stop-OwError 'MIRROR_RULES_UNREADABLE' "$Relative does not parse." }
    return $ast
}

# The path literal of "$<Variable> = Join-Path $RepositoryRoot '<path>'".
function Get-JoinPathLiteral([object]$Ast, [string]$Variable, [string]$Relative) {
    $a = $Ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq "`$$Variable" }, $true)
    if ($a) {
        $cmd = $a.Right.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        if ($cmd -and $cmd.GetCommandName() -eq 'Join-Path' -and $cmd.CommandElements.Count -eq 3) {
            $arg = $cmd.CommandElements[2]
            if ($arg -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $arg -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { return [string]$arg.Value }
        }
    }
    Stop-OwError 'MIRROR_RULES_UNREADABLE' "The `$$Variable path could not be read from $Relative."
}

function Get-MirrorPairs([string]$Root) {
    $pairs = [System.Collections.Generic.List[object]]::new()
    $rel = 'tests/validate-stealth-registry.ps1'
    $ast = Get-ValidatorAst $Root $rel
    $shared = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$shared' }, $true)
    if (-not $shared) { Stop-OwError 'MIRROR_RULES_UNREADABLE' "The `$shared list could not be read from $rel." }
    $names = @()
    try { $names = @($shared.Right.Find({ param($n) $n -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true).SafeGetValue()) } catch { Stop-OwError 'MIRROR_RULES_UNREADABLE' "The `$shared list in $rel is not a constant list." }
    if ($names.Count -eq 0) { Stop-OwError 'MIRROR_RULES_UNREADABLE' "The `$shared list in $rel is empty." }
    $iTemplate = Get-JoinPathLiteral $ast 'installer' $rel
    $sTemplate = Get-JoinPathLiteral $ast 'skill' $rel
    if (-not $iTemplate.Contains('$name') -or -not $sTemplate.Contains('$name')) { Stop-OwError 'MIRROR_RULES_UNREADABLE' "The stealth path templates in $rel do not use `$name." }
    foreach ($n in $names) { $pairs.Add([pscustomobject]@{ Rule = 'sha256'; Source = $rel; Installer = $iTemplate.Replace('$name', [string]$n); Skill = $sTemplate.Replace('$name', [string]$n) }) }
    $rel = 'tests/validate-health-check.ps1'
    $ast = Get-ValidatorAst $Root $rel
    if (-not $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Normalize-HealthScript' }, $true)) { Stop-OwError 'MIRROR_RULES_UNREADABLE' "The normalisation rule could not be read from $rel." }
    $pairs.Add([pscustomobject]@{ Rule = 'normalized-line-endings'; Source = $rel; Installer = (Get-JoinPathLiteral $ast 'installerHealth' $rel); Skill = (Get-JoinPathLiteral $ast 'skillHealth' $rel) })
    $rel = 'tests/validate-profile-v2.ps1'
    $ast = Get-ValidatorAst $Root $rel
    $pairs.Add([pscustomobject]@{ Rule = 'text'; Source = $rel; Installer = (Get-JoinPathLiteral $ast 'installerMigration' $rel); Skill = (Get-JoinPathLiteral $ast 'skillMigration' $rel) })
    return @($pairs)
}

function Get-Preview([string]$Line, [string]$Root) {
    $t = ConvertTo-OwSafeText $Line.Trim() $Root
    if ($t.Length -gt 80) { $t = $t.Substring(0, 80) + '...' }
    return $t
}

try {
    $root = Get-OwRepositoryRoot $RepositoryRoot
    $pairs = @(Get-MirrorPairs $root)
}
catch {
    Write-Output ("MIRROR_PARITY status=BLOCKED code={0} :: {1}" -f (Get-OwErrorCode $_), (ConvertTo-OwSafeText ($_.Exception.Message -replace '^OW:[A-Z_]+:\s*', '') $null))
    exit 2
}

$drift = 0
foreach ($p in $pairs) {
    $ia = Join-Path $root $p.Installer; $sa = Join-Path $root $p.Skill
    $label = "$($p.Installer) <-> $($p.Skill) [$($p.Rule); $($p.Source)]"
    $missing = @(@($p.Installer, $p.Skill) | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf) })
    if ($missing.Count -gt 0) { $drift++; Write-Output "MIRROR DRIFT  $label :: missing $($missing -join ', ')"; continue }
    $ib = [System.IO.File]::ReadAllBytes($ia); $sb = [System.IO.File]::ReadAllBytes($sa)
    $it = [System.Text.Encoding]::UTF8.GetString($ib); $st = [System.Text.Encoding]::UTF8.GetString($sb)
    $same = switch ($p.Rule) {
        'sha256' { [System.Linq.Enumerable]::SequenceEqual($ib, $sb) }
        'normalized-line-endings' { ($it.Replace("`r`n", "`n").TrimEnd()) -ceq ($st.Replace("`r`n", "`n").TrimEnd()) }
        default { $it -ceq $st }
    }
    if ($same) { Write-Output "MIRROR IDENTICAL  $label"; continue }
    $drift++
    $il = @($it.Replace("`r`n", "`n").Split("`n")); $sl = @($st.Replace("`r`n", "`n").Split("`n"))
    $i = 0; while ($i -lt [Math]::Min($il.Count, $sl.Count) -and $il[$i] -ceq $sl[$i]) { $i++ }
    if ($i -ge $il.Count -and $i -ge $sl.Count) {
        $k = 0; while ($k -lt [Math]::Min($ib.Length, $sb.Length) -and $ib[$k] -eq $sb[$k]) { $k++ }
        Write-Output "MIRROR DRIFT  $label :: same lines, bytes differ from offset $k (line endings, trailing whitespace or encoding)"
    }
    else {
        $a = if ($i -lt $il.Count) { Get-Preview $il[$i] $root } else { '<end of file>' }
        $b = if ($i -lt $sl.Count) { Get-Preview $sl[$i] $root } else { '<end of file>' }
        Write-Output ("MIRROR DRIFT  {0} :: first difference at line {1} (installer {2} lines, skill {3} lines)" -f $label, ($i + 1), $il.Count, $sl.Count)
        Write-Output "              installer: $a"
        Write-Output "              skill    : $b"
    }
}
Write-Output ("MIRROR_PARITY status={0} pairs={1} drift={2} (read-only; nothing is fixed, synced or committed)" -f $(if ($drift -eq 0) { 'PASS' } else { 'DRIFT' }), $pairs.Count, $drift)
exit $(if ($drift -eq 0) { 0 } else { 1 })
