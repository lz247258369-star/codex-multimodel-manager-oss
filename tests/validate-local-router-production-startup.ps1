param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR6 - LOCAL ROUTER PRODUCTION STARTUP validation.
#
# The checked-in defaults are the disabled-safe baseline and an explicit user
# router.config.json is the only opt-in source, so the production host must
# resolve the effective config (defaults + user) before it decides whether
# Router Mode may start. This validator pins that contract:
#
#   * checked-in defaults stay disabled;
#   * the host no longer exits from the defaults flag before considering an
#     existing user config (source ordering assertion);
#   * a missing user config still takes the disabled safe exit;
#   * an explicitly disabled user config still takes the disabled safe exit;
#   * an explicitly enabled user config reaches the production startup path
#     (it gets past the disabled gate into local client token resolution);
#   * an invalid user config fails closed;
#   * nothing here issues a provider request;
#   * the LR-14P lifecycle control gap stays declared.
#
# Every host invocation below runs against a throw-away CODEX_HOME, so the real
# ~/.codex is never read or written, and no listener is ever bound: each case
# either exits disabled or fails closed at token resolution.

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Pass $Message } else { Fail $Message }
}

function Read-SourceText([string]$RelativePath) {
    return (Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $RelativePath))
}

$hostSource = Read-SourceText "local-router/src/Router.Host/RouterHostBootstrap.cs"
$validatorSource = Get-Content -Raw -LiteralPath $PSCommandPath

# --- 1. Checked-in defaults stay the disabled-safe baseline ------------------
$defaults = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/config/router.defaults.json") | ConvertFrom-Json
Assert-True ([string]$defaults.mode -eq "direct") "Checked-in defaults keep mode=direct"
Assert-True ([bool]$defaults.local_router.enabled -eq $false) "Checked-in defaults keep local_router.enabled=false"

# --- 2. The startup decision no longer comes from the defaults flag alone ----
$loadIndex = $hostSource.IndexOf("LoadAsync(pathProvider.DefaultsPath, pathProvider.UserConfigPath", [StringComparison]::Ordinal)
$enabledIndex = $hostSource.IndexOf("if (!snapshot.Config.LocalRouter.Enabled)", [StringComparison]::Ordinal)
Assert-True ($loadIndex -gt 0) "Host loads the effective config from defaults + user config"
Assert-True ($enabledIndex -gt 0) "Host keeps an explicit effective-config enable check"
Assert-True ($loadIndex -lt $enabledIndex) "Host resolves the effective config before the enable/disable decision"
Assert-True ($hostSource.Contains("DisabledExitMessage")) "Host keeps the DISABLED safe-exit marker"
Assert-True ($hostSource.Contains("mode=direct; Router Mode is not active; exiting safely.")) "Host keeps the fail-closed mode guard"
$defaultsPhase = $hostSource.Substring(
    $hostSource.IndexOf("LoadDefaultsAsync(", [StringComparison]::Ordinal),
    $loadIndex - $hostSource.IndexOf("LoadDefaultsAsync(", [StringComparison]::Ordinal))
Assert-True (-not $defaultsPhase.Contains("DisabledExitMessage")) "Host never exits DISABLED from the defaults-only phase"
Assert-True ($defaultsPhase.Contains("ConfigErrorExitCode")) "Defaults-only phase fails closed instead of exiting disabled"

# --- 3. The LR-14P lifecycle control gap is preserved ------------------------
$controlPlaneSource = Read-SourceText "local-router/src/Router.Ingress/ControlPlane/ControlPlaneProjections.cs"
$controlPlaneHandler = Read-SourceText "local-router/src/Router.Ingress/Handlers/ControlPlaneHandlers.cs"
$payloadSource = Read-SourceText "local-router/src/Router.Ingress/ControlPlane/ControlPlanePayloads.cs"
Assert-True ($controlPlaneSource.Contains('LifecycleControlGapCode = "LIFECYCLE_CONTROL_GAP"')) "LIFECYCLE_CONTROL_GAP code is still declared"
Assert-True ($controlPlaneHandler.Contains("ReasonCode = ControlPlaneProjections.LifecycleControlGapCode")) "Control-plane status still reports the lifecycle gap reason"
Assert-True ($payloadSource.Contains("StartStopAvailable")) "Lifecycle control payload still exposes start_stop_available"
Assert-True (-not ($hostSource -match '(?i)control-plane/start|StartStopAsync|start_stop_available\s*=\s*true')) "Host does not fake a Start/Stop lifecycle API"

# --- 4. No provider network primitive is used by this startup validator ------
# The primitives are assembled from fragments so this check cannot match its own
# source text: it asserts the absence of a real call, not of the word.
$httpPrimitiveNames = @(("Invoke-" + "RestMethod"), ("Invoke-" + "WebRequest"))
foreach ($primitive in $httpPrimitiveNames) {
    Assert-True (-not $validatorSource.Contains($primitive)) "Startup validator issues no $primitive request"
}
$providerEndpointNames = @(("api." + "deepseek.com"), ("dash" + "scope"), ("open" + "router.ai"), ("xiaomi" + "mimo"))
foreach ($endpointName in $providerEndpointNames) {
    Assert-True (-not $validatorSource.Contains($endpointName)) "Startup validator references no provider endpoint ($endpointName)"
}
Assert-True (-not $hostSource.Contains($httpPrimitiveNames[0])) "Host bootstrap issues no HTTP request of its own"

# --- 5. Behaviour: run the built host against throw-away homes ---------------
$hostDll = Join-Path $RepositoryRoot "local-router/src/Router.Host/bin/Release/net10.0/Router.Host.dll"
$hostDefaultsOutput = Join-Path $RepositoryRoot "local-router/src/Router.Host/bin/Release/net10.0/config/router.defaults.json"

# The host is invoked as the Release DLL through an explicit dotnet host, which
# is also how the DSR6 runtime gate starts it: no apphost, no `dotnet run`, and
# no ambiguity about which runtime resolves the framework.
$dotnetCandidates = @()
if (-not [string]::IsNullOrWhiteSpace($env:DOTNET_ROOT)) {
    $dotnetCandidates += (Join-Path $env:DOTNET_ROOT "dotnet.exe")
}
$dotnetCandidates += (Join-Path $env:USERPROFILE ".dotnet/dotnet.exe")
$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
if ($null -ne $dotnetCommand) { $dotnetCandidates += $dotnetCommand.Source }
$dotnetHost = $dotnetCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1

Assert-True (Test-Path -LiteralPath $hostDll -PathType Leaf) "Release host build output is available for the startup checks"
Assert-True (Test-Path -LiteralPath $hostDefaultsOutput -PathType Leaf) "Release output carries the checked-in router.defaults.json"
Assert-True ($null -ne $dotnetHost) "A dotnet host is available to run the Release build"

$hostCommand = $dotnetHost
$hostArguments = @($hostDll)
$hostEnvironment = @{ DOTNET_ROOT = (Split-Path $dotnetHost) }

function New-StartupSandbox {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-lr6-startup-" + [guid]::NewGuid().ToString("N"))
    $sandboxHome = Join-Path $root "codex-home"
    New-Item -ItemType Directory -Force -Path (Join-Path $sandboxHome "multimodel-manager/local-router") | Out-Null
    return [pscustomobject]@{ Root = $root; CodexHome = $sandboxHome; UserConfigPath = (Join-Path $sandboxHome "multimodel-manager/local-router/router.config.json") }
}

function Invoke-StartupProbe($Sandbox, [int]$TimeoutSeconds = 20) {
    $stdoutPath = Join-Path $Sandbox.Root "stdout.log"
    $stderrPath = Join-Path $Sandbox.Root "stderr.log"
    $arguments = @($hostArguments) + @()
    $process = Start-Process -FilePath $hostCommand -ArgumentList $arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath `
        -Environment ($hostEnvironment + @{ CODEX_HOME = $Sandbox.CodexHome })
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        # Only ever stop the exact process this call started, and only because a
        # host that ignores the disabled/fail-closed contract is a defect.
        try { $process.Kill($true) } catch { }
        return [pscustomobject]@{ ExitCode = -1; StdOut = (Get-Content -Raw $stdoutPath -ErrorAction SilentlyContinue); StdErr = (Get-Content -Raw $stderrPath -ErrorAction SilentlyContinue); TimedOut = $true }
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = (Get-Content -Raw $stdoutPath -ErrorAction SilentlyContinue)
        StdErr = (Get-Content -Raw $stderrPath -ErrorAction SilentlyContinue)
        TimedOut = $false
    }
}

$envBefore = [Environment]::GetEnvironmentVariable("CODEX_HOME", [EnvironmentVariableTarget]::Process)
$sandboxes = New-Object System.Collections.Generic.List[object]
try {
    if ($null -ne $hostCommand) {
        # Missing user config: the defaults stay disabled and the host exits safely.
        $caseA = New-StartupSandbox
        $sandboxes.Add($caseA)
        $resultA = Invoke-StartupProbe $caseA
        Assert-True (-not $resultA.TimedOut) "Missing user config: the host does not start a listener"
        Assert-True ($resultA.ExitCode -eq 0) "Missing user config: the host exits 0 (actual $($resultA.ExitCode))"
        Assert-True ($resultA.StdOut -match "DISABLED") "Missing user config: the host reports DISABLED"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $caseA.CodexHome "multimodel-manager/local-router/runtime/router.state.json"))) "Missing user config: no runtime state is created"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $caseA.CodexHome "multimodel-manager/local-router/runtime/router.pid.json"))) "Missing user config: no owner record is written"

        # Explicitly disabled user config: still the disabled safe exit.
        $caseB = New-StartupSandbox
        $sandboxes.Add($caseB)
        '{"schema_version":1,"version":1,"mode":"direct","local_router":{"enabled":false}}' |
            Set-Content -LiteralPath $caseB.UserConfigPath -Encoding UTF8
        $resultB = Invoke-StartupProbe $caseB
        Assert-True ($resultB.ExitCode -eq 0) "Disabled user config: the host exits 0 (actual $($resultB.ExitCode))"
        Assert-True ($resultB.StdOut -match "DISABLED") "Disabled user config: the host reports DISABLED"

        # Enabled user config: the host must get past the disabled gate. It is
        # pointed at a deliberately unresolvable local client token so the run
        # still terminates without binding a listener or touching a provider.
        $caseC = New-StartupSandbox
        $sandboxes.Add($caseC)
        '{"schema_version":1,"version":1,"mode":"router","local_router":{"enabled":true,"client_auth":{"mode":"bearer_env_ref","token_ref":"DSR6_VALIDATOR_ABSENT_TOKEN"}}}' |
            Set-Content -LiteralPath $caseC.UserConfigPath -Encoding UTF8
        $resultC = Invoke-StartupProbe $caseC
        Assert-True ($resultC.ExitCode -eq 2) "Enabled user config: startup reaches token resolution and fails closed (actual $($resultC.ExitCode))"
        Assert-True (-not ($resultC.StdOut -match "DISABLED")) "Enabled user config: the host does not take the disabled exit"
        Assert-True ($resultC.StdErr -match "token|secret|missing") "Enabled user config: the failure is the unresolved local client token"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $caseC.CodexHome "multimodel-manager/local-router/runtime/router.pid.json"))) "Enabled user config: no listener owner record is written when the token is missing"

        # Invalid user config: fail closed with the config error code.
        $caseD = New-StartupSandbox
        $sandboxes.Add($caseD)
        '{"schema_version":1,"mode":"router",' | Set-Content -LiteralPath $caseD.UserConfigPath -Encoding UTF8
        $resultD = Invoke-StartupProbe $caseD
        Assert-True ($resultD.ExitCode -eq 2) "Invalid user config: the host fails closed (actual $($resultD.ExitCode))"
        Assert-True (-not ($resultD.StdOut -match "DISABLED")) "Invalid user config: the disabled exit is never used as a fallback"

        # Enabled user config with mode=direct: config error, never a listener.
        $caseE = New-StartupSandbox
        $sandboxes.Add($caseE)
        '{"schema_version":1,"version":1,"mode":"direct","local_router":{"enabled":true}}' |
            Set-Content -LiteralPath $caseE.UserConfigPath -Encoding UTF8
        $resultE = Invoke-StartupProbe $caseE
        Assert-True ($resultE.ExitCode -eq 2) "Enabled user config with mode=direct: the host fails closed (actual $($resultE.ExitCode))"

        # Unknown user config field: merge safety violation, fail closed.
        $caseF = New-StartupSandbox
        $sandboxes.Add($caseF)
        '{"schema_version":1,"version":1,"mode":"router","local_router":{"enabled":true},"unexpected_field":true}' |
            Set-Content -LiteralPath $caseF.UserConfigPath -Encoding UTF8
        $resultF = Invoke-StartupProbe $caseF
        Assert-True ($resultF.ExitCode -eq 2) "Unknown user config field: the host fails closed (actual $($resultF.ExitCode))"
    }
}
finally {
    if ($null -eq $envBefore) { Remove-Item -Path "Env:CODEX_HOME" -ErrorAction SilentlyContinue }
    else { Set-Item -Path "Env:CODEX_HOME" -Value $envBefore -ErrorAction SilentlyContinue }

    $tempRoot = [System.IO.Path]::GetTempPath()
    foreach ($sandbox in $sandboxes) {
        if ($null -ne $sandbox -and $sandbox.Root.StartsWith($tempRoot) -and (Test-Path -LiteralPath $sandbox.Root)) {
            Remove-Item -LiteralPath $sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- 6. Reliability Fix 2: readiness / lifecycle contract ---------------------
# Binding the loopback listener is not readiness. The production Host defers the
# public READY state until the owner record and the durable runtime READY state
# are committed, and a cancellation inside that window must stop the ingress
# through the normal STOPPING path, archive (never delete) the owner record this
# process wrote, avoid a fabricated STOPPED state, and keep its own exit code.
#
# The dynamic behaviour is owned by the deterministic xUnit assets below and is
# executed by `dotnet test local-router/LocalRouter.sln` in the same gate. These
# checks only stop the source contract from silently regressing; they issue no
# request, read no secret and sleep nowhere.
$ingressSource = Read-SourceText "local-router/src/Router.Ingress/ResponsesIngress.cs"
$lifecycleSource = Read-SourceText "local-router/src/Router.Core/Lifecycle/RouterLifecycle.cs"

# --- 6.1 The production Host selects deferred READY --------------------------
Assert-True ($hostSource.Contains("deferReadyPublication: true")) "FIX2 A: the production Host explicitly selects deferred READY"
Assert-True ($ingressSource.Contains("bool deferReadyPublication")) "FIX2 D: ResponsesIngress accepts a deferred-ready start mode"
Assert-True ($ingressSource.Contains("if (!deferReadyPublication)")) "FIX2 D: deferred mode keeps the historical immediate READY for other callers"
Assert-True ($ingressSource.Contains("public bool TryPublishReady()")) "FIX2 E: ResponsesIngress exposes one explicit READY publication"
Assert-True ($ingressSource.Contains("TryTransition(LifecycleState.Starting, LifecycleState.Ready)")) "FIX2 E: publication only performs the legal STARTING -> READY transition"

# --- 6.2 Source order: owner < durable READY < public READY ------------------
$ownerWriteIndex = $hostSource.IndexOf("WriteAsync(pathProvider.OwnerRecordPath, ownerRecord", [StringComparison]::Ordinal)
$readyWriteIndex = $hostSource.IndexOf("SaveAsync(pathProvider.RuntimeStatePath, readyState", [StringComparison]::Ordinal)
$publishIndex = $hostSource.IndexOf("TryPublishReady()", [StringComparison]::Ordinal)
$readyPrintIndex = $hostSource.IndexOf("[local-router] READY on http://", [StringComparison]::Ordinal)
Assert-True ($ownerWriteIndex -gt 0) "FIX2 B: the Host still commits the owner record"
Assert-True ($readyWriteIndex -gt 0) "FIX2 C: the Host still commits the durable runtime READY state"
Assert-True ($publishIndex -gt 0) "FIX2 C: the Host publishes READY through the ingress"
Assert-True ($ownerWriteIndex -lt $readyWriteIndex) "FIX2 B: the owner commit happens before the durable READY commit"
Assert-True ($readyWriteIndex -lt $publishIndex) "FIX2 C: the durable READY commit happens before the public READY publication"
Assert-True ($readyPrintIndex -gt 0 -and $publishIndex -lt $readyPrintIndex) "FIX2 C: the READY banner is printed only after a successful publication"
Assert-True ($hostSource.Contains("ownerCommitted = true;")) "FIX2 D: the Host records the owner commit explicitly"
Assert-True ($hostSource.Contains("durableReadyCommitted = true;")) "FIX2 C: the Host records the durable READY commit explicitly"

# --- 6.3 Startup-tail cancellation semantics ---------------------------------
Assert-True ($hostSource.Contains("if (ownerCommitted && !durableReadyCommitted)")) "FIX2 H: cleanup only archives an owner this process committed before READY"
Assert-True ($hostSource.Contains("owner_startup_cancelled")) "FIX2 H: the aborted-startup owner record is archived with a safe reason code"
Assert-True ($hostSource.Contains("CancelledExitCode = 130")) "FIX2 H: the cancellation exit code stays 130"
Assert-True ($hostSource.Contains("return CancelledExitCode;")) "FIX2 H: cancellation returns the cancellation exit code"
Assert-True ($hostSource.Contains("RouterErrorCode.Cancelled")) "FIX2 H: a cancelled listener start is not reported as a configuration error"

# --- 6.4 Steady-state shutdown stays intact ----------------------------------
$stoppedWriteIndex = $hostSource.IndexOf("SaveAsync(pathProvider.RuntimeStatePath, stoppedState", [StringComparison]::Ordinal)
Assert-True ($stoppedWriteIndex -gt 0) "FIX2 I: the steady-state path still persists the terminal STOPPED state"
Assert-True ($stoppedWriteIndex -gt $publishIndex) "FIX2 I: STOPPED is persisted after the READY publication"
Assert-True ($hostSource.Contains('QuarantineAsync(pathProvider.OwnerRecordPath, pathProvider.QuarantineRootPath, "owner_stopped"')) "FIX2 I: the steady-state path still quarantines the owner record"
Assert-True ($hostSource.Contains("startupExitCode = 0;")) "FIX2 I: a completed steady state still returns exit code 0"

# --- 6.5 Lifecycle transition table -----------------------------------------
$startingTransition = [regex]::Match($lifecycleSource, 'LifecycleState\.Starting => (?<body>[^\r\n]*)')
Assert-True ($startingTransition.Success) "FIX2 F: the lifecycle still declares a STARTING transition row"
if ($startingTransition.Success) {
    $startingBody = $startingTransition.Groups["body"].Value
    Assert-True ($startingBody.Contains("LifecycleState.Ready")) "FIX2 F: STARTING still reaches READY"
    Assert-True ($startingBody.Contains("LifecycleState.Stopping")) "FIX2 F: STARTING can enter STOPPING (startup shutdown)"
    Assert-True (-not $startingBody.Contains("LifecycleState.Stopped")) "FIX2 G: STARTING must never jump straight to STOPPED"
}
Assert-True ($lifecycleSource.Contains("LifecycleState.Stopping => to is LifecycleState.Stopped")) "FIX2 G: STOPPING still reaches STOPPED, so the checkpoint is never skipped"

# --- 6.6 Deterministic assets and coverage markers ---------------------------
$hostReadinessTest = "local-router/tests/Router.Core.Tests/Host/HostReadinessLifecycleTests.cs"
$ingressDeferredTest = "local-router/tests/Router.Ingress.Tests/IngressDeferredReadyTests.cs"
$blockingFileSystem = "local-router/tests/Router.Core.Tests/Fakes/BlockingRuntimeStateFileSystem.cs"
foreach ($asset in @($hostReadinessTest, $ingressDeferredTest, $blockingFileSystem)) {
    Assert-True (Test-Path -LiteralPath (Join-Path $RepositoryRoot $asset) -PathType Leaf) "FIX2 J: deterministic readiness asset exists: $asset"
}
if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $hostReadinessTest) -PathType Leaf) {
    $hostReadinessSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $hostReadinessTest)
    Assert-True ($hostReadinessSource.Contains("Health_200_implies_durable_ready")) "FIX2 K: coverage marker - public READY implies durable READY"
    Assert-True ($hostReadinessSource.Contains("Startup_tail_cancellation_stops_safely")) "FIX2 K: coverage marker - startup-tail cancellation"
    Assert-True ($hostReadinessSource.Contains("Steady_state_shutdown_remains_clean")) "FIX2 K: coverage marker - steady-state graceful shutdown"
    Assert-True ($hostReadinessSource.Contains("HttpStatusCode.ServiceUnavailable")) "FIX2 K: coverage marker - health is not ready before the durable commit"
    Assert-True (-not $hostReadinessSource.Contains("Thread.Sleep")) "FIX2 L: the readiness tests use no sleep-based hook"
}
if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $ingressDeferredTest) -PathType Leaf) {
    $ingressDeferredSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $ingressDeferredTest)
    Assert-True ($ingressDeferredSource.Contains("Deferred_ingress_reports_starting_until_ready_is_published")) "FIX2 K: coverage marker - a bound listener still reports STARTING"
    Assert-True ($ingressDeferredSource.Contains("Deferred_ingress_can_stop_without_ever_reaching_ready")) "FIX2 K: coverage marker - STARTING can be stopped safely"
    Assert-True ($ingressDeferredSource.Contains("HttpStatusCode.ServiceUnavailable")) "FIX2 K: coverage marker - pre-durable health is 503"
    Assert-True ($ingressDeferredSource.Contains("HttpStatusCode.OK")) "FIX2 K: coverage marker - published health is 200"
    Assert-True (-not $ingressDeferredSource.Contains("Thread.Sleep")) "FIX2 L: the deferred-ready tests use no sleep-based hook"
}
if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $blockingFileSystem) -PathType Leaf) {
    $blockingSource = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $blockingFileSystem)
    Assert-True ($blockingSource.Contains("TaskCompletionSource")) "FIX2 K: the startup window is opened by a deterministic completion source"
    Assert-True ($blockingSource.Contains("Timeout.InfiniteTimeSpan, cancellationToken")) "FIX2 K: only cancellation releases the held durable write"
}

# --- 6.7 This validator stays network-free, secret-free and sleep-free -------
# Assembled from fragments so the check cannot match its own source text: it
# asserts the absence of a real sleep call, not of the word.
$sleepPrimitive = ("Start-" + "Sleep")
Assert-True (-not $validatorSource.Contains($sleepPrimitive)) "FIX2 L: the startup validator never sleeps"

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "Local Router production startup validation PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "Local Router production startup validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
exit 1
