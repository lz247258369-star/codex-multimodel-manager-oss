param([string]$RepositoryRoot=(Get-Location).Path)
# LR15-PR9: actual win-x64 publish from a clean temporary Git clone. Linux
# validates the cross-built artifact, never executes Windows Host or claims CI.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$RepositoryRoot=(Resolve-Path -LiteralPath $RepositoryRoot).Path
Import-Module (Join-Path $RepositoryRoot 'installer/scripts/router-host-release.psm1')
Import-Module (Join-Path $RepositoryRoot 'installer/scripts/router-install-ownership.psm1')
$passes=0; $failures=[Collections.Generic.List[string]]::new()
function Assert-True([bool]$Condition,[string]$Message) {
    if ($Condition) { $script:passes++; Write-Host "PASS  $Message" }
    else { $failures.Add($Message); Write-Host "FAIL  $Message" }
}
function Assert-Refused([scriptblock]$Action,[string]$Message,[string]$Reason='') {
    try { & $Action | Out-Null; Assert-True $false $Message }
    catch { Assert-True (-not $Reason -or $_.Exception.Message -match $Reason) "$Message ($($_.Exception.Message))" }
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('lr15-pr9-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temp
$links=[Collections.Generic.List[string]]::new(); $child=$null; $childStarted=$false; $receipt=$null
$timer=[Diagnostics.Stopwatch]::StartNew()
try {
    $source=Join-Path $temp 'source'; $output=Join-Path $temp 'output'
    $null=New-Item -ItemType Directory -Path $output
    & git clone --no-hardlinks --quiet $RepositoryRoot $source
    if ($LASTEXITCODE) { throw 'Temporary Git clone failed' }
    $commit=(& git -C $source rev-parse HEAD).Trim()
    $sourceLock=Join-Path $source 'local-router/src/Router.Host/packages.lock.json'
    $sourceLockHash=(Get-FileHash -LiteralPath $sourceLock).Hash
    $receipt=New-RouterHostRelease -SourceRoot $source -SourceCommit $commit -OutputRoot $output -Version '3.8.0'
    $release=$receipt.release_root
    $arguments=@{ReleaseRoot=$release;ExpectedManifestSha256=$receipt.manifest_sha256;ExpectedPackageSha256=$receipt.package_sha256;ExpectedVersion='3.8.0';ExpectedSourceCommit=$commit}
    $verified=Get-VerifiedRouterHostRelease @arguments
    Assert-True (-not $verified.installation_permitted -and $verified.manifest.file_count -gt 6) 'Actual committed Host builds and verifies as independent artifact'
    Assert-True ((Get-FileHash -LiteralPath $sourceLock).Hash -ceq $sourceLockHash -and -not (& git -C $source status --porcelain)) 'Build leaves original source and portable locks unchanged'
    Assert-True (($verified.files.path -ccontains 'Router.Host.exe') -and ($verified.files.path -ccontains 'Router.Host.dll') -and
        ($verified.files.path -ccontains 'Router.Host.deps.json') -and ($verified.files.path -ccontains 'Router.Host.runtimeconfig.json') -and
        ($verified.files.path -ccontains 'config/router.defaults.json') -and ($verified.files.path -ccontains 'model-catalog.json')) 'Entry, managed runtime dependencies and default configuration are shipped'
    Assert-True (@($verified.files.path | Where-Object { $_ -match '(?i)(^|/)(auth\.json|\.env|state|bin|obj|tests)(/|$)|\.(cs|pdb|key|pem)$|Tests\.dll|Fake' }).Count -eq 0) 'No user credentials/state, source, test assemblies or build caches in release'
    $exeBytes=[IO.File]::ReadAllBytes((Join-Path $release 'Router.Host.exe'))
    Assert-True ($exeBytes[0] -eq 0x4d -and $exeBytes[1] -eq 0x5a) 'Cross-built Windows entry has PE signature'
    $bad=$arguments.Clone(); $bad.ExpectedManifestSha256='0'*64
    Assert-Refused { Get-VerifiedRouterHostRelease @bad } 'Wrong external manifest SHA refused' 'external trusted digest'
    $bad=$arguments.Clone(); $bad.ExpectedPackageSha256='0'*64
    Assert-Refused { Get-VerifiedRouterHostRelease @bad } 'Wrong external package SHA refused' 'identity mismatch'
    $bad=$arguments.Clone(); $bad.ExpectedVersion='3.8.1'
    Assert-Refused { Get-VerifiedRouterHostRelease @bad } 'Wrong expected version refused' 'identity mismatch'
    $bad=$arguments.Clone(); $bad.ExpectedTargetRuntime='linux-x64'
    Assert-Refused { Get-VerifiedRouterHostRelease @bad } 'Wrong expected RID refused' 'trusted release identities'
    $bad=$arguments.Clone(); $bad.ExpectedSourceCommit='0'*40
    Assert-Refused { Get-VerifiedRouterHostRelease @bad } 'Wrong expected source commit refused' 'identity mismatch'
    Assert-Refused { New-RouterHostRelease -SourceRoot $source -SourceCommit $commit -OutputRoot $output -Version '3.8.0' } 'Existing release target is never overwritten' 'already exists'
    $unknownTarget=Join-Path $output "router-host-3.8.1-win-x64-$($commit.Substring(0,8))"
    $null=New-Item -ItemType Directory -Path $unknownTarget
    'unknown target bytes' | Set-Content -LiteralPath (Join-Path $unknownTarget 'user.txt')
    Assert-Refused { New-RouterHostRelease -SourceRoot $source -SourceCommit $commit -OutputRoot $output -Version '3.8.1' } 'Unknown existing target is never adopted' 'already exists'
    Assert-True ((Get-Content -LiteralPath (Join-Path $unknownTarget 'user.txt') -Raw).Trim() -eq 'unknown target bytes') 'Target refusal preserves unknown user bytes'
    'unknown user file' | Set-Content -LiteralPath (Join-Path $output 'sentinel.txt')
    Assert-Refused { New-RouterHostRelease -SourceRoot $source -SourceCommit ('0'*40) -OutputRoot $output -Version '3.8.1' } 'Non-HEAD source claim refused' 'checked-out HEAD'
    $untracked=Join-Path $source 'pr9-untracked-fixture.txt'; 'uncommitted' | Set-Content -LiteralPath $untracked
    Assert-Refused { New-RouterHostRelease -SourceRoot $source -SourceCommit $commit -OutputRoot $output -Version '3.8.1' } 'Dirty source cannot masquerade as commit output' 'Dirty source'
    [IO.File]::Delete($untracked)
    $program=Join-Path $source 'local-router/src/Router.Host/Program.cs'; $committedProgram=[IO.File]::ReadAllBytes($program)
    try {
        '// uncommitted source replacement' | Set-Content -LiteralPath $program
        Assert-Refused { New-RouterHostRelease -SourceRoot $source -SourceCommit $commit -OutputRoot $output -Version '3.8.2' } 'Tracked source edits cannot impersonate commit output' 'Dirty source'
    }
    finally { [IO.File]::WriteAllBytes($program,$committedProgram) }
    Assert-True ((Get-Content -LiteralPath (Join-Path $output 'sentinel.txt') -Raw).Trim() -eq 'unknown user file') 'Rejected builds preserve unknown output files'

    function New-ReleaseCase {
        $copy=Join-Path $temp ('case-'+[guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $release -Destination $copy -Recurse
        $case=$arguments.Clone(); $case.ReleaseRoot=$copy; return $case
    }
    $case=New-ReleaseCase
    [IO.File]::Delete((Join-Path $case.ReleaseRoot 'Router.Core.dll'))
    Assert-Refused { Get-VerifiedRouterHostRelease @case } 'Missing dependency refused' 'missing or changed'
    $case=New-ReleaseCase
    'tampered' | Set-Content -LiteralPath (Join-Path $case.ReleaseRoot 'Router.Host.dll')
    Assert-Refused { Get-VerifiedRouterHostRelease @case } 'Tampered binary refused' 'missing or changed'
    $case=New-ReleaseCase
    'unowned' | Set-Content -LiteralPath (Join-Path $case.ReleaseRoot 'extra.txt')
    Assert-Refused { Get-VerifiedRouterHostRelease @case } 'Extra file refused' 'Unknown Host release file'
    $case=New-ReleaseCase
    $null=New-Item -ItemType Directory -Path (Join-Path $case.ReleaseRoot 'obj')
    Assert-Refused { Get-VerifiedRouterHostRelease @case } 'Empty unknown/cache directory refused' 'Unknown Host release directory'
    $case=New-ReleaseCase
    $manifestPath=Join-Path $case.ReleaseRoot 'router-host-release-manifest.json'
    $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.version='3.8.1'; $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath
    Assert-Refused { Get-VerifiedRouterHostRelease @case } 'Manifest metadata tampering refused by external trust anchor' 'external trusted digest'
    foreach ($attack in @('traversal','ads','device','case','schema','rid','entry','count','prerequisite')) {
        $case=New-ReleaseCase; $manifestPath=Join-Path $case.ReleaseRoot 'router-host-release-manifest.json'
        $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        switch ($attack) {
            'traversal' { $manifest.files[0].path='../outside.txt' }
            'ads' { $manifest.files[0].path='Router.Host.dll:stream' }
            'device' { $manifest.files[0].path='CON.dll' }
            'case' { $manifest.files+= $manifest.files[0].PSObject.Copy(); $manifest.files[-1].path=$manifest.files[0].path.ToUpperInvariant(); $manifest.file_count++ }
            'schema' { $manifest.schema_version=2 }
            'rid' { $manifest.target_runtime='win-arm64' }
            'entry' { $manifest.entry_file='Router.Core.dll' }
            'count' { $manifest.file_count++ }
            'prerequisite' { $manifest.runtime_prerequisites.minimum_version='9.0.0' }
        }
        $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath
        # Deliberately trusted malformed fixture tests semantic validation IN
        # ADDITION to the external-digest tamper refusal above; no real receipt
        # is authenticated by hashing itself in production or examples.
        $case.ExpectedManifestSha256=(Get-FileHash -LiteralPath $manifestPath).Hash.ToLowerInvariant()
        Assert-Refused { Get-VerifiedRouterHostRelease @case } "Malformed $attack ledger refused despite test trust anchor"
    }
    foreach ($binaryAttack in @('architecture','assembly-name')) {
        $case=New-ReleaseCase
        $binaryPath=if ($binaryAttack -eq 'architecture') { 'Router.Host.exe' } else { 'Router.Host.dll' }
        $binary=Join-Path $case.ReleaseRoot $binaryPath
        if ($binaryAttack -eq 'architecture') {
            $bytes=[IO.File]::ReadAllBytes($binary); $pe=[BitConverter]::ToInt32($bytes,0x3c)
            $bytes[$pe+4]=0x64; $bytes[$pe+5]=0xaa # ARM64, not AMD64
            [IO.File]::WriteAllBytes($binary,$bytes)
        }
        else { [IO.File]::Copy((Join-Path $case.ReleaseRoot 'Router.Core.dll'),$binary,$true) }
        $manifestPath=Join-Path $case.ReleaseRoot 'router-host-release-manifest.json'
        $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $entry=$manifest.files | Where-Object path -ceq $binaryPath
        $entry.size=(Get-Item -LiteralPath $binary).Length; $entry.sha256=(Get-FileHash -LiteralPath $binary).Hash.ToLowerInvariant()
        # A deliberately malformed, externally trusted test fixture verifies
        # binary identity independently of correct per-file hashes.
        $manifest.package_sha256=& (Get-Module router-host-release) { param($f) Get-HostDigest $f } $manifest.files
        $case.ExpectedPackageSha256=$manifest.package_sha256
        $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath
        $case.ExpectedManifestSha256=(Get-FileHash -LiteralPath $manifestPath).Hash.ToLowerInvariant()
        Assert-Refused { Get-VerifiedRouterHostRelease @case } "Wrong binary $binaryAttack refused despite valid test hashes" 'AMD64 PE|assembly identity'
    }
    $outside=Join-Path $temp 'outside'; $null=New-Item -ItemType Directory -Path $outside
    'outside user bytes' | Set-Content -LiteralPath (Join-Path $outside 'user.txt')
    $case=New-ReleaseCase; $link=Join-Path $case.ReleaseRoot 'linked'
    $kind=if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    $null=New-Item -ItemType $kind -Path $link -Target $outside; $links.Add($link)
    Assert-Refused { Get-VerifiedRouterHostRelease @case } 'Linked directory/junction refused' 'Linked entry'
    $case=New-ReleaseCase; $linkedRoot=Join-Path $temp 'linked-root'
    $null=New-Item -ItemType $kind -Path $linkedRoot -Target $case.ReleaseRoot; $links.Add($linkedRoot)
    $case.ReleaseRoot=$linkedRoot
    Assert-Refused { Get-VerifiedRouterHostRelease @case } 'Linked release root refused' 'Reparse point'
    if ($IsWindows) {
        $case=New-ReleaseCase; $link=Join-Path $case.ReleaseRoot 'Router.Core.dll'
        [IO.File]::Delete($link)
        $null=New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $outside 'user.txt'); $links.Add($link)
        Assert-Refused { Get-VerifiedRouterHostRelease @case } 'Windows file symlink refused' 'Linked entry'
    }
    Assert-True ((Get-Content -LiteralPath (Join-Path $outside 'user.txt') -Raw).Trim() -eq 'outside user bytes') 'Link attacks leave outside user file unchanged'
    Assert-Refused { Install-RouterOwnedPackage -PackageRoot $release -InstallRoot (Join-Path $temp 'not-installable') -ExpectedPackageSha256 $receipt.package_sha256 } 'Host component cannot bypass PR6/PR7 installation contract' 'PR6 package verification failed'
    Assert-Refused { Uninstall-RouterOwnedPackage -PackageRoot $release -InstallRoot $release -ExpectedPackageSha256 $receipt.package_sha256 -ExpectedInstallationId ([guid]::NewGuid()) -Execute -Confirm:$false } 'Host component cannot bypass PR8 ownership/lifecycle contract' 'PR6 package verification failed'
    $hostPath=(Get-Process -Id $PID).Path
    & $hostPath -NoProfile -File (Join-Path $RepositoryRoot 'installer/scripts/build-router-host-release.ps1') -Verify -VerifyTarget $release -ExpectedManifestSha256 $receipt.manifest_sha256 -ExpectedPackageSha256 $receipt.package_sha256 -Version '3.8.0' -SourceCommit $commit
    Assert-True ($LASTEXITCODE -eq 0) 'Independent CLI verification mode passes'

    if ($IsWindows) {
        # Clear inherited process environment, not the parent/session environment.
        # Only this owned temporary process may be terminated on a test timeout.
        $runHome=Join-Path $temp 'run-home'; $codexHome=Join-Path $runHome 'codex-home'
        $null=New-Item -ItemType Directory -Path $runHome,$codexHome
        $psi=[Diagnostics.ProcessStartInfo]::new((Join-Path $release 'Router.Host.exe'))
        $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.WorkingDirectory=$runHome
        $psi.Environment.Clear()
        foreach ($name in @('CODEX_HOME','HOME','USERPROFILE','APPDATA','LOCALAPPDATA','TEMP','TMP')) {
            $psi.Environment[$name]=if ($name -eq 'CODEX_HOME') { $codexHome } else { $runHome }
        }
        $psi.Environment['SystemRoot']=[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        $dotnetRoot=[IO.Path]::GetDirectoryName((Get-Command dotnet).Source)
        $psi.Environment['DOTNET_ROOT']=$dotnetRoot; $psi.Environment['DOTNET_ROOT_X64']=$dotnetRoot
        $psi.Environment['DOTNET_NOLOGO']='1'; $psi.Environment['DOTNET_CLI_TELEMETRY_OPTOUT']='1'
        $child=[Diagnostics.Process]::new(); $child.StartInfo=$psi
        $childStarted=$child.Start(); $stdout=$child.StandardOutput.ReadToEndAsync(); $stderr=$child.StandardError.ReadToEndAsync()
        $exited=$child.WaitForExit(30000)
        if (-not $exited) { $child.Kill(); $child.WaitForExit(); throw 'Owned isolated Host failed to exit disabled; test refused' }
        $out=$stdout.GetAwaiter().GetResult(); $err=$stderr.GetAwaiter().GetResult()
        Assert-True ($child.ExitCode -eq 0 -and $out.Contains('[local-router] DISABLED: local_router.enabled=false; exiting safely.') -and [string]::IsNullOrEmpty($err)) 'WINDOWS published apphost exits 0 with DISABLED and no listener startup'
        Assert-True (@(Get-ChildItem -LiteralPath $runHome -Recurse -File -Force).Count -eq 0) 'WINDOWS disabled release creates no user config/owner/runtime state'
        Assert-True (@($psi.Environment.Keys | Where-Object { $_ -match '(?i)API_KEY|TOKEN|SECRET' }).Count -eq 0) 'WINDOWS child receives no Provider keys or client tokens'
        Write-Host "HOST_RELEASE_WINDOWS_SMOKE exit=$($child.ExitCode) stdout=$($out.Trim()) isolated_home_empty=True"
        # The existing DSR6 fake-secret/port regressions also run in the full
        # Windows .NET gate; exit/empty-state alone is not a packet trace.
    }
    else { Write-Host 'UNRUN Windows apphost startup/junction/native file-symlink; Linux performed actual win-x64 cross-publish/integrity checks only' }
    $timer.Stop()
    Write-Host "HOST_RELEASE_SUMMARY PASS=$passes FAIL=$($failures.Count) WindowsNative=$IsWindows elapsed_seconds=$([int]$timer.Elapsed.TotalSeconds) files=$($verified.manifest.file_count)"
    if ($failures.Count) { exit 1 }
    Write-Host 'Router Host release validation PASSED'
}
finally {
    if ($child) { if ($childStarted -and -not $child.HasExited) { $child.Kill(); $child.WaitForExit() }; $child.Dispose() }
    foreach ($link in $links) { if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force } }
    # Cleanup only the generated test sandbox. Production builder retains its
    # independent build_work/staging and never deletes an output directory.
    Remove-Item -LiteralPath $temp -Recurse -Force
}
