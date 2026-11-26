param(
    [Parameter(Mandatory = $false)][string]$RepositoryRoot = (Get-Location).Path
)

# LR-15 PR10B lifecycle controller validation.
#
# Synthetic half: read-only status proofs and anti-misreport cases (a persisted
# terminal state is history, never a current stop proof), refusal paths, static
# safety contract and the negative stop/start completion proofs, each with a real
# child process that must still be alive afterwards.
#
# Windows half: the canonical case publishes a real PR9 verified Host release from
# a temporary clone of this checkout, starts it, verifies the REAL managed READY
# (durable READY for that exact process + verified current-user-only control
# endpoint + live pipe instance), stops it through the authenticated control
# channel and proves the graceful exit, the durable STOPPED and the archive bound
# to THIS owner. Failure injections use only owned temporary sandboxes.

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]
$passes = 0
function Pass([string]$Message) { $script:passes++; Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }
function Assert-True([bool]$Condition, [string]$Message) { if ($Condition) { Pass $Message } else { Fail $Message } }

$script = Join-Path $RepositoryRoot 'installer/scripts/router-lifecycle.ps1'
Assert-True (Test-Path -LiteralPath $script -PathType Leaf) 'the lifecycle controller script exists'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$tempBase = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
$tempRoot = Join-Path $tempBase ('lr15-pr10b-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempRoot
$children = New-Object System.Collections.Generic.List[object]
$serverProcesses = New-Object System.Collections.Generic.List[object]
$locks = New-Object System.Collections.Generic.List[object]
$script:invocationCounter = 0

function New-CaseHome {
    $h = Join-Path $tempRoot ('home-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $h 'multimodel-manager/local-router/runtime')
    return $h
}

# The Windows startup gate refuses an inheritance-unsafe runtime parent, so the
# host cases use the production convention: a private sandbox (owner-only,
# inheritance removed) whose children inherit that descriptor.
function New-PrivateCaseHome {
    $root = Join-Path $tempRoot ('private-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $root
    if ($IsWindows) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetOwner($sid)
        $security.SetAccessRuleProtection($true, $false)
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        Set-Acl -LiteralPath $root -AclObject $security
    }

    $h = Join-Path $root 'codex-home'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $h 'multimodel-manager/local-router')
    return $h
}

function Get-LifecycleDir([string]$Case) { return (Join-Path $Case 'multimodel-manager/local-router') }

function Write-UserConfig([string]$Case, [bool]$Enabled, [int]$Port = 47821) {
    $mode = if ($Enabled) { 'router' } else { 'direct' }
    # `@(...)` around the whole expression: an `if` statement unrolls a
    # single-element result, which would serialize `clients` as an object.
    $clients = @(
        if ($Enabled) {
            [ordered]@{ client_id = 'client.local_test'; adapter_id = 'adapter.client.local_test.responses.v1'; enabled = $true; auth_scope = 'responses:invoke'; capabilities = @('text', 'streaming', 'responses'); version = 1 }
        }
    )
    ([ordered]@{
            schema_version = 1; version = 1; mode = $mode
            local_router   = [ordered]@{ enabled = $Enabled; port = $Port; client_auth = [ordered]@{ mode = 'bearer_env_ref'; token_ref = 'CODEX_LOCAL_ROUTER_TOKEN' } }
            clients        = $clients
        } | ConvertTo-Json -Depth 8) |
        Set-Content -LiteralPath (Join-Path (Get-LifecycleDir $Case) 'router.config.json') -Encoding UTF8
}

function Write-RuntimeState([string]$Case, [string]$Lifecycle, [string]$Generation = ('a' * 64)) {
    ([ordered]@{ schema_version = 1; version = 1; lifecycle = $Lifecycle; config_generation = $Generation; updated_at = '2026-01-01T00:00:00+00:00' } | ConvertTo-Json -Depth 6) |
        Set-Content -LiteralPath (Join-Path (Get-LifecycleDir $Case) 'runtime/router.state.json') -Encoding UTF8
}

function Get-Fingerprint([int]$ProcessId, [long]$Ticks) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString(
                $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$ProcessId`:$Ticks")))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Write-OwnerRecord([string]$Case, [int]$ProcessId, [long]$Ticks, [string]$Fingerprint) {
    ([ordered]@{ schema_version = 1; pid = $ProcessId; process_fingerprint = $Fingerprint; process_start_ticks = $Ticks;
            host = '127.0.0.1'; port = 47821; created_at = '2026-01-01T00:00:00+00:00'; version = 1 } | ConvertTo-Json -Depth 6) |
        Set-Content -LiteralPath (Join-Path (Get-LifecycleDir $Case) 'runtime/router.pid.json') -Encoding UTF8
}

function Write-ControlEndpoint {
    param([string]$Case, [int]$ProcessId, [long]$Ticks, [string]$Fingerprint, [string]$PipeName, [string]$Token,
        [string]$Generation = ('a' * 64), [string]$Acl = 'current_user')
    ([ordered]@{ schema_version = 1; version = 1; pipe_name = $PipeName; token = $Token; pid = $ProcessId;
            process_fingerprint = $Fingerprint; process_start_ticks = $Ticks; config_generation = $Generation
            created_at = '2026-01-01T00:00:00+00:00' } | ConvertTo-Json -Depth 6) |
        Set-Content -LiteralPath (Join-Path (Get-LifecycleDir $Case) 'runtime/router.control.json') -Encoding UTF8
    Set-CapabilityFileAcl -Path (Join-Path (Get-LifecycleDir $Case) 'runtime/router.control.json') -Mode $Acl
}

# Capability access-control fixtures. Each mode is applied in a single descriptor
# write (re-applying a descriptor to an already protected file needs a privilege
# this session does not hold), and `unprotected` deliberately leaves the
# inherited broad access in place.
function Set-CapabilityFileAcl {
    param([string]$Path, [string]$Mode)
    if (-not $IsWindows) { return }
    if ($Mode -eq 'unprotected') { return }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
    if ($Mode -eq 'foreign_users_read') {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'), 'Read', 'Allow'))
    }
    elseif ($Mode -eq 'foreign_everyone_read') {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-1-0'), 'Read', 'Allow'))
    }

    try { Set-Acl -LiteralPath $Path -AclObject $acl }
    catch { & icacls $Path '/inheritance:r' '/grant:r' "*$($sid.Value):F" | Out-Null }
}

function Get-Identity([int]$ProcessId) {
    $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
    try { $ticks = $process.StartTime.ToUniversalTime().Ticks } finally { $process.Dispose() }
    return [pscustomobject]@{ ticks = $ticks; fingerprint = (Get-Fingerprint -ProcessId $ProcessId -Ticks $ticks) }
}

function Invoke-Lifecycle {
    param([string]$Case, [string]$Action, [switch]$Json, [string[]]$ExtraArguments = @(), [switch]$NoCodexHome)
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Action', $Action)
    if (-not $NoCodexHome) { $arguments += @('-CodexHome', $Case) }
    if ($Json) { $arguments += '-AsJson' }
    $arguments += $ExtraArguments
    $script:invocationCounter++
    $stdoutPath = Join-Path $tempRoot ('controller-' + $script:invocationCounter + '.out.log')
    $stderrPath = Join-Path $tempRoot ('controller-' + $script:invocationCounter + '.err.log')
    # File redirection, deliberately: a successful Start leaves a Host running,
    # and an inherited pipe would keep this validator's own output open.
    $startParameters = @{
        FilePath               = $pwsh
        ArgumentList           = $arguments
        PassThru               = $true
        NoNewWindow            = $true
        RedirectStandardOutput = $stdoutPath
        RedirectStandardError  = $stderrPath
    }
    if ($NoCodexHome) { $startParameters['Environment'] = @{ CODEX_HOME = '' } }
    $process = Start-Process @startParameters
    if (-not $process.WaitForExit(300000)) {
        try { $process.Kill() } catch { }
        throw "The lifecycle controller did not exit: action=$Action"
    }
    $code = $process.ExitCode
    $process.Dispose()
    $stdout = if (Test-Path -LiteralPath $stdoutPath) { [string](Get-Content -Raw -LiteralPath $stdoutPath) } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { [string](Get-Content -Raw -LiteralPath $stderrPath) } else { '' }
    # Never use Out-String here: it re-wraps a long single-line JSON answer at the
    # host width and would split the very line this validator parses.
    $lines = @((($stdout + "`n" + $stderr) -split "`r?`n") | Where-Object { $_.Trim() } | ForEach-Object { $_.TrimEnd("`r") })
    return [pscustomobject]@{ ExitCode = $code; Lines = $lines; Text = (($stdout + "`n" + $stderr).Trim()) }
}

function Get-JsonResult($Invocation) {
    $line = @($Invocation.Lines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
    if ($line.Count -eq 0) { return $null }
    return ($line[0] | ConvertFrom-Json)
}

function Get-Status([string]$Case) { return (Get-JsonResult (Invoke-Lifecycle $Case 'Status' -Json)) }

function Get-CaseSnapshot([string]$Case) {
    return (@(Get-ChildItem -LiteralPath $Case -Recurse -File | ForEach-Object {
                "$($_.FullName.Substring($Case.Length)):$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
            } | Sort-Object) -join "`n")
}

function Start-SyntheticChild {
    $child = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -PassThru -WindowStyle Hidden
    $children.Add($child)
    return $child
}

function Assert-ChildAlive($Child, [string]$Message) {
    $alive = $false
    try { $alive = -not $Child.HasExited } catch { $alive = $false }
    Assert-True $alive $Message
}

# A channel that always answers `accepted` (or refuses), so the controller's own
# completion proof can be exercised against a process that never stops.
function Start-FakeControlServer([string]$PipeName, [bool]$Accepted) {
    $answer = if ($Accepted) { '{"schema_version":1,"accepted":true}' } else { '{"schema_version":1,"accepted":false,"reason":"authentication_failed"}' }
    $serverCode = @'
$server = [System.IO.Pipes.NamedPipeServerStream]::new('PIPENAME', [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
$server.WaitForConnection()
$buffer = New-Object byte[] 512
$null = $server.Read($buffer, 0, 512)
$response = [System.Text.Encoding]::UTF8.GetBytes('ANSWER' + "`n")
$server.Write($response, 0, $response.Length)
$server.Flush()
Start-Sleep -Milliseconds 300
'@.Replace('PIPENAME', $PipeName).Replace('ANSWER', $answer)
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($serverCode))
    $server = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -PassThru -WindowStyle Hidden
    $serverProcesses.Add($server)
    return $server
}

function New-ReleaseIdentity {
    $cloneRoot = Join-Path $tempRoot ('source-' + [guid]::NewGuid().ToString('N'))
    $outputRoot = Join-Path $tempRoot ('release-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $outputRoot

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = & git clone --no-hardlinks --quiet $RepositoryRoot $cloneRoot 2>&1; $cloneExit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if ($cloneExit -ne 0) { throw 'Temporary Git clone failed' }

    $headSha = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
    $ErrorActionPreference = 'Continue'
    try { $null = & git -C $cloneRoot checkout --detach --quiet $headSha 2>&1; $checkoutExit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if ($checkoutExit -ne 0) { throw 'Temporary clone does not contain the reviewed commit' }

    Import-Module (Join-Path $RepositoryRoot 'installer/scripts/router-host-release.psm1') -Force
    $receipt = New-RouterHostRelease -SourceRoot $cloneRoot -SourceCommit $headSha -OutputRoot $outputRoot -Version '3.9.0'
    return [pscustomobject]@{
        Root     = $receipt.release_root
        Manifest = $receipt.manifest_sha256
        Package  = $receipt.package_sha256
        Version  = '3.9.0'
        Commit   = $headSha
    }
}

function New-ReleaseArguments($Release, [switch]$Tamper) {
    $manifest = if ($Tamper) { '0' * 64 } else { $Release.Manifest }
    return @(
        '-ReleaseRoot', $Release.Root,
        '-ExpectedManifestSha256', $manifest,
        '-ExpectedPackageSha256', $Release.Package,
        '-ExpectedVersion', $Release.Version,
        '-ExpectedSourceCommit', $Release.Commit
    )
}

function Get-FreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}

function Get-HostProcessesUnderRelease($Release) {
    if ($null -eq $Release) { return @() }
    return @(Get-CimInstance Win32_Process -Filter "Name = 'Router.Host.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Release.Root) })
}

function Get-ControllerRunCount { return $script:invocationCounter }

$releaseIdentity = $null
try {
    # --- 1. Status: read-only, and never a fabricated stop --------------------
    $case = New-CaseHome
    Assert-True ((Get-Status $case).state -eq 'DISABLED') 'A: default-disabled Router reports DISABLED'
    $case = New-CaseHome; Write-UserConfig $case $true
    $missing = Get-Status $case
    Assert-True ($missing.state -eq 'UNKNOWN') 'B: enabled Router without runtime state reports UNKNOWN, never STOPPED'
    Assert-True ($missing.reason -eq 'runtime_state_missing') 'B: the UNKNOWN reason names the missing runtime state'

    # STATUS-1: only a historical STOPPED file, no owner record, no proof.
    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'STOPPED'
    $historical = Get-Status $case
    Assert-True ($historical.state -eq 'UNKNOWN') 'STATUS-1: a historical STOPPED file alone is never reported as a verified stop'
    Assert-True ($historical.reason -eq 'terminal_state_without_owner_record') 'STATUS-1: the UNKNOWN reason names the missing owner record'
    Assert-True ($historical.evidence.historical_lifecycle -eq 'STOPPED') 'STATUS-1: the historical state is reported as history, not as a current state'
    Assert-True ($historical.evidence.current_stop_proof -eq 'none') 'STATUS-1: no current stop proof is claimed'

    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    Assert-True ((Get-Status $case).state -eq 'UNKNOWN') 'C: READY without an owner record reports UNKNOWN'

    # STATUS-2: the recorded PID exists but belongs to a different process.
    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    $live = Start-SyntheticChild
    $reused = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', 'exit 0') -PassThru -WindowStyle Hidden
    $children.Add($reused)
    $previousStartTicks = ([long]$reused.StartTime.ToUniversalTime().Ticks)
    $reused.WaitForExit(15000) | Out-Null
    # An internally consistent record that describes a DIFFERENT process instance
    # of that same PID: the live process must not be trusted (PID reuse).
    Write-OwnerRecord $case $live.Id $previousStartTicks (Get-Fingerprint -ProcessId $live.Id -Ticks $previousStartTicks)
    $reuseResult = Get-Status $case
    Assert-True ($reuseResult.state -eq 'UNKNOWN') 'STATUS-2: a reused PID reports UNKNOWN instead of trusting the PID'
    Assert-True ($reuseResult.reason -eq 'process_identity_mismatch') 'STATUS-2: the UNKNOWN reason names the identity mismatch'

    # STATUS-3: the process identity cannot be read at all.
    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    Write-OwnerRecord $case 4 1 (Get-Fingerprint -ProcessId 4 -Ticks 1)
    $unreadable = Get-Status $case
    Assert-True ($unreadable.state -eq 'UNKNOWN') 'STATUS-3: an unreadable process identity reports UNKNOWN'
    Assert-True ($unreadable.reason -in @('process_start_time_unavailable', 'process_identity_mismatch', 'process_state_unavailable')) 'STATUS-3: the UNKNOWN reason names the unverifiable identity'

    $dead = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', 'exit 0') -PassThru -WindowStyle Hidden
    $children.Add($dead)
    $deadIdentity = Get-Identity $dead.Id
    $dead.WaitForExit(15000) | Out-Null
    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    Write-OwnerRecord $case $dead.Id $deadIdentity.ticks $deadIdentity.fingerprint
    Assert-True ((Get-Status $case).state -eq 'FAILED') 'D: a durable READY whose recorded owner is absent reports FAILED, never STOPPED'

    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'STOPPED'
    Write-OwnerRecord $case $dead.Id $deadIdentity.ticks $deadIdentity.fingerprint
    $goneTerminal = Get-Status $case
    Assert-True ($goneTerminal.state -eq 'UNKNOWN') 'E: a terminal state whose recorded owner is absent is still not a verified stop'
    Assert-True ($goneTerminal.reason -eq 'terminal_state_without_current_stop_proof') 'E: the UNKNOWN reason names the missing current proof'

    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    $owner = Start-SyntheticChild
    $ownerIdentity = Get-Identity $owner.Id
    Write-OwnerRecord $case $owner.Id $ownerIdentity.ticks $ownerIdentity.fingerprint
    $ready = Get-Status $case
    Assert-True ($ready.state -eq 'READY' -and $ready.reason -eq 'owner_identity_verified') 'F: a verified live owner reports READY'
    Assert-True ($ready.evidence.current_state_proof -eq 'live_owner_identity_verified') 'F: the active state names its proof source'

    Write-RuntimeState $case 'STOPPED'
    Assert-True ((Get-Status $case).state -eq 'UNKNOWN') 'G: a live verified owner with a terminal state is a contradiction, not a stop'

    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    Set-Content -LiteralPath (Join-Path (Get-LifecycleDir $case) 'runtime/router.pid.json') -Value '{ broken' -Encoding UTF8
    Assert-True ((Get-Status $case).state -eq 'UNKNOWN') 'H: an unreadable owner record reports UNKNOWN'

    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'STOPPED'
    $before = Get-CaseSnapshot $case
    $null = Invoke-Lifecycle $case 'Status'
    Assert-True ((Get-CaseSnapshot $case) -eq $before) 'I: Status reads only: the isolated home is byte-for-byte unchanged'

    $usage = Invoke-Lifecycle '' 'Status' -NoCodexHome
    Assert-True ($usage.ExitCode -eq 2) 'J: a missing Codex home is a usage error, never a guessed path'
    Assert-True $usage.Text.Contains('lifecycle_usage_error') 'J: the usage error is named for the operator'
    $usage = Invoke-Lifecycle 'relative-codex-home' 'Status'
    Assert-True ($usage.ExitCode -eq 2) 'J: a relative Codex home is refused as a usage error'

    # --- 2. Static safety contract -------------------------------------------
    $source = Get-Content -Raw -LiteralPath $script
    foreach ($forbidden in @('.Kill(', 'Stop-Process', 'taskkill', 'Remove-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Clear-Content')) {
        Assert-True (-not $source.Contains($forbidden)) "K: the controller never contains '$forbidden'"
    }
    foreach ($reason in @('start_requires_verified_release', 'start_refused_already_running', 'start_verified_ready_managed',
            'start_failed_control_channel_unavailable', 'stop_refused_status_unknown', 'stop_refused_control_channel_unavailable',
            'stop_refused_by_host_control_channel', 'stop_completed_gracefully', 'stop_incomplete_process_still_running',
            'stop_incomplete_process_exit_unverified', 'stop_incomplete_terminal_state_unproven', 'stop_incomplete_owner_archive_unproven',
            'terminal_state_without_current_stop_proof')) {
        Assert-True $source.Contains($reason) "K: the fixed reason '$reason' is declared"
    }
    foreach ($leaseToken in @('AcquireStopped', 'IStoppedRouterLease', 'IRouterLifecycleGuard', 'installationId')) {
        Assert-True (-not $source.Contains($leaseToken)) "K: the controller never claims the PR8 lease surface ($leaseToken)"
    }
    Assert-True (-not $source.Contains('auth.json')) 'K: the controller never reads user credentials'
    # Exception discipline: only the documented not-running failure is evidence of
    # absence, a generic process-state failure is unverifiable, and no generic
    # exception type is ever treated as an exit proof.
    Assert-True $source.Contains('[System.ArgumentException]') 'K: absence is classified from the documented not-running failure'
    Assert-True $source.Contains("'process_id_absent'") 'K: the exit proof names its documented absence evidence'
    Assert-True $source.Contains("'process_state_unavailable'") 'K: a generic process-state failure is reported as unverifiable'
    Assert-True (-not $source.Contains('[System.InvalidOperationException]')) 'K: no generic exception type is used as an exit or absence proof'
    Assert-True $source.Contains("'control_endpoint_acl_foreign_identity'") 'K: a foreign identity on the capability file is a fixed refusal reason'
    Assert-True $source.Contains("'control_endpoint_acl_inherits_foreign_access'") 'K: inherited foreign access on the capability file is a fixed refusal reason'
    $uninstallContract = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'installer/scripts/router-uninstall-safety.cs')
    Assert-True ($uninstallContract.Contains('IStoppedRouterLease') -and $uninstallContract.Contains('AcquireStopped')) 'K: the PR8 stopped-lease contract is still declared and untouched'

    # --- 2b. Shared runtime-state reads (OSS-M4-2-HOTFIX2) --------------------
    # The Host replaces router.state.json and router.pid.json with File.Replace
    # while Start polls them. A read handle that does not grant FileShare.Delete
    # makes that replace fail with ERROR_SHARING_VIOLATION (32), so the
    # controller's reader must grant it and otherwise behave as the previous one.
    $controllerAst = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
    $readerAsts = @{}
    foreach ($definition in $controllerAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($definition.Name -in @('Open-SharedReadStream', 'Read-JsonFile')) { $readerAsts[$definition.Name] = $definition }
    }
    $getContentCalls = @($controllerAst.FindAll({ param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-Content' }, $true))
    Assert-True ($getContentCalls.Count -eq 0) 'R: the controller never reads a file through Get-Content'
    Assert-True ($readerAsts.Count -eq 2) 'R: the controller defines Open-SharedReadStream and Read-JsonFile'
    if ($readerAsts.Count -eq 2) {
        $openText = $readerAsts['Open-SharedReadStream'].Extent.Text
        $readText = $readerAsts['Read-JsonFile'].Extent.Text
        Assert-True ($openText.Contains('[System.IO.FileAccess]::Read,') -and
            $openText.Contains('[System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete')) 'R: runtime-state reads are read-only and share ReadWrite and Delete'
        Assert-True ($readText.Contains('Open-SharedReadStream $Path') -and $readText.Contains('$reader.Dispose()') -and
            $readText.Contains('$stream.Dispose()')) 'R: Read-JsonFile reads through the shared stream and disposes the reader and the stream'

        $sharedReader = New-Module -Name 'hotfix2-controller-reader' -ScriptBlock ([scriptblock]::Create(
                "`$ErrorActionPreference = 'Stop'`n$openText`n$readText`nExport-ModuleMember"))
        $readerRoot = Join-Path $tempRoot 'hotfix2-reader'
        $null = New-Item -ItemType Directory -Path $readerRoot

        # A: an open controller read never blocks the Host's atomic replace.
        $target = Join-Path $readerRoot 'router.state.json'
        $replacement = Join-Path $readerRoot '.tmp-replacement'
        [System.IO.File]::WriteAllText($target, '{"lifecycle":"READY"}')
        [System.IO.File]::WriteAllText($replacement, '{"lifecycle":"STOPPED"}')
        $held = & $sharedReader { param($Path) Open-SharedReadStream $Path } $target
        $replaceError = $null
        $heldText = $null
        try {
            try { [System.IO.File]::Replace($replacement, $target, [NullString]::Value) } catch { $replaceError = $_.Exception }
            $heldReader = [System.IO.StreamReader]::new($held)
            try { $heldText = $heldReader.ReadToEnd() } finally { $heldReader.Dispose() }
        }
        finally { $held.Dispose() }
        Assert-True ($null -eq $replaceError) 'R-A: an atomic replace succeeds while a controller read is open'
        Assert-True ($heldText -ceq '{"lifecycle":"READY"}') 'R-A: the open read still sees the complete previous content'
        $afterReplace = & $sharedReader { param($Path) Read-JsonFile $Path } $target
        Assert-True ([string]$afterReplace.lifecycle -ceq 'STOPPED') 'R-A: the next read sees the complete replacement'

        # Control: the previous reader's Get-Content -Raw call keeps the file open
        # without Delete sharing while it hands the content on, so the same
        # replace issued during that read fails with native 32. Check A therefore
        # detects the defect it guards against.
        if ($IsWindows) {
            [System.IO.File]::WriteAllText($replacement, '{"lifecycle":"READY"}')
            $controlError = $null
            Get-Content -Raw -LiteralPath $target | ForEach-Object {
                try { [System.IO.File]::Replace($replacement, $target, [NullString]::Value) }
                catch { $controlError = if ($_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception } }
            }
            Assert-True ($null -ne $controlError -and $controlError.HResult -eq -2147024864) 'R-A: control - a replace during the previous Get-Content -Raw read fails with a sharing violation'
            Assert-True ([System.IO.File]::ReadAllText($target) -ceq '{"lifecycle":"STOPPED"}') 'R-A: control - the blocked replace left the target unchanged'
        }

        # Equivalence: the shared reader returns exactly what the previous
        # Get-Content -Raw reader returned for every input class.
        $previousReader = New-Module -Name 'hotfix2-previous-reader' -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            function Read-JsonFile {
                param([string]$Path)
                if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
                try { return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json) }
                catch { return [pscustomobject]@{ __corrupt = $true } }
            }
            Export-ModuleMember
        }
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $inputs = [ordered]@{
            'valid'      = $utf8.GetBytes('{"lifecycle":"READY","version":3,"owner":{"pid":42,"ticks":638000000000000000}}')
            'utf8-bom'   = [byte[]](@(0xEF, 0xBB, 0xBF) + $utf8.GetBytes('{"lifecycle":"STOPPED"}'))
            'utf16-bom'  = [byte[]]([System.Text.Encoding]::Unicode.GetPreamble() + [System.Text.Encoding]::Unicode.GetBytes('{"lifecycle":"READY"}'))
            'empty'      = [byte[]]@()
            'whitespace' = $utf8.GetBytes("  `r`n`t ")
            'invalid'    = $utf8.GetBytes('{"lifecycle":')
            'non-json'   = $utf8.GetBytes('not json')
            'unicode'    = $utf8.GetBytes("{`"label`":`"`u{72B6}`u{6001}-`u{E9}`"}")
        }
        $inputPaths = [ordered]@{}
        foreach ($name in $inputs.Keys) {
            $inputPaths[$name] = Join-Path $readerRoot "$name.json"
            [System.IO.File]::WriteAllBytes($inputPaths[$name], $inputs[$name])
        }
        $inputPaths['missing'] = Join-Path $readerRoot 'missing.json'
        $inputPaths['directory'] = (New-Item -ItemType Directory -Path (Join-Path $readerRoot 'directory.json')).FullName
        foreach ($name in $inputPaths.Keys) {
            $previous = & $previousReader { param($Path) Read-JsonFile $Path } $inputPaths[$name]
            $current = & $sharedReader { param($Path) Read-JsonFile $Path } $inputPaths[$name]
            $previousJson = ConvertTo-Json -InputObject $previous -Compress -Depth 8 -EscapeHandling EscapeNonAscii
            $currentJson = ConvertTo-Json -InputObject $current -Compress -Depth 8 -EscapeHandling EscapeNonAscii
            Assert-True ($previousJson -ceq $currentJson) "R-E: Read-JsonFile matches the previous reader for the '$name' input ($currentJson)"
            if ($name -eq 'unicode') {
                Assert-True ([string]$current.label -ceq "`u{72B6}`u{6001}-`u{E9}") 'R-E: non-ASCII UTF-8 content is decoded exactly'
            }
        }
    }

    # --- 3. Refusals: no capability, no side effect, no killed process --------
    $case = New-CaseHome; Write-UserConfig $case $true
    $before = Get-CaseSnapshot $case
    $start = Invoke-Lifecycle $case 'Start'
    Assert-True ($start.ExitCode -eq 4) 'L: Start without a verified release is refused (exit 4)'
    Assert-True $start.Text.Contains('start_requires_verified_release') 'L: the refusal names the missing verified release'
    Assert-True ((Get-CaseSnapshot $case) -eq $before) 'L: a refused Start has no side effect'

    $case = New-CaseHome
    $start = Invoke-Lifecycle $case 'Start'
    Assert-True ($start.ExitCode -eq 4) 'L: Start in a disabled Router is refused before any release check'

    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'STOPPED'
    $stop = Invoke-Lifecycle $case 'Stop'
    Assert-True ($stop.ExitCode -eq 5) 'M: Stop without a target owner record is refused (exit 5)'
    Assert-True $stop.Text.Contains('stop_refused_not_running') 'M: the refusal names the missing target'

    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    $before = Get-CaseSnapshot $case
    $stop = Invoke-Lifecycle $case 'Stop'
    Assert-True ($stop.ExitCode -eq 5) 'N: Stop with an UNKNOWN (unowned) status is refused (exit 5)'
    Assert-True $stop.Text.Contains('stop_refused_not_running') 'N: the refusal names the missing verified owner'
    Assert-True ((Get-CaseSnapshot $case) -eq $before) 'N: a refused Stop has no side effect'

    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    $target = Start-SyntheticChild
    $targetIdentity = Get-Identity $target.Id
    Write-OwnerRecord $case $target.Id $targetIdentity.ticks $targetIdentity.fingerprint
    $before = Get-CaseSnapshot $case
    $stop = Invoke-Lifecycle $case 'Stop'
    Assert-True ($stop.ExitCode -eq 4) 'O: Stop without a published control endpoint is refused (exit 4)'
    Assert-True $stop.Text.Contains('stop_refused_control_channel_unavailable') 'O: the refusal names the missing control channel'
    Assert-True ((Get-CaseSnapshot $case) -eq $before) 'O: a refused Stop has no side effect'
    Assert-ChildAlive $target 'O: the verified owner process was never touched'

    Write-ControlEndpoint $case $target.Id $targetIdentity.ticks ('c' * 64) ('codex-router-host-' + ('d' * 32)) ('e' * 64)
    $stop = Invoke-Lifecycle $case 'Stop'
    Assert-True ($stop.ExitCode -eq 4) 'P: Stop with an endpoint that does not match the verified owner is refused (exit 4)'
    Assert-True $stop.Text.Contains('control_endpoint_owner_mismatch') 'P: the refusal names the owner mismatch'
    Assert-ChildAlive $target 'P: a mismatched endpoint never touches the owner process'

    $orphanPipe = 'codex-router-host-' + ([guid]::NewGuid().ToString('N').Substring(0, 32))
    Write-ControlEndpoint $case $target.Id $targetIdentity.ticks $targetIdentity.fingerprint $orphanPipe ('f' * 64)
    $stop = Invoke-Lifecycle $case 'Stop' -ExtraArguments @('-ControlTimeoutSeconds', '2')
    Assert-True ($stop.ExitCode -eq 4) 'Q: Stop with no live control pipe instance is refused (exit 4)'
    Assert-True $stop.Text.Contains('control_channel_not_listening') 'Q: the refusal names the absent live capability'
    Assert-ChildAlive $target 'Q: an absent capability never touches the owner process'

    $refusingPipe = 'codex-router-host-' + ([guid]::NewGuid().ToString('N').Substring(0, 32))
    Write-ControlEndpoint $case $target.Id $targetIdentity.ticks $targetIdentity.fingerprint $refusingPipe ('a' * 64)
    $null = Start-FakeControlServer -PipeName $refusingPipe -Accepted $false
    Start-Sleep -Milliseconds 700
    $stop = Invoke-Lifecycle $case 'Stop' -ExtraArguments @('-ControlTimeoutSeconds', '5')
    Assert-True ($stop.ExitCode -eq 8) 'R: a host-side refusal maps to the control-channel refusal code (exit 8)'
    Assert-True $stop.Text.Contains('stop_refused_by_host_control_channel') 'R: the refusal names the control-channel decision'
    Assert-ChildAlive $target 'R: a refused control request never touches the owner process'

    # ACL-1..3: the capability is a credential, so an ACL that lets any identity
    # other than the current user read it is refused before any request is sent.
    $aclPipe = 'codex-router-host-' + ([guid]::NewGuid().ToString('N').Substring(0, 32))
    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    Write-OwnerRecord $case $target.Id $targetIdentity.ticks $targetIdentity.fingerprint
    Write-ControlEndpoint $case $target.Id $targetIdentity.ticks $targetIdentity.fingerprint $aclPipe ('3' * 64) -Acl unprotected
    $stop = Invoke-Lifecycle $case 'Stop' -ExtraArguments @('-ControlTimeoutSeconds', '2')
    Assert-True ($stop.ExitCode -eq 4) 'ACL-1: a capability that still inherits foreign access is refused (exit 4)'
    Assert-True $stop.Text.Contains('control_endpoint_acl_inherits_foreign_access') 'ACL-1: the refusal names the inherited foreign access'
    Assert-ChildAlive $target 'ACL-1: the owner process was never touched'

    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    Write-OwnerRecord $case $target.Id $targetIdentity.ticks $targetIdentity.fingerprint
    Write-ControlEndpoint $case $target.Id $targetIdentity.ticks $targetIdentity.fingerprint $aclPipe ('4' * 64) -Acl foreign_users_read
    $stop = Invoke-Lifecycle $case 'Stop' -ExtraArguments @('-ControlTimeoutSeconds', '2')
    Assert-True ($stop.ExitCode -eq 4) 'ACL-2: a protected capability that grants Users read is refused (exit 4)'
    Assert-True $stop.Text.Contains('control_endpoint_acl_foreign_identity') 'ACL-2: the refusal names the foreign identity'
    Assert-ChildAlive $target 'ACL-2: the owner process was never touched'

    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    Write-OwnerRecord $case $target.Id $targetIdentity.ticks $targetIdentity.fingerprint
    Write-ControlEndpoint $case $target.Id $targetIdentity.ticks $targetIdentity.fingerprint $aclPipe ('5' * 64) -Acl foreign_everyone_read
    $stop = Invoke-Lifecycle $case 'Stop' -ExtraArguments @('-ControlTimeoutSeconds', '2')
    Assert-True ($stop.ExitCode -eq 4) 'ACL-3: a protected capability that grants Everyone read is refused (exit 4)'
    Assert-True $stop.Text.Contains('control_endpoint_acl_foreign_identity') 'ACL-3: the refusal names the foreign identity'
    Assert-ChildAlive $target 'ACL-3: the owner process was never touched'

    # The same file with the current-user-only descriptor the Host applies is
    # accepted by the access-control check (the channel itself is then absent, so
    # the refusal is the liveness one, not the ACL one).
    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    Write-OwnerRecord $case $target.Id $targetIdentity.ticks $targetIdentity.fingerprint
    Write-ControlEndpoint $case $target.Id $targetIdentity.ticks $targetIdentity.fingerprint $aclPipe ('6' * 64)
    $stop = Invoke-Lifecycle $case 'Stop' -ExtraArguments @('-ControlTimeoutSeconds', '2')
    Assert-True ($stop.ExitCode -eq 4) 'ACL-4: a current-user-only capability passes the ACL check'
    Assert-True $stop.Text.Contains('control_channel_not_listening') 'ACL-4: the remaining refusal is the absent live capability, not the ACL'
    Assert-ChildAlive $target 'ACL-4: the owner process was never touched'

    # --- 4. Negative completion proofs ---------------------------------------
    # STOP-2: the recorded process state cannot be read at all.
    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    Write-OwnerRecord $case 4 1 (Get-Fingerprint -ProcessId 4 -Ticks 1)
    $stop = Invoke-Lifecycle $case 'Stop'
    Assert-True ($stop.ExitCode -eq 5) 'STOP-2: an unverifiable process state is refused, never treated as an exit (exit 5)'
    Assert-True ($stop.Text.Contains('stop_refused_status_unknown')) 'STOP-2: the refusal names the unverifiable state'
    Assert-True (-not $stop.Text.Contains('stop_completed_gracefully')) 'STOP-2: no completion is reported'
    Assert-True (-not $stop.Text.Contains('process_exit_proof')) 'STOP-2: no exit proof is produced for an unverifiable process'

    # STOP-2b: the same rule at the identity level - a process whose identity
    # cannot be read is never reported as exited, whatever the exception was.
    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    Write-OwnerRecord $case 4 7 (Get-Fingerprint -ProcessId 4 -Ticks 7)
    $stop = Invoke-Lifecycle $case 'Stop' -Json
    $stopResult = Get-JsonResult $stop
    Assert-True ($stop.ExitCode -eq 5) 'STOP-2b: an unreadable identity is refused (exit 5)'
    Assert-True ($null -eq $stopResult -or $stopResult.state -eq 'UNKNOWN') 'STOP-2b: no confident or completed state is reported'
    Assert-True $stop.Text.Contains('stop_refused_status_unknown') 'STOP-2b: the refusal names the unverifiable identity'
    Assert-True (-not $stop.Text.Contains('process_exit_proof')) 'STOP-2b: no exit proof is produced'
    Assert-True (-not $stop.Text.Contains('stop_completed_gracefully')) 'STOP-2b: no completion is reported'

    # STOP-1: the control request is accepted, but the target process keeps running.
    $case = New-CaseHome; Write-UserConfig $case $true; Write-RuntimeState $case 'READY'
    $running = Start-SyntheticChild
    $runningIdentity = Get-Identity $running.Id
    Write-OwnerRecord $case $running.Id $runningIdentity.ticks $runningIdentity.fingerprint
    $acceptingPipe = 'codex-router-host-' + ([guid]::NewGuid().ToString('N').Substring(0, 32))
    Write-ControlEndpoint $case $running.Id $runningIdentity.ticks $runningIdentity.fingerprint $acceptingPipe ('b' * 64)
    $null = Start-FakeControlServer -PipeName $acceptingPipe -Accepted $true
    Start-Sleep -Milliseconds 700
    $stop = Invoke-Lifecycle $case 'Stop' -Json -ExtraArguments @('-ControlTimeoutSeconds', '5', '-StopTimeoutSeconds', '5')
    Assert-True ($stop.ExitCode -eq 7) 'STOP-1: an accepted request whose process keeps running is not a completed stop (exit 7)'
    $stopResult = Get-JsonResult $stop
    Assert-True ($stopResult.reason -eq 'stop_incomplete_process_still_running') 'STOP-1: the outcome names the still-running process'
    Assert-True ($stopResult.evidence.process_exit_proof -eq 'running') 'STOP-1: the exit proof reports running, not exited'
    Assert-ChildAlive $running 'STOP-1: the still-running process was never killed'

    # --- 5. Windows execution evidence: real verified release -----------------
    if ($IsWindows) {
        $releaseIdentity = New-ReleaseIdentity
        Assert-True (Test-Path -LiteralPath (Join-Path $releaseIdentity.Root 'Router.Host.exe') -PathType Leaf) 'S: a real PR9 verified Host release was published for this checkout'

        $tokenBefore = [Environment]::GetEnvironmentVariable('CODEX_LOCAL_ROUTER_TOKEN', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('CODEX_LOCAL_ROUTER_TOKEN', 'lr15-pr10b-validator-token', 'Process')

            # START-1: the capability path is occupied by a directory, so the Host
            # reaches READY but cannot publish a usable capability.
            $blockedHome = New-PrivateCaseHome
            Write-UserConfig $blockedHome $true (Get-FreePort)
            $null = New-Item -ItemType Directory -Path (Join-Path (Get-LifecycleDir $blockedHome) 'runtime/router.control.json') -Force
            $start = Invoke-Lifecycle $blockedHome 'Start' -Json -ExtraArguments (New-ReleaseArguments $releaseIdentity)
            Assert-True ($start.ExitCode -eq 6) 'START-1: a READY Host whose capability cannot be published is never a successful start (exit 6)'
            Assert-True $start.Text.Contains('start_failed_control_channel_unavailable') 'START-1: the failure names the unavailable control channel'
            Assert-True (-not $start.Text.Contains('start_verified_ready_managed')) 'START-1: no managed READY is reported'
            Assert-True (@(Get-HostProcessesUnderRelease $releaseIdentity).Count -eq 0) 'START-1: the Host did not stay running unmanaged'

            # START-2: an endpoint exists but does not belong to the started owner,
            # and it cannot be replaced, so no complete success may be reported.
            $staleHome = New-PrivateCaseHome
            Write-UserConfig $staleHome $true (Get-FreePort)
            $null = New-Item -ItemType Directory -Force -Path (Join-Path (Get-LifecycleDir $staleHome) 'runtime')
            $staleEndpoint = Join-Path (Get-LifecycleDir $staleHome) 'runtime/router.control.json'
            Write-ControlEndpoint $staleHome 4242 111111 ('9' * 64) ('codex-router-host-' + ('8' * 32)) ('7' * 64)
            $lock = [System.IO.File]::Open($staleEndpoint, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            $locks.Add($lock)
            $start = Invoke-Lifecycle $staleHome 'Start' -Json -ExtraArguments (New-ReleaseArguments $releaseIdentity)
            Assert-True ($start.ExitCode -eq 6) 'START-2: a control capability that does not belong to the started owner is never a successful start (exit 6)'
            Assert-True (-not $start.Text.Contains('start_verified_ready_managed')) 'START-2: no managed READY is reported for a foreign capability'
            Assert-True (@(Get-HostProcessesUnderRelease $releaseIdentity).Count -eq 0) 'START-2: no unmanaged Host was left running'
            $lock.Dispose(); $locks.Remove($lock) | Out-Null

            # START-4: two controllers starting concurrently must never produce two
            # successfully running routers of the same identity.
            $raceHome = New-PrivateCaseHome
            Write-UserConfig $raceHome $true (Get-FreePort)
            $raceArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Action', 'Start', '-CodexHome', $raceHome, '-AsJson') + (New-ReleaseArguments $releaseIdentity)
            $raceLogA = Join-Path $tempRoot 'race-a.log'; $raceLogB = Join-Path $tempRoot 'race-b.log'
            $raceA = Start-Process -FilePath $pwsh -ArgumentList $raceArguments -PassThru -NoNewWindow -RedirectStandardOutput $raceLogA -RedirectStandardError ($raceLogA + '.err')
            $raceB = Start-Process -FilePath $pwsh -ArgumentList $raceArguments -PassThru -NoNewWindow -RedirectStandardOutput $raceLogB -RedirectStandardError ($raceLogB + '.err')
            $null = $raceA.WaitForExit(180000); $null = $raceB.WaitForExit(180000)
            $raceSuccess = @(@($raceA.ExitCode, $raceB.ExitCode) | Where-Object { $_ -eq 0 }).Count
            Assert-True ($raceSuccess -le 1) 'START-4: concurrent Starts never produce two successful routers'
            $raceHosts = @(Get-HostProcessesUnderRelease $releaseIdentity)
            Assert-True ($raceHosts.Count -le 1) 'START-4: concurrent Starts never leave two Host processes'
            $raceOwner = if (Test-Path -LiteralPath (Join-Path (Get-LifecycleDir $raceHome) 'runtime/router.pid.json')) {
                (Get-Content -Raw -LiteralPath (Join-Path (Get-LifecycleDir $raceHome) 'runtime/router.pid.json') | ConvertFrom-Json)
            }
            else { $null }
            if ($raceSuccess -eq 1 -and $null -ne $raceOwner) {
                Assert-True (@($raceHosts | Where-Object { $_.ProcessId -eq [int]$raceOwner.pid }).Count -eq 1) 'START-4: the durable owner is the single surviving Host'
                $cleanup = Invoke-Lifecycle $raceHome 'Stop' -Json -ExtraArguments @('-StopTimeoutSeconds', '30')
                Assert-True ($cleanup.ExitCode -eq 0) 'START-4: the surviving router is still stoppable through the authenticated channel'
            }
            Assert-True (@(Get-HostProcessesUnderRelease $releaseIdentity).Count -eq 0) 'START-4: no Host is left running after the race'

            # START-3 / STOP-5: the canonical managed READY and graceful stop.
            $startHome = New-PrivateCaseHome
            Write-UserConfig $startHome $true (Get-FreePort)
            # A decoy archive of a different owner must never stand in for this one.
            $decoyDirectory = Join-Path (Get-LifecycleDir $startHome) 'quarantine/20000101-000000-decoy'
            $null = New-Item -ItemType Directory -Force -Path $decoyDirectory
            ([ordered]@{ schema_version = 1; pid = 4242; process_fingerprint = ('6' * 64); process_start_ticks = 222222
                    host = '127.0.0.1'; port = 47821; created_at = '2026-01-01T00:00:00+00:00'; version = 1 } | ConvertTo-Json -Depth 6) |
                Set-Content -LiteralPath (Join-Path $decoyDirectory 'router.pid.json') -Encoding UTF8

            $start = Invoke-Lifecycle $startHome 'Start' -Json -ExtraArguments (New-ReleaseArguments $releaseIdentity)
            $startResult = Get-JsonResult $start
            Assert-True ($start.ExitCode -eq 0) "START-3: Start with a verified release succeeds (exit $($start.ExitCode))"
            Assert-True ($null -ne $startResult -and $startResult.state -eq 'READY') 'START-3: Start reports READY only after a real managed READY'
            Assert-True ($null -ne $startResult -and $startResult.reason -eq 'start_verified_ready_managed') 'START-3: the success reason names the managed READY'
            $hostPid = if ($null -ne $startResult) { [int]$startResult.evidence.pid } else { 0 }
            Assert-True ($hostPid -gt 0) 'START-3: the reported READY is bound to the spawned Host process'
            Assert-True ($startResult.evidence.control_endpoint_verified -eq $true) 'START-3: the control endpoint identity was verified'
            Assert-True ($startResult.evidence.control_pipe_listening -eq $true) 'START-3: the control capability is a live pipe, not a stale file'
            Assert-True ($startResult.evidence.control_endpoint_acl -eq 'current_user_only') 'START-3: the capability file access control is current-user-only'
            Assert-True ($startResult.evidence.host_running -eq $true) 'START-3: the Host is still running at success'

            $status = Get-Status $startHome
            Assert-True ($status.state -eq 'READY' -and $status.reason -eq 'owner_identity_verified') 'START-3: an independent Status query verifies the running owner identity'

            $running = $false
            try { $running = ($hostPid -gt 0) -and (-not (Get-Process -Id $hostPid -ErrorAction Stop).HasExited) } catch { $running = $false }
            Assert-True $running 'START-3: the verified Host process is really running'

            $stdoutLog = Join-Path (Get-LifecycleDir $startHome) 'host-stdout.log'
            $stdoutText = if (Test-Path -LiteralPath $stdoutLog) { [string](Get-Content -Raw -LiteralPath $stdoutLog) } else { '' }
            Assert-True ($stdoutText.Contains('[local-router] READY on http://127.0.0.1:')) 'START-3: the real Host announced READY on loopback'
            Assert-True (-not $stdoutText.Contains('DISABLED')) 'START-3: the real Host was not in the disabled path'

            $start = Invoke-Lifecycle $startHome 'Start' -Json -ExtraArguments (New-ReleaseArguments $releaseIdentity)
            Assert-True ($start.ExitCode -eq 5 -and $start.Text.Contains('start_refused_already_running')) 'START-3: Start refuses while a verified owner is running'
            $stillRunning = $false
            try { $stillRunning = -not (Get-Process -Id $hostPid -ErrorAction Stop).HasExited } catch { $stillRunning = $false }
            Assert-True $stillRunning 'START-3: the refused Start left the verified owner untouched'

            # A tampered release identity is refused before anything is spawned.
            # This runs in its own idle home: with a verified owner present the
            # already-running refusal (correctly) comes first.
            $tamperHome = New-PrivateCaseHome
            Write-UserConfig $tamperHome $true (Get-FreePort)
            $start = Invoke-Lifecycle $tamperHome 'Start' -Json -ExtraArguments (New-ReleaseArguments $releaseIdentity -Tamper)
            Assert-True ($start.ExitCode -eq 4 -and $start.Text.Contains('start_refused_release_verification')) 'S: a tampered release identity is refused (exit 4)'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path (Get-LifecycleDir $tamperHome) 'runtime/router.pid.json'))) 'S: a refused release identity spawns no Host and writes no owner record'

            # STOP-3: the process exits but the durable STOPPED write cannot happen.
            # The state path is replaced by a directory AFTER the managed READY, so
            # the controller can still run its full stop path while the Host cannot
            # persist its terminal state.
            $statePath = Join-Path (Get-LifecycleDir $startHome) 'runtime/router.state.json'
            Remove-Item -LiteralPath $statePath -Force
            $null = New-Item -ItemType Directory -Path $statePath -Force
            $stop = Invoke-Lifecycle $startHome 'Stop' -Json -ExtraArguments @('-StopTimeoutSeconds', '60')
            Assert-True ($stop.ExitCode -eq 7) 'STOP-3: a stop whose durable STOPPED write failed is never a success (exit 7)'
            Assert-True $stop.Text.Contains('stop_incomplete_terminal_state_unproven') 'STOP-3: the outcome names the unproven terminal state'
            Assert-True (Test-Path -LiteralPath $statePath -PathType Container) 'STOP-3: the durable state really was never rewritten as STOPPED'
            Assert-True (Test-Path -LiteralPath (Join-Path (Get-LifecycleDir $startHome) 'runtime/router.pid.json')) 'STOP-3: the owner record was not archived by the failed stop'
            Assert-True (@(Get-HostProcessesUnderRelease $releaseIdentity).Count -eq 0) 'STOP-3: the Host process did exit'

            # STOP-4: another archive exists, but this owner could not be archived.
            $unarchivedHome = New-PrivateCaseHome
            Write-UserConfig $unarchivedHome $true (Get-FreePort)
            $start = Invoke-Lifecycle $unarchivedHome 'Start' -Json -ExtraArguments (New-ReleaseArguments $releaseIdentity)
            $startResult = Get-JsonResult $start
            Assert-True ($start.ExitCode -eq 0) 'STOP-4 setup: a real managed READY was reached'
            $unarchivedPid = if ($null -ne $startResult) { [int]$startResult.evidence.pid } else { 0 }
            # The quarantine root is replaced by a file: the archive cannot be created.
            $quarantinePath = Join-Path (Get-LifecycleDir $unarchivedHome) 'quarantine'
            Set-Content -LiteralPath $quarantinePath -Value 'not a directory' -Encoding UTF8
            $stop = Invoke-Lifecycle $unarchivedHome 'Stop' -Json -ExtraArguments @('-StopTimeoutSeconds', '60')
            Assert-True ($stop.ExitCode -eq 7) 'STOP-4: a stop whose owner archive was not created is never a success (exit 7)'
            Assert-True $stop.Text.Contains('stop_incomplete_owner_archive_unproven') 'STOP-4: the outcome names the unproven archive'
            Assert-True (Test-Path -LiteralPath (Join-Path (Get-LifecycleDir $unarchivedHome) 'runtime/router.pid.json')) 'STOP-4: the live owner record is still present'
            $unarchivedGone = $false
            try { $null = Get-Process -Id $unarchivedPid -ErrorAction Stop } catch { $unarchivedGone = $true }
            Assert-True $unarchivedGone 'STOP-4: the target process really exited (the failure is the proof, not the stop)'
            Assert-True (@(Get-HostProcessesUnderRelease $releaseIdentity).Count -eq 0) 'STOP-4: no Host is left running'

            # The canonical graceful stop, in the home whose archive path is intact.
            $canonicalHome = New-PrivateCaseHome
            Write-UserConfig $canonicalHome $true (Get-FreePort)
            $decoyDirectory = Join-Path (Get-LifecycleDir $canonicalHome) 'quarantine/20000101-000000-decoy'
            $null = New-Item -ItemType Directory -Force -Path $decoyDirectory
            ([ordered]@{ schema_version = 1; pid = 4242; process_fingerprint = ('6' * 64); process_start_ticks = 222222
                    host = '127.0.0.1'; port = 47821; created_at = '2026-01-01T00:00:00+00:00'; version = 1 } | ConvertTo-Json -Depth 6) |
                Set-Content -LiteralPath (Join-Path $decoyDirectory 'router.pid.json') -Encoding UTF8

            $start = Invoke-Lifecycle $canonicalHome 'Start' -Json -ExtraArguments (New-ReleaseArguments $releaseIdentity)
            $startResult = Get-JsonResult $start
            Assert-True ($start.ExitCode -eq 0) 'STOP-5 setup: a real managed READY was reached'
            $canonicalPid = if ($null -ne $startResult) { [int]$startResult.evidence.pid } else { 0 }
            Assert-True ($canonicalPid -gt 0) 'STOP-5 setup: the managed READY is bound to a real process'

            $stop = Invoke-Lifecycle $canonicalHome 'Stop' -Json -ExtraArguments @('-StopTimeoutSeconds', '60')
            $stopResult = Get-JsonResult $stop
            Assert-True ($stop.ExitCode -eq 0) "STOP-5: the authenticated graceful stop succeeds (exit $($stop.ExitCode))"
            Assert-True ($stopResult.state -eq 'STOPPED' -and $stopResult.reason -eq 'stop_completed_gracefully') 'STOP-5: completion is proven, not assumed'
            Assert-True ($stopResult.evidence.host_accepted_stop -eq $true) 'STOP-5: the target Host accepted the request'
            Assert-True ($stopResult.evidence.process_exit_proof -eq 'exited') 'STOP-5: the verified process exit is proven'
            Assert-True ($stopResult.evidence.runtime_lifecycle -eq 'STOPPED') 'STOP-5: the durable runtime state is STOPPED'
            Assert-True ($stopResult.evidence.owner_archive_proof -eq 'owner_record_archived_for_this_owner') 'STOP-5: THIS owner record was archived (a decoy archive cannot stand in)'
            Assert-True ($stopResult.evidence.owner_record_live -eq $false) 'STOP-5: no live owner record remains'
            Assert-True ($stopResult.evidence.control_endpoint_withdrawn -eq $true) 'STOP-5: the stop capability was withdrawn'

            $gone = $false
            try { $null = Get-Process -Id $canonicalPid -ErrorAction Stop } catch { $gone = $true }
            Assert-True $gone 'STOP-5: the Host process is really gone after the graceful stop'

            $status = Get-Status $canonicalHome
            Assert-True ($status.state -eq 'UNKNOWN') 'STOP-5: after a stop only historical evidence remains, never a fabricated STOPPED'
            Assert-True ($status.evidence.historical_lifecycle -eq 'STOPPED') 'STOP-5: the historical STOPPED state is reported as history'

            $stop = Invoke-Lifecycle $canonicalHome 'Stop' -Json
            Assert-True ($stop.ExitCode -eq 5) 'STOP-5: repeating Stop without a target is refused, never reported as completed again'

            Assert-True (@(Get-HostProcessesUnderRelease $releaseIdentity).Count -eq 0) 'S: no verified Host process is left running by this validation'
        }
        finally {
            [Environment]::SetEnvironmentVariable('CODEX_LOCAL_ROUTER_TOKEN', $tokenBefore, 'Process')
        }
    }
    else {
        Write-Host 'UNRUN Windows end-to-end verified-release start/stop: this platform cannot establish it' -ForegroundColor Yellow
    }
}
finally {
    foreach ($lock in $locks) { try { $lock.Dispose() } catch { } }
    # Test-only cleanup: any Host this validation started is identified by the
    # release root it was launched from, and a leftover one is removed so a failed
    # case cannot interfere with the next run. The production controller never
    # kills a process; this is the harness cleaning up its own test children.
    if ($null -ne $releaseIdentity) {
        foreach ($leftover in (Get-HostProcessesUnderRelease $releaseIdentity)) {
            try { Stop-Process -Id $leftover.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    foreach ($child in $children) {
        try { if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit(5000) | Out-Null } } catch { }
        try { $child.Dispose() } catch { }
    }
    foreach ($serverProcess in $serverProcesses) {
        try { if (-not $serverProcess.HasExited) { $serverProcess.Kill(); $serverProcess.WaitForExit(5000) | Out-Null } } catch { }
        try { $serverProcess.Dispose() } catch { }
    }
    if ($tempRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $tempRoot).StartsWith('lr15-pr10b-', [System.StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "LIFECYCLE_SUMMARY PASS=$passes FAIL=$($failures.Count) WindowsNative=$IsWindows"
if ($failures.Count -gt 0) {
    Write-Host "Router host lifecycle validation FAILED ($($failures.Count) failure(s))" -ForegroundColor Red
    exit 1
}

Write-Host "Router host lifecycle validation PASSED" -ForegroundColor Green
exit 0
