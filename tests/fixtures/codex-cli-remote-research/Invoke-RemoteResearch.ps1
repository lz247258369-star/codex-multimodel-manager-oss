#Requires -Version 7.4
<#
Offline research runner for docs/CLI_REMOTE_TUI_INTEGRATION_VALIDATION.md (U3 + U6).

Runs the REAL Codex CLI TUI (inside a Windows ConPTY) against an isolated, token-protected
`codex app-server --listen ws://127.0.0.1:<port>`, with a loopback-only fake Responses provider.
A second WebSocket JSON-RPC client stands in for the Manager.

DISABLED BY DEFAULT: this revision has only been verified statically (docs section 10.5); it refuses to run
(exit 2) unless -AllowUnverifiedRunner is passed, which requires explicit owner/PM approval.

Safety contract (enforced below):
- OutDir must be absolute, outside %TEMP%, writable only by the current user/SYSTEM/Administrators,
  and must NOT exist yet: every directory the runner uses is created fresh and verified empty.
- Every Codex process uses a fresh CODEX_HOME inside OutDir; the real ~/.codex is never read.
- All *_API_KEY variables are removed from this process before any child starts; tokens are synthetic.
- OutDir, its existing ancestors and every directory created here must not be reparse points
  (junctions/symlinks), and OutDir must be outside this repository.
- The fake provider binds 127.0.0.1 only; Codex plugin/app sync features are disabled in the isolated
  config. Every process started here is created suspended and joins its own kill-on-close job object
  BY HANDLE before it runs; a supervisor checks the job members' TCP connections every 500 ms and
  terminates all of them on the first non-loopback connection (network circuit breaker), on any
  failure to read the job members or TCP tables (fail closed), or when -MaxSeconds is exhausted.
- No paid inference, no real account call, no Desktop interaction; only job members are ever stopped.
Exit codes: 0 COMPLETED, 2 safety guard refused, 3 ERROR, 4 TIMEOUT (budget, or any step/RPC soft
timeout), 5 NETWORK_VIOLATION (including a monitor failure).
Not part of CI: it needs an installed Codex binary and an interactive-capable Windows console host.
#>
param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    # Explicit path to the Codex CLI binary under test (no machine-specific default).
    [Parameter(Mandatory = $true)][string]$Codex,
    [ValidateSet('Tui', 'Exhaustion', 'U6', 'All')][string]$Scenario = 'All',
    [string[]]$U6Codex = @(),
    # Hard wall-clock budget for the whole run; the watchdog terminates every child when it expires.
    [int]$MaxSeconds = 600,
    # The runner is disabled unless this is passed (needs explicit owner/PM approval; see docs section 10.5).
    [switch]$AllowUnverifiedRunner
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# --- safety guards (exit code 2 on refusal) ---------------------------------------------------
function Stop-Guard([string]$Message) {
    [Console]::Error.WriteLine("GUARD REFUSED: $Message")
    $r = Get-Variable -Scope Script -Name Result -ValueOnly -ErrorAction Ignore
    if ($null -ne $r) { $r['status'] = 'GUARD_REFUSED'; $r['error'] = $Message }
    exit 2
}

if (-not $AllowUnverifiedRunner) {
    Stop-Guard 'this runner revision has only been verified statically and is disabled by default (docs section 10.5); running it needs explicit owner/PM approval and -AllowUnverifiedRunner.'
}

function Assert-NoReparseChain([string]$Path) {
    # Refuse when the path itself or any EXISTING ancestor is a reparse point (junction/symlink).
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-Guard "reparse point (junction/symlink) in path: $current" }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function New-SafeDirectory([string[]]$Paths) {
    # Every directory the runner uses must be created by this run: an existing path (even an empty
    # one) is refused, so no file, state or ACL from an earlier run is ever reused.
    foreach ($p in $Paths) {
        Assert-NoReparseChain $p
        if (Test-Path -LiteralPath $p) { Stop-Guard "directory already exists (a new, unique directory is required): $p" }
        [void][IO.Directory]::CreateDirectory($p)
        Assert-NoReparseChain $p
        if (@(Get-ChildItem -LiteralPath $p -Force).Count -ne 0) { Stop-Guard "newly created directory is not empty: $p" }
    }
}

if (-not [IO.Path]::IsPathRooted($OutDir)) { Stop-Guard 'OutDir must be an absolute path.' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if ($OutDir.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { Stop-Guard 'OutDir must not be under %TEMP%.' }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$sep = [IO.Path]::DirectorySeparatorChar
if (($OutDir.TrimEnd($sep) + $sep).StartsWith($repoRoot.TrimEnd($sep) + $sep, [StringComparison]::OrdinalIgnoreCase)) { Stop-Guard 'OutDir must be outside the repository.' }
New-SafeDirectory @($OutDir)
$me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$writeMask = 0x2 -bor 0x4 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
foreach ($rule in (Get-Acl -LiteralPath $OutDir).Access) {
    if ($rule.AccessControlType -ne 'Allow' -or (([int]$rule.FileSystemRights -band $writeMask) -eq 0)) { continue }
    $sid = try { $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { 'UNRESOLVED' }
    if ($sid -notin @($me, 'S-1-5-18', 'S-1-5-32-544')) { Stop-Guard "OutDir grants write access to another identity ($($rule.IdentityReference))." }
}
if (-not (Test-Path -LiteralPath $Codex -PathType Leaf)) { Stop-Guard "Codex binary not found: $Codex" }
foreach ($name in @(Get-ChildItem Env: | Where-Object { $_.Name -like '*_API_KEY' -or $_.Name -eq 'CODEX_LOCAL_ROUTER_TOKEN' } | ForEach-Object Name)) {
    Remove-Item -LiteralPath "Env:$name"
}
if (-not ('CodexRemoteResearch.FakeProvider' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'RemoteResearchHarness.cs') }
[CodexRemoteResearch.SoftTimeouts]::Rpc.Clear()
# The real TUI prewarms a public announcement tip over HTTPS at startup (unconditionally in
# codex-rs/tui/src/lib.rs). Route every child's proxy-aware HTTP client to a CLOSED loopback port
# so that fetch fails locally; loopback traffic is excluded via NO_PROXY. Verified per step below.
$deadListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $deadListener.Start(); $deadPort = $deadListener.LocalEndpoint.Port; $deadListener.Stop()
foreach ($v in 'HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'https_proxy', 'http_proxy', 'all_proxy') { Set-Item -LiteralPath "Env:$v" -Value "http://127.0.0.1:$deadPort" }
$env:NO_PROXY = '127.0.0.1,localhost,::1'; $env:no_proxy = $env:NO_PROXY
# Even the version probe runs under an isolated CODEX_HOME: the real ~/.codex is never selected.
$env:CODEX_HOME = Join-Path $OutDir 'version-probe-home'
New-SafeDirectory @($env:CODEX_HOME)

$script:Result = [ordered]@{ status = 'RUNNING'; started = (Get-Date).ToString('o'); maxSeconds = $MaxSeconds; codex = $Codex; codexVersion = ''; steps = @(); timeouts = @() }
$script:Timeouts = [Collections.Generic.List[string]]::new()
$script:ProgressLog = Join-Path $OutDir "progress-$Scenario.log"
$script:ResultPath = Join-Path $OutDir "result-$Scenario.json"
# Supervisor: per-process kill-on-close jobs, wall-clock budget and network circuit breaker.
$script:Supervisor = [CodexRemoteResearch.Supervisor]::new()
$script:Supervisor.Start($MaxSeconds)

function New-Group([string]$Label) {
    $g = [CodexRemoteResearch.ProcessGroup]::new($Label)
    $script:Supervisor.Register($g)
    $g
}

function Stop-Group($Group) {
    # Terminates exactly the members of this job (no PID-tree guessing) and waits for them to exit:
    # a following Codex process on the same CODEX_HOME was observed to fail its SQLite state
    # initialisation while the previous one was still exiting.
    if ($null -eq $Group) { return }
    if (-not $Group.TerminateAndWait(10000)) { Add-Content -LiteralPath $script:ProgressLog -Value "WARN group $($Group.Label) still has active processes 10 s after termination" }
    $script:Supervisor.Unregister($Group)
    $Group.Dispose()
}

function Get-CodexVersion([string]$Exe) {
    # The version probe is a Codex process too: it is started through the same suspended/job path.
    $script:VersionProbe = 1 + [int](Get-Variable -Scope Script -Name VersionProbe -ValueOnly -ErrorAction Ignore)
    $g = New-Group "version-$($script:VersionProbe)"
    $p = [CodexRemoteResearch.JobProcess]::Start($Exe, '--version', $OutDir, $null, (Join-Path $OutDir "version-$($script:VersionProbe).err"), $g)
    try {
        $read = $p.StandardOutput.ReadToEndAsync()
        if (-not $read.Wait(15000)) { throw "codex --version did not finish within 15 s: $Exe" }
        $read.Result.Trim()
    }
    finally { $p.Dispose(); Stop-Group $g }
}

function Save-Result {
    $script:Result['timeouts'] = @($script:Timeouts)
    $script:Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ResultPath -Encoding utf8
}

function Assert-Budget([string]$Where) {
    $tripped = $script:Supervisor.Tripped
    if ($tripped -eq 'NETWORK_VIOLATION') { throw "RUN_NETWORK_VIOLATION at ${Where}: $(@($script:Supervisor.Violations) -join ', ')" }
    if ($tripped -eq 'TIMEOUT' -or $script:Supervisor.BudgetExceeded) { throw "RUN_TIMEOUT: budget of $MaxSeconds s exhausted at $Where" }
}

function Add-Step([string]$Name, [hashtable]$Data) {
    $entry = [ordered]@{ step = $Name; at = (Get-Date).ToString('HH:mm:ss') }
    foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }
    foreach ($k in @($entry.Keys)) {
        if ($k -match 'pstream$' -and [string]::IsNullOrEmpty([string]$entry[$k])) { $entry[$k] = 'TIMEOUT (no matching upstream request; see timeouts)' }
    }
    $entry['externalConnections'] = @(Get-ExternalConnection)
    $script:Result.steps += [pscustomobject]$entry
    $line = "[{0}] {1} {2}" -f $entry.at, $Name, (($entry.GetEnumerator() | Where-Object { $_.Key -notin 'step', 'at' } | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
    Write-Host $line
    Add-Content -LiteralPath $script:ProgressLog -Value $line
    Save-Result
    Assert-Budget $Name
}

function Get-ExternalConnection { @($script:Supervisor.ScanNow()) }

function New-ResearchRun([string]$Label) {
    $dir = Join-Path $OutDir $Label
    $codexHome = Join-Path $dir 'codex-home'; $ws = Join-Path $dir 'workspace'
    New-SafeDirectory @($codexHome, $ws)
    $providerToken = 'synthetic-provider-' + [guid]::NewGuid().ToString('N')
    $wsToken = 'synthetic-ws-' + [guid]::NewGuid().ToString('N')
    $fake = [CodexRemoteResearch.FakeProvider]::new($providerToken)
    $wsKey = $ws.Replace('\', '\\')
    $providers = foreach ($id in 'fake_a', 'fake_b') {
        "[model_providers.$id]`nname = `"$id`"`nbase_url = `"http://127.0.0.1:$($fake.Port)/$id/v1`"`nwire_api = `"responses`"`nenv_key = `"CRR_PROVIDER_TOKEN`"`nrequires_openai_auth = false`nrequest_max_retries = 1`nstream_max_retries = 1`nstream_idle_timeout_ms = 5000`n"
    }
    @"
model = "m-sub"
model_provider = "fake_a"
approval_policy = "never"
sandbox_mode = "read-only"
check_for_update_on_startup = false

[analytics]
enabled = false

[features]
plugins = false
remote_plugin = false
apps = false
plugin_sharing = false
skill_mcp_dependency_install = false

[projects."$wsKey"]
trust_level = "trusted"

$($providers -join "`n")
"@ | Set-Content -LiteralPath (Join-Path $codexHome 'config.toml') -Encoding utf8
    $env:CODEX_HOME = $codexHome
    $env:CRR_PROVIDER_TOKEN = $providerToken
    $env:CRR_WS_TOKEN = $wsToken
    [pscustomobject]@{ Dir = $dir; Home = $codexHome; Ws = $ws; Fake = $fake; WsToken = $wsToken }
}

function Get-FreePort { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); $p }

function Start-WsServer($Run, [string]$Exe, [string]$Tag) {
    $port = Get-FreePort
    $sha = -join ([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Run.WsToken)) | ForEach-Object { $_.ToString('x2') })
    # Created suspended, joined to its job by handle, then resumed (no window before job membership).
    $group = New-Group "app-server-$Tag"
    $proc = [CodexRemoteResearch.JobProcess]::Start($Exe, "app-server --listen ws://127.0.0.1:$port --ws-auth capability-token --ws-token-sha256 $sha", $Run.Dir,
        (Join-Path $Run.Dir "app-server-$Tag.out"), (Join-Path $Run.Dir "app-server-$Tag.err"), $group)
    for ($i = 0; $i -lt 60; $i++) {
        try { ([Net.Sockets.TcpClient]::new('127.0.0.1', $port)).Dispose(); return [pscustomobject]@{ Proc = $proc; Port = $port; Group = $group } } catch { Start-Sleep -Milliseconds 250 }
    }
    throw 'app-server did not start listening within 15 s'
}

function Connect-Manager($Server, [string]$Token) {
    $c = [CodexRemoteResearch.WsRpcClient]::TryConnect($Server.Port, $Token, 5000)
    if (-not $c.Connected) { throw "Manager could not connect: $($c.HandshakeError)" }
    [void]$c.Initialize('crr-manager')
    $c
}

function Start-Tui($Run, [string]$Exe, $Server, [string[]]$Extra = @()) {
    $args2 = @($Extra) + @('--remote', "ws://127.0.0.1:$($Server.Port)", '--remote-auth-token-env', 'CRR_WS_TOKEN', '-C', "`"$($Run.Ws)`"")
    $group = New-Group 'tui'
    $tui = [CodexRemoteResearch.ConPtySession]::new("`"$Exe`" " + ($args2 -join ' '), $Run.Ws, $group)
    $rendered = $tui.WaitFor('Ask Codex', 30000)
    if (-not $rendered) { $script:Timeouts.Add('TIMEOUT 30s: real TUI did not render its composer'); Add-Content -LiteralPath $script:ProgressLog -Value $script:Timeouts[-1] }
    # Wait until the screen stops changing (resume renders history after the composer appears);
    # typing earlier was observed to reorder characters.
    $last = -1; $stableSince = Get-Date; $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $len = $tui.Raw.Length
        if ($len -ne $last) { $last = $len; $stableSince = Get-Date } elseif (((Get-Date) - $stableSince).TotalMilliseconds -ge 1500) { break }
        Start-Sleep -Milliseconds 250
    }
    if ($tui.Plain -match 'Update available|npm install') { $tui.Dispose(); throw 'TUI showed an update prompt; aborting before any keystroke.' }
    [pscustomobject]@{ Tui = $tui; Rendered = $rendered; Group = $group }
}

function Submit-Tui($Tui, [string]$Marker) {
    # TUI-typed markers are lowercase letters and digits only (`mk...`): characters that need Shift
    # were observed to be dropped when typed into the ConPTY at speed. The upstream request is the
    # only ground truth for what was submitted; the screen is never used to confirm typing.
    if ($Marker -cnotmatch '^mk[a-z0-9]+$') { throw ('TUI marker must match ^mk[a-z0-9]+$ : ' + $Marker) }
    $Tui.Type($Marker, 40)
    Start-Sleep -Milliseconds 500
    $Tui.Send("`r")
}

function Get-TuiStatusModel($Tui) {
    # Ask the real TUI for its own view of the session via the official /status command and read
    # the model it reports in the newly rendered output.
    $before = $Tui.Plain.Length
    $Tui.Type('/status', 40); Start-Sleep -Milliseconds 700; $Tui.Send("`r"); Start-Sleep -Seconds 3
    $delta = ($Tui.Plain.Substring([Math]::Min($before, $Tui.Plain.Length))) -replace '\s+', ' '
    $m = [regex]::Match($delta, 'Model:?\s*([A-Za-z0-9._-]+)')
    $Tui.Send([string][char]27); Start-Sleep -Milliseconds 500
    if ($m.Success) { return $m.Groups[1].Value }
    return 'unparsed: ' + $delta.Substring(0, [Math]::Min(160, $delta.Length))
}

function Save-Upstream($Run, [string]$Label) { $script:Result["upstream_$Label"] = @($Run.Fake.Snapshot() | ForEach-Object { $_.ToString() }) }

function Wait-Upstream($Run, [string]$Marker, [int]$Seconds = 30, [string]$ThreadId = '') {
    # Returns the first upstream request whose CURRENT user text is $Marker (i.e. the marker is the
    # newest marker of that request) on the given thread, or on any thread when no id is given.
    # Codex 0.162 also sends an auxiliary request per user turn on a separate helper thread; those
    # are counted by Get-SideRequest, never mistaken for the main conversation.
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        $hit = @($Run.Fake.Snapshot() | Where-Object { $_.Markers -contains $Marker -and (-not $ThreadId -or $ThreadId.EndsWith($_.Thread)) })
        if ($hit.Count -gt 0) { return $hit[0] }
        Assert-Budget "wait upstream $Marker"
        Start-Sleep -Milliseconds 250
    }
    $script:Timeouts.Add(("TIMEOUT {0}s: no upstream request with marker {1}{2}" -f $Seconds, $Marker, $(if ($ThreadId) { " on thread .." + $ThreadId.Substring($ThreadId.Length - 6) } else { '' })))
    Add-Content -LiteralPath $script:ProgressLog -Value $script:Timeouts[-1]
    return $null
}

function Get-SideRequest($Run, [string]$Marker, [string]$ThreadId) {
    @($Run.Fake.Snapshot() | Where-Object { $_.Markers -contains $Marker -and -not $ThreadId.EndsWith($_.Thread) }).Count
}

function Get-MainThreadId($Client) {
    # The user's conversation thread is the loaded thread that thread/read can return with turns;
    # Codex 0.162 helper threads created per TUI turn are not readable (recorded in the inventory).
    foreach ($id in $Client.Request('thread/loaded/list', [Text.Json.Nodes.JsonObject]::new())['result']['data'].AsArray()) {
        $r = $Client.Request('thread/read', [Text.Json.Nodes.JsonNode]::Parse("{`"threadId`":`"$id`",`"includeTurns`":true}"))
        if ($null -ne $r['result'] -and $r['result']['thread']['turns'].AsArray().Count -gt 0) { return $id.ToString() }
    }
    return $null
}

function Get-ThreadInventory($Client) {
    $ids = $Client.Request('thread/loaded/list', [Text.Json.Nodes.JsonObject]::new())['result']['data'].AsArray()
    foreach ($id in $ids) {
        $r = $Client.Request('thread/read', [Text.Json.Nodes.JsonNode]::Parse("{`"threadId`":`"$id`",`"includeTurns`":true}"))
        $t = $r['result']?['thread']
        $tail = $id.ToString(); $tail = $tail.Substring($tail.Length - 6)
        if ($null -eq $t) { "..$tail read-error=" + ($r['error']?['message']?.ToString()); continue }
        "..$tail turns=$($t['turns'].AsArray().Count) ephemeral=$($t['ephemeral']) source=$($t['source']?.ToJsonString()) threadSource=$($t['threadSource']?.ToJsonString()) agentRole=$($t['agentRole']) parent=$($t['parentThreadId']) forkedFrom=$($t['forkedFromId']) provider=$($t['modelProvider'])/$($t['model'])"
    }
}

function Wait-Note($Client, [string]$Method, [string]$ThreadId, [int]$Seconds = 20) {
    $end = (Get-Date).AddSeconds($Seconds); $seen = @()
    while ((Get-Date) -lt $end) {
        $seen += $Client.Drain()
        $hit = @($seen | Where-Object { $_['method'].GetValue[string]() -eq $Method -and (-not $ThreadId -or ($_['params']?['threadId']?.ToString()) -eq $ThreadId) })
        if ($hit.Count -gt 0) { return [pscustomobject]@{ Hit = $hit[0]; Seen = $seen } }
        Assert-Budget "wait notification $Method"
        Start-Sleep -Milliseconds 250
    }
    $script:Timeouts.Add("TIMEOUT ${Seconds}s: no $Method notification")
    Add-Content -LiteralPath $script:ProgressLog -Value $script:Timeouts[-1]
    [pscustomobject]@{ Hit = $null; Seen = $seen }
}

function Exit-Tui($Handle) {
    $t = $Handle.Tui
    foreach ($i in 1..3) { if ($t.HasExited) { break }; $t.Send([string][char]3); Start-Sleep -Seconds 2 }
    $how = if ($t.HasExited) { 'ctrl-c' } else { 'terminated-by-runner' }
    $screen = $t.Plain
    $t.Dispose()
    Stop-Group $Handle.Group
    [pscustomobject]@{ How = $how; Screen = $screen }
}

function Save-Screen($Run, [string]$Name, [string]$Text) { Set-Content -LiteralPath (Join-Path $Run.Dir "screen-$Name.txt") -Value $Text -Encoding utf8 }

function Get-Settings($Response) {
    $r = $Response['result']
    if ($null -eq $r) { return "error:" + ($Response['error']?['message']?.ToString()) }
    "$($r['modelProvider'])/$($r['model'])"
}

# --- Scenario 1: real TUI connection, dual observation, disconnect/reattach (U3) ---------------
function Invoke-TuiScenario {
    $run = New-ResearchRun 'u3-tui'
    $srv = Start-WsServer $run $Codex 'p1'
    $anon = [CodexRemoteResearch.WsRpcClient]::TryConnect($srv.Port, $null, 5000)
    $wrong = [CodexRemoteResearch.WsRpcClient]::TryConnect($srv.Port, 'wrong-synthetic-token', 5000)
    Add-Step 'auth-negative' @{ anonymousConnected = $anon.Connected; anonymousError = $anon.HandshakeError; wrongTokenConnected = $wrong.Connected; wrongTokenError = $wrong.HandshakeError }
    $anon.Dispose(); $wrong.Dispose()

    $h = Start-Tui $run $Codex $srv
    Add-Step 'tui-start' @{ rendered = $h.Rendered; exited = $h.Tui.HasExited; showsModel = $h.Tui.Plain.Contains('m-sub') }
    [void](Submit-Tui $h.Tui 'mku3t1')
    [void](Wait-Upstream $run 'mku3t1')
    $reply1 = $h.Tui.WaitFor('SYNTH_REPLY_FROM_M_SUB', 20000)
    Start-Sleep -Seconds 2

    $m = Connect-Manager $srv $run.WsToken
    $tid = Get-MainThreadId $m
    $u1 = Wait-Upstream $run 'mku3t1' 5 $tid
    Add-Step 'tui-turn1' @{ mainThreadUpstream = "$u1"; sideRequests = (Get-SideRequest $run 'mku3t1' $tid); replyRendered = $reply1 }
    Add-Step 'thread-inventory' @{ threads = ((Get-ThreadInventory $m) -join ' || ') }
    $sub = $m.Request('thread/resume', [Text.Json.Nodes.JsonNode]::Parse("{`"threadId`":`"$tid`"}"))
    Add-Step 'manager-subscribe' @{ threadTail = $tid.Substring($tid.Length - 6); settings = (Get-Settings $sub) }
    [void]$m.Drain()

    [void](Submit-Tui $h.Tui 'mku3t2')
    $u2 = Wait-Upstream $run 'mku3t2' 30 $tid
    $obs = Wait-Note $m 'turn/completed' $tid 20
    $methods = @($obs.Seen | ForEach-Object { $_['method'].ToString() } | Sort-Object -Unique) -join ','
    Add-Step 'dual-observation' @{ upstream = "$u2"; managerSawTurnCompleted = [bool]$obs.Hit; managerSawMethods = $methods; tuiReply = $h.Tui.WaitFor('mku3t2', 1000) }

    $m.Dispose()
    $m = Connect-Manager $srv $run.WsToken
    $sub2 = $m.Request('thread/resume', [Text.Json.Nodes.JsonNode]::Parse("{`"threadId`":`"$tid`"}"))
    [void](Submit-Tui $h.Tui 'mku3t3')
    $u3 = Wait-Upstream $run 'mku3t3' 30 $tid
    Add-Step 'manager-reconnect' @{ resubscribe = (Get-Settings $sub2); tuiTurnAfterReconnect = "$u3" }

    $exit = Exit-Tui $h
    Save-Screen $run 'tui-first' $exit.Screen
    $loadedAfter = $m.Request('thread/loaded/list', [Text.Json.Nodes.JsonObject]::new())
    Add-Step 'tui-exit' @{ how = $exit.How; serverAlive = (-not $srv.Proc.HasExited); loadedAfterTuiExit = ($loadedAfter['result']?['data']?.ToJsonString()) }

    $h2 = Start-Tui $run $Codex $srv @('resume', $tid)
    $historyShown = $h2.Tui.WaitFor('SYNTH_REPLY_FROM_M_SUB', 15000)
    [void](Submit-Tui $h2.Tui 'mku3t4')
    $u4 = Wait-Upstream $run 'mku3t4' 30 $tid
    Add-Step 'tui-reattach-resume' @{ rendered = $h2.Rendered; historyShown = $historyShown; upstream = "$u4" }
    $exit2 = Exit-Tui $h2
    Save-Screen $run 'tui-reattach' $exit2.Screen
    Save-Upstream $run 'tui'
    $m.Dispose(); Stop-Group $srv.Group; $run.Fake.Dispose()
}

# --- Scenario 2: simulated exhaustion, then A same-provider / B fork / C new-process resume ------
function Invoke-ExhaustionScenario {
    $run = New-ResearchRun 'exhaustion'
    $srv = Start-WsServer $run $Codex 'p1'
    $h = Start-Tui $run $Codex $srv
    [void](Submit-Tui $h.Tui 'mkxt1')
    [void](Wait-Upstream $run 'mkxt1')
    [void]$h.Tui.WaitFor('SYNTH_REPLY_FROM_M_SUB', 20000)
    Start-Sleep -Seconds 2
    $m = Connect-Manager $srv $run.WsToken
    $tid = Get-MainThreadId $m
    $u1 = Wait-Upstream $run 'mkxt1' 5 $tid
    [void]$m.Request('thread/resume', [Text.Json.Nodes.JsonNode]::Parse("{`"threadId`":`"$tid`"}"))
    [void]$m.Drain()
    Add-Step 'x-setup' @{ upstream = "$u1"; threadTail = $tid.Substring($tid.Length - 6) }

    $run.Fake.Exhausted['m-sub'] = $true
    [void](Submit-Tui $h.Tui 'mkxt2')
    $u2 = Wait-Upstream $run 'mkxt2' 30 $tid
    $done = Wait-Note $m 'turn/completed' $tid 30
    $errs = @($done.Seen | Where-Object { $_['method'].ToString() -eq 'error' } | ForEach-Object { $_['params']['error']['codexErrorInfo']?.ToJsonString() })
    $rl = @($done.Seen | Where-Object { $_['method'].ToString() -eq 'account/rateLimits/updated' } | ForEach-Object { "$($_['params']['rateLimits']['primary']?['usedPercent'])/$($_['params']['rateLimits']['rateLimitReachedType'])" })
    $tuiShowsLimit = $h.Tui.WaitFor('usage limit', 10000)
    $nudge = $h.Tui.WaitFor('Keep current model', 6000)
    $nudgeText = if ($nudge) { ([regex]::Match(($h.Tui.Plain -replace '\s+', ' '), 'Approaching rate limits.{0,160}')).Value } else { '' }
    if ($nudge) { $h.Tui.Send([string][char]27); Start-Sleep -Seconds 2 }
    Add-Step 'x-official-switch-prompt' @{ shown = $nudge; text = $nudgeText; action = $(if ($nudge) { 'Esc (no option selected)' } else { 'none' }) }
    Add-Step 'x-exhaustion-signal' @{ upstream = "$u2"; turnStatus = ($done.Hit?['params']?['turn']?['status']?.ToString()); managerErrors = ($errs -join ';'); managerRateLimits = ($rl -join ';'); tuiShowsUsageLimit = $tuiShowsLimit }

    # A. same provider: Manager starts the next turn on another model of the same provider.
    [void]$m.Drain()
    $start = $m.Request('turn/start', [Text.Json.Nodes.JsonNode]::Parse("{`"threadId`":`"$tid`",`"model`":`"m-alt`",`"input`":[{`"type`":`"text`",`"text`":`"MARK_A_MANAGER_TURN synthetic continue`"}]}"))
    $ua = Wait-Upstream $run 'MARK_A_MANAGER_TURN' 30 $tid
    $aDone = Wait-Note $m 'turn/completed' $tid 30
    $tuiSawManagerTurn = $h.Tui.WaitFor('SYNTH_REPLY_FROM_M_ALT', 15000)
    [void](Submit-Tui $h.Tui 'mkausernext')
    $uaNext = Wait-Upstream $run 'mkausernext' 30 $tid
    $statusShowsAlt = Get-TuiStatusModel $h.Tui
    Add-Step 'A-same-provider' @{ managerTurnAccepted = ($null -ne $start['result']); managerTurnUpstream = "$ua"; managerTurnStatus = ($aDone.Hit?['params']?['turn']?['status']?.ToString()); tuiRenderedManagerTurn = $tuiSawManagerTurn; userNextUpstream = "$uaNext"; tuiStatusModelAfterSwitch = $statusShowsAlt }

    # B. cross provider: fork to fake_b and reattach the real TUI to the fork.
    $fork = $m.Request('thread/fork', [Text.Json.Nodes.JsonNode]::Parse("{`"threadId`":`"$tid`",`"modelProvider`":`"fake_b`",`"model`":`"m-b`"}"))
    $fid = $fork['result']?['thread']?['id']?.ToString()
    [void](Submit-Tui $h.Tui 'mkboriginalafterfork')
    $ubOrig = Wait-Upstream $run 'mkboriginalafterfork' 30 $tid
    $exitA = Exit-Tui $h
    Save-Screen $run 'x-original' $exitA.Screen
    $hb = Start-Tui $run $Codex $srv @('resume', $fid)
    $bHistory = $hb.Tui.WaitFor('SYNTH_REPLY_FROM_M_ALT', 15000)
    [void](Submit-Tui $hb.Tui 'mkbforkusernext')
    $ub = Wait-Upstream $run 'mkbforkusernext' 30 $fid
    $forkStatus = Get-TuiStatusModel $hb.Tui
    $origRead = $m.Request('thread/read', [Text.Json.Nodes.JsonNode]::Parse("{`"threadId`":`"$tid`"}"))
    Add-Step 'B-fork-cross-provider' @{ forkSettings = (Get-Settings $fork); newThreadId = ($fid -ne $tid); originalTuiAfterFork = "$ubOrig"; tuiExit = $exitA.How; reattachRendered = $hb.Rendered; forkHistoryShown = $bHistory; forkUserNextUpstream = "$ub"; forkTuiStatusModel = $forkStatus; originalStillReadable = ($null -ne $origRead['result']) }
    $exitB = Exit-Tui $hb
    Save-Screen $run 'x-fork' $exitB.Screen
    $m.Dispose()

    # C. stop the isolated app-server, start a new one, resume the ORIGINAL thread on fake_b.
    Stop-Group $srv.Group
    $srv2 = Start-WsServer $run $Codex 'p2'
    $m2 = Connect-Manager $srv2 $run.WsToken
    $res = $m2.Request('thread/resume', [Text.Json.Nodes.JsonNode]::Parse("{`"threadId`":`"$tid`",`"modelProvider`":`"fake_b`",`"model`":`"m-b`"}"))
    $hc = Start-Tui $run $Codex $srv2 @('resume', $tid)
    [void](Submit-Tui $hc.Tui 'mkcusernext')
    $uc = Wait-Upstream $run 'mkcusernext' 30 $tid
    $cStatus = Get-TuiStatusModel $hc.Tui
    Add-Step 'C-new-process-resume' @{ resumeSettings = (Get-Settings $res); tuiRendered = $hc.Rendered; userNextUpstream = "$uc"; tuiStatusModel = $cStatus; sameThread = ($uc -and $tid.EndsWith($uc.Thread)) }
    $exitC = Exit-Tui $hc
    Save-Screen $run 'x-newprocess' $exitC.Screen

    # C'. same as C but the real TUI resumes WITHOUT the Manager pre-resuming the thread.
    $m2.Dispose(); Stop-Group $srv2.Group
    $srv3 = Start-WsServer $run $Codex 'p3'
    $hd = Start-Tui $run $Codex $srv3 @('resume', $tid)
    [void](Submit-Tui $hd.Tui 'mkc2tuionlyresume')
    $ud = Wait-Upstream $run 'mkc2tuionlyresume' 30 $tid
    Add-Step 'C2-tui-only-resume' @{ tuiRendered = $hd.Rendered; upstream = "$ud" }
    $exitD = Exit-Tui $hd
    Save-Screen $run 'x-tui-only' $exitD.Screen
    Save-Upstream $run 'exhaustion'
    Stop-Group $srv3.Group; $run.Fake.Dispose()
}

# --- Scenario 3: U6 minimal matrix (protocol only, single client) ------------------------------
function Invoke-U6Row($Client, $Run, [string]$Row, [string]$Ws, [hashtable]$Opt) {
    $model = "m-$($Row.ToLower())"
    $t = $Client.Request('thread/start', [Text.Json.Nodes.JsonNode]::Parse("{`"model`":`"$model`",`"modelProvider`":`"fake_a`",`"cwd`":$(ConvertTo-Json $Ws),`"approvalPolicy`":`"never`",`"sandbox`":`"read-only`"}"))
    $tid = $t['result']['thread']['id'].ToString()
    $turn = { param($text, $mdl) $p = "{`"threadId`":`"$tid`",`"input`":[{`"type`":`"text`",`"text`":`"$text`"}]" + $(if ($mdl) { ",`"model`":`"$mdl`"" } else { '' }) + '}'; [void]$Client.Request('turn/start', [Text.Json.Nodes.JsonNode]::Parse($p)); [void](Wait-Upstream $Run $text.Split(' ')[0] 20 $tid); Start-Sleep -Milliseconds 800 }
    & $turn "MARK_${Row}_OK" $null
    if ($Opt['override']) { & $turn "MARK_${Row}_OVERRIDE" "$model-o" }
    if ($Opt['fail']) { $Run.Fake.Exhausted[$(if ($Opt['override']) { "$model-o" } else { $model })] = $true; & $turn "MARK_${Row}_FAIL" $null }
    $loadedBefore = ($Client.Request('thread/loaded/list', [Text.Json.Nodes.JsonObject]::new())['result']['data'].ToJsonString()).Contains($tid)
    $u = $Client.Request('thread/unsubscribe', [Text.Json.Nodes.JsonNode]::Parse("{`"threadId`":`"$tid`"}"))
    if ($Opt['wait']) { Start-Sleep -Seconds $Opt['wait'] }
    $notes = @($Client.Drain() | Where-Object { $_['method'].ToString() -like 'thread/*' -and ($_['params']?['threadId']?.ToString()) -eq $tid } | ForEach-Object { $_['method'].ToString() + ':' + $_['params']['status']?.ToJsonString() })
    $loadedAfter = ($Client.Request('thread/loaded/list', [Text.Json.Nodes.JsonObject]::new())['result']['data'].ToJsonString()).Contains($tid)
    $target = if ($Opt['cross']) { "{`"threadId`":`"$tid`",`"modelProvider`":`"fake_b`",`"model`":`"m-b`"}" } else { "{`"threadId`":`"$tid`",`"model`":`"m-alt`"}" }
    $r = $Client.Request('thread/resume', [Text.Json.Nodes.JsonNode]::Parse($target))
    $p = "{`"threadId`":`"$tid`",`"input`":[{`"type`":`"text`",`"text`":`"MARK_${Row}_NEXT`"}]}"
    [void]$Client.Request('turn/start', [Text.Json.Nodes.JsonNode]::Parse($p))
    $next = Wait-Upstream $Run "MARK_${Row}_NEXT" 20 $tid
    Start-Sleep -Milliseconds 800
    [pscustomobject]@{ row = $Row; failedTurn = [bool]$Opt['fail']; overrideTurn = [bool]$Opt['override']; crossProvider = [bool]$Opt['cross']; waitSeconds = [int]$Opt['wait']
        loadedBeforeUnsubscribe = $loadedBefore; unsubscribe = ($u['result']?['status']?.ToString()); threadNotes = ($notes -join ','); loadedAfterUnsubscribe = $loadedAfter
        resumeSettings = (Get-Settings $r); nextUpstream = $(if ($next) { "$($next.Provider)/$($next.Model)" } else { 'none' }) }
}

function Add-U6Row([string]$Tag, $Row) {
    $key = "u6_$Tag"
    $script:Result[$key] = @($script:Result[$key]) + $Row | Where-Object { $_ }
    Save-Result
}

function Invoke-U6Scenario([string]$Exe, [string]$Tag) {
    $rows = @()
    foreach ($transport in 'stdio', 'ws') {
        # Each transport phase gets its own CODEX_HOME so no two app-server processes share state.
        $run = New-ResearchRun "u6-$Tag-$transport"
        if ($transport -eq 'stdio') {
            $stdioGroup = New-Group 'stdio'
            $client = [CodexRemoteResearch.StdioRpcClient]::new($Exe, $run.Dir, (Join-Path $run.Dir 'stdio.err'), $stdioGroup)
            [void]$client.Initialize('crr-u6')
        } else {
            $srv = Start-WsServer $run $Exe 'u6'; $client = Connect-Manager $srv $run.WsToken
        }
        $prefix = if ($transport -eq 'stdio') { 'S' } else { 'W' }
        $rows += Invoke-U6Row $client $run "${prefix}1" $run.Ws @{}                                  # historical A5 shape
        $rows += Invoke-U6Row $client $run "${prefix}2" $run.Ws @{ override = $true }
        $rows += Invoke-U6Row $client $run "${prefix}3" $run.Ws @{ fail = $true }
        $rows += Invoke-U6Row $client $run "${prefix}4" $run.Ws @{ override = $true; fail = $true }    # M1 E2b V1 shape
        $rows += Invoke-U6Row $client $run "${prefix}5" $run.Ws @{ cross = $true }
        $rows += Invoke-U6Row $client $run "${prefix}6" $run.Ws @{ wait = 10 }
        foreach ($r in $rows | Where-Object { $_.row -like "$prefix*" }) { $r | Add-Member transport $transport; Add-U6Row $Tag $r }
        if ($transport -eq 'stdio') { $client.Dispose(); Stop-Group $stdioGroup } else { $client.Dispose(); Stop-Group $srv.Group }
        Save-Upstream $run "u6_${Tag}_$transport"
        $run.Fake.Dispose()
    }
    $run = New-ResearchRun "u6-$Tag-newprocess"
    # New-process rows: a thread created and left by one process, resumed by a fresh process.
    $g1 = New-Group 'stdio-np1'
    $c1 = [CodexRemoteResearch.StdioRpcClient]::new($Exe, $run.Dir, (Join-Path $run.Dir 'stdio-np1.err'), $g1); [void]$c1.Initialize('crr-u6')
    $ids = @{}
    foreach ($row in 'N1', 'N2') {
        $t = $c1.Request('thread/start', [Text.Json.Nodes.JsonNode]::Parse("{`"model`":`"m-$($row.ToLower())`",`"modelProvider`":`"fake_a`",`"cwd`":$(ConvertTo-Json $run.Ws),`"approvalPolicy`":`"never`",`"sandbox`":`"read-only`"}"))
        $ids[$row] = $t['result']['thread']['id'].ToString()
        [void]$c1.Request('turn/start', [Text.Json.Nodes.JsonNode]::Parse("{`"threadId`":`"$($ids[$row])`",`"input`":[{`"type`":`"text`",`"text`":`"MARK_${row}_OK`"}]}"))
        [void](Wait-Upstream $run "MARK_${row}_OK" 20); Start-Sleep -Milliseconds 800
    }
    $c1.Dispose(); Stop-Group $g1
    $g2 = New-Group 'stdio-np2'
    $c2 = [CodexRemoteResearch.StdioRpcClient]::new($Exe, $run.Dir, (Join-Path $run.Dir 'stdio-np2.err'), $g2); [void]$c2.Initialize('crr-u6')
    foreach ($row in 'N1', 'N2') {
        $target = if ($row -eq 'N2') { "{`"threadId`":`"$($ids[$row])`",`"modelProvider`":`"fake_b`",`"model`":`"m-b`"}" } else { "{`"threadId`":`"$($ids[$row])`",`"model`":`"m-alt`"}" }
        $r = $c2.Request('thread/resume', [Text.Json.Nodes.JsonNode]::Parse($target))
        [void]$c2.Request('turn/start', [Text.Json.Nodes.JsonNode]::Parse("{`"threadId`":`"$($ids[$row])`",`"input`":[{`"type`":`"text`",`"text`":`"MARK_${row}_NEXT`"}]}"))
        $next = Wait-Upstream $run "MARK_${row}_NEXT" 20
        $newRow = [pscustomobject]@{ row = $row; transport = 'stdio-new-process'; failedTurn = $false; overrideTurn = $false; crossProvider = ($row -eq 'N2'); waitSeconds = 0
            loadedBeforeUnsubscribe = $false; unsubscribe = 'n/a'; threadNotes = ''; loadedAfterUnsubscribe = $false
            resumeSettings = (Get-Settings $r); nextUpstream = $(if ($next) { "$($next.Provider)/$($next.Model)" } else { 'none' }) }
        $rows += $newRow; Add-U6Row $Tag $newRow
    }
    Save-Upstream $run "u6_${Tag}_newprocess"
    $c2.Dispose(); Stop-Group $g2; $run.Fake.Dispose()
    Add-Step "u6-matrix-$Tag" @{ version = (Get-CodexVersion $Exe); rows = $rows.Count }
}

try {
    $script:Result.codexVersion = Get-CodexVersion $Codex
    Add-Content -LiteralPath $script:ProgressLog -Value ("[{0}] START scenario={1} maxSeconds={2} codex={3}" -f (Get-Date -Format 'HH:mm:ss'), $Scenario, $MaxSeconds, $script:Result.codexVersion)
    if ($Scenario -in 'Tui', 'All') { Invoke-TuiScenario }
    if ($Scenario -in 'Exhaustion', 'All') { Invoke-ExhaustionScenario }
    if ($Scenario -in 'U6', 'All') {
        Invoke-U6Scenario $Codex 'primary'
        $i = 0; foreach ($e in $U6Codex) { $i++; Invoke-U6Scenario $e "extra$i" }
    }
    $script:Result['status'] = 'COMPLETED'
}
catch {
    $tripped = $script:Supervisor.Tripped
    $script:Result['status'] = if ($tripped -eq 'NETWORK_VIOLATION' -or $_.Exception.Message -like 'RUN_NETWORK_VIOLATION*') { 'NETWORK_VIOLATION' }
    elseif ($tripped -eq 'TIMEOUT' -or $_.Exception.Message -like 'RUN_TIMEOUT*') { 'TIMEOUT' } else { 'ERROR' }
    $script:Result['error'] = $_.Exception.Message
    Add-Content -LiteralPath $script:ProgressLog -Value ("[{0}] {1}: {2}" -f (Get-Date -Format 'HH:mm:ss'), $script:Result['status'], $_.Exception.Message)
}
finally {
    # Dispose first: it waits for any running supervisor callback and does a last fail-closed scan,
    # so the final status below sees every trip. A breach after the last step overrides COMPLETED,
    # and COMPLETED also requires zero step/RPC soft timeouts and a cleanly drained supervisor.
    $script:Supervisor.Dispose()
    $rpcTimeouts = @([CodexRemoteResearch.SoftTimeouts]::Rpc.ToArray())
    $script:Result['rpcTimeouts'] = $rpcTimeouts
    $script:Result['supervisorDrained'] = $script:Supervisor.DrainedCleanly
    if ($script:Supervisor.Tripped -eq 'NETWORK_VIOLATION') { $script:Result['status'] = 'NETWORK_VIOLATION' }
    elseif ($script:Result['status'] -eq 'COMPLETED') {
        if ($script:Supervisor.Tripped -eq 'TIMEOUT') { $script:Result['status'] = 'TIMEOUT'; $script:Result['timeoutKind'] = 'budget' }
        elseif ($script:Timeouts.Count -gt 0 -or $rpcTimeouts.Count -gt 0) { $script:Result['status'] = 'TIMEOUT'; $script:Result['timeoutKind'] = 'step' }
        elseif (-not $script:Supervisor.DrainedCleanly) { $script:Result['status'] = 'ERROR'; $script:Result['error'] = 'supervisor callbacks did not drain' }
    }
    $script:Result['networkViolations'] = @($script:Supervisor.Violations)
    $script:Result['finished'] = (Get-Date).ToString('o')
    $external = @($script:Result.steps | ForEach-Object { $_.externalConnections } | Where-Object { $_ })
    $script:Result['externalConnectionsObserved'] = $external
    Save-Result
    $summary = "END status=$($script:Result['status']) steps=$($script:Result.steps.Count) timeouts=$($script:Timeouts.Count) external=$($external.Count) result=$script:ResultPath"
    Add-Content -LiteralPath $script:ProgressLog -Value $summary
    Write-Host $summary
}
$exitCode = switch ($script:Result['status']) { 'COMPLETED' { 0 } 'TIMEOUT' { 4 } 'NETWORK_VIOLATION' { 5 } default { 3 } }
exit $exitCode
