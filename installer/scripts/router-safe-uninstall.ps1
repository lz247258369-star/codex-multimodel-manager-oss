# LR15-PR8: loaded privately by the ownership module; no automatic invocation.
if (-not ('CodexManager.Installation.WindowsOwnedFile' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'router-uninstall-safety.cs')
}

function Get-RouterRemovalIdentity([string]$Path, [long]$Size, [string]$Hash) {
    [CodexManager.Installation.WindowsOwnedFile]::Snapshot($Path, $Size, $Hash)
}
function Remove-RouterVerifiedFile([string]$Path, [long]$Size, [string]$Hash, [string]$Identity, $Lease) {
    [CodexManager.Installation.WindowsOwnedFile]::Delete($Path, $Size, $Hash, $Identity, $Lease)
}
function Get-RouterTextDigest([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Read-RouterProgressText([IO.FileStream]$Stream) {
    $Stream.Position = 0
    $reader = [IO.StreamReader]::new($Stream, [Text.UTF8Encoding]::new($false, $true), $true, 4096, $true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function Write-RouterProgress([IO.FileStream]$Stream, $Progress) {
    $text = $Progress | ConvertTo-Json -Depth 12 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $Stream.Position = 0
    $Stream.SetLength(0)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush($true)
    return Get-RouterTextDigest $text
}
function Test-RouterContainedPath([string]$Root, [string]$Other) {
    # Containment is used ONLY to refuse self-hosted execution/source deletion,
    # never to grant deletion authority. Authority remains the exact ledger.
    $relative = [IO.Path]::GetRelativePath($Root, [IO.Path]::GetFullPath($Other))
    return ($relative -eq '.' -or (-not [IO.Path]::IsPathRooted($relative) -and
        $relative -ne '..' -and -not $relative.StartsWith('../') -and -not $relative.StartsWith('..\')))
}

function Uninstall-RouterOwnedPackage {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ExpectedPackageSha256,
        [Parameter(Mandatory)][guid]$ExpectedInstallationId,
        [switch]$Execute,
        # Trusted lifecycle integration must hold a stop lease, not merely
        # assert a boolean or remember a PID. No default observer guesses safety.
        [object]$LifecycleGuard,
        # A retry/completed run requires the last externally retained digest.
        [string]$ExpectedProgressSha256 = ''
    )
    $root = Assert-RouterPlainPath $InstallRoot
    if ($root -eq [IO.Path]::GetPathRoot($root) -or $root.StartsWith('\\') -or
        $root -match '(?i)(^|[\\/])\.codex([\\/]|$)') { throw 'Unsafe uninstall root' }
    $package = Get-RouterVerifiedPackage $PackageRoot $ExpectedPackageSha256
    if ((Test-RouterContainedPath $root $package.root) -or (Test-RouterContainedPath $root $PSScriptRoot)) {
        throw 'Trusted package and executor must remain outside the uninstall tree for recovery'
    }
    if (@($package.files | Where-Object { $_.path -ieq 'router-uninstall-progress.json' }).Count) { throw 'Package collides with reserved progress receipt' }
    $manifestPath = Join-Path $root $script:OwnershipFile
    $progressPath = Join-Path $root 'router-uninstall-progress.json'
    $null = Assert-RouterPlainPath $progressPath
    $stream = $null; $lease = $null; $progress = $null; $digest = ''
    try {
        $hasProgress = Test-Path -LiteralPath $progressPath
        if ($hasProgress) {
            if ($ExpectedProgressSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Trusted progress digest required for recovery; no guessing' }
            $access = if ($Execute -and -not $WhatIfPreference) { [IO.FileAccess]::ReadWrite } else { [IO.FileAccess]::Read }
            $stream = [IO.FileStream]::new($progressPath, [IO.FileMode]::Open, $access, [IO.FileShare]::None)
            $text = Read-RouterProgressText $stream
            $digest = Get-RouterTextDigest $text
            if ($digest -cne $ExpectedProgressSha256) { throw 'Progress receipt changed or corrupted' }
            $progress = $text | ConvertFrom-Json
            Assert-RouterObjectFields $progress @('schema_version', 'install_root', 'installation_id', 'package_sha256', 'ownership_json', 'ownership_sha256', 'entries')
            foreach ($field in @('install_root', 'installation_id', 'package_sha256', 'ownership_json', 'ownership_sha256')) {
                if ($progress.$field -isnot [string]) { throw 'Invalid progress identity type' }
            }
            if ($progress.schema_version -ne 1 -or $progress.schema_version -isnot [long] -and $progress.schema_version -isnot [int] -or
                $progress.install_root -cne $root -or $progress.installation_id -cne $ExpectedInstallationId.ToString('D') -or
                $progress.package_sha256 -cne $ExpectedPackageSha256 -or
                (Get-RouterTextDigest $progress.ownership_json) -cne $progress.ownership_sha256) { throw 'Progress identity or ownership record mismatch' }
        }
        elseif ($ExpectedProgressSha256) { throw 'Expected recovery receipt missing' }
        else {
            $plan = Get-RouterOwnedRemovalPlan -PackageRoot $PackageRoot -InstallRoot $root -ExpectedPackageSha256 $ExpectedPackageSha256 -ExpectedInstallationId $ExpectedInstallationId
            $ownership = [IO.File]::ReadAllText($manifestPath)
            $progress = [pscustomobject]@{
                schema_version = 1; install_root = $root; installation_id = $ExpectedInstallationId.ToString('D')
                package_sha256 = $ExpectedPackageSha256; ownership_json = $ownership
                ownership_sha256 = Get-RouterTextDigest $ownership
                entries = @($package.files | ForEach-Object { [pscustomobject]@{ path = $_.path; state = 'ready'; identity = '' } }) + @([pscustomobject]@{ path = $script:OwnershipFile; state = 'ready'; identity = '' })
            }
        }

        $expectedPaths = @($package.files.path) + @($script:OwnershipFile)
        if ($progress.entries -isnot [array] -or $progress.entries.Count -ne $expectedPaths.Count) { throw 'Invalid progress ledger' }
        $missing = [Collections.Generic.List[string]]::new()
        $started = $false; $pendingSeen = $false
        for ($i = 0; $i -lt $expectedPaths.Count; $i++) {
            $entry = $progress.entries[$i]
            Assert-RouterObjectFields $entry @('path', 'state', 'identity')
            if ($entry.path -isnot [string] -or $entry.state -isnot [string] -or
                $entry.path -cne $expectedPaths[$i] -or $entry.state -cnotin @('ready', 'pending', 'done') -or $entry.identity -isnot [string]) { throw 'Invalid progress entry' }
            if ($hasProgress -and [string]::IsNullOrWhiteSpace($entry.identity)) { throw 'Missing original file identity' }
            if ($entry.state -eq 'done' -and $started) { throw 'Out-of-order progress' }
            if ($entry.state -eq 'pending') { if ($started -or $pendingSeen) { throw 'Multiple or misplaced pending entries' }; $pendingSeen = $true }
            if ($entry.state -ne 'done') { $started = $true }
            $file = Assert-RouterPlainPath (Join-Path $root $entry.path)
            $exists = Test-Path -LiteralPath $file
            if ($entry.state -eq 'done' -and $exists) { throw 'Deleted path reappeared; preserve and refuse' }
            if ($entry.state -in @('pending', 'done') -and -not $exists) { $missing.Add($entry.path) }
        }
        if (Test-Path -LiteralPath $manifestPath) {
            if ((Get-RouterTextDigest ([IO.File]::ReadAllText($manifestPath))) -cne $progress.ownership_sha256) { throw 'Ownership manifest changed' }
        }
        elseif ($script:OwnershipFile -cnotin $missing) { throw 'Ownership manifest unexpectedly missing' }
        # The schema-v1 manifest and verified package are checked anew, including
        # on recovery. Journal states allow only recorded absent paths, never
        # authorize deletion of a new/unowned path.
        $plan = Get-RouterOwnedRemovalPlanCore -PackageRoot $PackageRoot -InstallRoot $root -ExpectedPackageSha256 $ExpectedPackageSha256 -ExpectedInstallationId $ExpectedInstallationId -OwnershipJson $progress.ownership_json -MissingOwnedPaths @($missing)
        if (-not $Execute -or $WhatIfPreference) {
            return [pscustomobject]@{ status = 'DryRun'; execution_permitted = $false; plan = $plan; progress_sha256 = $digest }
        }
        if (-not ($LifecycleGuard -is [CodexManager.Installation.IRouterLifecycleGuard])) { throw 'Host stopped lease unavailable; lifecycle unknown' }
        $lease = $LifecycleGuard.AcquireStopped($root, $ExpectedInstallationId)
        if (-not ($lease -is [CodexManager.Installation.IStoppedRouterLease])) { throw 'Host stopped lease could not be verified' }
        $lease.AssertStopped()
        if (-not $PSCmdlet.ShouldProcess($root, 'Delete only verified owned files; preserve directories and user files')) {
            return [pscustomobject]@{ status = 'Declined'; execution_permitted = $false; plan = $plan; progress_sha256 = $digest }
        }
        if (-not $hasProgress) {
            foreach ($entry in $progress.entries) {
                $baseline = if ($entry.path -ceq $script:OwnershipFile) { [pscustomobject]@{ size = [Text.Encoding]::UTF8.GetByteCount($progress.ownership_json); sha256 = $progress.ownership_sha256 } } else { $package.files | Where-Object { $_.path -ceq $entry.path } }
                $entry.identity = Get-RouterRemovalIdentity (Join-Path $root $entry.path) $baseline.size $baseline.sha256
            }
            $null = Assert-RouterPlainPath $progressPath
            $stream = [IO.FileStream]::new($progressPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $digest = Write-RouterProgress $stream $progress
        }
        foreach ($entry in $progress.entries) {
            if ($entry.state -eq 'done') { continue }
            $lease.AssertStopped()
            $null = @(Get-RouterTreeFiles $root)
            if ($digest -cne (Get-RouterTextDigest (Read-RouterProgressText $stream))) { throw 'Progress changed during execution' }
            if (Test-Path -LiteralPath $manifestPath) {
                if ((Get-RouterTextDigest ([IO.File]::ReadAllText($manifestPath))) -cne $progress.ownership_sha256) { throw 'Ownership changed during execution' }
            }
            elseif ($entry.path -cne $script:OwnershipFile) { throw 'Ownership lost before payload completion' }
            $file = Assert-RouterPlainPath (Join-Path $root $entry.path)
            if ($entry.state -eq 'pending' -and -not (Test-Path -LiteralPath $file)) {
                $entry.state = 'done'; $digest = Write-RouterProgress $stream $progress
                continue
            }
            $baseline = if ($entry.path -ceq $script:OwnershipFile) { [pscustomobject]@{ size = [Text.Encoding]::UTF8.GetByteCount($progress.ownership_json); sha256 = $progress.ownership_sha256 } } else { $package.files | Where-Object { $_.path -ceq $entry.path } }
            # Persist the intention BEFORE deleting; a crash between deletion and
            # completion leaves exactly one recoverable pending entry.
            $entry.state = 'pending'; $digest = Write-RouterProgress $stream $progress
            $lease.AssertStopped()
            $null = Assert-RouterPlainPath $file
            Remove-RouterVerifiedFile $file $baseline.size $baseline.sha256 $entry.identity $lease
            if (Test-Path -LiteralPath $file) { throw 'Deletion did not complete' }
            $entry.state = 'done'; $digest = Write-RouterProgress $stream $progress
        }
        return [pscustomobject]@{ status = 'Completed'; deleted_files = @($progress.entries.path); progress_path = $progressPath; progress_sha256 = $digest; preserved_directories = $true }
    }
    catch {
        # Corrupt/torn state fails closed. The caller must retain this digest
        # externally for a retry; reading an arbitrary journal and trusting its
        # own hash is not recovery authorization.
        if ($stream -and $progress) {
            try { $_.Exception.Data['progress_sha256'] = Get-RouterTextDigest (Read-RouterProgressText $stream); $_.Exception.Data['progress_path'] = $progressPath } catch { }
        }
        throw
    }
    finally {
        if ($stream) { $stream.Dispose() }
        if ($lease) { $lease.Dispose() }
    }
}
