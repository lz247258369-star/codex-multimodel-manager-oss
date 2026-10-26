param([string]$RepositoryRoot = (Get-Location).Path)
# LR15-PR8: isolated fake lifecycle + actual temporary files; native Windows
# deletion is exercised on Windows. Linux substitutes only the private backend.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$modulePath = Join-Path $RepositoryRoot 'installer/scripts/router-install-ownership.psm1'
if (-not ('Pr8FakeGuard' -as [type])) {
    $fakeSource = @'

public sealed class Pr8FakeGuard : CodexManager.Installation.IRouterLifecycleGuard {
    public string State = "Stopped";
    public int Checks, Disposals;
    public int FailAtCheck;
    public CodexManager.Installation.IStoppedRouterLease AcquireStopped(string root, Guid id) {
        if (State != "Stopped") throw new InvalidOperationException("Fake lifecycle: " + State);
        return new Lease(this);
    }
    private sealed class Lease : CodexManager.Installation.IStoppedRouterLease {
        readonly Pr8FakeGuard owner;
        public Lease(Pr8FakeGuard o) { owner = o; }
        public void AssertStopped() {
            owner.Checks++;
            if (owner.State != "Stopped" || (owner.FailAtCheck > 0 && owner.Checks >= owner.FailAtCheck))
                throw new InvalidOperationException("Stopped lease lost");
        }
        public void Dispose() { owner.Disposals++; }
    }
}
'@
    Add-Type -TypeDefinition ((Get-Content -LiteralPath (Join-Path $RepositoryRoot 'installer/scripts/router-uninstall-safety.cs') -Raw) + "`n" + $fakeSource)
}
Import-Module $modulePath -Force
$passes = 0; $failures = [Collections.Generic.List[string]]::new()
function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passes++; Write-Host "PASS  $Message" }
    else { $failures.Add($Message); Write-Host "FAIL  $Message" }
}
function Assert-Refused([scriptblock]$Action, [string]$Message) {
    $script:FailureData = $null
    try { & $Action | Out-Null; Assert-True $false $Message }
    catch { $script:FailureData = $_.Exception.Data; Assert-True $true $Message }
}
function Configure-TestBackend {
    Import-Module $modulePath -Force
    $module = Get-Module router-install-ownership
    & $module {
        param($linux)
        $script:Pr8DeleteCount = 0; $script:Pr8FailAt = 0; $script:Pr8FailAfterDelete = $false; $script:Pr8Mutation = $null
        if ($linux) {
            function script:Get-RouterRemovalIdentity {
                param($Path, $Size, $Hash)
                $null = Assert-RouterPlainPath $Path
                if ((Get-Item -LiteralPath $Path).Length -ne $Size -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Hash) { throw 'Fake content mismatch' }
                return ([IO.File]::GetCreationTimeUtc($Path).Ticks.ToString() + ':' + [IO.File]::GetLastWriteTimeUtc($Path).Ticks.ToString())
            }
            $script:Pr8BaseDelete = {
                param($Path, $Size, $Hash, $Identity, $Lease)
                if ((Get-RouterRemovalIdentity $Path $Size $Hash) -cne $Identity) { throw 'Fake file replaced' }
                $Lease.AssertStopped()
                [IO.File]::Delete($Path)
            }
        }
        else { $script:Pr8BaseDelete = (Get-Command Remove-RouterVerifiedFile).ScriptBlock }
        function script:Remove-RouterVerifiedFile {
            param($Path, $Size, $Hash, $Identity, $Lease)
            $script:Pr8DeleteCount++
            if ($script:Pr8Mutation) { & $script:Pr8Mutation $Path }
            if ($script:Pr8FailAt -eq $script:Pr8DeleteCount -and -not $script:Pr8FailAfterDelete) { throw 'Injected deletion failure' }
            & $script:Pr8BaseDelete $Path $Size $Hash $Identity $Lease
            if ($script:Pr8FailAt -eq $script:Pr8DeleteCount -and $script:Pr8FailAfterDelete) { throw 'Injected crash after deletion before completion' }
        }
    } (-not $IsWindows)
}
# FIX1: test-fixture recovery only, never a production uninstall/repair API.
# Restore exact pre-attack paths; moving a directory into an existing directory
# nests it and cannot recover a partially completed Windows Move-Item fallback.
function Restore-RootMoveFixture([string]$Root, [string]$Saved, [array]$Files) {
    foreach ($directory in @($Root, $Saved)) {
        if ((Test-Path -LiteralPath $directory) -and
            ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Fixture recovery refuses linked directories'
        }
    }
    foreach ($entry in $Files) {
        $target = Join-Path $Root $entry.path; $source = Join-Path $Saved $entry.path
        $atRoot = Test-Path -LiteralPath $target -PathType Leaf
        $atSaved = Test-Path -LiteralPath $source -PathType Leaf
        if ($atRoot -eq $atSaved) { throw "Fixture recovery requires exactly one original: $($entry.path)" }
        $original = if ($atRoot) { $target } else { $source }
        if ((Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -cne $entry.hash) {
            throw "Fixture recovery refuses changed original: $($entry.path)"
        }
        if ($atSaved) {
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            [IO.File]::Move($source, $target) # no overwrite, no directory merge
        }
    }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('lr15-pr8-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
$links = [Collections.Generic.List[string]]::new()
$hostPath = (Get-Process -Id $PID).Path
try {
    $source = Join-Path $temp 'source'; $output = Join-Path $temp 'packages'
    $null = New-Item -ItemType Directory -Path (Join-Path $source 'installer'), $output
    '# fixture' | Set-Content -LiteralPath (Join-Path $source 'README.md')
    'Write-Output "fixture"' | Set-Content -LiteralPath (Join-Path $source 'installer/setup.ps1')
    foreach ($gitArgs in @(@('init', '-q'), @('add', '.'), @('-c', 'user.name=uninstall-test', '-c', 'user.email=uninstall-test@local', 'commit', '-q', '-m', 'fixture'))) {
        & git -C $source @gitArgs
        if ($LASTEXITCODE) { throw 'Fixture git failed' }
    }
    & $hostPath -NoProfile -File (Join-Path $RepositoryRoot 'installer/scripts/build-release-package.ps1') -SourceRoot $source -OutputRoot $output -Version '3.8.0' -EntryPoints 'installer/setup.ps1' | Out-Null
    if ($LASTEXITCODE) { throw 'Fixture PR6 package failed' }
    $package = (Get-ChildItem -LiteralPath $output -Directory | Select-Object -First 1).FullName
    $release = Get-Content -Raw -LiteralPath (Join-Path $package 'release-manifest.json') | ConvertFrom-Json
    function New-InstallCase {
        Configure-TestBackend
        $root = Join-Path $temp ([guid]::NewGuid().ToString('N'))
        $receipt = Install-RouterOwnedPackage -PackageRoot $package -InstallRoot $root -ExpectedPackageSha256 $release.package_sha256
        return @{ PackageRoot = $package; InstallRoot = $root; ExpectedPackageSha256 = $release.package_sha256; ExpectedInstallationId = [guid]$receipt.installation_id }
    }
    $case = New-InstallCase
    $dry = Uninstall-RouterOwnedPackage @case
    Assert-True ($dry.status -eq 'DryRun' -and (Test-Path -LiteralPath (Join-Path $case.InstallRoot 'README.md')) -and -not (Test-Path -LiteralPath (Join-Path $case.InstallRoot 'router-uninstall-progress.json'))) 'Default Dry Run deletes/writes nothing'
    $dry = Uninstall-RouterOwnedPackage @case -Execute -WhatIf
    Assert-True ($dry.status -eq 'DryRun' -and -not (Test-Path -LiteralPath (Join-Path $case.InstallRoot 'router-uninstall-progress.json'))) 'Execute plus WhatIf remains read-only'
    Assert-Refused { Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false } 'No trustworthy lifecycle guard refuses execution'
    Assert-Refused { Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false -LifecycleGuard ([pscustomobject]@{ State = 'Stopped' }) } 'Caller boolean/status object is not a lifecycle lease'
    foreach ($state in @('Running', 'Unknown')) {
        $guard = [Pr8FakeGuard]::new(); $guard.State = $state
        Assert-Refused { Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false -LifecycleGuard $guard } "Lifecycle $state refuses execution"
    }
    Assert-True ((Get-ChildItem -LiteralPath $case.InstallRoot -Recurse -File).Count -eq 4) 'Denied executions leave original installation intact'
    $wrong = $case.Clone(); $wrong.ExpectedInstallationId = [guid]::NewGuid()
    Assert-Refused { Uninstall-RouterOwnedPackage @wrong -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Wrong installation UUID refused'
    $wrong = $case.Clone(); $wrong.ExpectedPackageSha256 = ('0' * 64)
    Assert-Refused { Uninstall-RouterOwnedPackage @wrong } 'Wrong package digest refused'

    $ownership = Join-Path $case.InstallRoot 'router-install-ownership.json'
    $original = [IO.File]::ReadAllText($ownership)
    foreach ($mutation in @('corrupt', 'forged', 'traversal', 'ads', 'case', 'unknown-schema')) {
        if ($mutation -eq 'corrupt') { '{bad' | Set-Content -LiteralPath $ownership }
        else {
            $m = $original | ConvertFrom-Json
            switch ($mutation) {
                'forged' { $m.files[0].sha256 = ('0' * 64) }
                'traversal' { $m.files[0].path = '../outside.txt' }
                'ads' { $m.files[0].path += ':stream' }
                'case' { $m.files[0].path = $m.files[0].path.ToUpperInvariant() }
                'unknown-schema' { $m.schema_version = 8 }
            }
            $m | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ownership
        }
        Assert-Refused { Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } "Ownership $mutation refused"
    }
    Remove-Item -LiteralPath $ownership
    Assert-Refused { Uninstall-RouterOwnedPackage @case } 'Missing manifest refuses inferred ownership'
    [IO.File]::WriteAllText($ownership, $original)
    $payload = Join-Path $case.InstallRoot 'README.md'; $bytes = [IO.File]::ReadAllBytes($payload)
    'user changed' | Set-Content -LiteralPath $payload
    Assert-Refused { Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Modified owned file refuses execution'
    [IO.File]::WriteAllBytes($payload, $bytes)

    $outside = Join-Path $temp 'outside'; $null = New-Item -ItemType Directory -Path $outside
    'outside sentinel' | Set-Content -LiteralPath (Join-Path $outside 'sentinel.txt')
    $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    $link = Join-Path $case.InstallRoot 'linked'
    $null = New-Item -ItemType $kind -Path $link -Target $outside; $links.Add($link)
    Assert-Refused { Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Linked unowned subtree blocks deletion'
    Remove-Item -LiteralPath $link -Force; $links.Remove($link) | Out-Null
    $ownedDir = Join-Path $case.InstallRoot 'installer'; $saved = Join-Path $temp 'saved-installer'
    Move-Item -LiteralPath $ownedDir -Destination $saved
    $null = New-Item -ItemType $kind -Path $ownedDir -Target $outside; $links.Add($ownedDir)
    Assert-Refused { Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Owned directory replaced by junction/link blocks deletion'
    Remove-Item -LiteralPath $ownedDir -Force; $links.Remove($ownedDir) | Out-Null
    Move-Item -LiteralPath $saved -Destination $ownedDir
    Assert-True ((Get-Content -LiteralPath (Join-Path $outside 'sentinel.txt') -Raw).Trim() -eq 'outside sentinel') 'Link attacks preserve outside sentinel'
    if ($IsWindows) {
        $fileLink = Join-Path $case.InstallRoot 'unowned-symlink.txt'
        $null = New-Item -ItemType SymbolicLink -Path $fileLink -Target (Join-Path $outside 'sentinel.txt')
        $links.Add($fileLink)
        Assert-Refused { Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Windows file symbolic link refuses deletion'
        Remove-Item -LiteralPath $fileLink -Force; $links.Remove($fileLink) | Out-Null
        $hardlink = Join-Path $outside 'hardlink.txt'
        $null = New-Item -ItemType HardLink -Path $hardlink -Target $payload
        Assert-Refused { Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Windows hard-linked owned file refused'
        Remove-Item -LiteralPath $hardlink
        $locked = [IO.FileStream]::new($payload, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try { Assert-Refused { Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Windows competing exclusive handle refuses deletion' }
        finally { $locked.Dispose() }
    }
    else { Write-Host 'UNRUN Windows file-symlink/hardlink/exclusive-handle semantics; Linux backend is FAKE' }

    'keep user file' | Set-Content -LiteralPath (Join-Path $case.InstallRoot 'user.txt')
    $guard = [Pr8FakeGuard]::new()
    $result = Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false -LifecycleGuard $guard
    Assert-True ($result.status -eq 'Completed' -and -not (Test-Path -LiteralPath $ownership) -and -not (Test-Path -LiteralPath $payload)) 'Normal authorized uninstall removes payload then manifest'
    Assert-True ((Get-Content -LiteralPath (Join-Path $case.InstallRoot 'user.txt') -Raw).Trim() -eq 'keep user file' -and (Test-Path -LiteralPath (Join-Path $case.InstallRoot 'installer'))) 'Unowned user file and directories preserved'
    Assert-True ($guard.Checks -ge 9 -and $guard.Disposals -eq 1) 'Stop lease held, repeatedly checked and released'
    Assert-Refused { Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Repeated run without trusted progress digest refused'
    $again = Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) -ExpectedProgressSha256 $result.progress_sha256
    Assert-True ($again.status -eq 'Completed' -and $again.progress_sha256 -ceq $result.progress_sha256) 'Authenticated completed retry is idempotent'
    'new user replacement' | Set-Content -LiteralPath $payload
    Assert-Refused { Uninstall-RouterOwnedPackage @case -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) -ExpectedProgressSha256 $result.progress_sha256 } 'Recreated deleted path is preserved and blocks repeat'
    Assert-True ((Get-Content -LiteralPath $payload -Raw).Trim() -eq 'new user replacement') 'Repeat never deletes recreated user file'

    foreach ($afterDelete in @($false, $true)) {
        $partial = New-InstallCase
        $module = Get-Module router-install-ownership
        & $module { param($after) $script:Pr8FailAt = 2; $script:Pr8FailAfterDelete = $after } $afterDelete
        Assert-Refused { Uninstall-RouterOwnedPackage @partial -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } "Mid-delete failure (after=$afterDelete) stops without force"
        $sha = [string]$script:FailureData['progress_sha256']
        Assert-True ($sha -match '^[0-9a-f]{64}$' -and (Test-Path -LiteralPath (Join-Path $partial.InstallRoot 'router-install-ownership.json'))) 'Partial failure retains manifest and trusted recovery receipt'
        Assert-Refused { Uninstall-RouterOwnedPackage @partial -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Partial retry cannot guess missing ownership'
        Configure-TestBackend
        $resumed = Uninstall-RouterOwnedPackage @partial -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) -ExpectedProgressSha256 $sha
        Assert-True ($resumed.status -eq 'Completed') 'Pending delete recovers with original identities and trusted digest'
    }

    $partial = New-InstallCase
    $module = Get-Module router-install-ownership
    & $module { $script:Pr8FailAt = 2 }
    Assert-Refused { Uninstall-RouterOwnedPackage @partial -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Create partial state for corruption regression'
    $sha = [string]$script:FailureData['progress_sha256']
    $journal = Join-Path $partial.InstallRoot 'router-uninstall-progress.json'
    '{torn journal' | Set-Content -LiteralPath $journal
    Assert-Refused { Uninstall-RouterOwnedPackage @partial -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) -ExpectedProgressSha256 $sha } 'Changed/torn progress fails closed instead of forcing recovery'

    $changing = New-InstallCase
    $module = Get-Module router-install-ownership
    & $module { $script:Pr8Mutation = { param($p) 'race mutation' | Set-Content -LiteralPath $p } }
    Assert-Refused { Uninstall-RouterOwnedPackage @changing -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Mutation after planning and before delete is rechecked'
    Assert-True (Test-Path -LiteralPath (Join-Path $changing.InstallRoot 'router-install-ownership.json')) 'Mutation abort preserves ownership record'

    $replaced = New-InstallCase
    $module = Get-Module router-install-ownership
    & $module {
        $script:Pr8Mutation = {
            param($p)
            $bytes = [IO.File]::ReadAllBytes($p)
            Move-Item -LiteralPath $p -Destination ($p + '.saved')
            [IO.File]::WriteAllBytes($p, $bytes)
        }
    }
    Assert-Refused { Uninstall-RouterOwnedPackage @replaced -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Same-content file substitution after snapshot is refused'
    Assert-True ((Test-Path -LiteralPath (Join-Path $replaced.InstallRoot 'README.md')) -and (Test-Path -LiteralPath (Join-Path $replaced.InstallRoot 'README.md.saved'))) 'Replacement and saved original both survive refusal'

    # Deterministic recovery controls on every OS: refused move, complete move,
    # and partial move. They do not substitute for the real Windows attack below.
    foreach ($moveState in @('refused', 'complete', 'partial')) {
        $control = Join-Path $temp ('move-control-' + $moveState)
        $controlSaved = $control + '-saved'
        $null = New-Item -ItemType Directory -Path $control
        'original ownership' | Set-Content -LiteralPath (Join-Path $control 'router-install-ownership.json')
        'original user bytes' | Set-Content -LiteralPath (Join-Path $control 'user.txt')
        $controlFiles = @(Get-ChildItem -LiteralPath $control -File | ForEach-Object {
            [pscustomobject]@{ path = $_.Name; hash = (Get-FileHash -LiteralPath $_.FullName).Hash }
        })
        if ($moveState -eq 'complete') { [IO.Directory]::Move($control, $controlSaved) }
        elseif ($moveState -eq 'partial') {
            $null = New-Item -ItemType Directory -Path $controlSaved
            [IO.File]::Move((Join-Path $control 'router-install-ownership.json'), (Join-Path $controlSaved 'router-install-ownership.json'))
        }
        Restore-RootMoveFixture $control $controlSaved $controlFiles
        Assert-True (@($controlFiles | Where-Object {
            (Get-FileHash -LiteralPath (Join-Path $control $_.path)).Hash -cne $_.hash
        }).Count -eq 0) "FIX1 $moveState recovery retains exact ownership/user bytes at original paths"
    }

    $swapped = New-InstallCase
    'root attack user bytes' | Set-Content -LiteralPath (Join-Path $swapped.InstallRoot 'user.txt')
    $rootFiles = @(Get-ChildItem -LiteralPath $swapped.InstallRoot -Recurse -File | ForEach-Object {
        [pscustomobject]@{ path = [IO.Path]::GetRelativePath($swapped.InstallRoot, $_.FullName); hash = (Get-FileHash -LiteralPath $_.FullName).Hash }
    })
    $savedRoot = Join-Path $temp 'saved-install-root'
    $module = Get-Module router-install-ownership
    & $module {
        param($r, $s, $o, $k)
        $script:Pr8SwapRoot = $r; $script:Pr8SavedRoot = $s; $script:Pr8Outside = $o; $script:Pr8LinkKind = $k
        $script:Pr8Mutation = {
            param($p)
            function Write-RootMoveState($phase) {
                foreach ($directory in @($script:Pr8SwapRoot, $script:Pr8SavedRoot)) {
                    $exists = Test-Path -LiteralPath $directory
                    $linked = $exists -and ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
                    $files = if ($exists -and -not $linked) { @((Get-ChildItem -LiteralPath $directory -Recurse -File -Force).FullName) } else { @() }
                    Write-Host ("ROOT_MOVE_STATE $phase " + ([pscustomobject]@{ root = $directory; exists = $exists; linked = [bool]$linked; files = $files } | ConvertTo-Json -Compress))
                }
            }
            Write-RootMoveState 'before'
            try {
                Move-Item -LiteralPath $script:Pr8SwapRoot -Destination $script:Pr8SavedRoot -ErrorAction Stop
                $null = New-Item -ItemType $script:Pr8LinkKind -Path $script:Pr8SwapRoot -Target $script:Pr8Outside
            }
            catch {
                Write-Host "ROOT_MOVE_EXCEPTION $($_.FullyQualifiedErrorId); $($_.Exception.GetType().FullName); HResult=$($_.Exception.HResult); $($_.Exception.Message)"
                throw
            }
            finally { Write-RootMoveState 'after' }
        }
    } $swapped.InstallRoot $savedRoot $outside $kind
    Assert-Refused { Uninstall-RouterOwnedPackage @swapped -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Root exchanged for junction/link after planning is refused'
    Assert-True ((Get-Content -LiteralPath (Join-Path $outside 'sentinel.txt') -Raw).Trim() -eq 'outside sentinel') 'Root replacement attack preserves outside bytes'
    $rootExists = Test-Path -LiteralPath $swapped.InstallRoot
    $rootLinked = $rootExists -and ((Get-Item -LiteralPath $swapped.InstallRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
    $savedExists = Test-Path -LiteralPath $savedRoot
    $observedMove = if ($savedExists -and $rootExists -and -not $rootLinked) { 'partial' } elseif ($savedExists) { 'complete' } else { 'refused' }
    Write-Host "ROOT_MOVE_OUTCOME $observedMove WindowsNative=$IsWindows"
    $manifestRelative = 'router-install-ownership.json'
    $originalManifest = $rootFiles | Where-Object path -eq $manifestRelative
    $manifestLocations = @(@($swapped.InstallRoot, $savedRoot) | Where-Object {
        (Test-Path -LiteralPath $_) -and -not ((Get-Item -LiteralPath $_ -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
    } | ForEach-Object { Join-Path $_ $manifestRelative } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    Assert-True ($manifestLocations.Count -eq 1 -and
        (Get-FileHash -LiteralPath $manifestLocations[0]).Hash -ceq $originalManifest.hash) 'FIX1 original manifest survives once in a plain root before fixture recovery'
    # Windows may already prevent renaming the directory containing the open,
    # exclusive progress stream. Both that refusal and a detected replacement
    # are safe outcomes; never treat an unchanged real directory as a link.
    if ((Test-Path -LiteralPath $swapped.InstallRoot) -and
        ((Get-Item -LiteralPath $swapped.InstallRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $swapped.InstallRoot -Force
    }
    Restore-RootMoveFixture $swapped.InstallRoot $savedRoot $rootFiles
    Assert-True (Test-Path -LiteralPath (Join-Path $swapped.InstallRoot 'router-install-ownership.json')) 'Root replacement or OS rename refusal retains original ownership'
    Assert-True (@($rootFiles | Where-Object {
        (Get-FileHash -LiteralPath (Join-Path $swapped.InstallRoot $_.path)).Hash -cne $_.hash
    }).Count -eq 0) 'FIX1 attack refusal preserves every original owned/user file at exact paths'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $swapped.InstallRoot 'saved-install-root'))) 'FIX1 recovery never nests the saved directory'

    $losing = New-InstallCase
    $guard = [Pr8FakeGuard]::new(); $guard.FailAtCheck = 5
    Assert-Refused { Uninstall-RouterOwnedPackage @losing -Execute -Confirm:$false -LifecycleGuard $guard } 'Lost stop lease aborts remaining deletes'
    Assert-True (Test-Path -LiteralPath (Join-Path $losing.InstallRoot 'router-install-ownership.json')) 'Host uncertainty never removes ownership early'

    $nested = New-InstallCase
    $nestedPackage = Join-Path $nested.InstallRoot 'trusted-package'
    Copy-Item -LiteralPath $package -Destination $nestedPackage -Recurse
    $nested.PackageRoot = $nestedPackage
    Assert-Refused { Uninstall-RouterOwnedPackage @nested -Execute -Confirm:$false -LifecycleGuard ([Pr8FakeGuard]::new()) } 'Package inside uninstall tree refused to preserve recovery source'

    Write-Host "Safe uninstall summary: PASS=$passes FAIL=$($failures.Count) WindowsNative=$IsWindows"
    if ($failures.Count) { exit 1 }
    Write-Host 'Router safe uninstall validation PASSED'
}
finally {
    foreach ($link in $links) { if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force } }
    Remove-Item -LiteralPath $temp -Recurse -Force
    Remove-Module router-install-ownership -ErrorAction SilentlyContinue
}
