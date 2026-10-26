param([string]$RepositoryRoot = (Get-Location).Path)

# LR15-PR7: real file-boundary regression tests in isolated temporary roots.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$failures = [Collections.Generic.List[string]]::new()
$passes = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passes++; Write-Host "PASS  $Message" }
    else { $failures.Add($Message); Write-Host "FAIL  $Message" }
}
function Assert-Refused([scriptblock]$Action, [string]$Message) {
    $refused = $false
    try { & $Action | Out-Null } catch { $refused = $true; $script:LastRefusal = $_.Exception.Message }
    Assert-True $refused $Message
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$modulePath = Join-Path $RepositoryRoot 'installer/scripts/router-install-ownership.psm1'
$tokens = $null; $errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'Ownership module parses'
Import-Module $modulePath -Force
$hostPath = (Get-Process -Id $PID).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('lr15-pr7-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
$linkPaths = [Collections.Generic.List[string]]::new()
try {
    $source = Join-Path $temp 'source'
    $null = New-Item -ItemType Directory -Path (Join-Path $source 'installer')
    'Write-Output "fixture"' | Set-Content -LiteralPath (Join-Path $source 'installer/setup.ps1')
    '# fixture' | Set-Content -LiteralPath (Join-Path $source 'README.md')
    foreach ($argsForGit in @(@('init', '-q'), @('add', '.'), @('-c', 'user.name=ownership-test', '-c', 'user.email=ownership-test@local', 'commit', '-q', '-m', 'isolated fixture'))) {
        & git -C $source @argsForGit
        if ($LASTEXITCODE -ne 0) { throw 'Fixture git command failed' }
    }
    $builder = Join-Path $RepositoryRoot 'installer/scripts/build-release-package.ps1'
    $null = New-Item -ItemType Directory -Path (Join-Path $temp 'packages')
    & $hostPath -NoLogo -NoProfile -File $builder -SourceRoot $source -OutputRoot (Join-Path $temp 'packages') -Version '3.8.0' -EntryPoints 'installer/setup.ps1' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'PR6 fixture package build failed' }
    $package = (Get-ChildItem -LiteralPath (Join-Path $temp 'packages') -Directory | Select-Object -First 1).FullName
    $release = Get-Content -LiteralPath (Join-Path $package 'release-manifest.json') -Raw | ConvertFrom-Json
    $root = Join-Path $temp 'install'
    $installArgs = @{ PackageRoot = $package; InstallRoot = $root; ExpectedPackageSha256 = $release.package_sha256 }
    $receipt = Install-RouterOwnedPackage @installArgs
    $planArgs = $installArgs.Clone()
    $planArgs.ExpectedInstallationId = $receipt.installation_id
    $ownership = Join-Path $root 'router-install-ownership.json'
    $original = [IO.File]::ReadAllText($ownership)
    $plan = Get-RouterOwnedRemovalPlan @planArgs
    Assert-True ($plan.delete_files.Count -eq 4 -and $plan.delete_directories.Count -eq 0 -and -not $plan.execution_permitted) 'Only payload, provenance and ownership files planned; no deletion executed'
    Assert-True (@((Get-Content -Raw -LiteralPath $ownership | ConvertFrom-Json).managed_config).Count -eq 0) 'No user configuration is claimed'
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'README.md')) 'Planning leaves installed bytes intact'
    Assert-Refused { Install-RouterOwnedPackage @installArgs } 'Repeat install refuses existing destination'
    $empty = Join-Path $temp 'existing-empty'; $null = New-Item -ItemType Directory -Path $empty
    Assert-Refused { Install-RouterOwnedPackage -PackageRoot $package -InstallRoot $empty -ExpectedPackageSha256 $release.package_sha256 } 'Existing empty directory cannot be adopted'
    $wrong = $planArgs.Clone(); $wrong.ExpectedInstallationId = [guid]::NewGuid().ToString('D')
    Assert-Refused { Get-RouterOwnedRemovalPlan @wrong } 'Wrong installation identity refused'
    $wrong = $planArgs.Clone(); $wrong.ExpectedPackageSha256 = ('0' * 64)
    Assert-Refused { Get-RouterOwnedRemovalPlan @wrong } 'Wrong trusted package digest refused'

    # Unowned files, including runtime/config state, never enter the plan.
    'user sentinel' | Set-Content -LiteralPath (Join-Path $root 'config.toml')
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'logs')
    'runtime sentinel' | Set-Content -LiteralPath (Join-Path $root 'logs/request.json')
    $plan = Get-RouterOwnedRemovalPlan @planArgs
    Assert-True ($plan.preserve_files.Count -eq 2 -and (Join-Path $root 'config.toml') -notin $plan.delete_files) 'User config and logs are preserved explicitly'
    Assert-Refused { Install-RouterOwnedPackage -PackageRoot $package -InstallRoot (Join-Path $temp '.codex/new-install') -ExpectedPackageSha256 $release.package_sha256 } 'Codex directory refused even with explicit destination'

    # Fake a post-verification copy mismatch, without threads or real user files.
    # The fake is module-private and is removed by reimporting the real module.
    $module = Get-Module router-install-ownership
    $faultPackage = & $module { param($p, $digest) Get-RouterVerifiedPackage $p $digest } $package $release.package_sha256
    $faultPackage.files[0].sha256 = ('0' * 64)
    & $module {
        param($fake)
        $script:FaultPackage = $fake
        function script:Get-RouterVerifiedPackage { param($PackageRoot, $ExpectedPackageSha256) return $script:FaultPackage }
    } $faultPackage
    $faultRoot = Join-Path $temp 'failed-copy'
    try {
        Assert-Refused { Install-RouterOwnedPackage -PackageRoot $package -InstallRoot $faultRoot -ExpectedPackageSha256 $release.package_sha256 } 'Copy integrity failure refuses publication'
        Assert-True (-not (Test-Path -LiteralPath $faultRoot) -and @(Get-ChildItem -LiteralPath $temp -Directory -Force -Filter '.router-install-stage-*').Count -eq 1 -and $script:LastRefusal -like '*changed during copy*') 'Copy failure retains staging and never publishes a destination'
    }
    finally { Import-Module $modulePath -Force }

    $mutations = @(
        @{ name = 'Unknown schema'; change = { param($m) $m.schema_version = 2 } },
        @{ name = 'String schema'; change = { param($m) $m.schema_version = '1' } },
        @{ name = 'Unknown field'; change = { param($m) $m | Add-Member -NotePropertyName surprise -NotePropertyValue 'bad' } },
        @{ name = 'Wrong root'; change = { param($m) $m.install_root = $temp } },
        @{ name = 'Wrong version'; change = { param($m) $m.version = '99.0.0' } },
        @{ name = 'Wrong source commit'; change = { param($m) $m.source_commit = ('0' * 40) } },
        @{ name = 'Managed external config'; change = { param($m) $m.managed_config = @('config.toml') } },
        @{ name = 'Missing ledger entry'; change = { param($m) $m.files = @($m.files | Select-Object -Skip 1) } },
        @{ name = 'Duplicate ledger entry'; change = { param($m) $m.files[1] = $m.files[0] } },
        @{ name = 'Case alias'; change = { param($m) $m.files[0].path = $m.files[0].path.ToUpperInvariant() } },
        @{ name = 'Forged hash'; change = { param($m) $m.files[0].sha256 = ('0' * 64) } },
        @{ name = 'Forged size'; change = { param($m) $m.files[0].size = 999 } },
        @{ name = 'String size'; change = { param($m) $m.files[0].size = [string]$m.files[0].size } }
    )
    foreach ($case in $mutations) {
        $m = $original | ConvertFrom-Json
        & $case.change $m
        $m | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ownership
        Assert-Refused { Get-RouterOwnedRemovalPlan @planArgs } ($case.name + ' refused')
    }
    foreach ($unsafe in @('../outside.txt', '/outside.txt', 'C:/outside.txt', 'installer/../outside.txt', 'installer\setup.ps1', 'installer/setup.ps1:stream', 'NUL.txt', 'COM1', 'bad. ', 'bad.', 'config.toml', 'logs/file.txt')) {
        $m = $original | ConvertFrom-Json; $m.files[0].path = $unsafe
        $m | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ownership
        Assert-Refused { Get-RouterOwnedRemovalPlan @planArgs } "Unsafe ownership path refused: $unsafe"
    }
    '{invalid' | Set-Content -LiteralPath $ownership
    Assert-Refused { Get-RouterOwnedRemovalPlan @planArgs } 'Corrupt JSON refuses all planning'
    [IO.File]::WriteAllText($ownership, $original)
    $readme = Join-Path $root 'README.md'; $bytes = [IO.File]::ReadAllBytes($readme)
    'changed by user' | Set-Content -LiteralPath $readme
    Assert-Refused { Get-RouterOwnedRemovalPlan @planArgs } 'Changed owned file blocks the entire plan'
    [IO.File]::WriteAllBytes($readme, $bytes)
    Remove-Item -LiteralPath $readme
    Assert-Refused { Get-RouterOwnedRemovalPlan @planArgs } 'Missing owned file blocks the entire plan'
    [IO.File]::WriteAllBytes($readme, $bytes)
    Remove-Item -LiteralPath $ownership
    Assert-Refused { Get-RouterOwnedRemovalPlan @planArgs } 'Missing ownership manifest cannot infer ownership'
    [IO.File]::WriteAllText($ownership, $original)

    # Junctions on Windows require no symlink privilege. Never follow them.
    $outside = Join-Path $temp 'outside'; $null = New-Item -ItemType Directory -Path $outside
    $sentinel = Join-Path $outside 'sentinel.txt'; 'untouched' | Set-Content -LiteralPath $sentinel
    $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    $link = Join-Path $root 'linked'
    $null = New-Item -ItemType $kind -Path $link -Target $outside; $linkPaths.Add($link)
    Assert-Refused { Get-RouterOwnedRemovalPlan @planArgs } 'Unowned linked subtree blocks planning without traversal'
    Remove-Item -LiteralPath $link -Force; $linkPaths.Remove($link) | Out-Null
    $ownedDirectory = Join-Path $root 'installer'
    $savedDirectory = Join-Path $temp 'saved-installer'
    Move-Item -LiteralPath $ownedDirectory -Destination $savedDirectory
    $null = New-Item -ItemType $kind -Path $ownedDirectory -Target $outside; $linkPaths.Add($ownedDirectory)
    Assert-Refused { Get-RouterOwnedRemovalPlan @planArgs } 'Owned directory replaced by junction/link refuses planning'
    Remove-Item -LiteralPath $ownedDirectory -Force; $linkPaths.Remove($ownedDirectory) | Out-Null
    Move-Item -LiteralPath $savedDirectory -Destination $ownedDirectory
    $link = Join-Path $temp 'linked-parent'
    $null = New-Item -ItemType $kind -Path $link -Target $outside; $linkPaths.Add($link)
    Assert-Refused { Install-RouterOwnedPackage -PackageRoot $package -InstallRoot (Join-Path $link 'install') -ExpectedPackageSha256 $release.package_sha256 } 'Linked install ancestor refused'
    Assert-True ((Get-Content -LiteralPath $sentinel -Raw).Trim() -eq 'untouched' -and -not (Test-Path -LiteralPath (Join-Path $outside 'install'))) 'Outside sentinel and destination preserved'
    Remove-Item -LiteralPath $link -Force; $linkPaths.Remove($link) | Out-Null
    $link = Join-Path $package 'linked'
    $null = New-Item -ItemType $kind -Path $link -Target $outside; $linkPaths.Add($link)
    Assert-Refused { Install-RouterOwnedPackage -PackageRoot $package -InstallRoot (Join-Path $temp 'bad-link-install') -ExpectedPackageSha256 $release.package_sha256 } 'Linked package entry refused'
    Remove-Item -LiteralPath $link -Force; $linkPaths.Remove($link) | Out-Null

    $packageReadme = Join-Path $package 'README.md'
    'tampered package' | Set-Content -LiteralPath $packageReadme
    $badRoot = Join-Path $temp 'bad-package-install'
    Assert-Refused { Install-RouterOwnedPackage -PackageRoot $package -InstallRoot $badRoot -ExpectedPackageSha256 $release.package_sha256 } 'PR6 tampered package refused before installation'
    Assert-True (-not (Test-Path -LiteralPath $badRoot)) 'Failed package validation leaves no destination'
    Assert-True ((Get-Content -LiteralPath (Join-Path $root 'config.toml') -Raw).Trim() -eq 'user sentinel') 'All negative tests preserve user sentinel'
    Write-Host "Ownership validation summary: PASS=$passes FAIL=$($failures.Count) platform=$([Runtime.InteropServices.RuntimeInformation]::OSDescription)"
    if ($failures.Count) { exit 1 }
    Write-Host 'Router install ownership validation PASSED'
}
finally {
    # Only the test owns these directories; remove junctions before temp cleanup.
    foreach ($link in $linkPaths) { if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force } }
    Remove-Item -LiteralPath $temp -Recurse -Force
    Remove-Module router-install-ownership -ErrorAction SilentlyContinue
}
