#Requires -Version 7.2
# Shared helpers for the OSS development-workflow tools (tiered verification,
# verification receipts, LR-14 registration candidates, commit identity privacy
# and evidence reports).
#
# These tools never change product code, the CI workflow, the LR-14 gate or Git
# configuration. They read Git state, run existing validators and write receipts
# only inside the Git directory (never into the working tree).

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:OwToolVersion = '1.0.0'
$script:OwReceiptSchema = 'oss-workflow.receipt/v1'
$script:OwLevels = @('L1', 'L2', 'L3', 'L4')
$script:OwToolRoot = $PSScriptRoot

# ---------------------------------------------------------------------------
# Errors: every tool failure carries a stable code ("OW:<CODE>: message").
# ---------------------------------------------------------------------------
function Stop-OwError([string]$Code, [string]$Message) {
    throw ("OW:{0}: {1}" -f $Code, $Message)
}

function Get-OwErrorCode([object]$ErrorRecord) {
    $text = [string]$ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $text = $ErrorRecord.Exception.Message }
    if ($text -match '^OW:([A-Z_]+):') { return $Matches[1] }
    return 'INTERNAL_ERROR'
}

# ---------------------------------------------------------------------------
# Hashing and safe text
# ---------------------------------------------------------------------------
function Get-OwSha256Text([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-OwSha256File([string]$Path) {
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
}

# Replaces machine-specific paths so receipts and reports never carry a user
# name, profile path or temp path.
function ConvertTo-OwSafeText([string]$Text, [string]$RepositoryRoot) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $result = $Text
    $replacements = [ordered]@{}
    if ($RepositoryRoot) {
        $replacements[$RepositoryRoot] = '<repo>'
        $replacements[$RepositoryRoot.Replace('\', '/')] = '<repo>'
    }
    $temp = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
    if ($temp) { $replacements[$temp] = '<temp>'; $replacements[$temp.Replace('\', '/')] = '<temp>' }
    $profileDir = [Environment]::GetFolderPath('UserProfile')
    if ($profileDir) { $replacements[$profileDir] = '<profile>'; $replacements[$profileDir.Replace('\', '/')] = '<profile>' }
    foreach ($key in $replacements.Keys) {
        if ($key) { $result = $result.Replace($key, $replacements[$key], [StringComparison]::OrdinalIgnoreCase) }
    }
    # Any remaining e-mail address shape is withheld.
    $result = [regex]::Replace($result, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '<email-withheld>')
    return $result
}

# ---------------------------------------------------------------------------
# Git (strict: a failed git command never silently becomes data)
# ---------------------------------------------------------------------------
function Invoke-OwGit {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # Git writes UTF-8; decode it as UTF-8 whatever the console code page is.
    $previousEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $raw = @(& git -c core.quotepath=off -C $Root @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous; [Console]::OutputEncoding = $previousEncoding }
    $out = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
    $err = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
    if ($code -ne 0 -and -not $AllowFailure) {
        Stop-OwError 'GIT_FAILED' ("git {0} failed (exit {1}): {2}" -f ($Arguments -join ' '), $code, (($err | Select-Object -First 2) -join ' | '))
    }
    return [pscustomobject]@{ Code = $code; Lines = $out; Errors = $err }
}

function Get-OwRepositoryRoot([string]$Path) {
    $r = Invoke-OwGit -Root $Path -Arguments @('rev-parse', '--show-toplevel') -AllowFailure
    if ($r.Code -ne 0 -or $r.Lines.Count -ne 1) { Stop-OwError 'NOT_A_REPOSITORY' 'The path is not inside a Git working tree.' }
    return [System.IO.Path]::GetFullPath($r.Lines[0])
}

function Get-OwGitDirectory([string]$Root) {
    return [System.IO.Path]::GetFullPath((Invoke-OwGit -Root $Root -Arguments @('rev-parse', '--absolute-git-dir')).Lines[0])
}

# Resolves a revision to a full commit id or stops with INVALID_REVISION.
function Resolve-OwCommit([string]$Root, [string]$Revision, [string]$Label = 'revision') {
    if ([string]::IsNullOrWhiteSpace($Revision) -or $Revision -match '\s' -or $Revision.StartsWith('-')) {
        Stop-OwError 'INVALID_REVISION' "The $Label is empty or malformed."
    }
    $r = Invoke-OwGit -Root $Root -Arguments @('rev-parse', '--verify', '--quiet', "$Revision^{commit}") -AllowFailure
    if ($r.Code -ne 0 -or $r.Lines.Count -ne 1 -or $r.Lines[0] -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') {
        Stop-OwError 'INVALID_REVISION' "The $Label '$Revision' does not resolve to a commit in this repository."
    }
    return $r.Lines[0]
}

function Test-OwAncestor([string]$Root, [string]$Ancestor, [string]$Descendant) {
    return ((Invoke-OwGit -Root $Root -Arguments @('merge-base', '--is-ancestor', $Ancestor, $Descendant) -AllowFailure).Code -eq 0)
}

function Get-OwTree([string]$Root, [string]$Commit) {
    return (Invoke-OwGit -Root $Root -Arguments @('rev-parse', "$Commit^{tree}")).Lines[0]
}

function Get-OwParents([string]$Root, [string]$Commit) {
    $line = (Invoke-OwGit -Root $Root -Arguments @('log', '-1', '--format=%P', $Commit)).Lines
    if ($line.Count -eq 0 -or [string]::IsNullOrWhiteSpace($line[0])) { return @() }
    return @($line[0].Trim() -split '\s+')
}

function Get-OwCommitFiles([string]$Root, [string]$Commit) {
    $parents = @(Get-OwParents $Root $Commit)
    if ($parents.Count -eq 0) {
        return @((Invoke-OwGit -Root $Root -Arguments @('ls-tree', '-r', '--name-only', $Commit)).Lines)
    }
    return @((Invoke-OwGit -Root $Root -Arguments @('diff', '--name-only', '--no-renames', $parents[0], $Commit)).Lines)
}

# Remote as "owner/repo" for GitHub, without any credential or local path.
function Get-OwRemoteSlug([string]$Root) {
    $r = Invoke-OwGit -Root $Root -Arguments @('remote', 'get-url', 'origin') -AllowFailure
    if ($r.Code -ne 0 -or $r.Lines.Count -eq 0) { return 'no-origin-remote' }
    if ($r.Lines[0] -match 'github\.com[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(\.git)?/?$') { return "$($Matches[1])/$($Matches[2])" }
    return 'non-github-remote'
}

function Get-OwBranch([string]$Root) {
    $r = Invoke-OwGit -Root $Root -Arguments @('branch', '--show-current') -AllowFailure
    if ($r.Lines.Count -eq 0 -or [string]::IsNullOrWhiteSpace($r.Lines[0])) { return '(detached)' }
    return $r.Lines[0]
}

# Working-tree state. The fingerprint covers staged, unstaged and untracked
# (non-ignored) content, so any uncommitted change produces a new fingerprint.
function Get-OwWorktreeState([string]$Root) {
    $status = @((Invoke-OwGit -Root $Root -Arguments @('status', '--porcelain=v1', '--untracked-files=all')).Lines)
    if ($status.Count -eq 0) { return [ordered]@{ clean = $true; entries = 0; fingerprint = $null } }
    $diff = (Invoke-OwGit -Root $Root -Arguments @('diff', '--binary', 'HEAD')).Lines -join "`n"
    $untracked = @((Invoke-OwGit -Root $Root -Arguments @('ls-files', '--others', '--exclude-standard')).Lines | Sort-Object)
    $parts = [System.Text.StringBuilder]::new()
    $null = $parts.Append($diff)
    foreach ($u in $untracked) {
        $full = Join-Path $Root $u
        $hash = if (Test-Path -LiteralPath $full -PathType Leaf) { Get-OwSha256File $full } else { 'missing' }
        $null = $parts.Append("`nuntracked:${u}:${hash}")
    }
    return [ordered]@{ clean = $false; entries = $status.Count; fingerprint = (Get-OwSha256Text $parts.ToString()) }
}

# Files changed between the merge base and the working tree (committed,
# staged, unstaged and untracked), each with its origin.
function Get-OwChangedFiles([string]$Root, [string]$MergeBase) {
    $map = [ordered]@{}
    foreach ($line in (Invoke-OwGit -Root $Root -Arguments @('diff', '--name-status', '--no-renames', $MergeBase, 'HEAD')).Lines) {
        $p = $line -split "`t"
        if ($p.Count -ge 2) { $map[$p[1]] = [ordered]@{ path = $p[1]; status = $p[0].Substring(0, 1); source = 'committed' } }
    }
    foreach ($line in (Invoke-OwGit -Root $Root -Arguments @('status', '--porcelain=v1', '--untracked-files=all', '--no-renames')).Lines) {
        if ($line.Length -lt 4) { continue }
        $path = $line.Substring(3).Trim('"')
        $code = $line.Substring(0, 2)
        $source = if ($code -eq '??') { 'untracked' } else { 'worktree' }
        $status = if ($code -eq '??') { 'A' } elseif ($code.Contains('D')) { 'D' } else { 'M' }
        $map[$path] = [ordered]@{ path = $path; status = $status; source = $source }
    }
    return @($map.Values)
}

# ---------------------------------------------------------------------------
# Change classification policy (ordered; first match wins). Unknown paths and
# changes spanning more than one module require L3. Security-critical surfaces
# can never be verified below their minimum level.
# ---------------------------------------------------------------------------
$script:OwPolicy = @(
    [ordered]@{ id = 'ci-workflow'; pattern = '^\.github/'; level = 'L3'; security = $true; module = 'ci' }
    [ordered]@{ id = 'sdk-pin-and-build-props'; pattern = '^(global\.json|local-router/global\.json|local-router/Directory\.(Build|Packages)\.props|local-router/[^/]+\.sln)$|(^|/)packages\.lock\.json$'; level = 'L3'; security = $true; module = 'build' }
    [ordered]@{ id = 'lr14-gate-and-shared'; pattern = '^tests/validate-local-router-lr14-scope(-regression)?\.ps1$|^tests/shared/'; level = 'L3'; security = $true; module = 'gate' }
    [ordered]@{ id = 'history-and-authorization-gates'; pattern = '^tests/validate-(dsr7c-apply-patch-(file-authorization(-regression)?|final-integration)|local-router-hs1b-rb1-scope|local-router-lr13-scope|oss-genesis|repo)\.ps1$|^tests/fixtures/oss-genesis/'; level = 'L3'; security = $true; module = 'gate' }
    [ordered]@{ id = 'installer'; pattern = '^installer/'; level = 'L3'; security = $true; module = 'installer' }
    [ordered]@{ id = 'skill-payload'; pattern = '^skill/'; level = 'L3'; security = $true; module = 'skill' }
    [ordered]@{ id = 'router-host-and-config'; pattern = '^local-router/src/Router\.Host/|^local-router/config/'; level = 'L3'; security = $true; module = 'router-host' }
    [ordered]@{ id = 'router-project'; pattern = '^local-router/(src|tests)/(?<proj>[A-Za-z0-9.]+)/'; level = 'L2'; security = $true; module = 'router:{proj}' }
    [ordered]@{ id = 'workflow-tools'; pattern = '^tools/oss-workflow/'; level = 'L2'; security = $false; module = 'workflow-tools' }
    [ordered]@{ id = 'validator'; pattern = '^tests/(?<leaf>validate-[A-Za-z0-9.-]+)\.ps1$'; level = 'L2'; security = $false; module = 'validator:{leaf}' }
    [ordered]@{ id = 'test-fixtures'; pattern = '^tests/fixtures/'; level = 'L2'; security = $false; module = 'fixtures' }
    [ordered]@{ id = 'documentation'; pattern = '(?i)^(docs/.+|[^/]+\.md|local-router/[^/]+\.md|LICENSE|NOTICE)$'; level = 'L1'; security = $false; module = 'docs' }
)

function Get-OwFileClassification([string]$Path) {
    foreach ($rule in $script:OwPolicy) {
        $m = [regex]::Match($Path, $rule.pattern)
        if ($m.Success) {
            $module = $rule.module
            if ($module.Contains('{proj}')) { $module = $module.Replace('{proj}', ($m.Groups['proj'].Value -replace '\.Tests$', '')) }
            if ($module.Contains('{leaf}')) { $module = $module.Replace('{leaf}', $m.Groups['leaf'].Value) }
            $project = if ($m.Groups['proj'].Success) { $m.Groups['proj'].Value } else { $null }
            return [ordered]@{ path = $Path; rule = $rule.id; level = $rule.level; security = $rule.security; module = $module; project = $project }
        }
    }
    return [ordered]@{ path = $Path; rule = 'unknown'; level = 'L3'; security = $true; module = "unknown:$Path"; project = $null }
}

function Get-OwLevelIndex([string]$Level) { return [array]::IndexOf($script:OwLevels, $Level) }

function Get-OwMaxLevel([string[]]$Levels) {
    $max = 'L1'
    foreach ($l in $Levels) { if ((Get-OwLevelIndex $l) -gt (Get-OwLevelIndex $max)) { $max = $l } }
    return $max
}

# True only when the LR-14 gate file differs from its merge-base version by a
# single contiguous insertion of new entries at the end of RegisteredSlices,
# with every existing entry and all other text unchanged. Anything else is a
# change to the gate itself.
function Test-OwRegistrationOnlyChange([string]$Root, [string]$MergeBase) {
    $rel = 'tests/validate-local-router-lr14-scope.ps1'
    $path = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $old = Invoke-OwGit -Root $Root -Arguments @('show', "${MergeBase}:$rel") -AllowFailure
    if ($old.Code -ne 0) { return $false }
    # git output drops the final newline, so both sides are compared without it.
    $oldText = ($old.Lines -join "`n").TrimEnd("`n")
    $newText = ([System.IO.File]::ReadAllText($path)).Replace("`r`n", "`n").TrimEnd("`n")
    if ($newText -ceq $oldText) { return $false }
    if ($newText.Length -le $oldText.Length) { return $false }
    # A single insertion: new = old[0..pre) + inserted + old[pre..end).
    $pre = 0; while ($pre -lt $oldText.Length -and $oldText[$pre] -ceq $newText[$pre]) { $pre++ }
    $tail = $oldText.Substring($pre)
    if (-not $newText.EndsWith($tail, [StringComparison]::Ordinal)) { return $false }   # something was removed or replaced
    $suf = $tail.Length
    $find = {
        param([string]$Text)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        $a = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:RegisteredSlices' }, $true)
        if (-not $a) { return $null }
        $arr = $a.Right.Find({ param($n) $n -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true)
        $entries = @($arr.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] -and $n.Parent -is [System.Management.Automation.Language.ConvertExpressionAst] }, $true) | ForEach-Object { $_.Parent.Extent.Text })
        return [pscustomobject]@{ Start = $arr.Extent.StartOffset; End = $arr.Extent.EndOffset; Entries = $entries }
    }
    $o = & $find $oldText; $n = & $find $newText
    if (-not $o -or -not $n) { return $false }
    if ($pre -lt $n.Start -or ($newText.Length - $suf) -gt $n.End) { return $false }   # insertion outside the array
    if ($n.Entries.Count -le $o.Entries.Count) { return $false }
    for ($i = 0; $i -lt $o.Entries.Count; $i++) { if ($n.Entries[$i] -cne $o.Entries[$i]) { return $false } }
    return $true
}

# Recommended (and minimum) level for a set of changed paths. With -Root and
# -MergeBase, a proven append-only LR-14 registration is classified as such.
function Get-OwVerificationPlan([string[]]$Paths, [string]$Root, [string]$MergeBase) {
    $files = @($Paths | Where-Object { $_ } | Sort-Object -Unique | ForEach-Object { Get-OwFileClassification $_ })
    if ($Root -and $MergeBase) {
        foreach ($f in $files | Where-Object { $_.path -ceq 'tests/validate-local-router-lr14-scope.ps1' }) {
            if (Test-OwRegistrationOnlyChange $Root $MergeBase) { $f.rule = 'lr14-registration-append'; $f.level = 'L2'; $f.module = 'lr14-registration' }
        }
    }
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($files.Count -eq 0) {
        $reasons.Add('no changed files relative to the base')
        return [ordered]@{ recommended = 'L1'; reasons = @($reasons); files = @(); modules = @() }
    }
    $level = Get-OwMaxLevel @($files | ForEach-Object { $_.level })
    foreach ($f in $files | Where-Object { $_.level -eq $level -and $level -ne 'L1' } | Select-Object -First 5) {
        $reasons.Add(("{0} -> {1} ({2})" -f $f.path, $f.level, $f.rule))
    }
    if (@($files | Where-Object { $_.rule -eq 'unknown' }).Count -gt 0) { $reasons.Add('unknown change scope defaults to L3') }
    # Documentation and the slice's own LR-14 registration never count as a second module.
    $modules = @($files | Where-Object { $_.module -notin @('docs', 'lr14-registration') } | ForEach-Object { $_.module } | Sort-Object -Unique)
    if ($modules.Count -gt 1 -and (Get-OwLevelIndex $level) -lt (Get-OwLevelIndex 'L3')) {
        $level = 'L3'
        $reasons.Add("cross-module change ($($modules.Count) modules: $(($modules | Select-Object -First 4) -join ', ')) upgrades to L3")
    }
    if ($level -eq 'L1') { $reasons.Add('documentation-only change') }
    return [ordered]@{ recommended = $level; reasons = @($reasons); files = $files; modules = $modules }
}

# ---------------------------------------------------------------------------
# .NET project graph: test projects that (transitively) reference a project.
# ---------------------------------------------------------------------------
function Get-OwAffectedTestProjects([string]$Root, [string[]]$Projects) {
    $routerRoot = Join-Path $Root 'local-router'
    if (-not (Test-Path -LiteralPath $routerRoot)) { return @() }
    $csprojs = @(Get-ChildItem -LiteralPath $routerRoot -Recurse -Filter '*.csproj' -File | Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' })
    $byName = @{}
    $refs = @{}
    foreach ($p in $csprojs) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($p.Name)
        $byName[$name] = [IO.Path]::GetRelativePath($Root, $p.FullName).Replace('\', '/')
        $xml = [xml](Get-Content -Raw -LiteralPath $p.FullName)
        $refs[$name] = @($xml.SelectNodes('//ProjectReference') | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Include.Replace('\', '/')) })
    }
    $affected = [System.Collections.Generic.HashSet[string]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($p in $Projects) { if ($p -and $affected.Add($p)) { $queue.Enqueue($p) } }
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        foreach ($name in $refs.Keys) { if ($refs[$name] -contains $cur -and $affected.Add($name)) { $queue.Enqueue($name) } }
    }
    return @($affected | Where-Object { $_ -match '\.Tests$' -and $byName.ContainsKey($_) } | Sort-Object | ForEach-Object { $byName[$_] })
}

# Validators whose source references a changed path, project or script name.
function Select-OwValidators([string]$Root, [object[]]$Files) {
    $validators = @((Invoke-OwGit -Root $Root -Arguments @('ls-files', 'tests/validate-*.ps1')).Lines)
    $needles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $selected = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($f in $Files) {
        if ($f.module -in @('docs', 'workflow-tools', 'lr14-registration')) { continue }
        $null = $needles.Add($f.path)
        if ($f.project) { $null = $needles.Add($f.project) }
        if ($f.path -match '\.(ps1|psm1|cmd)$') { $null = $needles.Add([System.IO.Path]::GetFileName($f.path)) }
        if ($f.path -match '^tests/validate-[^/]+\.ps1$' -and (Test-Path -LiteralPath (Join-Path $Root $f.path))) { $null = $selected.Add($f.path) }
    }
    if ($needles.Count -gt 0) {
        foreach ($v in $validators) {
            $text = Get-Content -Raw -LiteralPath (Join-Path $Root $v)
            foreach ($n in $needles) { if ($text.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $null = $selected.Add($v); break } }
        }
    }
    return @($selected | Sort-Object)
}

# ---------------------------------------------------------------------------
# Environment fingerprint. Any difference makes an earlier receipt unusable.
# ---------------------------------------------------------------------------
function Get-OwEnvironment([string]$Root) {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    $sdk = 'unavailable'; $sdks = ''
    if ($dotnet) {
        Push-Location -LiteralPath $Root
        try {
            $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { $v = @(& dotnet --version 2>&1); $code = $LASTEXITCODE; $list = @(& dotnet --list-sdks 2>&1) } finally { $ErrorActionPreference = $previous }
            $sdk = if ($code -eq 0) { ([string]($v | Select-Object -Last 1)).Trim() } else { "unresolved(exit $code)" }
            $sdks = (@($list | ForEach-Object { ([string]$_) -replace '\s*\[.*\]\s*$', '' }) -join ',')
        }
        finally { Pop-Location }
    }
    $gitVersion = ((Invoke-OwGit -Root $Root -Arguments @('--version')).Lines -join '') -replace '^git version\s*', ''
    return [ordered]@{
        os = [System.Environment]::OSVersion.VersionString
        pwsh = $PSVersionTable.PSVersion.ToString()
        git = $gitVersion
        dotnet_sdk_at_repository_root = $sdk
        dotnet_sdks_installed = $sdks
        runner = if ($env:GITHUB_ACTIONS -eq 'true') { 'github-actions' } else { 'local' }
        image_os = [string]$env:ImageOS
        image_version = [string]$env:ImageVersion
        machine_sha256 = Get-OwSha256Text ([System.Environment]::MachineName)
    }
}

function Get-OwToolFingerprint() {
    $files = @(Get-ChildItem -LiteralPath $script:OwToolRoot -File | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.json') } | Sort-Object Name)
    $map = [ordered]@{}
    foreach ($f in $files) { $map[$f.Name] = Get-OwSha256File $f.FullName }
    return [ordered]@{ version = $script:OwToolVersion; files = $map; sha256 = (Get-OwSha256Text (($map.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';')) }
}

function Get-OwReceiptKey([System.Collections.IDictionary]$Inputs) {
    return Get-OwSha256Text ($Inputs | ConvertTo-Json -Depth 20 -Compress)
}

# ---------------------------------------------------------------------------
# Receipts: written with a self hash over the exact file text (hash field
# blanked), so any edit is detected. Receipts are local evidence only.
# ---------------------------------------------------------------------------
function Get-OwReceiptDirectory([string]$Root) {
    return Join-Path (Get-OwGitDirectory $Root) 'oss-workflow/receipts'
}

function Write-OwReceipt([System.Collections.IDictionary]$Receipt, [string]$Directory) {
    $null = New-Item -ItemType Directory -Force -Path $Directory
    $Receipt['receipt_sha256'] = ''
    $json = $Receipt | ConvertTo-Json -Depth 20
    $hash = Get-OwSha256Text $json
    $final = $json.Replace('"receipt_sha256": ""', ('"receipt_sha256": "{0}"' -f $hash))
    $name = '{0}-{1}-{2}.json' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')), $Receipt['level_executed'], $hash.Substring(0, 12)
    $path = Join-Path $Directory $name
    [System.IO.File]::WriteAllText($path, $final, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Read-OwReceipt([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path)
    $m = [regex]::Match($text, '"receipt_sha256": "([0-9a-f]{64})"')
    $intact = $false
    if ($m.Success) {
        $blank = $text.Replace($m.Value, '"receipt_sha256": ""')
        $intact = ((Get-OwSha256Text $blank) -ceq $m.Groups[1].Value)
    }
    $obj = $null
    try { $obj = $text | ConvertFrom-Json -DateKind String } catch { $obj = $null }
    $schemaOk = ($null -ne $obj -and $obj.PSObject.Properties.Name -contains 'schema' -and $obj.schema -ceq $script:OwReceiptSchema)
    return [pscustomobject]@{ Path = $Path; Receipt = $obj; Intact = ($intact -and $schemaOk) }
}

# Why a receipt does not describe the current state (empty = still current).
function Get-OwReceiptStaleReasons([object]$Receipt, [System.Collections.IDictionary]$Current) {
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($Receipt.commit_sha -cne $Current.commit_sha) { $reasons.Add('commit changed') }
    if ($Receipt.tree_sha -cne $Current.tree_sha) { $reasons.Add('tree changed') }
    if ([string]$Receipt.worktree.fingerprint -cne [string]$Current.worktree.fingerprint -or [bool]$Receipt.worktree.clean -ne [bool]$Current.worktree.clean) { $reasons.Add('uncommitted changes differ') }
    if ($Receipt.merge_base_sha -cne $Current.merge_base_sha) { $reasons.Add('base changed') }
    foreach ($k in $Current.environment.Keys) {
        $old = if ($Receipt.environment.PSObject.Properties.Name -contains $k) { [string]$Receipt.environment.$k } else { '<missing>' }
        if ($old -cne [string]$Current.environment[$k]) { $reasons.Add("environment changed: $k") }
    }
    if ($Receipt.tool.sha256 -cne $Current.tool.sha256) { $reasons.Add('verification tool changed') }
    return @($reasons)
}

# ---------------------------------------------------------------------------
# LR-14 registry (read-only, via the PowerShell AST; no gate code executes).
# ---------------------------------------------------------------------------
function Get-OwLr14Registry([string]$Root) {
    $gate = Join-Path $Root 'tests/validate-local-router-lr14-scope.ps1'
    if (-not (Test-Path -LiteralPath $gate -PathType Leaf)) { Stop-OwError 'GATE_NOT_FOUND' 'tests/validate-local-router-lr14-scope.ps1 is missing.' }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($gate, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { Stop-OwError 'GATE_UNPARSABLE' 'The LR-14 gate file does not parse.' }
    $assign = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
    $gateFiles = @()
    $gateAssign = $assign | Where-Object { $_.Left.Extent.Text -ceq '$script:GateFiles' } | Select-Object -First 1
    if ($gateAssign) { $gateFiles = @($gateAssign.Right.Find({ param($n) $n -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true).SafeGetValue()) }
    $slicesAssign = $assign | Where-Object { $_.Left.Extent.Text -ceq '$script:RegisteredSlices' } | Select-Object -First 1
    if (-not $slicesAssign) { Stop-OwError 'GATE_UNPARSABLE' 'RegisteredSlices was not found in the LR-14 gate.' }
    $tables = @($slicesAssign.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] -and $n.Parent -is [System.Management.Automation.Language.ConvertExpressionAst] }, $true))
    $slices = [System.Collections.Generic.List[object]]::new()
    $unparsed = 0
    foreach ($t in $tables) {
        try {
            $h = $t.SafeGetValue()
            $slices.Add([pscustomobject]@{ Name = [string]$h['Name']; Base = [string]$h['Base']; Tip = [string]$h['Tip']; Artifacts = @($h['Artifacts']); Markers = $h['Markers'] })
        }
        catch { $unparsed++ }
    }
    return [pscustomobject]@{ GatePath = $gate; GateFiles = $gateFiles; Slices = @($slices); Unparsed = $unparsed }
}

# ---------------------------------------------------------------------------
# Commit identity privacy. Values are compared, never printed.
# ---------------------------------------------------------------------------
function Get-OwApprovedIdentities([string]$Path = (Join-Path $script:OwToolRoot 'approved-identities.json')) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-OwError 'IDENTITY_POLICY_MISSING' 'approved-identities.json is missing.' }
    $p = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    if ($p.schema -cne 'oss-workflow.approved-identities/v1') { Stop-OwError 'IDENTITY_POLICY_INVALID' 'Unknown identity policy schema.' }
    return $p
}

function Find-OwIdentity([object[]]$Entries, [string]$Name, [string]$Email) {
    foreach ($e in $Entries) { if ($e.name -ceq $Name -and $e.email -ceq $Email) { return [string]$e.label } }
    return $null
}

function Test-OwMessageEmails([string]$Text, [object]$Policy) {
    $bad = 0
    foreach ($m in [regex]::Matches($Text, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}')) {
        $v = $m.Value
        $ok = $false
        foreach ($a in $Policy.message_email_exact) { if ($v -ceq $a) { $ok = $true } }
        foreach ($s in $Policy.message_email_suffix) { if ($v.EndsWith($s, [StringComparison]::Ordinal)) { $ok = $true } }
        if (-not $ok) { $bad++ }
    }
    return $bad
}

# Checks every commit in Base..Head plus the effective local identity.
function Test-OwIdentityPrivacy([string]$Root, [string]$BaseSha, [string]$HeadSha, [object]$Policy) {
    $results = [System.Collections.Generic.List[object]]::new()
    $sep = [char]0x1f
    $fmt = "%H$sep%an$sep%ae$sep%cn$sep%ce$sep%P"
    $lines = @((Invoke-OwGit -Root $Root -Arguments @('log', "--format=$fmt", "$BaseSha..$HeadSha")).Lines)
    foreach ($line in $lines) {
        $f = $line -split [regex]::Escape([string]$sep)
        if ($f.Count -lt 6) { continue }
        $short = $f[0].Substring(0, 12)
        $isMerge = (@($f[5].Trim() -split '\s+' | Where-Object { $_ }).Count -gt 1)
        $authorLabel = Find-OwIdentity @($Policy.author) $f[1] $f[2]
        $results.Add([pscustomobject]@{ commit = $short; field = 'author'; ok = [bool]$authorLabel; label = $(if ($authorLabel) { $authorLabel } else { 'not-approved' }) })
        $committerLabel = Find-OwIdentity @($Policy.committer) $f[3] $f[4]
        if ($committerLabel -and @($Policy.committer_requires_approved_author) -contains $committerLabel -and -not $authorLabel) { $committerLabel = $null }
        if ($committerLabel -and @($Policy.committer_merge_only) -contains $committerLabel -and -not $isMerge) { $committerLabel = $null }
        $results.Add([pscustomobject]@{ commit = $short; field = 'committer'; ok = [bool]$committerLabel; label = $(if ($committerLabel) { $committerLabel } else { 'not-approved' }) })
        $message = (Invoke-OwGit -Root $Root -Arguments @('log', '-1', '--format=%B', $f[0])).Lines -join "`n"
        $badMail = Test-OwMessageEmails $message $Policy
        $results.Add([pscustomobject]@{ commit = $short; field = 'message'; ok = ($badMail -eq 0); label = $(if ($badMail -eq 0) { 'no-unapproved-address' } else { "unapproved-address-count=$badMail" }) })
    }
    # Effective local identity (config of this repository plus environment overrides).
    $cfgName = (Invoke-OwGit -Root $Root -Arguments @('config', '--get', 'user.name') -AllowFailure).Lines
    $cfgMail = (Invoke-OwGit -Root $Root -Arguments @('config', '--get', 'user.email') -AllowFailure).Lines
    $localName = if ($cfgName.Count -gt 0) { $cfgName[0] } else { '' }
    $localMail = if ($cfgMail.Count -gt 0) { $cfgMail[0] } else { '' }
    $localLabel = if ($localName -and $localMail) { Find-OwIdentity @($Policy.local_config) $localName $localMail } else { $null }
    $results.Add([pscustomobject]@{ commit = '(local)'; field = 'git-config'; ok = [bool]$localLabel; label = $(if ($localLabel) { $localLabel } elseif (-not $localName -or -not $localMail) { 'unset' } else { 'not-approved' }) })
    foreach ($pair in @(@('GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'env-author'), @('GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'env-committer'))) {
        $n = [Environment]::GetEnvironmentVariable($pair[0]); $e = [Environment]::GetEnvironmentVariable($pair[1])
        if ($n -or $e) {
            $lab = Find-OwIdentity @($Policy.local_config) ([string]$n) ([string]$e)
            $results.Add([pscustomobject]@{ commit = '(local)'; field = $pair[2]; ok = [bool]$lab; label = $(if ($lab) { $lab } else { 'not-approved' }) })
        }
    }
    return @($results)
}

# ---------------------------------------------------------------------------
# CI workflow steps, read from .github/workflows/ci.yml (the single source of
# truth for the L3/L4 step set; nothing is copied into this tool).
# ---------------------------------------------------------------------------
function Get-OwWorkflowSteps([string]$Root) {
    $path = Join-Path $Root '.github/workflows/ci.yml'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-OwError 'WORKFLOW_NOT_FOUND' '.github/workflows/ci.yml is missing.' }
    $lines = @(Get-Content -LiteralPath $path)
    $steps = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^(\s*)- name:\s*(.+?)\s*$') {
            if ($cur) { $steps.Add([pscustomobject]$cur) }
            $cur = [ordered]@{ index = $steps.Count + 1; name = $Matches[2]; indent = $Matches[1].Length; run = $null; uses = $null; shell = $null; condition = $null }
            continue
        }
        if (-not $cur) { continue }
        $keyIndent = $cur.indent + 2
        if ($line -match "^\s{$keyIndent}(run|uses|shell|if):\s*(.*?)\s*$") {
            $key = $Matches[1]; $value = $Matches[2]
            if ($key -eq 'run' -and $value -in @('|', '|-', '>', '>-')) {
                $block = [System.Collections.Generic.List[string]]::new()
                $j = $i + 1
                while ($j -lt $lines.Count -and ($lines[$j] -match "^\s{$($keyIndent + 2)}" -or [string]::IsNullOrWhiteSpace($lines[$j]))) {
                    $block.Add($(if ($lines[$j].Length -ge $keyIndent + 2) { $lines[$j].Substring($keyIndent + 2) } else { '' })); $j++
                }
                $value = ($block -join "`n").TrimEnd()
                $i = $j - 1
            }
            switch ($key) { 'run' { $cur.run = $value } 'uses' { $cur.uses = $value } 'shell' { $cur.shell = $value } 'if' { $cur.condition = $value } }
        }
    }
    if ($cur) { $steps.Add([pscustomobject]$cur) }
    return @($steps)
}

# Runs a PowerShell script in a child pwsh with the repository root as the
# working directory and optional extra environment variables.
function Invoke-OwPwshFile([string]$Root, [string]$File, [string[]]$Arguments = @(), [hashtable]$Environment = @{}) {
    $pwsh = (Get-Process -Id $PID).Path
    $saved = @{}
    foreach ($k in $Environment.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$Environment[$k]) }
    Push-Location -LiteralPath $Root
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& $pwsh -NoLogo -NoProfile -File $File @Arguments 2>&1 | ForEach-Object { [string]$_ }); $code = $LASTEXITCODE }
    finally {
        $ErrorActionPreference = $previous
        Pop-Location
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    return [pscustomobject]@{ Code = $code; Lines = $out }
}

function Invoke-OwNative([string]$Root, [string]$Command, [string[]]$Arguments, [hashtable]$Environment = @{}) {
    $saved = @{}
    foreach ($k in $Environment.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$Environment[$k]) }
    Push-Location -LiteralPath $Root
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& $Command @Arguments 2>&1 | ForEach-Object { [string]$_ }); $code = $LASTEXITCODE }
    finally {
        $ErrorActionPreference = $previous
        Pop-Location
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    return [pscustomobject]@{ Code = $code; Lines = $out }
}

Export-ModuleMember -Function *-Ow* -Variable OwToolVersion, OwReceiptSchema, OwLevels
