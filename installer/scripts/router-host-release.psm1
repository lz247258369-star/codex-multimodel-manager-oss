# LR15-PR9: compiled Host artifact only; not a PR6 product/PR7 installation.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Policy = Import-Module (Join-Path $PSScriptRoot 'router-install-ownership.psm1') -PassThru
$script:HostManifest = 'router-host-release-manifest.json'
function Assert-HostPlainPath([string]$Path) { & $script:Policy { param($p) Assert-RouterPlainPath $p } $Path }
function Assert-HostRelativePath([string]$Path) { & $script:Policy { param($p) Assert-RouterRelativePath $p } $Path }
function Assert-HostFields($Object, [string[]]$Fields) { & $script:Policy { param($o,$f) Assert-RouterObjectFields $o $f } $Object $Fields }
function Get-HostTreeFiles([string]$Root) { & $script:Policy { param($r) Get-RouterTreeFiles $r } $Root }
function Get-HostHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-HostDigest([array]$Files) {
    $lines = @($Files | ForEach-Object { "$($_.path):$($_.size):$($_.sha256)" })
    [Array]::Sort($lines, [StringComparer]::Ordinal)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Assert-HostVersion([string]$Version) {
    if ($Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
        @($Version.Split('.') | Where-Object { [long]$_ -gt 65534 }).Count) { throw 'Three-part numeric release version required' }
}
function Assert-HostPayloadPath([string]$Path) {
    Assert-HostRelativePath $Path
    if ($Path -cmatch '^Router\.[A-Za-z0-9.]+\.dll$' -and $Path -notmatch '(?i)test|fake') { return }
    if ($Path -cin @('Router.Host.exe','Router.Host.deps.json','Router.Host.runtimeconfig.json','config/router.defaults.json','model-catalog.json')) { return }
    throw "Unknown Host payload path: $Path"
}
function Assert-HostExecutable([string]$Path) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw 'Host entry is not a PE executable' }
        $reader.BaseStream.Position = 0x3c; $offset = $reader.ReadUInt32()
        $reader.BaseStream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw 'Host entry must be Windows AMD64 PE' }
        $reader.BaseStream.Position = $offset + 24
        if ($reader.ReadUInt16() -ne 0x20b) { throw 'Host entry must be PE32+' }
    }
    finally { $reader.Dispose() }
}
function Assert-HostStructure([string]$Root, [string]$Version, [array]$Files) {
    $required = @('Router.Host.exe','Router.Host.dll','Router.Host.deps.json','Router.Host.runtimeconfig.json','config/router.defaults.json','model-catalog.json')
    foreach ($path in $required) { if ($path -cnotin $Files.path) { throw "Required Host payload missing: $path" } }
    Assert-HostExecutable (Join-Path $Root 'Router.Host.exe')
    $assembly = [Reflection.AssemblyName]::GetAssemblyName((Join-Path $Root 'Router.Host.dll'))
    if ($assembly.Name -cne 'Router.Host' -or $assembly.Version.ToString() -cne "$Version.0") { throw 'Host assembly identity/version mismatch' }
    $runtime = Get-Content -LiteralPath (Join-Path $Root 'Router.Host.runtimeconfig.json') -Raw | ConvertFrom-Json
    if ($runtime.runtimeOptions.tfm -cne 'net10.0' -or $runtime.runtimeOptions.rollForward -cne 'LatestPatch') { throw 'Unsupported runtime compatibility policy' }
    $frameworks = @($runtime.runtimeOptions.frameworks)
    if ($frameworks.Count -ne 2 -or @($frameworks | Where-Object { $_.name -cnotin @('Microsoft.NETCore.App','Microsoft.AspNetCore.App') -or $_.version -cne '10.0.0' }).Count -or
        @($frameworks.name | Sort-Object -Unique).Count -ne 2) { throw '.NET/ASP.NET Core 10 x64 runtime requirements mismatch' }
    $deps = Get-Content -LiteralPath (Join-Path $Root 'Router.Host.deps.json') -Raw | ConvertFrom-Json
    $targetName = '.NETCoreApp,Version=v10.0/win-x64'
    if ($deps.runtimeTarget.name -cne $targetName) { throw 'Host dependency target mismatch' }
    $target = $deps.targets.PSObject.Properties[$targetName].Value
    $runtimeFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($library in $target.PSObject.Properties) {
        if ($deps.libraries.PSObject.Properties[$library.Name].Value.type -cne 'project') { throw 'Unreviewed external runtime dependency' }
        foreach ($asset in $library.Value.runtime.PSObject.Properties) {
            Assert-HostPayloadPath $asset.Name
            $null = $runtimeFiles.Add($asset.Name)
            if ($asset.Name -cnotin $Files.path) { throw "Runtime dependency missing: $($asset.Name)" }
        }
    }
    foreach ($dll in @($Files.path | Where-Object { $_.EndsWith('.dll') })) {
        if (-not $runtimeFiles.Contains($dll)) { throw "Unreferenced assembly in publish output: $dll" }
    }
    $defaults = Get-Content -LiteralPath (Join-Path $Root 'config/router.defaults.json') -Raw | ConvertFrom-Json
    if ($defaults.mode -cne 'direct' -or $defaults.local_router.enabled -isnot [bool] -or $defaults.local_router.enabled) { throw 'Release defaults must remain Router-disabled' }
    $null = Get-Content -LiteralPath (Join-Path $Root 'model-catalog.json') -Raw | ConvertFrom-Json
}
function Get-VerifiedRouterHostRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReleaseRoot,
        [Parameter(Mandatory)][string]$ExpectedManifestSha256,
        [Parameter(Mandatory)][string]$ExpectedPackageSha256,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$ExpectedSourceCommit,
        [string]$ExpectedTargetRuntime = 'win-x64'
    )
    Assert-HostVersion $ExpectedVersion
    if ($ExpectedTargetRuntime -cne 'win-x64' -or $ExpectedSourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
        $ExpectedManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or $ExpectedPackageSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'External trusted release identities required' }
    $root = Assert-HostPlainPath $ReleaseRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Host release missing' }
    $actual = @(Get-HostTreeFiles $root)
    $manifestPath = Join-Path $root $script:HostManifest
    if ((Get-HostHash $manifestPath) -cne $ExpectedManifestSha256) { throw 'Host manifest differs from external trusted digest' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-HostFields $manifest @('schema_version','product','component','version','source_commit','target_runtime','deployment_mode','entry_file','file_count','files','package_sha256','runtime_prerequisites')
    foreach ($field in @('product','component','version','source_commit','target_runtime','deployment_mode','entry_file','package_sha256')) {
        if ($manifest.$field -isnot [string]) { throw 'Invalid Host identity type' }
    }
    if ($manifest.schema_version -isnot [int] -and $manifest.schema_version -isnot [long]) { throw 'Invalid Host schema type' }
    if ($manifest.schema_version -ne 1 -or $manifest.product -cne 'codex-multimodel-manager' -or $manifest.component -cne 'Router.Host' -or
        $manifest.version -cne $ExpectedVersion -or $manifest.source_commit -cne $ExpectedSourceCommit -or $manifest.target_runtime -cne 'win-x64' -or
        $manifest.deployment_mode -cne 'framework-dependent' -or $manifest.entry_file -cne 'Router.Host.exe' -or $manifest.package_sha256 -cne $ExpectedPackageSha256) { throw 'Host release identity mismatch' }
    Assert-HostFields $manifest.runtime_prerequisites @('tfm','architecture','frameworks','minimum_version','roll_forward','os')
    $req = $manifest.runtime_prerequisites
    foreach ($field in @('tfm','architecture','minimum_version','roll_forward','os')) {
        if ($req.$field -isnot [string]) { throw 'Invalid runtime prerequisite type' }
    }
    if ($req.tfm -cne 'net10.0' -or $req.architecture -cne 'x64' -or $req.minimum_version -cne '10.0.0' -or $req.roll_forward -cne 'LatestPatch' -or
        $req.os -cne 'Windows supported by .NET 10' -or $req.frameworks -isnot [array] -or ($req.frameworks -join '|') -cne 'Microsoft.NETCore.App|Microsoft.AspNetCore.App') { throw 'Host prerequisites mismatch' }
    if ($manifest.files -isnot [array] -or $manifest.file_count -isnot [int] -and $manifest.file_count -isnot [long] -or $manifest.files.Count -ne $manifest.file_count -or $manifest.files.Count -eq 0) { throw 'Invalid Host ledger count' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = @(
        foreach ($entry in $manifest.files) {
            Assert-HostFields $entry @('path','size','sha256')
            if ($entry.path -isnot [string] -or $entry.sha256 -isnot [string] -or $entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                $entry.size -isnot [int] -and $entry.size -isnot [long] -or $entry.size -lt 0) { throw 'Invalid Host file identity' }
            Assert-HostPayloadPath $entry.path
            if (-not $seen.Add($entry.path)) { throw 'Host case/duplicate path collision' }
            $path = Assert-HostPlainPath (Join-Path $root $entry.path)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne $entry.size -or (Get-HostHash $path) -cne $entry.sha256) { throw "Host file missing or changed: $($entry.path)" }
            $entry
        }
    )
    $allowed = @($files.path) + @($script:HostManifest)
    foreach ($path in $actual) {
        $relative = [IO.Path]::GetRelativePath($root, $path).Replace('\','/')
        if ($relative -cnotin $allowed) { throw "Unknown Host release file: $relative" }
    }
    # Reject unknown/unsafe directories too (including empty linked trees).
    $allowedDirs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $null = $allowedDirs.Add('config')
    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -Recurse -Force) {
        if (-not $allowedDirs.Contains([IO.Path]::GetRelativePath($root,$dir.FullName).Replace('\','/'))) { throw 'Unknown Host release directory' }
    }
    if ((Get-HostDigest $files) -cne $ExpectedPackageSha256) { throw 'Host payload digest mismatch' }
    Assert-HostStructure $root $ExpectedVersion $files
    # Independent Host artifact is intentionally NOT an installable PR6 package.
    return [pscustomobject]@{ root = $root; manifest = $manifest; files = @($files) + @([pscustomobject]@{path=$script:HostManifest;size=(Get-Item $manifestPath).Length;sha256=$ExpectedManifestSha256}); installation_permitted = $false }
}
function Invoke-HostTool([string]$Tool, [string[]]$Arguments, [string]$LogPath = '') {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $output = @(& $Tool @Arguments 2>&1); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if ($LogPath) { $output | Out-File -LiteralPath $LogPath -Encoding utf8 }
    if ($code -ne 0) { throw "$Tool failed ($code): $($output -join ' ')" }
    return ($output -join "`n").Trim()
}
function New-RouterHostRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$Version,
        [string]$TargetRuntime = 'win-x64'
    )
    Assert-HostVersion $Version
    if ($TargetRuntime -cne 'win-x64' -or $SourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'Only explicit Git commit and win-x64 releases are supported' }
    $source = Assert-HostPlainPath $SourceRoot; $output = Assert-HostPlainPath $OutputRoot
    if ($source -match '(?i)(^|[\\/])\.codex([\\/]|$)' -or
        (Invoke-HostTool git @('-C',$source,'rev-parse','--show-prefix'))) { throw 'Source must be the isolated Git checkout root' }
    if (-not (Test-Path -LiteralPath $output -PathType Container) -or $output -match '(?i)(^|[\\/])\.codex([\\/]|$)') { throw 'Existing isolated output parent required' }
    $relativeOutput = [IO.Path]::GetRelativePath($source,$output)
    if ($relativeOutput -eq '.' -or (-not [IO.Path]::IsPathRooted($relativeOutput) -and $relativeOutput -notmatch '^\.\.([\\/]|$)')) { throw 'Output must be outside source checkout' }
    $head = Invoke-HostTool git @('-C',$source,'rev-parse','--verify','HEAD^{commit}')
    if ($head -cne $SourceCommit) { throw 'Source commit must equal checked-out HEAD' }
    if (Invoke-HostTool git @('-C',$source,'status','--porcelain','--untracked-files=all')) { throw 'Dirty source checkout refused; commit/export a trusted source first' }
    $final = Join-Path $output "router-host-$Version-win-x64-$($SourceCommit.Substring(0,8))"
    if (Test-Path -LiteralPath $final) { throw 'Host release destination already exists; never overwrite/adopt' }
    $inputRoots = @('local-router/src','local-router/Directory.Build.props','local-router/Directory.Packages.props','local-router/global.json','local-router/config/router.defaults.json','installer/model-catalog.json')
    $tree = Invoke-HostTool git (@('-C',$source,'ls-tree','-r',$SourceCommit,'--') + $inputRoots)
    $inputSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $tree.Split("`n")) {
        if ($line -cnotmatch '^100(644|755) blob [0-9a-f]{40}\t(.+)$') { throw 'Linked/submodule/unknown source entry refused' }
        $path = $Matches[2]; Assert-HostRelativePath $path
        if (-not $inputSeen.Add($path)) { throw 'Source case collision refused' }
        if ($path -match '(?i)(^|/)(bin|obj|tests|.*Tests)(/|$)' -or $path -notmatch '\.(cs|csproj|json|props)$') { throw "Unreviewed build input: $path" }
        if ($path.EndsWith('.json') -and $path -cnotin @('local-router/global.json','local-router/config/router.defaults.json','installer/model-catalog.json') -and
            $path -cnotmatch '^local-router/src/Router\.[A-Za-z0-9.]+/packages\.lock\.json$') { throw "Unreviewed source JSON/state input: $path" }
    }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('router-host-build-' + [guid]::NewGuid().ToString('N'))
    $stage = Join-Path $output ('.router-host-release-stage-' + [guid]::NewGuid().ToString('N'))
    $null = Assert-HostPlainPath $work; $null = New-Item -ItemType Directory -Path $work, $stage
    # All generated source/cache/staging is retained on error; no recursive cleanup.
    try {
        $archive = Join-Path $work 'source.tar'; $export = Join-Path $work 'source'
        $null = New-Item -ItemType Directory -Path $export
        $null = Invoke-HostTool git (@('-C',$source,'archive','--format=tar',"--output=$archive",$SourceCommit,'--') + $inputRoots)
        [System.Formats.Tar.TarFile]::ExtractToDirectory($archive,$export,$false)
        $buildRoot = Join-Path $export 'local-router'
        $sdk = (Get-Content -LiteralPath (Join-Path $buildRoot 'global.json') -Raw | ConvertFrom-Json).sdk.version
        Push-Location $buildRoot
        try {
            if ((Invoke-HostTool dotnet @('--version')) -cne $sdk -or $sdk -cne '10.0.400') { throw 'Pinned .NET SDK 10.0.400 required' }
            $project = 'src/Router.Host/Router.Host.csproj'
            $null = Invoke-HostTool dotnet @('restore',$project,'--locked-mode') (Join-Path $work 'restore-portable.log')
            # Existing production graph has Project entries only. Derive an EMPTY
            # RID target in isolated copies; do not unlock/evaluate new dependencies.
            $locks = @(Get-ChildItem -LiteralPath (Join-Path $buildRoot 'src') -Filter packages.lock.json -Recurse)
            $lockedHashes = @{}
            foreach ($lock in $locks) {
                $json = Get-Content -LiteralPath $lock.FullName -Raw | ConvertFrom-Json
                if ($json.version -ne 2 -or ($json.dependencies.PSObject.Properties.Name -join '|') -cne 'net10.0') { throw 'Unsupported source lock schema/targets' }
                foreach ($dep in $json.dependencies.'net10.0'.PSObject.Properties) {
                    if ($dep.Value.type -cne 'Project') { throw 'RID lock derivation requires reviewed Project-only dependency graph' }
                }
                $json.dependencies | Add-Member -NotePropertyName 'net10.0/win-x64' -NotePropertyValue ([pscustomobject]@{})
                $json | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $lock.FullName -Encoding utf8NoBOM
                $lockedHashes[$lock.FullName] = Get-HostHash $lock.FullName
            }
            $null = Invoke-HostTool dotnet @('restore',$project,'-r','win-x64','--locked-mode','-p:SelfContained=false') (Join-Path $work 'restore-rid.log')
            $null = Invoke-HostTool dotnet @('publish',$project,'-c','Release','-r','win-x64','--self-contained','false','--no-restore','-o',$stage,
                '-p:PublishSingleFile=false','-p:UseAppHost=true','-p:DebugType=None','-p:DebugSymbols=false','-p:RollForward=LatestPatch',"-p:Version=$Version",'-p:ContinuousIntegrationBuild=true') (Join-Path $work 'publish.log')
            foreach ($lock in $locks) { if ((Get-HostHash $lock.FullName) -cne $lockedHashes[$lock.FullName]) { throw 'Locked dependency graph changed during RID restore/publish' } }
        }
        finally { Pop-Location }
        $files = @(
            foreach ($path in @(Get-HostTreeFiles $stage)) {
                $relative = [IO.Path]::GetRelativePath($stage,$path).Replace('\','/')
                Assert-HostPayloadPath $relative
                [pscustomobject]@{path=$relative;size=(Get-Item -LiteralPath $path).Length;sha256=(Get-HostHash $path)}
            }
        )
        Assert-HostStructure $stage $Version $files
        $manifest = [ordered]@{
            schema_version=1;product='codex-multimodel-manager';component='Router.Host';version=$Version;source_commit=$SourceCommit
            target_runtime='win-x64';deployment_mode='framework-dependent';entry_file='Router.Host.exe';file_count=$files.Count;files=$files
            package_sha256=(Get-HostDigest $files)
            runtime_prerequisites=[ordered]@{tfm='net10.0';architecture='x64';frameworks=@('Microsoft.NETCore.App','Microsoft.AspNetCore.App');minimum_version='10.0.0';roll_forward='LatestPatch';os='Windows supported by .NET 10'}
        }
        $manifestPath = Join-Path $stage $script:HostManifest
        $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
        $digest = Get-HostHash $manifestPath
        $null = Get-VerifiedRouterHostRelease -ReleaseRoot $stage -ExpectedManifestSha256 $digest -ExpectedPackageSha256 $manifest.package_sha256 -ExpectedVersion $Version -ExpectedSourceCommit $SourceCommit
        $null = Assert-HostPlainPath $final; [IO.Directory]::Move($stage,$final)
        return [pscustomobject]@{release_root=$final;manifest_sha256=$digest;package_sha256=$manifest.package_sha256;version=$Version;source_commit=$SourceCommit;target_runtime='win-x64';build_work=$work;installation_permitted=$false}
    }
    catch { $_.Exception.Data['build_work']=$work; $_.Exception.Data['release_stage']=$stage; throw }
}
Export-ModuleMember -Function New-RouterHostRelease, Get-VerifiedRouterHostRelease
