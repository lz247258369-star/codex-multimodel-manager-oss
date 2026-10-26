# LR15-PR7: isolated package installation and ownership-only removal planning.
# No user Codex configuration, provider secrets or host startup.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:OwnershipFile = 'router-install-ownership.json'

function Assert-RouterPlainPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point / symbolic link refused: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $full
}

function Assert-RouterRelativePath([string]$Relative) {
    # Windows semantics apply on every OS: no ADS, device names, ambiguous
    # separators, trailing dots/spaces, traversal or case-colliding entries.
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative.Contains('\') -or
        $Relative.StartsWith('/') -or $Relative.Contains(':')) { throw 'Unsafe relative path' }
    foreach ($part in $Relative.Split('/')) {
        if ($part -in @('', '.', '..') -or $part -match '[\x00-\x1f<>"|?*]' -or
            $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') {
            throw "Unsafe Windows path component: $part"
        }
        if ($part -match '^(?i:\.codex|\.git|\.env(?:\..*)?|auth\.json|config\.toml|router\.config\.json|state\.json|backups|logs|reports|handoffs)$' -or
            $part -match '(?i)\.(key|pem|p12|pfx|sqlite|sqlite3|db)$') { throw "Preserved user/runtime path: $Relative" }
    }
    if ($Relative -ieq $script:OwnershipFile) { throw 'Reserved ownership filename' }
}

function Get-RouterTreeFiles([string]$Root) {
    $null = Assert-RouterPlainPath $Root
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked entry refused: $($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            else { $item.FullName }
        }
    }
}

function Assert-RouterObjectFields($Object, [string[]]$Fields) {
    if ($null -eq $Object) { throw 'Missing object' }
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    if (($actual -join '|') -cne (($Fields | Sort-Object) -join '|')) { throw 'Unknown or missing manifest fields' }
}

function Get-RouterVerifiedPackage([string]$PackageRoot, [string]$ExpectedPackageSha256) {
    $root = Assert-RouterPlainPath $PackageRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Package directory missing' }
    $null = @(Get-RouterTreeFiles $root)
    if ($ExpectedPackageSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Expected package digest required' }
    # Reuse PR6 verification in a child process: it must really return exit 0.
    $hostPath = (Get-Process -Id $PID).Path
    $output = & $hostPath -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'build-release-package.ps1') -Verify -VerifyTarget $root 2>&1
    if ($LASTEXITCODE -ne 0) { throw "PR6 package verification failed: $($output -join ' ')" }
    $release = Get-Content -LiteralPath (Join-Path $root 'release-manifest.json') -Raw | ConvertFrom-Json
    if ($release.product -cne 'codex-multimodel-manager' -or $release.package_sha256 -cne $ExpectedPackageSha256) {
        throw 'Unexpected product or package digest'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = @(
        foreach ($entry in $release.files) {
            Assert-RouterRelativePath $entry.path
            if (-not $seen.Add($entry.path) -or $entry.path -ieq 'release-manifest.json') { throw 'Duplicate or reserved package path' }
            [pscustomobject]@{ path = [string]$entry.path; size = [long]$entry.size; sha256 = [string]$entry.sha256 }
        }
    )
    $provenance = Join-Path $root 'release-manifest.json'
    $files += [pscustomobject]@{ path = 'release-manifest.json'; size = (Get-Item -LiteralPath $provenance).Length; sha256 = (Get-FileHash -LiteralPath $provenance -Algorithm SHA256).Hash.ToLowerInvariant() }
    return [pscustomobject]@{ root = $root; release = $release; files = $files }
}

function Install-RouterOwnedPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ExpectedPackageSha256
    )
    $package = Get-RouterVerifiedPackage $PackageRoot $ExpectedPackageSha256
    $root = Assert-RouterPlainPath $InstallRoot
    # Never adopt, overwrite or recursively merge any existing destination.
    if (Test-Path -LiteralPath $root) { throw 'Install destination already exists; ownership cannot be adopted' }
    if ($root -match '(?i)(^|[\\/])\.codex([\\/]|$)') { throw 'Codex user directory is never an install destination' }
    $parent = [IO.Path]::GetDirectoryName($root)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Install parent must already exist' }
    $id = [guid]::NewGuid().ToString('D')
    $stage = Join-Path $parent ('.router-install-stage-' + $id)
    if (Test-Path -LiteralPath $stage) { throw 'Staging directory collision' }
    $null = New-Item -ItemType Directory -Path $stage
    # Failed staging is deliberately retained, never recursively deleted: an
    # unexpected concurrent/user file must not become a cleanup casualty.
    foreach ($entry in $package.files) {
        $source = Assert-RouterPlainPath (Join-Path $package.root $entry.path)
        $target = Join-Path $stage $entry.path
        $null = New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy($source, $target, $false)
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256 -or
            (Get-Item -LiteralPath $target).Length -ne $entry.size) { throw 'Package changed during copy; staging retained' }
    }
    $manifest = [ordered]@{
        schema_version = 1
        product = 'codex-multimodel-manager'
        installation_id = $id
        install_root = $root
        version = [string]$package.release.version
        source_commit = [string]$package.release.source_commit
        package_sha256 = $ExpectedPackageSha256
        files = @($package.files)
        managed_config = @()
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage $script:OwnershipFile) -Encoding utf8NoBOM
    $stagedPlan = Get-RouterOwnedRemovalPlanCore -PackageRoot $package.root -InstallRoot $stage -ExpectedPackageSha256 $ExpectedPackageSha256 -ExpectedInstallationId $id -RecordedInstallRoot $root
    if ($stagedPlan.preserve_files.Count -ne 0) { throw 'Unexpected staging files; staging retained' }
    $null = Assert-RouterPlainPath $root
    [IO.Directory]::Move($stage, $root)
    return [pscustomobject]@{ installation_id = $id; install_root = $root; package_sha256 = $ExpectedPackageSha256; version = $manifest.version; manifest_path = (Join-Path $root $script:OwnershipFile) }
}

function Get-RouterOwnedRemovalPlanCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ExpectedPackageSha256,
        [Parameter(Mandatory)][guid]$ExpectedInstallationId,
        # Private staging validation override; never exported as deletion authority.
        [string]$RecordedInstallRoot = '',
        # Private PR8 recovery inputs. Public PR7 planning never accepts these.
        [string]$OwnershipJson = '',
        [string[]]$MissingOwnedPaths = @()
    )
    $package = Get-RouterVerifiedPackage $PackageRoot $ExpectedPackageSha256
    $root = Assert-RouterPlainPath $InstallRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Installation missing' }
    $actualFiles = @(Get-RouterTreeFiles $root)
    $path = Join-Path $root $script:OwnershipFile
    $manifest = if ($OwnershipJson) { $OwnershipJson | ConvertFrom-Json } else { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    Assert-RouterObjectFields $manifest @('schema_version', 'product', 'installation_id', 'install_root', 'version', 'source_commit', 'package_sha256', 'files', 'managed_config')
    foreach ($field in @('product', 'installation_id', 'install_root', 'version', 'source_commit', 'package_sha256')) {
        if ($manifest.$field -isnot [string]) { throw 'Invalid ownership identity type' }
    }
    $expectedRoot = if ($RecordedInstallRoot) { [IO.Path]::GetFullPath($RecordedInstallRoot) } else { $root }
    if ($manifest.schema_version -isnot [long] -and $manifest.schema_version -isnot [int]) { throw 'Invalid schema type' }
    if ($manifest.schema_version -ne 1 -or $manifest.product -cne 'codex-multimodel-manager' -or
        $manifest.installation_id -cne $ExpectedInstallationId.ToString('D') -or
        $manifest.install_root -cne $expectedRoot -or $manifest.package_sha256 -cne $ExpectedPackageSha256 -or
        $manifest.version -cne $package.release.version -or $manifest.source_commit -cne $package.release.source_commit) { throw 'Ownership identity mismatch' }
    if ($manifest.files -isnot [array] -or $manifest.managed_config -isnot [array] -or $manifest.managed_config.Count -ne 0 -or
        $manifest.files.Count -ne $package.files.Count) { throw 'Invalid ownership file/config ledger' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $delete = [Collections.Generic.List[string]]::new()
    foreach ($entry in $manifest.files) {
        Assert-RouterObjectFields $entry @('path', 'size', 'sha256')
        if ($entry.path -isnot [string] -or $entry.sha256 -isnot [string]) { throw 'Invalid file identity type' }
        Assert-RouterRelativePath $entry.path
        if (-not $seen.Add($entry.path)) { throw 'Duplicate ownership path' }
        $baseline = @($package.files | Where-Object { $_.path -ceq $entry.path })
        if ($baseline.Count -ne 1 -or $entry.sha256 -cne $baseline[0].sha256 -or $entry.size -ne $baseline[0].size -or
            $entry.size -isnot [long] -and $entry.size -isnot [int]) { throw 'Ownership differs from verified package' }
        $file = Assert-RouterPlainPath (Join-Path $root $entry.path)
        if ($entry.path -cin $MissingOwnedPaths -and -not (Test-Path -LiteralPath $file)) {
            $delete.Add($file)
            continue
        }
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
            (Get-Item -LiteralPath $file).Length -ne $entry.size -or
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256) { throw "Missing or modified owned file: $($entry.path)" }
        $delete.Add($file)
    }
    $delete.Add($path)
    return [pscustomobject]@{
        schema_version = 1
        installation_id = $manifest.installation_id
        install_root = $root
        delete_files = @($delete.ToArray())
        preserve_files = @($actualFiles | Where-Object { $_ -cnotin $delete })
        delete_directories = @()
        execution_permitted = $false
    }
}

function Get-RouterOwnedRemovalPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ExpectedPackageSha256,
        [Parameter(Mandatory)][guid]$ExpectedInstallationId
    )
    Get-RouterOwnedRemovalPlanCore @PSBoundParameters
}

Export-ModuleMember -Function Install-RouterOwnedPackage, Get-RouterOwnedRemovalPlan

# PR8 adds execution without changing PR7's public read-only contract.
. (Join-Path $PSScriptRoot 'router-safe-uninstall.ps1')
Export-ModuleMember -Function Install-RouterOwnedPackage, Get-RouterOwnedRemovalPlan, Uninstall-RouterOwnedPackage
