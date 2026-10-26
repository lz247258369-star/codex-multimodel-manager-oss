param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Status', 'Start', 'Stop')]
    [string]$Action,

    # Isolated Codex home. Never defaults to a path it would have to guess: an
    # explicit `-CodexHome` or an explicit CODEX_HOME is required.
    [Parameter(Mandatory = $false)][string]$CodexHome = "",

    [Parameter(Mandatory = $false)][switch]$AsJson,

    # Start only: the verified PR9 Host release identity. Start never spawns
    # anything this verification did not produce.
    [Parameter(Mandatory = $false)][string]$ReleaseRoot = "",
    [Parameter(Mandatory = $false)][string]$ExpectedManifestSha256 = "",
    [Parameter(Mandatory = $false)][string]$ExpectedPackageSha256 = "",
    [Parameter(Mandatory = $false)][string]$ExpectedVersion = "",
    [Parameter(Mandatory = $false)][string]$ExpectedSourceCommit = "",

    [Parameter(Mandatory = $false)][int]$ReadyTimeoutSeconds = 60,
    [Parameter(Mandatory = $false)][int]$ControlTimeoutSeconds = 10,
    [Parameter(Mandatory = $false)][int]$StopTimeoutSeconds = 60
)

# LR-15 PR10B: Router Host lifecycle controller (Status / Start / Graceful Stop).
#
# Status is strictly read-only. It reports an active lifecycle only for a
# VERIFIED live owner, and it never converts an unprovable situation into a
# confident STOPPED: a persisted terminal state is history, not a current stop
# proof, so it is reported as UNKNOWN with the historical state as evidence.
#
# Start spawns ONLY a PR9-verified Host release and reports success only after
# every one of these is true: the release verified, the spawned process identity
# matches, durable READY belongs to that process, the control endpoint exists and
# matches that owner and its config generation, the endpoint carries the required
# current-user access control, a live control pipe instance for exactly that name
# exists (a stale JSON file is not a capability), and the Host is still running.
#
# Stop is authenticated and graceful, and it never kills an unknown process.
# Success requires: the target Host accepted the request, the verified process was
# confirmed EXITED (an unreadable or unverifiable process state is never treated
# as an exit), the durable lifecycle was re-read as STOPPED, THIS owner record was
# archived (matched by content hash and identity, so another historical archive
# cannot stand in for it), and no live owner record remains.
#
# Exit codes:
#   0  the action succeeded (a status was determined; Start verified a complete
#      managed READY; Stop completed or the router was already stopped)
#   2  usage error (missing/!absolute CodexHome)
#   4  refused: a required capability is unavailable (Start without a verified
#      release; Stop without a matching control endpoint)
#   5  refused: the observed lifecycle does not allow the action
#   6  Start did not reach a verified managed READY (early exit, missing control
#      capability, or timeout)
#   7  Stop was accepted but not proven complete (never killed)
#   8  the Host refused the control request (authentication or request shape)

$ErrorActionPreference = 'Stop'

$script:EndpointFileName = 'router.control.json'
$script:PipeNamePattern = '^codex-router-host-[0-9a-f]{32}$'
$script:TokenPattern = '^[0-9a-f]{64}$'
$script:PipeNamespace = '\\.\pipe\'
# Write-class rights that must never be granted to a broad identity on a
# capability file: write data/append, extended attributes/attributes, delete,
# write permissions/owner, plus the generic ALL/WRITE masks.
# The capability is a credential: any allow-grant to an identity other than the
# current user (or the local SYSTEM account, which already administers the
# machine) is a leak, whether it is read or write. `S-1-5-18` is SYSTEM.
$script:AuthorizedCapabilitySids = @('S-1-5-18')

function New-Result {
    param([string]$State, [string]$Reason, [hashtable]$Evidence)
    return [pscustomobject]@{ state = $State; reason = $Reason; evidence = $Evidence }
}

function Write-LifecycleResult {
    param($Result)
    if ($AsJson) {
        $Result | ConvertTo-Json -Depth 5 -Compress
    }
    else {
        Write-Host ("Router lifecycle : {0} ({1})" -f $Result.state, $Result.reason)
        foreach ($key in ($Result.evidence.Keys | Sort-Object)) {
            Write-Host ("  {0} = {1}" -f $key, $Result.evidence[$key])
        }
    }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ __corrupt = $true } }
}

function Get-ProcessFingerprint {
    param([int]$ProcessId, [long]$Ticks)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString(
                $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$ProcessId`:$Ticks")))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-InnerException {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    $depth = 0
    while ($null -ne $exception.InnerException -and $depth -lt 6) {
        $exception = $exception.InnerException
        $depth++
    }
    return $exception
}

# Three-way process presence. A read failure, an access failure or an identity
# change is NEVER reported as "the process exited": only a positive absence (the
# process with that id does not exist) or a complete identity match is trusted.
function Get-ProcessPresence {
    param([int]$ProcessId, [long]$ExpectedTicks, [string]$ExpectedFingerprint)
    if ($ProcessId -lt 1) {
        return [pscustomobject]@{ state = 'unverifiable'; reason = 'invalid_pid'; ticks = 0; fingerprint = "" }
    }

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
    }
    catch {
        $inner = Get-InnerException $_
        # Only the documented "Process with an Id of N is not running" failure is
        # evidence of absence. Any other exception (for example a generic
        # InvalidOperationException) says nothing about the process and must never
        # be converted into an exit.
        if ($inner -is [System.ArgumentException]) {
            return [pscustomobject]@{ state = 'absent'; reason = 'process_not_running'; ticks = 0; fingerprint = "" }
        }

        return [pscustomobject]@{ state = 'unverifiable'; reason = 'process_state_unavailable'; ticks = 0; fingerprint = "" }
    }

    try {
        $start = $null
        try { $start = $process.StartTime } catch { $start = $null }
        if ($null -eq $start) {
            return [pscustomobject]@{ state = 'unverifiable'; reason = 'process_start_time_unavailable'; ticks = 0; fingerprint = "" }
        }

        $ticks = $start.ToUniversalTime().Ticks
        $fingerprint = Get-ProcessFingerprint -ProcessId $ProcessId -Ticks $ticks
        if ($ticks -ne $ExpectedTicks -or $fingerprint -cne $ExpectedFingerprint) {
            # PID reuse or a different process instance.
            return [pscustomobject]@{ state = 'unverifiable'; reason = 'process_identity_mismatch'; ticks = $ticks; fingerprint = $fingerprint }
        }

        return [pscustomobject]@{ state = 'present'; reason = 'process_identity_verified'; ticks = $ticks; fingerprint = $fingerprint }
    }
    finally {
        try { $process.Dispose() } catch { }
    }
}

function Get-ProcessExitProof {
    param([int]$ProcessId, [long]$ExpectedTicks, [string]$ExpectedFingerprint, [int]$TimeoutSeconds)
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
    }
    catch {
        $inner = Get-InnerException $_
        if ($inner -is [System.ArgumentException]) {
            # The documented "not running" failure, combined with the identity
            # verification this controller performed before sending the stop
            # request, is explicit evidence that the process is gone.
            return [pscustomobject]@{ proof = 'exited'; detail = 'process_id_absent'; ticks = 0; fingerprint = "" }
        }

        # Any other exception proves nothing about the process.
        return [pscustomobject]@{ proof = 'unverifiable'; detail = 'process_open_failed'; ticks = 0; fingerprint = "" }
    }

    try {
        $ticks = $null
        try { $ticks = $process.StartTime.ToUniversalTime().Ticks } catch { $ticks = $null }
        if ($null -eq $ticks) {
            return [pscustomobject]@{ proof = 'unverifiable'; detail = 'process_start_time_unavailable'; ticks = 0; fingerprint = "" }
        }

        if ($ticks -ne $ExpectedTicks -or
            (Get-ProcessFingerprint -ProcessId $ProcessId -Ticks $ticks) -cne $ExpectedFingerprint) {
            return [pscustomobject]@{ proof = 'unverifiable'; detail = 'process_identity_mismatch'; ticks = $ticks; fingerprint = "" }
        }

        $exited = $false
        try { $exited = $process.WaitForExit($TimeoutSeconds * 1000) }
        catch {
            return [pscustomobject]@{ proof = 'unverifiable'; detail = 'process_wait_failed'; ticks = $ticks; fingerprint = "" }
        }

        if (-not $exited) {
            return [pscustomobject]@{ proof = 'running'; detail = 'process_still_running'; ticks = $ticks; fingerprint = "" }
        }

        # The handle bound to the verified identity signalled termination.
        return [pscustomobject]@{ proof = 'exited'; detail = 'wait_for_exit_signalled'; ticks = $ticks; fingerprint = "" }
    }
    finally {
        try { $process.Dispose() } catch { }
    }
}

function Get-LifecyclePaths {
    # Never name this parameter `Home`: `$HOME` is a read-only automatic
    # variable in PowerShell, so binding it fails the whole script.
    param([string]$CodexHomePath)
    $managerRoot = Join-Path $CodexHomePath 'multimodel-manager/local-router'
    return [pscustomobject]@{
        ManagerRoot    = $managerRoot
        RuntimeDir     = Join-Path $managerRoot 'runtime'
        UserConfigPath = Join-Path $managerRoot 'router.config.json'
        StatePath      = Join-Path $managerRoot 'runtime/router.state.json'
        OwnerPath      = Join-Path $managerRoot 'runtime/router.pid.json'
        EndpointPath   = Join-Path $managerRoot ('runtime/' + $script:EndpointFileName)
        QuarantineRoot = Join-Path $managerRoot 'quarantine'
        HostStdoutPath = Join-Path $managerRoot 'host-stdout.log'
        HostStderrPath = Join-Path $managerRoot 'host-stderr.log'
    }
}

function Get-LifecycleFacts {
    param($Paths)
    $state = Read-JsonFile $Paths.StatePath
    $owner = Read-JsonFile $Paths.OwnerPath
    return [pscustomobject]@{
        StateCorrupt = ($null -ne $state -and $null -ne $state.PSObject.Properties['__corrupt'])
        OwnerCorrupt = ($null -ne $owner -and $null -ne $owner.PSObject.Properties['__corrupt'])
        State        = $state
        Owner        = $owner
    }
}

function Get-OwnerIdentity {
    param($Facts)
    if ($null -eq $Facts.Owner) {
        return [pscustomobject]@{ usable = $false; reason = 'owner_record_missing'; pid = 0; ticks = 0; fingerprint = "" }
    }
    if ($Facts.OwnerCorrupt) {
        return [pscustomobject]@{ usable = $false; reason = 'owner_record_unreadable'; pid = 0; ticks = 0; fingerprint = "" }
    }

    $ownerPid = 0
    $ticks = 0
    try {
        $ownerPid = [int]$Facts.Owner.pid
        $ticks = [long]$Facts.Owner.process_start_ticks
    }
    catch {
        return [pscustomobject]@{ usable = $false; reason = 'owner_record_invalid'; pid = 0; ticks = 0; fingerprint = "" }
    }

    $fingerprint = [string]$Facts.Owner.process_fingerprint
    if ($ownerPid -lt 1 -or $ticks -le 0 -or $fingerprint -cnotmatch $script:TokenPattern) {
        return [pscustomobject]@{ usable = $false; reason = 'owner_record_invalid'; pid = 0; ticks = 0; fingerprint = "" }
    }

    # The record must be internally consistent: the fingerprint is derived from
    # the identity it claims, so a forged pair cannot masquerade as a process.
    if ((Get-ProcessFingerprint -ProcessId $ownerPid -Ticks $ticks) -cne $fingerprint) {
        return [pscustomobject]@{ usable = $false; reason = 'owner_record_fingerprint_inconsistent'; pid = $ownerPid; ticks = $ticks; fingerprint = $fingerprint }
    }

    return [pscustomobject]@{ usable = $true; reason = 'owner_record_consistent'; pid = $ownerPid; ticks = $ticks; fingerprint = $fingerprint }
}

function Get-OwnerPresence {
    param($OwnerIdentity)
    return Get-ProcessPresence -ProcessId $OwnerIdentity.pid -ExpectedTicks $OwnerIdentity.ticks -ExpectedFingerprint $OwnerIdentity.fingerprint
}

function Get-RouterStatus {
    param($Paths)
    $result = $null
    try {
        # 1. Effective enablement. Absent user config means the shipped
        #    default-disabled baseline: Router Mode is not enabled.
        $userConfig = Read-JsonFile $Paths.UserConfigPath
        $enabled = $false
        if ($null -ne $userConfig) {
            if ($userConfig.PSObject.Properties['__corrupt']) {
                $result = New-Result 'UNKNOWN' 'user_config_unreadable' @{ current_stop_proof = 'none' }
            }
            else {
                $mode = [string]$userConfig.mode
                $flag = $userConfig.local_router
                $routerEnabled = ($null -ne $flag -and $null -ne $flag.PSObject.Properties['enabled'] -and [bool]$flag.enabled)
                $enabled = ($mode -eq 'router') -and $routerEnabled
            }
        }
        else {
            $result = New-Result 'DISABLED' 'default_and_no_user_config' @{ enabled = $false; stop_claim = 'none' }
        }

        if ($null -eq $result -and -not $enabled) {
            $result = New-Result 'DISABLED' 'user_config_not_enabled' @{ enabled = $false; stop_claim = 'none' }
        }

        if ($null -eq $result) {
            $facts = Get-LifecycleFacts $Paths
            $evidence = @{
                enabled               = $true
                runtime_state_present = ($null -ne $facts.State)
                owner_present         = ($null -ne $facts.Owner)
                current_stop_proof    = 'none'
            }

            if ($facts.StateCorrupt) {
                $result = New-Result 'UNKNOWN' 'runtime_state_unreadable' $evidence
            }
            elseif ($null -eq $facts.State) {
                $result = New-Result 'UNKNOWN' 'runtime_state_missing' $evidence
            }
            else {
                $lifecycle = [string]$facts.State.lifecycle
                $evidence['runtime_lifecycle'] = $lifecycle
                $knownLifecycle = @('STARTING', 'READY', 'STOPPING', 'STOPPED', 'DEGRADED', 'FAILED') -contains $lifecycle
                if (-not $knownLifecycle) {
                    $result = New-Result 'UNKNOWN' 'runtime_lifecycle_unknown' $evidence
                }
                else {
                    # A persisted terminal state is history. It cannot by itself
                    # prove that no Host is running now, and no read-only query has
                    # an independent current proof (a fresh Host can be inside its
                    # pre-owner startup window). It is therefore reported as
                    # UNKNOWN with the historical state as evidence, never as a
                    # verified stop.
                    $evidence['historical_lifecycle'] = $lifecycle
                    if ($facts.OwnerCorrupt) {
                        $result = New-Result 'UNKNOWN' 'owner_record_unreadable' $evidence
                    }
                    elseif ($null -eq $facts.Owner) {
                        if ($lifecycle -eq 'STOPPED') {
                            $result = New-Result 'UNKNOWN' 'terminal_state_without_owner_record' $evidence
                        }
                        else {
                            $result = New-Result 'UNKNOWN' 'active_state_without_owner' $evidence
                        }
                    }
                    else {
                        $identity = Get-OwnerIdentity $facts
                        if (-not $identity.usable) {
                            $result = New-Result 'UNKNOWN' $identity.reason $evidence
                        }
                        else {
                            $presence = Get-OwnerPresence $identity
                            $evidence['recorded_owner_process'] = $presence.state
                            switch ($presence.state) {
                                'present' {
                                    if ($lifecycle -eq 'STOPPED') {
                                        # A live verified owner with a terminal state
                                        # is a contradiction: never a clean stop.
                                        $result = New-Result 'UNKNOWN' 'live_process_with_terminal_state' $evidence
                                    }
                                    else {
                                        $evidence['current_state_proof'] = 'live_owner_identity_verified'
                                        $result = New-Result $lifecycle 'owner_identity_verified' $evidence
                                    }
                                }
                                'absent' {
                                    if ($lifecycle -eq 'STOPPED') {
                                        # The recorded owner is gone, but that is not a
                                        # current stop proof for the runtime directory.
                                        $result = New-Result 'UNKNOWN' 'terminal_state_without_current_stop_proof' $evidence
                                    }
                                    else {
                                        # Verified absence of the recorded owner with a
                                        # non-terminal durable state is a crash, never a
                                        # clean stop.
                                        $result = New-Result 'FAILED' 'owner_process_exited_without_terminal_state' $evidence
                                    }
                                }
                                default {
                                    $result = New-Result 'UNKNOWN' $presence.reason $evidence
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    catch {
        $result = New-Result 'UNKNOWN' 'status_read_error' @{ current_stop_proof = 'none' }
    }

    return $result
}

# Verifies a real current-user-only DACL. It is not enough that broad write access
# is absent: the capability token must not be READABLE by any identity other than
# the current user (or the local SYSTEM account). Anything else - inheritance that
# was never removed, a foreign identity with read or write, an unresolvable
# identity - is refused, and the check never mistakes "no broad write" for "safe".
function Test-CapabilityFileAcl {
    param([string]$Path)
    try {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        if ($null -eq $currentUser) { return [pscustomobject]@{ ok = $false; reason = 'control_endpoint_acl_unresolved_user' } }

        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if (-not $acl.AreAccessRulesProtected) {
            return [pscustomobject]@{ ok = $false; reason = 'control_endpoint_acl_inherits_foreign_access' }
        }

        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -ne 'Allow') { continue }
            $sid = $null
            try { $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $sid = $null }
            if ($null -eq $sid) {
                return [pscustomobject]@{ ok = $false; reason = 'control_endpoint_acl_unresolved_identity' }
            }
            if ($sid -ceq $currentUser.Value) { continue }
            if ($script:AuthorizedCapabilitySids -contains $sid) { continue }

            return [pscustomobject]@{ ok = $false; reason = 'control_endpoint_acl_foreign_identity' }
        }

        return [pscustomobject]@{ ok = $true; reason = 'control_endpoint_acl_current_user_only' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'control_endpoint_acl_unreadable' }
    }
}

function Test-ControlPipeInstance {
    param([string]$PipeName)
    if ($PipeName -cnotmatch $script:PipeNamePattern) { return $false }
    try {
        foreach ($entry in [System.IO.Directory]::GetFiles($script:PipeNamespace)) {
            if ([System.IO.Path]::GetFileName($entry) -ceq $PipeName) { return $true }
        }
    }
    catch { return $false }

    return $false
}

# Reads and validates the published control capability. The endpoint must match
# the verified owner identity and the durable config generation, carry the
# current-user-only access control, and — when a live capability is required —
# have a live pipe instance of exactly that random name. A stale, forged,
# unprotected or mismatching endpoint is never used.
function Get-ControlEndpoint {
    param($Paths, $Facts, $OwnerIdentity, [switch]$RequireLivePipe)
    $endpoint = Read-JsonFile $Paths.EndpointPath
    if ($null -eq $endpoint -or $null -ne $endpoint.PSObject.Properties['__corrupt']) {
        return [pscustomobject]@{ usable = $false; reason = 'control_endpoint_unavailable' }
    }

    try {
        if ([int]$endpoint.schema_version -ne 1 -or [int]$endpoint.version -lt 1) {
            return [pscustomobject]@{ usable = $false; reason = 'control_endpoint_schema' }
        }
        if ([string]$endpoint.pipe_name -cnotmatch $script:PipeNamePattern) {
            return [pscustomobject]@{ usable = $false; reason = 'control_endpoint_pipe_name' }
        }
        if ([string]$endpoint.token -cnotmatch $script:TokenPattern) {
            return [pscustomobject]@{ usable = $false; reason = 'control_endpoint_token_shape' }
        }
        if ([int]$endpoint.pid -ne $OwnerIdentity.pid -or
            [long]$endpoint.process_start_ticks -ne $OwnerIdentity.ticks -or
            [string]$endpoint.process_fingerprint -cne $OwnerIdentity.fingerprint) {
            return [pscustomobject]@{ usable = $false; reason = 'control_endpoint_owner_mismatch' }
        }
        if ($null -ne $Facts.State -and -not $Facts.StateCorrupt -and
            [string]$endpoint.config_generation -cne [string]$Facts.State.config_generation) {
            return [pscustomobject]@{ usable = $false; reason = 'control_endpoint_generation_mismatch' }
        }
    }
    catch {
        return [pscustomobject]@{ usable = $false; reason = 'control_endpoint_invalid' }
    }

    $aclCheck = Test-CapabilityFileAcl $Paths.EndpointPath
    if (-not $aclCheck.ok) {
        return [pscustomobject]@{ usable = $false; reason = $aclCheck.reason }
    }

    $pipeName = [string]$endpoint.pipe_name
    if ($RequireLivePipe -and -not (Test-ControlPipeInstance $pipeName)) {
        return [pscustomobject]@{ usable = $false; reason = 'control_channel_not_listening' }
    }

    return [pscustomobject]@{
        usable    = $true
        reason    = 'control_endpoint_matches_owner'
        pipe_name = $pipeName
        token     = [string]$endpoint.token
    }
}

# Sends the single fixed-shape stop request and returns the Host's answer. Any
# transport failure is a refusal, never a reason to touch the process.
function Invoke-StopRequest {
    param([string]$PipeName, [string]$Token, [int]$TimeoutSeconds)
    $client = $null
    $deadline = $null
    try {
        $client = [System.IO.Pipes.NamedPipeClientStream]::new(
            '.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
        $deadline = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
        $waitMs = ($TimeoutSeconds + 2) * 1000

        $connect = $client.ConnectAsync($deadline.Token)
        if (-not $connect.Wait($waitMs)) { return [pscustomobject]@{ accepted = $false; reason = 'control_connect_timeout' } }
        $connect.GetAwaiter().GetResult()

        $request = (@{ schema_version = 1; action = 'stop'; token = $Token } | ConvertTo-Json -Compress)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($request + "`n")
        $client.Write($bytes, 0, $bytes.Length)
        $client.Flush()

        $buffer = New-Object byte[] 512
        $read = 0
        while ($read -lt $buffer.Length) {
            # PowerShell cannot call extension methods (`AsMemory`), so the
            # array-based ReadAsync overload is used deliberately here.
            $readTask = $client.ReadAsync($buffer, $read, 1, $deadline.Token)
            if (-not $readTask.Wait($waitMs)) { return [pscustomobject]@{ accepted = $false; reason = 'control_response_timeout' } }
            $count = $readTask.GetAwaiter().GetResult()
            if ($count -le 0) { break }
            if ($buffer[$read] -eq 10) { break }
            $read++
        }

        if ($read -le 0) { return [pscustomobject]@{ accepted = $false; reason = 'control_response_missing' } }
        try { $answer = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read) | ConvertFrom-Json }
        catch { return [pscustomobject]@{ accepted = $false; reason = 'control_response_malformed' } }

        if ($null -ne $answer.PSObject.Properties['accepted'] -and [bool]$answer.accepted) {
            return [pscustomobject]@{ accepted = $true; reason = 'host_accepted_stop' }
        }

        return [pscustomobject]@{ accepted = $false; reason = 'host_refused_stop' }
    }
    catch {
        # Type name only: never a private message, path or value.
        [Console]::Error.WriteLine("[local-router] lifecycle_control_diagnostic: type=$($_.Exception.GetType().Name)")
        return [pscustomobject]@{ accepted = $false; reason = 'control_channel_error' }
    }
    finally {
        if ($null -ne $deadline) { try { $deadline.Dispose() } catch { } }
        if ($null -ne $client) { try { $client.Dispose() } catch { } }
    }
}

# Confirms that THIS owner record was archived by the documented quarantine
# contract (`<quarantine>/<stamp>-<id>/router.pid.json`, a byte copy of the live
# record). Another historical archive of a different owner cannot satisfy it: the
# archived content hash and the archived identity must both match the record read
# before the stop.
function Test-OwnerArchived {
    param([string]$QuarantineRoot, [string]$OwnerFileName, [byte[]]$ExpectedContent, [int]$ExpectedPid, [long]$ExpectedTicks, [string]$ExpectedFingerprint)
    if (-not (Test-Path -LiteralPath $QuarantineRoot -PathType Container)) {
        return [pscustomobject]@{ archived = $false; reason = 'quarantine_root_missing' }
    }

    $expectedHash = Get-Sha256Hex -Bytes $ExpectedContent
    $candidates = @(Get-ChildItem -LiteralPath $QuarantineRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $OwnerFileName })
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{ archived = $false; reason = 'no_archived_owner_record' }
    }

    $matchedHash = $false
    $matchedIdentity = $false
    foreach ($candidate in $candidates) {
        try { $bytes = [System.IO.File]::ReadAllBytes($candidate.FullName) } catch { continue }
        if ((Get-Sha256Hex -Bytes $bytes) -ceq $expectedHash) { $matchedHash = $true }
        try {
            $record = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
            if ([int]$record.pid -eq $ExpectedPid -and
                [long]$record.process_start_ticks -eq $ExpectedTicks -and
                [string]$record.process_fingerprint -ceq $ExpectedFingerprint) {
                $matchedIdentity = $true
            }
        }
        catch { }
    }

    if (-not $matchedHash) {
        return [pscustomobject]@{ archived = $false; reason = 'archived_content_not_this_owner'; candidates = $candidates.Count }
    }
    if (-not $matchedIdentity) {
        return [pscustomobject]@{ archived = $false; reason = 'archived_identity_not_this_owner'; candidates = $candidates.Count }
    }

    return [pscustomobject]@{ archived = $true; reason = 'owner_record_archived_for_this_owner'; candidates = $candidates.Count }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Invoke-StartAction {
    param($Paths, [string]$CodexHomePath)

    if ([string]::IsNullOrWhiteSpace($ReleaseRoot) -or
        [string]::IsNullOrWhiteSpace($ExpectedManifestSha256) -or
        [string]::IsNullOrWhiteSpace($ExpectedPackageSha256) -or
        [string]::IsNullOrWhiteSpace($ExpectedVersion) -or
        [string]::IsNullOrWhiteSpace($ExpectedSourceCommit)) {
        [Console]::Error.WriteLine('[local-router] lifecycle_refused: start_requires_verified_release; a PR9 verified Host release (release root, manifest digest, package digest, version, source commit) is required.')
        exit 4
    }

    # Start preconditions are decided from the durable facts. A clean slate and
    # a verifiable stale/crashed owner are startable - the Host's own
    # verified stale-owner recovery archives the latter and never kills a
    # process - while anything unprovable fails closed.
    $userConfig = Read-JsonFile $Paths.UserConfigPath
    $enabled = $false
    if ($null -ne $userConfig -and $null -eq $userConfig.PSObject.Properties['__corrupt']) {
        $flag = $userConfig.local_router
        $enabled = ([string]$userConfig.mode -eq 'router') -and
            ($null -ne $flag) -and
            ($null -ne $flag.PSObject.Properties['enabled']) -and
            [bool]$flag.enabled
    }
    if (-not $enabled) {
        [Console]::Error.WriteLine('[local-router] lifecycle_refused: start_refused_router_disabled; Router Mode is not enabled for this Codex home.')
        exit 5
    }

    $facts = Get-LifecycleFacts $Paths
    if ($facts.StateCorrupt -or $facts.OwnerCorrupt) {
        [Console]::Error.WriteLine('[local-router] lifecycle_refused: start_refused_status_unknown; reason=runtime_state_or_owner_record_unreadable')
        exit 5
    }

    if ($null -ne $facts.Owner) {
        $existingIdentity = Get-OwnerIdentity $facts
        if (-not $existingIdentity.usable) {
            [Console]::Error.WriteLine("[local-router] lifecycle_refused: start_refused_status_unknown; reason=$($existingIdentity.reason); the recorded owner cannot be attributed")
            exit 5
        }

        $existingPresence = Get-OwnerPresence $existingIdentity
        if ($existingPresence.state -eq 'present') {
            [Console]::Error.WriteLine("[local-router] lifecycle_refused: start_refused_already_running; a verified owner (pid=$($existingIdentity.pid)) already holds the loopback port.")
            exit 5
        }
        if ($existingPresence.state -ne 'absent') {
            [Console]::Error.WriteLine("[local-router] lifecycle_refused: start_refused_status_unknown; reason=$($existingPresence.reason); the recorded owner state cannot be verified")
            exit 5
        }
        # A verified-absent owner record is a stale/crashed record: the Host's own
        # stale-owner recovery archives it, and no process is killed or reused.
    }

    # A PR9 refusal is a refusal: nothing unverified is ever executed.
    $verified = $null
    try {
        Import-Module (Join-Path $PSScriptRoot 'router-host-release.psm1') -Force -ErrorAction Stop
        $verified = Get-VerifiedRouterHostRelease `
            -ReleaseRoot $ReleaseRoot `
            -ExpectedManifestSha256 $ExpectedManifestSha256 `
            -ExpectedPackageSha256 $ExpectedPackageSha256 `
            -ExpectedVersion $ExpectedVersion `
            -ExpectedSourceCommit $ExpectedSourceCommit
    }
    catch {
        [Console]::Error.WriteLine("[local-router] lifecycle_refused: start_refused_release_verification; $($_.Exception.Message)")
        exit 4
    }

    if ([bool]$verified.installation_permitted) {
        [Console]::Error.WriteLine('[local-router] lifecycle_refused: start_refused_release_identity; the release claims installation permission.')
        exit 4
    }

    $hostExecutable = Join-Path $verified.root 'Router.Host.exe'
    if (-not (Test-Path -LiteralPath $hostExecutable -PathType Leaf)) {
        [Console]::Error.WriteLine('[local-router] lifecycle_refused: start_refused_release_identity; the verified entry executable is missing.')
        exit 4
    }

    # The Host console logs live beside the runtime directory (never inside the
    # directory the startup gate pins) and are written by the child's own file
    # handles, so a spawned Host outlives this controller without a broken pipe.
    $null = New-Item -ItemType Directory -Force -Path $Paths.ManagerRoot

    try {
        $child = Start-Process -FilePath $hostExecutable `
            -WorkingDirectory $verified.root `
            -PassThru -NoNewWindow `
            -RedirectStandardOutput $Paths.HostStdoutPath `
            -RedirectStandardError $Paths.HostStderrPath `
            -Environment @{ CODEX_HOME = $CodexHomePath } `
            -ErrorAction Stop
    }
    catch {
        [Console]::Error.WriteLine("[local-router] lifecycle_refused: start_refused_spawn_failed; $($_.Exception.GetType().Name)")
        exit 6
    }

    $childPid = $child.Id
    $startTicks = $child.StartTime.ToUniversalTime().Ticks
    $fingerprint = Get-ProcessFingerprint -ProcessId $childPid -Ticks $startTicks

    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    $readyState = $null
    $endpointFailure = $null
    while ((Get-Date) -lt $deadline) {
        if ($child.HasExited) { break }
        $candidate = Get-RouterStatus $Paths
        if ($candidate.state -eq 'READY') {
            # 1. durable READY must belong to the process this controller started.
            $ownerRecord = Read-JsonFile $Paths.OwnerPath
            $identityMatches = $null -ne $ownerRecord -and
                $null -eq $ownerRecord.PSObject.Properties['__corrupt'] -and
                [int]$ownerRecord.pid -eq $childPid -and
                [long]$ownerRecord.process_start_ticks -eq $startTicks -and
                [string]$ownerRecord.process_fingerprint -ceq $fingerprint
            if ($identityMatches) {
                # 2. the stop capability must exist, match that owner and its
                #    config generation, carry the current-user-only access control
                #    and be backed by a LIVE pipe instance - a stale JSON file is
                #    not a capability.
                $readyFacts = Get-LifecycleFacts $Paths
                $readyIdentity = Get-OwnerIdentity $readyFacts
                if ($readyIdentity.usable) {
                    $endpoint = Get-ControlEndpoint -Paths $Paths -Facts $readyFacts -OwnerIdentity $readyIdentity -RequireLivePipe
                    if ($endpoint.usable) {
                        $readyState = $candidate
                        break
                    }

                    $endpointFailure = $endpoint.reason
                }
                else {
                    $endpointFailure = $readyIdentity.reason
                }
            }
        }

        Start-Sleep -Milliseconds 150
    }

    if ($null -eq $readyState) {
        $exited = $child.HasExited
        $exitCode = if ($exited) { $child.ExitCode } else { -1 }
        $reason = if (-not $exited) {
            if ($null -ne $endpointFailure) { 'start_incomplete_control_capability_unverified' } else { 'start_timeout_without_verified_ready' }
        }
        elseif ($exitCode -eq 4) {
            # The Host reached durable READY but could not publish its stop
            # capability, so it stopped itself through the normal shutdown path.
            'start_failed_control_channel_unavailable'
        }
        else {
            'start_failed_host_exited'
        }

        [Console]::Error.WriteLine("[local-router] lifecycle_failed: $reason; host_exited=$exited exit_code=$exitCode control_capability=$($null -ne $endpointFailure)")
        if ($null -ne $endpointFailure) {
            [Console]::Error.WriteLine("[local-router] lifecycle_failed: control_endpoint_reason=$endpointFailure; a READY Host without a verified stop capability is never reported as a successful start")
        }
        if (-not $exited) {
            [Console]::Error.WriteLine('[local-router] lifecycle_notice: the spawned Host is still running; this controller never kills a process. Stop can only address a verified control capability.')
        }
        exit 6
    }

    $ownerRecord = Read-JsonFile $Paths.OwnerPath
    $evidence = @{
        enabled                     = $true
        pid                         = $childPid
        process_start_ticks         = $startTicks
        process_fingerprint         = $fingerprint
        port                        = [int]$ownerRecord.port
        config_generation           = [string]$ownerRecord.config_generation
        ready_verified_by_owner     = $true
        control_endpoint_verified   = $true
        control_pipe_listening      = $true
        control_endpoint_acl        = 'current_user_only'
        host_running                = $true
        source_commit               = [string]$verified.manifest.source_commit
        version                     = [string]$verified.manifest.version
        manifest_sha256             = [string]$ExpectedManifestSha256
    }
    Write-LifecycleResult (New-Result 'READY' 'start_verified_ready_managed' $evidence)
    exit 0
}

function Invoke-StopAction {
    param($Paths)

    $facts = Get-LifecycleFacts $Paths
    if ($facts.StateCorrupt) {
        [Console]::Error.WriteLine('[local-router] lifecycle_refused: stop_refused_status_unknown; reason=runtime_state_unreadable; no process was touched')
        exit 5
    }

    if ($null -eq $facts.Owner) {
        [Console]::Error.WriteLine('[local-router] lifecycle_refused: stop_refused_not_running; reason=owner_record_missing; no process was touched')
        exit 5
    }

    $identity = Get-OwnerIdentity $facts
    if (-not $identity.usable) {
        [Console]::Error.WriteLine("[local-router] lifecycle_refused: stop_refused_status_unknown; reason=$($identity.reason); no process was touched")
        exit 5
    }

    $presence = Get-OwnerPresence $identity
    if ($presence.state -eq 'absent') {
        [Console]::Error.WriteLine('[local-router] lifecycle_refused: stop_refused_not_running; reason=owner_process_not_running; no process was touched')
        exit 5
    }
    if ($presence.state -ne 'present') {
        [Console]::Error.WriteLine("[local-router] lifecycle_refused: stop_refused_status_unknown; reason=$($presence.reason); no process was touched")
        exit 5
    }

    $endpoint = Get-ControlEndpoint -Paths $Paths -Facts $facts -OwnerIdentity $identity -RequireLivePipe
    if (-not $endpoint.usable) {
        [Console]::Error.WriteLine("[local-router] lifecycle_refused: stop_refused_control_channel_unavailable; reason=$($endpoint.reason); no process was touched")
        exit 4
    }

    # The exact live owner bytes are the archive binding: the documented
    # quarantine contract copies the live record byte for byte.
    $ownerBytesBefore = $null
    try { $ownerBytesBefore = [System.IO.File]::ReadAllBytes($Paths.OwnerPath) }
    catch {
        [Console]::Error.WriteLine('[local-router] lifecycle_refused: stop_refused_status_unknown; reason=owner_record_unreadable; no process was touched')
        exit 5
    }

    $answer = Invoke-StopRequest -PipeName $endpoint.pipe_name -Token $endpoint.token -TimeoutSeconds $ControlTimeoutSeconds
    if (-not $answer.accepted) {
        $code = if ($answer.reason -eq 'host_refused_stop') { 8 } else { 4 }
        [Console]::Error.WriteLine("[local-router] lifecycle_refused: stop_refused_by_host_control_channel; reason=$($answer.reason); no process was touched")
        exit $code
    }

    # Completion proof. The stop was authenticated and accepted, so the Host is
    # shutting down; the process is only ever waited for, never signalled.
    $exit = Get-ProcessExitProof -ProcessId $identity.pid -ExpectedTicks $identity.ticks `
        -ExpectedFingerprint $identity.fingerprint -TimeoutSeconds $StopTimeoutSeconds
    $exitProof = $exit.proof

    # Corroboration, reported as evidence: a still-verifiable identity after a
    # confirmed exit would be an unexplained contradiction and blocks success.
    $postExitPresence = Get-ProcessPresence -ProcessId $identity.pid -ExpectedTicks $identity.ticks `
        -ExpectedFingerprint $identity.fingerprint

    $finalState = Read-JsonFile $Paths.StatePath
    $stateReadable = $null -ne $finalState -and $null -eq $finalState.PSObject.Properties['__corrupt']
    $lifecycle = if ($stateReadable) { [string]$finalState.lifecycle } else { '' }
    $ownerStillPresent = Test-Path -LiteralPath $Paths.OwnerPath -PathType Leaf
    $archive = Test-OwnerArchived -QuarantineRoot $Paths.QuarantineRoot `
        -OwnerFileName (Split-Path -Leaf $Paths.OwnerPath) `
        -ExpectedContent $ownerBytesBefore `
        -ExpectedPid $identity.pid -ExpectedTicks $identity.ticks -ExpectedFingerprint $identity.fingerprint

    $evidence = @{
        pid                        = $identity.pid
        process_fingerprint        = $identity.fingerprint
        host_accepted_stop         = $true
        process_exit_proof         = $exitProof
        process_exit_evidence      = $exit.detail
        post_exit_presence         = $postExitPresence.state
        durable_state_readable     = $stateReadable
        runtime_lifecycle          = $lifecycle
        owner_record_live          = $ownerStillPresent
        owner_archive_proof        = $archive.reason
        owner_archive_candidates   = $archive.candidates
        control_endpoint_withdrawn = (-not (Test-Path -LiteralPath $Paths.EndpointPath -PathType Leaf))
    }

    if ($exitProof -ne 'exited') {
        $reason = if ($exitProof -eq 'running') { 'stop_incomplete_process_still_running' } else { 'stop_incomplete_process_exit_unverified' }
        [Console]::Error.WriteLine("[local-router] lifecycle_incomplete: $reason; no process was killed")
        Write-LifecycleResult (New-Result 'UNKNOWN' $reason $evidence)
        exit 7
    }

    if ($postExitPresence.state -eq 'present') {
        # The verified identity is still present after a confirmed exit: an
        # unexplained contradiction is never reported as a completed stop.
        [Console]::Error.WriteLine('[local-router] lifecycle_incomplete: stop_incomplete_identity_contradiction; no process was killed')
        Write-LifecycleResult (New-Result 'UNKNOWN' 'stop_incomplete_identity_contradiction' $evidence)
        exit 7
    }

    if (-not ($stateReadable -and $lifecycle -eq 'STOPPED')) {
        [Console]::Error.WriteLine('[local-router] lifecycle_incomplete: stop_incomplete_terminal_state_unproven; no process was killed')
        Write-LifecycleResult (New-Result 'UNKNOWN' 'stop_incomplete_terminal_state_unproven' $evidence)
        exit 7
    }

    if (-not $archive.archived -or $ownerStillPresent) {
        [Console]::Error.WriteLine("[local-router] lifecycle_incomplete: stop_incomplete_owner_archive_unproven; reason=$($archive.reason); no process was killed")
        Write-LifecycleResult (New-Result 'UNKNOWN' 'stop_incomplete_owner_archive_unproven' $evidence)
        exit 7
    }

    Write-LifecycleResult (New-Result 'STOPPED' 'stop_completed_gracefully' $evidence)
    exit 0
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) { $CodexHome = $env:CODEX_HOME }
if ([string]::IsNullOrWhiteSpace($CodexHome) -or -not [System.IO.Path]::IsPathFullyQualified($CodexHome)) {
    [Console]::Error.WriteLine('[local-router] lifecycle_usage_error: an absolute -CodexHome or CODEX_HOME is required.')
    exit 2
}

$paths = Get-LifecyclePaths -CodexHomePath $CodexHome

if ($Action -eq 'Status') {
    Write-LifecycleResult (Get-RouterStatus $paths)
    exit 0
}

if ($Action -eq 'Start') {
    Invoke-StartAction -Paths $paths -CodexHomePath $CodexHome
}

Invoke-StopAction -Paths $paths
