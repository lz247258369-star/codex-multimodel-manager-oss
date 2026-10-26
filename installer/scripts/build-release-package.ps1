param(
    [Parameter(Mandatory = $false)][string]$SourceRoot = "",

    [Parameter(Mandatory = $false)][string]$OutputRoot = "",

    [Parameter(Mandatory = $false)][string]$Version = "",

    # The commit the package content is exported from. When omitted the source
    # repository's HEAD is used. It is never accepted as an arbitrary claim: the
    # value must resolve inside the source repository and must equal its HEAD, so
    # the packaged bytes always come from a commit that is actually checked out.
    [Parameter(Mandatory = $false)][string]$SourceCommit = "",

    [Parameter(Mandatory = $false)][string]$PackageName = "codex-multimodel-manager",

    # Explicit allow list. Only tracked files that match one of these entries can
    # enter a package; "dir/**" selects a directory, "*" is a wildcard, anything
    # else is an exact relative path. There is no "package everything" mode.
    [Parameter(Mandatory = $false)][string[]]$Include = @(
        "installer/**",
        "skill/**",
        "local-router/**",
        "docs/**",
        "tests/**",
        "README.md",
        "CHANGELOG.md",
        "AGENTS.md",
        "manifest.json",
        ".gitignore"),

    [Parameter(Mandatory = $false)][string[]]$EntryPoints = @("installer/ONE_CLICK_SETUP.cmd"),

    [Parameter(Mandatory = $false)][string]$UninstallEntry = "",

    [Parameter(Mandatory = $false)][switch]$Verify,

    [Parameter(Mandatory = $false)][string]$VerifyTarget = "",

    # Optional: the source repository a verification must resolve the recorded
    # source_commit against.
    [Parameter(Mandatory = $false)][string]$VerifySourceRoot = ""
)

# LR15-PR6: verifiable release package builder + provenance verifier.
#
# A release package is a BUILT artifact. Its bytes are exported with
# `git archive` from one commit of a real repository, never copied from a
# working tree, so uncommitted edits, local runtime state and user configuration
# can never leak into a package. Only tracked files matching the explicit allow
# list are packaged; every packaged file is hashed into release-manifest.json
# together with the product version, the source commit, the build time, the
# documented entry points and a package-wide digest.
#
# Exit codes (bounded and explicit):
#   0  success (package built, or -Verify passed)
#   2  usage / parameter error
#   3  provenance error (missing, malformed, unresolvable or non-HEAD commit)
#   4  policy violation (allow/deny list, unsafe path, entry point not packaged)
#   6  verification failure (-Verify found content or manifest problems)
#
# What this proves: content integrity and provenance of THIS artifact.
# What it does NOT claim: byte-for-byte reproducibility across machines, code
# signing, or any trusted third-party attestation.

$ErrorActionPreference = "Stop"

function Write-Problem([string]$Message) {
    Write-Host "  - $Message" -ForegroundColor Red
}

function Get-Sha256Hex([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-GitText([string]$Directory, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(& git -C $Directory @Arguments 2>$null)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $code; Text = ((@($lines | Where-Object { $_ -is [string] }) -join "`n").Trim()) }
}

function Get-PackageDigest([object[]]$Files) {
    $lines = $Files | ForEach-Object { "$($_.path):$($_.sha256)" } | Sort-Object
    $text = ($lines -join "`n") + "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)))).Replace("-", "").ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

# Patterns that must never be packaged. A match is a hard failure: the builder
# refuses to produce a package instead of silently dropping the file.
$script:DenyPatterns = @(
    '(^|/)\.git(/|$)',
    '(^|/)\.github(/|$)',
    '(^|/)\.env$',
    '(^|/)\.env\..*$',
    '(^|/)auth\.json$',
    '(^|/)state\.json$',
    '(^|/)candidates\.json$',
    '(^|/)approved-models\.json$',
    '(^|/)discovered-models\.json$',
    '(^|/)discovery-baseline\.json$',
    '(^|/)model-history\.jsonl$',
    '\.(key|pem|p12|pfx)$',
    '\.(sqlite|sqlite3|db)$',
    '(^|/)backups(/|$)',
    '(^|/)handoffs(/|$)',
    '(^|/)reports(/|$)',
    '(^|/)bin(/|$)',
    '(^|/)obj(/|$)'
)

function Test-Includes([string]$Path, [string[]]$Patterns) {
    foreach ($pattern in $Patterns) {
        if ($pattern.EndsWith('/**')) {
            $prefix = $pattern.Substring(0, $pattern.Length - 3)
            if ($Path -eq $prefix -or $Path.StartsWith($prefix + '/', [System.StringComparison]::Ordinal)) { return $true }
            continue
        }

        if ($Path -eq $pattern) { return $true }
        if ($pattern.Contains('*')) {
            $regex = '^' + [regex]::Escape($pattern).Replace('\*', '[^/]*') + '$'
            if ($Path -match $regex) { return $true }
        }
    }

    return $false
}

function Test-Denied([string]$Path) {
    foreach ($pattern in $script:DenyPatterns) {
        if ($Path -match $pattern) { return $true }
    }

    return $false
}

function Test-UnsafePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    if ($Path.Contains('\')) { return $true }
    if ($Path.StartsWith('/')) { return $true }
    if ($Path -match '^[A-Za-z]:') { return $true }
    foreach ($segment in $Path.Split('/')) {
        if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..') { return $true }
    }

    return $false
}

if ($Verify) {
    $failures = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($VerifyTarget) -or -not (Test-Path -LiteralPath $VerifyTarget -PathType Container)) {
        Write-Host "Verify requires -VerifyTarget pointing at a package directory." -ForegroundColor Red
        exit 2
    }

    $packageDir = (Resolve-Path -LiteralPath $VerifyTarget).Path
    $manifestPath = Join-Path $packageDir "release-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Write-Host "release-manifest.json is missing." -ForegroundColor Red
        exit 6
    }

    try {
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    }
    catch {
        Write-Host "release-manifest.json is not valid JSON." -ForegroundColor Red
        exit 6
    }

    if ([int]$manifest.schema_version -ne 1) { $failures.Add("schema_version must be 1") }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.product)) { $failures.Add("product is missing") }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.version)) { $failures.Add("version is missing") }
    if ([string]$manifest.source_commit -notmatch '^[0-9a-f]{40}$') { $failures.Add("source_commit is not a 40-hex commit") }
    if ([string]$manifest.package_sha256 -notmatch '^[0-9a-f]{64}$') { $failures.Add("package_sha256 is not a 64-hex digest") }

    if (-not [string]::IsNullOrWhiteSpace($VerifySourceRoot)) {
        $sourcePath = (Resolve-Path -LiteralPath $VerifySourceRoot).Path
        $resolved = Get-GitText $sourcePath @("rev-parse", "--verify", "--quiet", ("{0}^{{commit}}" -f [string]$manifest.source_commit))
        if ($resolved.ExitCode -ne 0 -or $resolved.Text -notmatch '^[0-9a-f]{40}$') {
            $failures.Add("source_commit $([string]$manifest.source_commit) does not resolve in the source repository")
        }
    }

    $listed = New-Object System.Collections.Generic.List[string]
    $entries = @($manifest.files)
    foreach ($entry in $entries) {
        $relative = [string]$entry.path
        if (Test-UnsafePath $relative) { $failures.Add("unsafe manifest path: $relative"); continue }
        if (Test-Denied $relative) { $failures.Add("manifest path violates the deny list: $relative"); continue }
        $listed.Add($relative)
        $path = Join-Path $packageDir $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $failures.Add("missing file: $relative"); continue }
        if ((Get-Sha256Hex $path) -ne [string]$entry.sha256) { $failures.Add("content mismatch: $relative") }
        if ((Get-Item -LiteralPath $path).Length -ne [long]$entry.size) { $failures.Add("size mismatch: $relative") }
    }

    $actual = @(Get-ChildItem -LiteralPath $packageDir -Recurse -File |
            Where-Object { $_.Name -ne "release-manifest.json" } |
            ForEach-Object { $_.FullName.Substring($packageDir.Length).TrimStart('\', '/').Replace('\', '/') })
    foreach ($extra in @($actual | Where-Object { $_ -notin $listed })) { $failures.Add("file not listed in the manifest: $extra") }
    foreach ($missing in @($listed | Where-Object { $_ -notin $actual })) {
        if (-not ($failures -contains "missing file: $missing")) { $failures.Add("missing file: $missing") }
    }

    if ($listed.Count -ne [int]$manifest.file_count) { $failures.Add("file_count $([int]$manifest.file_count) does not match the manifest list ($($listed.Count))") }
    if ((Get-PackageDigest $entries) -ne [string]$manifest.package_sha256) { $failures.Add("package digest mismatch") }

    if ($failures.Count -gt 0) {
        Write-Host "Package verification FAILED ($($failures.Count) problem(s)):" -ForegroundColor Red
        foreach ($failure in $failures) { Write-Problem $failure }
        exit 6
    }

    Write-Host ("Package verification PASSED: {0} file(s), commit {1}, digest {2}..." -f $listed.Count, ([string]$manifest.source_commit).Substring(0, 8), ([string]$manifest.package_sha256).Substring(0, 16)) -ForegroundColor Green
    exit 0
}

if ([string]::IsNullOrWhiteSpace($SourceRoot) -or -not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    Write-Host "A source checkout is required (-SourceRoot)." -ForegroundColor Red
    exit 2
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Write-Host "-OutputRoot is required." -ForegroundColor Red
    exit 2
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    Write-Host "-Version is required." -ForegroundColor Red
    exit 2
}

$source = (Resolve-Path -LiteralPath $SourceRoot).Path
$head = Get-GitText $source @("rev-parse", "--verify", "--quiet", "HEAD^{commit}")
if ($head.ExitCode -ne 0 -or $head.Text -notmatch '^[0-9a-f]{40}$') {
    Write-Host "The source root is not a git checkout: a plain directory is never a release." -ForegroundColor Red
    exit 3
}

$commit = $SourceCommit
if ([string]::IsNullOrWhiteSpace($commit)) { $commit = $head.Text }
if ($commit -notmatch '^[0-9a-f]{40}$') {
    Write-Host "A 40-hex source commit is required; the packaged content must come from a real commit." -ForegroundColor Red
    exit 3
}

$resolved = Get-GitText $source @("rev-parse", "--verify", "--quiet", ("{0}^{{commit}}" -f $commit))
if ($resolved.ExitCode -ne 0 -or $resolved.Text -ne $commit) {
    Write-Host "source_commit $commit does not resolve to a commit in this repository." -ForegroundColor Red
    exit 3
}
if ($commit -ne $head.Text) {
    Write-Host "source_commit $commit is not the checkout HEAD ($($head.Text.Substring(0, 8))); refusing to label another state as the build source." -ForegroundColor Red
    exit 3
}

$dirty = (Get-GitText $source @("status", "--porcelain")).Text.Length -gt 0

$treeFiles = Get-GitText $source @("ls-tree", "-r", "--name-only", $commit)
if ($treeFiles.ExitCode -ne 0) {
    Write-Host "Unable to list the tracked files of $commit." -ForegroundColor Red
    exit 3
}

$selected = New-Object System.Collections.Generic.List[string]
$policyProblems = New-Object System.Collections.Generic.List[string]
foreach ($path in @($treeFiles.Text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    if (-not (Test-Includes $path $Include)) { continue }
    if (Test-UnsafePath $path) { $policyProblems.Add("unsafe tracked path: $path"); continue }
    if (Test-Denied $path) { $policyProblems.Add("sensitive or excluded path would be packaged: $path"); continue }
    $selected.Add($path)
}

foreach ($entryPoint in @($EntryPoints | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    if ($entryPoint -notin $selected) { $policyProblems.Add("entry point is not part of the packaged allow list: $entryPoint") }
}
if (-not [string]::IsNullOrWhiteSpace($UninstallEntry) -and $UninstallEntry -notin $selected) {
    $policyProblems.Add("uninstall entry is not part of the packaged allow list: $UninstallEntry")
}
if ($selected.Count -eq 0) { $policyProblems.Add("the allow list selected no tracked file") }

if ($policyProblems.Count -gt 0) {
    Write-Host "Release package refused ($($policyProblems.Count) policy problem(s)):" -ForegroundColor Red
    foreach ($problem in $policyProblems) { Write-Problem $problem }
    exit 4
}

$resolvedOutput = (Resolve-Path -LiteralPath $OutputRoot).Path
$packageDir = Join-Path $resolvedOutput ("$PackageName-$Version-" + $commit.Substring(0, 8))
$archivePath = Join-Path $resolvedOutput (".release-archive-" + [guid]::NewGuid().ToString("N") + ".tar")
$extractDir = Join-Path $resolvedOutput (".release-extract-" + [guid]::NewGuid().ToString("N"))

try {
    $archive = Get-GitText $source @("archive", "--format=tar", ("--output={0}" -f $archivePath), $commit)
    if ($archive.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        Write-Host "git archive failed for commit $commit." -ForegroundColor Red
        exit 3
    }

    if (Test-Path -LiteralPath $packageDir) { Remove-Item -LiteralPath $packageDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $packageDir, $extractDir
    [System.Formats.Tar.TarFile]::ExtractToDirectory($archivePath, $extractDir, $true)

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($relative in $selected) {
        $sourcePath = Join-Path $extractDir ($relative.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            Write-Host "Commit $commit does not contain the selected file: $relative" -ForegroundColor Red
            exit 3
        }

        $destination = Join-Path $packageDir ($relative.Replace('/', '\'))
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination)
        Copy-Item -LiteralPath $sourcePath -Destination $destination -Force
        $files.Add([ordered]@{
                path   = $relative
                size   = (Get-Item -LiteralPath $destination).Length
                sha256 = (Get-Sha256Hex $destination)
            })
    }

    $fileArray = $files.ToArray()
    $manifest = [ordered]@{}
    $manifest["schema_version"] = 1
    $manifest["product"] = $PackageName
    $manifest["version"] = $Version
    $manifest["source_commit"] = $commit
    $manifest["source_dirty"] = $dirty
    $manifest["built_at_utc"] = (Get-Date).ToUniversalTime().ToString("o")
    $manifest["entry_points"] = @($EntryPoints)
    $manifest["uninstall_entry"] = $UninstallEntry
    $manifest["file_count"] = $fileArray.Count
    $manifest["files"] = $fileArray
    $manifest["package_sha256"] = (Get-PackageDigest $fileArray)
    $manifest["content_source"] = "git archive of the recorded source_commit; the working tree is never copied"
    $manifest["reproducibility"] = "content integrity of this artifact only; cross-machine byte-for-byte reproducibility and code signing are not claimed"
    $manifestPath = Join-Path $packageDir "release-manifest.json"
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    Write-Host "Package built: $packageDir" -ForegroundColor Green
    Write-Host ("  source {0}  version {1}  files {2}  digest {3}" -f $commit.Substring(0, 8), $Version, $fileArray.Count, ([string]$manifest.package_sha256).Substring(0, 16))
    exit 0
}
finally {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
}
