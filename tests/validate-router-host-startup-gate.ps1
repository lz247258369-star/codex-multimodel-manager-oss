param(
    [string]$RepositoryRoot = (Get-Location).Path,
    [switch]$UseExistingBuild
)
$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$pass = 0; $fail = 0; $native = 0
function Assert-True([bool]$Value, [string]$Message) {
    if ($Value) { $script:pass++; Write-Host "PASS  $Message" }
    else { $script:fail++; Write-Host "FAIL  $Message" }
}
$timer = [Diagnostics.Stopwatch]::StartNew()
$temp = Join-Path ([IO.Path]::GetTempPath()) ('lr15-pr10a-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
$children = [Collections.Generic.List[object]]::new()
$dotnet = (Get-Command dotnet -ErrorAction Stop).Source
$hostBuild = Join-Path $RepositoryRoot 'local-router/src/Router.Host/bin/Release/net10.0'
try {
    if (-not $UseExistingBuild) {
        & $dotnet build (Join-Path $RepositoryRoot 'local-router/src/Router.Host/Router.Host.csproj') --configuration Release --no-restore
        if ($LASTEXITCODE) { throw 'Host build failed' }
    }
    foreach ($file in @('Router.Host.dll','Router.State.dll','Router.Host.runtimeconfig.json','Router.Host.deps.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $hostBuild $file))) { throw "Missing built Host file: $file" }
    }
    # Reuse the Gate's actual Host build. Compile ONLY a tiny fixture with the
    # pinned SDK compiler/reference pack; no restore, publish or new test project.
    $sdk = @(& $dotnet --list-sdks | Where-Object { $_ -match '^10\.0\.400 \[(.+)\]$' })
    if ($sdk.Count -ne 1) { throw 'Pinned .NET 10.0.400 SDK required' }
    $sdkBase = [regex]::Match($sdk[0], '\[(.+)\]$').Groups[1].Value
    $compiler = Join-Path $sdkBase '10.0.400/Roslyn/bincore/csc.dll'
    $dotnetRoot = Split-Path $sdkBase -Parent
    $pack = Get-ChildItem -LiteralPath (Join-Path $dotnetRoot 'packs/Microsoft.NETCore.App.Ref') -Directory |
        Where-Object { $_.Name -match '^10\.0\.' } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $pack) { throw 'Missing .NET 10 reference pack' }
    $references = @((Get-ChildItem -LiteralPath (Join-Path $pack.FullName 'ref/net10.0') -Filter '*.dll').FullName) +
        @((Get-ChildItem -LiteralPath $hostBuild -Filter '*.dll').FullName)
    Copy-Item -Path (Join-Path $hostBuild '*') -Destination $temp -Recurse
    $probe = Join-Path $temp 'StartupGateProbe.dll'
    # A response file avoids the Windows process command-line length limit and
    # preserves Program Files / checkout paths without shell interpolation.
    $compileArgs = @('-nologo','-target:exe','-nullable:enable','-langversion:latest',('-out:"' + $probe + '"')) +
        @($references | ForEach-Object { '-r:"' + $_ + '"' }) +
        @('"' + (Join-Path $RepositoryRoot 'tests/fixtures/local-router/startup-gate/StartupGateProbe.cs') + '"',
          '"' + (Join-Path $RepositoryRoot 'local-router/tests/Router.Core.Tests/Fakes/BlockingRuntimeStateFileSystem.cs') + '"')
    $responseFile = Join-Path $temp 'probe-compile.rsp'
    [IO.File]::WriteAllLines($responseFile,$compileArgs,[Text.UTF8Encoding]::new($false))
    & $dotnet exec $compiler "@$responseFile"
    if ($LASTEXITCODE) { throw 'Isolated probe compile failed' }
    Assert-True $true 'Probe compiles against the actual Host/State build without a second publish'

    function Start-Probe([string]$Mode, [string]$Root) {
        $probeHome = Join-Path $temp ('child-home-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $probeHome
        $info = [Diagnostics.ProcessStartInfo]::new($dotnet)
        $info.UseShellExecute = $false
        $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        foreach ($arg in @('exec','--runtimeconfig',(Join-Path $temp 'Router.Host.runtimeconfig.json'),
            '--depsfile',(Join-Path $temp 'Router.Host.deps.json'),$probe,$Mode,$Root)) { $info.ArgumentList.Add($arg) }
        $info.WorkingDirectory = $temp
        $info.Environment.Clear()
        foreach ($name in @('HOME','USERPROFILE','APPDATA','LOCALAPPDATA','CODEX_HOME','TEMP','TMP')) { $info.Environment[$name] = $probeHome }
        $info.Environment['DOTNET_ROOT'] = Split-Path $dotnet -Parent
        $info.Environment['DOTNET_ROOT_X64'] = Split-Path $dotnet -Parent
        if ($IsWindows) { $info.Environment['SystemRoot'] = [Environment]::GetFolderPath('Windows') }
        $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
        if (-not $process.Start()) { throw 'Probe did not start' }
        $child = @{ Process = $process; Error = $process.StandardError.ReadToEndAsync(); Output = [Collections.Generic.List[string]]::new() }
        $children.Add($child)
        return $child
    }
    function Read-Line($Child) {
        $line = $Child.Process.StandardOutput.ReadLineAsync().WaitAsync([timespan]::FromSeconds(15)).GetAwaiter().GetResult()
        if ($null -ne $line) { $Child.Output.Add($line); Write-Host "PROBE $line" }
        return $line
    }
    function Throw-ProbeEarlyExit($Child, [string]$ExpectedMarker) {
        if (-not $Child.Process.WaitForExit(15000)) { throw 'Probe closed stdout but did not finish within the original deadline' }
        $errorText = $Child.Error.GetAwaiter().GetResult()
        # Only fixed production/fixture diagnostics. Never surface arbitrary
        # stderr, exception messages, private paths or request/provider content.
        $safeLines = @($errorText -split '\r?\n' | Where-Object {
            $_ -match '^\[local-router\] state_persistence_failed: target=(owner_record|runtime_state|managed_file) operation=[A-Za-z]+ cause=[A-Za-z][A-Za-z0-9]* hresult=[0-9a-f]{8} native=\d+ category=(sharing_violation|access_denied|unknown)\.$' -or
            $_ -match '^\[local-router\] state_write_failed: The router runtime state could not be written\. phase=(owner_record|ready_state|stopped_state) operation=(file_security|atomic_write)$' -or
            $_ -match '^\[local-router\] startup_gate_[a-z_]+: enabled Host startup refused; stage=[a-z_]+ cause=[A-Za-z][A-Za-z0-9]* native=\d+\.$' -or
            $_ -match '^PROBE_FAILURE phase=[a-z_]+ cause=[A-Za-z][A-Za-z0-9]* native=\d+ hresult=[0-9a-f]{8}$'
        })
        Write-Host "PROBE_EARLY_EXIT exit_code=$($Child.Process.ExitCode) expected=$ExpectedMarker"
        foreach ($safeLine in $safeLines) { Write-Host "PROBE_ERROR $safeLine" }
        if ($safeLines.Count -eq 0) { Write-Host 'PROBE_ERROR no_whitelisted_diagnostic; arbitrary stderr redacted' }
        throw "Probe exited before $ExpectedMarker; exit_code=$($Child.Process.ExitCode); sanitized diagnostics printed"
    }
    function Await-Marker($Child, [string]$Marker) {
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        do { $line = Read-Line $Child; if ($null -eq $line) { Throw-ProbeEarlyExit $Child $Marker } }
        until ($line.Contains($Marker) -or $deadline.Elapsed.TotalSeconds -gt 15)
        if (-not $line.Contains($Marker)) { throw "Probe marker timeout: $Marker" }
    }
    function Await-StartupOutcome($Child) {
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        do { $line = Read-Line $Child; if ($null -eq $line) { Throw-ProbeEarlyExit $Child 'startup_outcome' } }
        until ($line -eq 'STARTING_WINDOW' -or $line -eq 'PROBE_EXIT=2 PROVIDER_CALLS=0' -or $deadline.Elapsed.TotalSeconds -gt 15)
        if ($line -ne 'STARTING_WINDOW' -and $line -ne 'PROBE_EXIT=2 PROVIDER_CALLS=0') { throw 'Host startup outcome timeout' }
        return $line
    }
    function Finish-Probe($Child, [int]$Code) {
        if (-not $Child.Process.WaitForExit(15000)) { throw 'Owned probe exit timeout' }
        $tail = $Child.Process.StandardOutput.ReadToEnd()
        if ($tail) { $Child.Output.Add($tail); Write-Host "PROBE $tail" }
        $errorText = $Child.Error.GetAwaiter().GetResult()
        if ($errorText) { Write-Host "PROBE_ERROR $errorText" }
        Assert-True ($Child.Process.ExitCode -eq $Code) "Probe exit $Code (actual $($Child.Process.ExitCode))"
        return $errorText
    }
    function New-Case([switch]$Enabled, [switch]$InheritAcl) {
        $root = Join-Path $temp ('case-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        if ($IsWindows -and -not $InheritAcl) {
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $security = [Security.AccessControl.DirectorySecurity]::new()
            $security.SetOwner($sid); $security.SetAccessRuleProtection($true,$false)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
            $security.AddAccessRule($rule); Set-Acl -LiteralPath $root -AclObject $security
        }
        if ($Enabled) {
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'user')
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
            $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
            $config = @{ schema_version = 1; version = 1; mode = 'router'; local_router = @{ enabled = $true; port = $port } }
            $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'user/router.config.json')
        }
        return $root
    }

    # FIX5: ACL fixtures are performed by the child probe, which calls the same
    # managed ACL writers the gate uses. PowerShell cannot call those writers
    # (extension methods) and Set-Acl round-trips the SACL, which needs
    # SeSecurityPrivilege in a non-elevated session. Both facts were measured; the
    # fixtures therefore construct the DACL change the gate actually validates.
    # A scenario claiming "insufficient permissions" must first prove the denial is
    # effective for the coordination access mask, because a DENY on
    # FILE_READ_ATTRIBUTES alone is NOT (Windows grants read-attributes implicitly
    # whenever any other access is granted).
    function Invoke-AclProbe([string]$Root, [string]$Action, [string]$Argument = "") {
        $aclMode = if ($Argument) { "$Action`:$Argument" } else { $Action }
        $aclProbe = Start-Probe $aclMode $Root
        return (Finish-Probe $aclProbe 0)
    }

    $root = New-Case
    $disabled = Start-Probe 'disabled' $root
    Await-Marker $disabled '[local-router] DISABLED:'
    $null = Finish-Probe $disabled 0
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'runtime')) -and
        -not (Test-Path -LiteralPath (Join-Path $root 'user')) -and
        @(Get-ChildItem -LiteralPath $root -Recurse -File).Count -eq 0) 'Disabled Host creates no user/runtime state and resolves no secret'
    if (-not $IsWindows) {
        $refused = Start-Probe 'once' $root
        $errorText = Finish-Probe $refused 23
        Assert-True ($errorText.Contains('startup_gate_windows_required')) 'Non-Windows production gate refuses; no fake native PASS'
        Write-Host 'STARTUP_GATE_NATIVE NOT_RUN platform=Linux Windows evidence required'
    }
    else {
        $native++
        $root = New-Case
        $first = Start-Probe 'gate' $root; Await-Marker $first 'ACQUIRED'
        $second = Start-Probe 'once' $root
        Assert-True ((Finish-Probe $second 23).Contains('startup_gate_busy')) 'Held coordination denies a second process'
        $caseAlias = Start-Probe 'once' $root.ToUpperInvariant()
        Assert-True ((Finish-Probe $caseAlias 23).Contains('startup_gate_busy')) 'Case aliases select the same physical runtime identity'
        $runtime = Join-Path $root 'runtime'
        $attacks = Start-Probe 'directory-attacks' $root
        $attackErrors = Finish-Probe $attacks 31
        Write-Host $attackErrors
        foreach ($marker in @('JUNCTION_CONTROL', 'LEGACY_METADATA_WRITE_OPEN', 'REPARSE_RUNTIME', 'REPARSE_PARENT', 'REPLACE_RUNTIME', 'REPLACE_PARENT')) {
            Assert-True ($attackErrors.Contains("$marker PASS")) "Native directory attack: $marker; physical identities and sentinel retained"
        }
        $writeAttack = Start-Probe 'directory-write' $root
        # Both access classes a reparse replacement needs must be refused while
        # coordination is held: the data-write class by directory sharing, and the
        # metadata-write class (FILE_WRITE_ATTRIBUTES, which Windows keeps outside
        # FILE_SHARE_WRITE) by the explicit metadata-write guard. The refusal code
        # per class is reported, not required to be a single value.
        $writeAttackEvidence = Finish-Probe $writeAttack 30
        Assert-True ($writeAttackEvidence.Contains('DIRECTORY_WRITE_REFUSED')) 'Held directory refuses native write handles used for reparse replacement'
        Assert-True ($writeAttackEvidence -match 'DIRECTORY_WRITE_REFUSED generic=(?:5|32) metadata=(?:5|32)') 'Held directory reports a refusal code for both the data-write and metadata-write classes'
        Assert-True ($writeAttackEvidence -match 'metadata=5') 'The metadata-write class needed by FSCTL_SET_REPARSE_POINT is refused with ACCESS_DENIED'
        Write-Host 'STATE_IO_CONTEXT runtime_origin=gate_created strict_directory_sharing=True'
        $stateIo = Start-Probe 'state-io' $root
        $null = Finish-Probe $stateIo 0
        'original user bytes' | Set-Content -LiteralPath (Join-Path $runtime 'user.txt')
        $hash = (Get-FileHash -LiteralPath (Join-Path $runtime 'user.txt')).Hash
        $refusedMove = $false
        try { [IO.Directory]::Move($root, ($root + '-replaced')) }
        catch { $refusedMove = $true; Write-Host "STARTUP_GATE_RENAME_REFUSAL $($_.Exception.GetType().FullName) HResult=$($_.Exception.HResult)" }
        Assert-True ($refusedMove -and (Test-Path -LiteralPath $root) -and
            (Get-FileHash -LiteralPath (Join-Path $runtime 'user.txt')).Hash -eq $hash) 'Pinned ancestors refuse replacement and retain original user bytes'
        $first.Process.StandardInput.WriteLine('RELEASE'); $null = Finish-Probe $first 0
        $again = Start-Probe 'once' $root; $null = Finish-Probe $again 0
        # Finish-Probe may append several lines as one list element. Match a
        # scalar joined string, retaining the exact RELEASED line semantics.
        Assert-True (($again.Output -join "`n") -match '(?m)^RELEASED\r?$') 'Normal exit releases coordination for a subsequent process'

        $root = New-Case
        $left = Start-Probe 'race' $root; $right = Start-Probe 'race' $root
        Await-Marker $left 'WAITING'; Await-Marker $right 'WAITING'
        $left.Process.StandardInput.WriteLine('GO'); $right.Process.StandardInput.WriteLine('GO')
        $leftLine = Read-Line $left; $rightLine = Read-Line $right
        Assert-True (($leftLine -eq 'ACQUIRED') -xor ($rightLine -eq 'ACQUIRED')) 'Simultaneous processes have exactly one startup winner'
        if ($leftLine -eq 'ACQUIRED') { $winner=$left; $loser=$right } else { $winner=$right; $loser=$left }
        Assert-True ((Finish-Probe $loser 23).Contains('startup_gate_busy')) 'Concurrent loser fails closed'
        $winner.Process.StandardInput.WriteLine('RELEASE'); $null = Finish-Probe $winner 0

        # Differential control: an existing plain runtime inherits the private
        # parent's OI/CI ACL. The gate uses identical strict sharing in both cases.
        $controlRoot = New-Case
        $null = New-Item -ItemType Directory -Path (Join-Path $controlRoot 'runtime')
        $controlGate = Start-Probe 'gate' $controlRoot; Await-Marker $controlGate 'ACQUIRED'
        Write-Host 'STATE_IO_CONTEXT runtime_origin=private_preexisting strict_directory_sharing=True'
        $controlIo = Start-Probe 'state-io' $controlRoot
        $null = Finish-Probe $controlIo 0
        $controlGate.Process.StandardInput.WriteLine('RELEASE'); $null = Finish-Probe $controlGate 0

        # Same production provider/layout, but a GUID CODEX_HOME in the child.
        # The actual user's profile, configuration and running Host are untouched.
        $layoutRoot = New-Case
        $null = New-Item -ItemType Directory -Path (Join-Path $layoutRoot 'multimodel-manager/local-router')
        $layoutGate = Start-Probe 'default-gate' $layoutRoot; Await-Marker $layoutGate 'ACQUIRED'
        Write-Host 'STATE_IO_CONTEXT runtime_origin=isolated_default_codex_home strict_directory_sharing=True'
        $layoutIo = Start-Probe 'default-state-io' $layoutRoot
        $null = Finish-Probe $layoutIo 0
        Assert-True (($layoutIo.Output -join "`n") -match '(?m)^DEFAULT_LAYOUT_PATHS PASS\r?$') 'Production default path provider supports held-gate state I/O in isolated CODEX_HOME layout'
        $layoutGate.Process.StandardInput.WriteLine('RELEASE'); $null = Finish-Probe $layoutGate 0

        # FIX2: reproduce the historical inherited runner-temp sandbox after
        # low-level held-gate I/O evidence. Report actual Host outcome and ACL roles;
        # runner ACLs vary, so either trusted STARTING or fail-closed is valid.
        $inheritedRoot = New-Case -Enabled -InheritAcl
        $inheritedHost = Start-Probe 'host-race' $inheritedRoot
        Await-Marker $inheritedHost 'WAITING'; $inheritedHost.Process.StandardInput.WriteLine('GO')
        $inheritedOutcome = Await-StartupOutcome $inheritedHost
        Write-Host "FIX2_INHERITED_HOST outcome=$inheritedOutcome"
        if ($inheritedOutcome -eq 'STARTING_WINDOW') {
            $inheritedHost.Process.StandardInput.WriteLine('STOP'); $inheritedError = Finish-Probe $inheritedHost 130
            Assert-True ($inheritedError -match '(?m)^FIX2_ACL owner_trusted=True protected=(?:True|False) other_mutation_aces=0\r?$') 'Inherited sandbox startup requires evidence of trusted owner and no foreign mutation grants'
        }
        else {
            $inheritedError = Finish-Probe $inheritedHost 2
            $unsafeInheritedAcl = $inheritedError.Contains('owner_trusted=False')
            if ($inheritedError -match 'other_mutation_aces=(\d+)') {
                $unsafeInheritedAcl = $unsafeInheritedAcl -or ([int]$Matches[1] -gt 0)
            }
            Assert-True ($unsafeInheritedAcl -and $inheritedError.Contains('startup_gate_untrusted') -and
                $inheritedError.Contains('stage=runtime_parent_acl')) 'Inherited sandbox may refuse only with evidence of unsafe parent ACL; trusted inherited directories must start'
        }
        $root = New-Case -Enabled
        $left = Start-Probe 'host-race' $root; $right = Start-Probe 'host-race' $root
        Await-Marker $left 'WAITING'; Await-Marker $right 'WAITING'
        $left.Process.StandardInput.WriteLine('GO'); $right.Process.StandardInput.WriteLine('GO')
        $leftLine = Await-StartupOutcome $left; $rightLine = Await-StartupOutcome $right
        Assert-True (($leftLine -eq 'STARTING_WINDOW') -xor ($rightLine -eq 'STARTING_WINDOW')) 'Two simultaneous actual Hosts have exactly one startup winner'
        if ($leftLine -eq 'STARTING_WINDOW') { $winner=$left; $loser=$right } else { $winner=$right; $loser=$left }
        Assert-True ((Finish-Probe $loser 2).Contains('startup_gate_busy')) 'Actual simultaneous Host loser never passes the startup gate'
        $winner.Process.StandardInput.WriteLine('STOP'); $null = Finish-Probe $winner 130

        foreach ($phase in @('starting','ready')) {
            $root = New-Case -Enabled
            $owner = Start-Probe $phase $root
            $marker = if ($phase -eq 'starting') { 'STARTING_WINDOW' } else { '[local-router] READY' }
            Await-Marker $owner $marker
            $ownerPath = Join-Path $root 'runtime/router.pid.json'
            $original = (Get-FileHash -LiteralPath $ownerPath).Hash
            $hostAttack = Start-Probe 'directory-attacks' $root
            $hostAttackErrors = Finish-Probe $hostAttack 31
            Write-Host $hostAttackErrors
            Assert-True ($hostAttackErrors.Contains('REPLACE_RUNTIME PASS') -and
                $hostAttackErrors.Contains('REPLACE_PARENT PASS') -and
                (Get-FileHash -LiteralPath $ownerPath).Hash -eq $original) "Actual $phase Host retains directory identity and original ownership under native attacks"
            $record = Get-Content -Raw -LiteralPath $ownerPath | ConvertFrom-Json
            Assert-True ($record.schema_version -eq 1 -and $record.pid -eq $owner.Process.Id -and
                $record.process_fingerprint -match '^[0-9a-f]{64}$') "Existing schema-v1 Owner Record remains valid in $phase"
            $competitor = Start-Probe 'ready' $root
            Assert-True ((Finish-Probe $competitor 2).Contains('startup_gate_busy')) "Actual Host refuses a competitor during $phase"
            Assert-True ((Get-FileHash -LiteralPath $ownerPath).Hash -eq $original) "Competitor preserves original $phase ownership"
            $owner.Process.StandardInput.WriteLine('STOP')
            $expected = if ($phase -eq 'starting') { 130 } else { 0 }
            $null = Finish-Probe $owner $expected
            Assert-True (-not (Test-Path -LiteralPath $ownerPath) -and
                @(Get-ChildItem -LiteralPath (Join-Path $root 'quarantine') -Recurse -File).Count -gt 0) "$phase shutdown retains Owner Record archive"
            $released = Start-Probe 'once' $root; $null = Finish-Probe $released 0
        }

        $root = New-Case -Enabled
        $failedStop = Start-Probe 'stop-write-failure' $root
        Await-Marker $failedStop '[local-router] READY'
        $failedStop.Process.StandardInput.WriteLine('STOP')
        Assert-True ((Finish-Probe $failedStop 2).Contains('STOP_WRITE_FAILURE PASS')) 'Failed durable STOPPED replacement retains original READY/ownership and releases ingress/coordination'

        $root = New-Case -Enabled
        $mutating = Start-Probe 'mutating' $root; Await-Marker $mutating '[local-router] READY'
        Assert-True ((Test-Path -LiteralPath (Join-Path $root 'runtime/router.pid.json')) -and
            -not (Test-Path -LiteralPath (Join-Path $root 'other-runtime'))) 'Mutable path provider cannot redirect ownership away from the pinned runtime identity'
        $mutating.Process.StandardInput.WriteLine('STOP'); $null = Finish-Probe $mutating 0
        $root = New-Case -Enabled
        $mismatch = Start-Probe 'mismatch' $root
        Assert-True ((Finish-Probe $mismatch 2).Contains('startup_gate_runtime_paths_mismatch') -and
            -not (Test-Path -LiteralPath (Join-Path $root 'runtime'))) 'Mismatched owner/state directories refuse before gate state creation or secret resolution'

        $root = New-Case -Enabled
        $crashed = Start-Probe 'ready' $root; Await-Marker $crashed '[local-router] READY'
        $crashed.Process.Kill() # ONLY the process object this test created.
        if (-not $crashed.Process.WaitForExit(15000)) { throw 'Known probe crash exit timeout' }
        $restarted = Start-Probe 'ready' $root; Await-Marker $restarted '[local-router] READY'
        Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $root 'quarantine') -Recurse -File).Count -gt 0) 'Abnormal exit frees kernel coordination; next Host revalidates and archives stale owner'
        $restarted.Process.StandardInput.WriteLine('STOP'); $null = Finish-Probe $restarted 0

        $root = New-Case
        $once = Start-Probe 'once' $root; $null = Finish-Probe $once 0
        $runtime = Join-Path $root 'runtime'
        $snapshotA = Join-Path $temp ('dacl-a-' + [guid]::NewGuid().ToString('N') + '.bin')
        $snapshotB = Join-Path $temp ('dacl-b-' + [guid]::NewGuid().ToString('N') + '.bin')

        # FIX5.B: a denial Windows actually enforces on the coordination access mask
        # must refuse startup - after the fixture proves the denial is effective.
        try {
            $null = Invoke-AclProbe $root 'acl-snapshot' $snapshotA
            $null = Invoke-AclProbe $root 'acl-deny' 'ListDirectory'
            $openCheck = Start-Probe 'gate-open' $root
            Assert-True ((Finish-Probe $openCheck 0).Contains('refused=True')) 'FIX5: the ListDirectory denial is effective for the coordination access mask'
            $probeDenied = Start-Probe 'once' $root
            Assert-True ((Finish-Probe $probeDenied 23).Contains('startup_gate_untrusted')) 'Insufficient directory permissions refuse coordination'
        }
        finally { $null = Invoke-AclProbe $root 'acl-restore' $snapshotA }

        # FIX5.B2: a denial that does not block the pin open but does block state
        # publication (FILE_WRITE_DATA/ADD_FILE) must still refuse at acquisition.
        try {
            $null = Invoke-AclProbe $root 'acl-deny' 'WriteData'
            $probeWriteDenied = Start-Probe 'once' $root
            Assert-True ((Finish-Probe $probeWriteDenied 23).Contains('startup_gate_untrusted')) 'FIX5: a denied state-write right refuses coordination fail-closed'
        }
        finally { $null = Invoke-AclProbe $root 'acl-restore' $snapshotA }

        # FIX5.E: a refused acquisition must not leak coordination. The refusal is
        # injected with an ACL deny, which is the only injectable lever: measured on
        # Windows, a read-only share mode does not block WRITE_DAC/WRITE_OWNER opens
        # (only the data-write class), and the owner keeps implicit DACL-write
        # rights, so a guard-install/restore failure cannot be forced from outside.
        # The observable contract - fail closed, no deadlock, no leaked mutex - is
        # asserted here.
        try {
            $null = Invoke-AclProbe $root 'acl-deny' 'ReadPermissions'
            $refusedAcquire = Start-Probe 'once' $root
            Assert-True ((Finish-Probe $refusedAcquire 23).Contains('startup_gate_untrusted')) 'FIX5: an acquisition refused by the directory ACL fails closed'
        }
        finally { $null = Invoke-AclProbe $root 'acl-restore' $snapshotA }
        $afterRefusal = Start-Probe 'once' $root
        $afterRefusalText = Finish-Probe $afterRefusal 0
        Assert-True (-not $afterRefusalText.Contains('startup_gate_busy')) 'FIX5: coordination is released after a refused acquisition (no leaked mutex or deadlock)'

        # FIX5.F/G: a guard-shaped residue (what a crashed Host leaves behind) is
        # healed by the next acquisition, and the original DACL is restored
        # byte-for-byte after release.
        $null = Invoke-AclProbe $root 'acl-snapshot' $snapshotA
        $null = Invoke-AclProbe $root 'acl-deny' 'WriteAttributes,WriteExtendedAttributes'
        $residueHealed = Start-Probe 'once' $root
        $residueHealedText = Finish-Probe $residueHealed 0
        Assert-True (-not $residueHealedText.Contains('startup_gate_busy')) 'FIX5: a guard-shaped residue does not block the next acquisition'
        $null = Invoke-AclProbe $root 'acl-snapshot' $snapshotB
        Assert-True (((Get-FileHash -LiteralPath $snapshotA -Algorithm SHA256).Hash) -eq ((Get-FileHash -LiteralPath $snapshotB -Algorithm SHA256).Hash)) 'FIX5: the guard residue is removed and the original DACL restored'

        $root = New-Case
        $once = Start-Probe 'once' $root; $null = Finish-Probe $once 0
        $runtime = Join-Path $root 'runtime'
        $null = Invoke-AclProbe $root 'acl-snapshot' $snapshotA
        $normalGate = Start-Probe 'gate' $root; Await-Marker $normalGate 'ACQUIRED'
        $normalGate.Process.StandardInput.WriteLine('RELEASE'); $null = Finish-Probe $normalGate 0
        $null = Invoke-AclProbe $root 'acl-snapshot' $snapshotB
        Assert-True (((Get-FileHash -LiteralPath $snapshotA -Algorithm SHA256).Hash) -eq ((Get-FileHash -LiteralPath $snapshotB -Algorithm SHA256).Hash)) 'FIX5: a normal release restores the exact runtime directory DACL'

        $root = New-Case
        $once = Start-Probe 'once' $root; $null = Finish-Probe $once 0
        $runtime = Join-Path $root 'runtime'
        $null = Invoke-AclProbe $root 'acl-snapshot' $snapshotA
        try {
            $unsafeProbe = Start-Probe 'acl-allow-everyone' $root
            $null = Finish-Probe $unsafeProbe 0
            $untrusted = Start-Probe 'once' $root
            Assert-True ((Finish-Probe $untrusted 23).Contains('startup_gate_untrusted')) 'Broadly writable runtime identity is not adopted'
        }
        finally { $null = Invoke-AclProbe $root 'acl-restore' $snapshotA }

        foreach ($kind in @('Junction','SymbolicLink')) {
            $root = New-Case; $target = New-Case
            'untouched' | Set-Content -LiteralPath (Join-Path $target 'user.txt')
            try {
                $null = New-Item -ItemType $kind -Path (Join-Path $root 'runtime') -Target $target
            }
            catch {
                # Creating a directory symbolic link needs SeCreateSymbolicLinkPrivilege,
                # which a non-elevated session does not hold (measured: "Administrator
                # privilege required for this operation"). The elevated Development
                # Gate runner does hold it, so this is an explicitly reported local
                # skip - never a silently weakened assertion.
                if ($_.Exception.Message -match 'Administrator privilege') {
                    Write-Host "SKIPPED $kind runtime fixture: symbolic link creation requires an elevated session"
                    continue
                }
                throw
            }
            $linked = Start-Probe 'once' $root
            Assert-True ((Finish-Probe $linked 23).Contains('startup_gate_untrusted')) "$kind runtime directory refused"
            Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $target 'user.txt')).Trim() -eq 'untouched') "$kind refusal preserves target user bytes"
        }
        $target = New-Case
        $alias = Join-Path $temp ('ancestor-link-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Junction -Path $alias -Target $target
        $linkedAncestor = Start-Probe 'once' $alias
        Assert-True ((Finish-Probe $linkedAncestor 23).Contains('startup_gate_untrusted') -and
            -not (Test-Path -LiteralPath (Join-Path $target 'runtime'))) 'Linked ancestor refused before target state creation'
        foreach ($unsafeRoot in @('relative-root',($target + ':ads'),($target + '\..\' + [IO.Path]::GetFileName($target)),('\\?\' + $target))) {
            $unsafeProbe = Start-Probe 'once' $unsafeRoot
            Assert-True ((Finish-Probe $unsafeProbe 23).Contains('startup_gate_untrusted')) 'Relative, ADS, traversal or device path refused'
        }
        # FIX5.I: repeated Dispose must not release coordination twice.
        $doubleDisposeRoot = New-Case
        $null = Start-Probe 'once' $doubleDisposeRoot | ForEach-Object { Finish-Probe $_ 0 }
        $doubleDispose = Start-Probe 'double-dispose' $doubleDisposeRoot
        $doubleDisposeText = Finish-Probe $doubleDispose 0
        Assert-True ((($doubleDispose.Output -join "`n").Contains('DOUBLE_DISPOSE_OK'))) 'FIX5: a repeated Dispose is a no-op and does not double-release coordination'

        # FIX5.E/F/G wiring: an ACL restore failure cannot be injected on Windows
        # (measured: share modes do not cover WRITE_DAC/WRITE_OWNER and the owner
        # keeps implicit DACL-write rights), so the contract that converts it into a
        # non-zero exit is pinned at the source level: a failed restore must raise a
        # fixed, identifiable cleanup failure from Dispose - after the mutex and
        # directory handles are released - and the Host must map that failure to its
        # own non-zero exit code with cleanup-specific wording.
        $gateSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'local-router/src/Router.State/Ownership/WindowsRouterStartupGate.cs')
        $hostSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'local-router/src/Router.Host/RouterHostBootstrap.cs')
        $gateDoc = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'docs/ROUTER_HOST_STARTUP_GATE.md')
        Assert-True ($gateSource.Contains('CleanupFailedMessage = "startup_gate_cleanup_failed"')) 'FIX5.E: the cleanup failure carries a fixed identifiable label'
        $throwIndex = $gateSource.IndexOf('CleanupFailedMessage,', [StringComparison]::Ordinal)
        $releaseIndex = $gateSource.IndexOf('_directories[index].Dispose();', [StringComparison]::Ordinal)
        Assert-True ($throwIndex -gt 0 -and $releaseIndex -gt 0 -and $releaseIndex -lt $throwIndex) 'FIX5.G: the cleanup failure is raised only after the mutex and directory handles are released'
        Assert-True ($gateSource.Contains('if (_metadataRestoreFailed)')) 'FIX5.E: the cleanup failure is raised only when the restore actually failed'
        Assert-True ($gateSource.Contains('Interlocked.Exchange(ref _disposed, 1) != 0) { return; }')) 'FIX5.I: Dispose stays idempotent'
        Assert-True ($hostSource.Contains('public const int CleanupFailedExitCode = 3;')) 'FIX5.E: the Host declares a non-zero exit code for cleanup failure'
        Assert-True ($hostSource.Contains('enabled Host shutdown cleanup failed')) 'FIX5.F: cleanup failure is reported as cleanup, never as a startup refusal'
        Assert-True ($hostSource.Contains('return cleanupFailure ? CleanupFailedExitCode : ConfigErrorExitCode;')) 'FIX5.E: a failed cleanup can never return the clean/zero or startup code'
        Assert-True ($hostSource.Contains('WindowsRouterStartupGate.CleanupFailedMessage')) 'FIX5.E: the Host matches the gate''s fixed cleanup label'
        Assert-True ($gateDoc.Contains('FIX5: effective ACL denial and guard/mutex lifecycle')) 'FIX5.F: the cleanup exit semantics are documented'

        if ($fail -eq 0) { Write-Host 'STARTUP_GATE_NATIVE PASS platform=Windows actual_kernel_mutex=True actual_host_children=True' }
        else { Write-Host 'STARTUP_GATE_NATIVE FAIL platform=Windows' }
    }
}
catch { $fail++; Write-Host "FAIL  Startup gate validation: $($_.Exception.Message)"; Write-Host $_.ScriptStackTrace }
finally {
    foreach ($child in $children) {
        if (-not $child.Process.HasExited) { $child.Process.Kill(); $null = $child.Process.WaitForExit(15000) }
        $child.Process.Dispose()
    }
    # Only new GUID-named temporary cases were used. Retain evidence; no
    # recursive deletion, no real user home, no PID-directed process operation.
    Write-Host "STARTUP_GATE_SUMMARY PASS=$pass FAIL=$fail WindowsNative=$IsWindows elapsed_seconds=$([int]$timer.Elapsed.TotalSeconds) evidence=$temp"
}
if ($fail) { exit 1 }
