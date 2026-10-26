using System.Diagnostics;
using Router.ClientAdapters.Responses;
using Router.CatalogProjection;
using Router.Configuration;
using Router.Core.Abstractions;
using Router.Core.Concurrency;
using Router.Core.Errors;
using Router.Core.Ids;
using Router.Core.Lifecycle;
using Router.Execution;
using Router.Health;
using Router.Ingress;
using Router.Metering;
using Router.Observability;
using Router.Secrets;
using Router.State;
using Router.State.Ownership;
using Router.ThreadSelection;

namespace Router.Host;

/// <summary>
/// LR-3 host bootstrap. Router Mode is disabled by default, and the checked-in
/// defaults stay the disabled-safe baseline; the only opt-in source is an
/// explicit user router.config.json. The host therefore resolves the effective
/// configuration (defaults + user) before it decides anything, exits safely
/// with DISABLED when the effective config is disabled, and only then binds the
/// loopback ingress (backed by the production execution service; tests may
/// inject a synthetic service). No provider endpoint and no secret resolution
/// ever exist in the disabled path.
/// </summary>
public static class RouterHostBootstrap
{
    /// <summary>Stable marker emitted on stdout when the disabled host exits safely.</summary>
    public const string DisabledExitMessage =
        "[local-router] DISABLED: local_router.enabled=false; exiting safely.";

    /// <summary>Exit code used when a shutdown token cancels the disabled host before exit.</summary>
    public const int CancelledExitCode = 130;

    /// <summary>Exit code used when defaults are missing/corrupt or Router Mode cannot start.</summary>
    public const int ConfigErrorExitCode = 2;

    /// <summary>
    /// Exit code used when the host could not restore the runtime directory access
    /// control while releasing coordination. A shutdown that leaves the access
    /// control unrecovered is not a clean stop, so it must never return 0.
    /// </summary>
    public const int CleanupFailedExitCode = 3;

    /// <summary>
    /// Exit code used when an enabled Windows Host published durable READY but
    /// could not publish and protect its host-local lifecycle control
    /// capability. A READY Host that no controller can authenticate against is
    /// not an acceptable steady state, so the process stops through the existing
    /// shutdown path (durable STOPPED, archived owner record) and reports this
    /// code instead of a clean stop. Other platforms have no Windows lifecycle
    /// capability and therefore keep serving without a control channel.
    /// </summary>
    public const int ControlChannelUnavailableExitCode = 4;

    /// <summary>Stable marker for a Host that could not publish its control capability.</summary>
    public const string ControlChannelUnavailableMessage = "lifecycle_control_channel_unavailable";

    /// <summary>
    /// Runs the host. The disabled path validates only checked-in defaults;
    /// no secret resolution, user-state access, or listener is ever performed.
    /// </summary>
    public static async Task<int> RunAsync(
        string[] args,
        IRouterPathProvider? pathProvider = null,
        IClock? clock = null,
        ISecretResolver? secretResolver = null,
        IIdGenerator? idGenerator = null,
        IProcessInspector? processInspector = null,
        IResponsesService? responsesService = null,
        RequestMeteringService? meteringService = null,
        DurableRequestLog? requestLog = null,
        PricingSnapshot? pricingSnapshot = null,
        HostObservabilityProbe? observabilityProbe = null,
        IFileSystem? fileSystemOverride = null,
        IFileSecurity? fileSecurityOverride = null,
        CancellationToken cancellationToken = default)
    {
        _ = args;

        try
        {
            cancellationToken.ThrowIfCancellationRequested();

            pathProvider ??= new DefaultRouterPathProvider();
            // Freeze caller/environment-derived paths once. Later owner/state
            // writes must target the same runtime directory as the native gate.
            pathProvider = new HostPathSnapshot(pathProvider.DefaultsPath, pathProvider.UserConfigPath,
                pathProvider.RuntimeStatePath, pathProvider.OwnerRecordPath, pathProvider.BackupRootPath,
                pathProvider.QuarantineRootPath, pathProvider.MigrationReceiptDirectory);
            clock ??= new SystemClock();
            secretResolver ??= new EnvironmentSecretResolver(new RealEnvironment());
            idGenerator ??= new UuidV7IdGenerator(clock);
            // The overrides exist only for deterministic lifecycle tests that must
            // hold a specific durable write inside the startup window; production
            // always composes the real Windows implementations.
            IFileSystem fileSystem = fileSystemOverride ?? new WindowsFileSystem();
            IFileSecurity fileSecurity = fileSecurityOverride ?? new WindowsFileSecurity();
            IProcessInspector inspector = processInspector ?? new SystemProcessInspector();

            RouterConfigurationLoader loader = new(fileSystem, clock);
            // DSR6 production startup contract.
            //
            // The checked-in defaults are the disabled-safe baseline, not the
            // authority on whether Router Mode may start: an explicit user
            // router.config.json is the only opt-in source. The effective config
            // (defaults + user) must therefore be resolved *before* any
            // enable/disable decision - deciding from the defaults flag alone
            // makes a correctly enabled user config unreachable, which is the
            // production startup defect this gate fixes.
            //
            // The order below is deliberate and stays fail-closed:
            //   A. checked-in defaults must load and validate; missing/corrupt
            //      defaults are a config error with no user-state read, no secret
            //      resolution and no listener;
            //   B. a missing user config keeps the original safe behaviour
            //      (defaults are mode=direct / enabled=false -> DISABLED, exit 0,
            //      no secret resolution, no listener, no runtime state);
            //   C. a present user config is merged; corrupt JSON, an unknown
            //      field, an unsupported schema or a violated security invariant
            //      fails closed with no listener and no provider network;
            //   D. an effective config with local_router.enabled=false is
            //      DISABLED (exit 0) without any secret resolution;
            //   E. enabled=true with mode!=router is a config error;
            //   F. only mode=router with enabled=true reaches ownership, local
            //      client token resolution, execution composition, bind, READY.
            RouterConfigLoadResult defaultsResult = await loader
                .LoadDefaultsAsync(pathProvider.DefaultsPath, cancellationToken)
                .ConfigureAwait(false);
            if (!defaultsResult.IsSuccess)
            {
                await Console.Error
                    .WriteLineAsync($"[local-router] {defaultsResult.Error!.Code}: {defaultsResult.Error.Message} ({defaultsResult.Error.Param})")
                    .ConfigureAwait(false);
                return ConfigErrorExitCode;
            }

            RouterConfigLoadResult effective = await loader
                .LoadAsync(pathProvider.DefaultsPath, pathProvider.UserConfigPath, cancellationToken)
                .ConfigureAwait(false);
            if (!effective.IsSuccess || effective.Snapshot is null)
            {
                await Console.Error
                    .WriteLineAsync($"[local-router] {effective.Error!.Code}: {effective.Error.Message} ({effective.Error.Param})")
                    .ConfigureAwait(false);
                return ConfigErrorExitCode;
            }

            EffectiveRouterConfigSnapshot snapshot = effective.Snapshot;

            if (!snapshot.Config.LocalRouter.Enabled)
            {
                await Console.Out.WriteLineAsync(DisabledExitMessage).ConfigureAwait(false);
                return 0;
            }

            if (snapshot.Config.Mode != RouterMode.Router)
            {
                await Console.Error
                    .WriteLineAsync("[local-router] mode=direct; Router Mode is not active; exiting safely.")
                    .ConfigureAwait(false);
                return ConfigErrorExitCode;
            }

            // PR10A: no state is created by the disabled path. Every enabled
            // Host enters the same native runtime boundary BEFORE ownership,
            // secrets or listener startup and retains it through drain/archive.
            // This coordination is not installation identity or uninstall authority.
            string? runtimeDirectory = Path.GetDirectoryName(pathProvider.OwnerRecordPath);
            if (!Path.IsPathFullyQualified(pathProvider.OwnerRecordPath)
                || !Path.IsPathFullyQualified(pathProvider.RuntimeStatePath)
                || !string.Equals(runtimeDirectory, Path.GetDirectoryName(pathProvider.RuntimeStatePath), StringComparison.OrdinalIgnoreCase)
                || !string.Equals(Path.GetFileName(pathProvider.OwnerRecordPath), "router.pid.json", StringComparison.OrdinalIgnoreCase)
                || !string.Equals(Path.GetFileName(pathProvider.RuntimeStatePath), "router.state.json", StringComparison.OrdinalIgnoreCase)
                || runtimeDirectory is null)
            {
                throw new RouterStartupGateException("startup_gate_runtime_paths_mismatch");
            }
            using WindowsRouterStartupGate startupGate = WindowsRouterStartupGate.Acquire(runtimeDirectory);

            ProductionObservabilityComponents observability = BuildProductionObservability(
                pathProvider,
                clock,
                meteringService,
                requestLog,
                pricingSnapshot,
                observabilityProbe);

            CurrentRouterState currentState = new(
                PublishedRouterState.From(snapshot.Config, snapshot.ConfigGeneration));

            // HS-1B thread-scoped model selection. Exactly ONE store exists per
            // router process: it is built from the validated configuration
            // (enabled defaults to false, so routing stays byte-for-byte
            // equivalent until the capability is turned on), and it is shared by
            // production execution and the control plane.
            //
            // The runtime consistency boundary is also process-wide and exactly
            // one: it orders the published-config update against the capability
            // transition, and every thread-selection operation plus every
            // combined control-plane projection enters the same instance.
            RouterRuntimeConsistencyGate runtimeConsistencyGate = new();

            ThreadSelectionStore threadSelectionStore = new(
                ThreadSelectionOptions.Create(
                    ThreadSelectionOptions.DefaultMaxObservedThreads,
                    ThreadSelectionOptions.DefaultEntryIdleTtl,
                    TimeSpan.FromMilliseconds(snapshot.Config.LocalRouter.ThreadSelection.PendingTtlMs),
                    TimeSpan.FromMilliseconds(snapshot.Config.LocalRouter.ThreadSelection.ActiveIdleTtlMs)),
                clock,
                snapshot.Config.LocalRouter.ThreadSelection.Enabled,
                runtimeConsistencyGate);

            // The single live runtime publication boundary. One successful
            // durable config commit publishes the shared CurrentRouterState AND
            // the runtime effective state of that same store, inside the config
            // mutation gate. Mutating the store anywhere else (for example in an
            // HTTP handler after the operator returns) would create a window in
            // which durable config and runtime capability disagree.
            RouterRuntimePublicationSink runtimePublicationSink = new(
                currentState,
                threadSelectionStore,
                runtimeConsistencyGate);

            LocalRouterConfigOperator? configOperator = null;
            try
            {
                configOperator = new LocalRouterConfigOperator(
                    fileSystem,
                    clock,
                    pathProvider.DefaultsPath,
                    pathProvider.UserConfigPath);
                configOperator = configOperator.WithPublicationSink(runtimePublicationSink);
            }
            catch (Exception)
            {
                // Control-plane config mutation is unavailable; host still runs.
            }

            // Ownership: a live owner fails closed, a foreign process is never
            // killed, and stale owner records are archived per LR-2 rules.
            OwnerRecordStore ownerStore = new(fileSystem, clock, fileSecurity, new OwnershipVerifier(inspector));
            OwnerLoadOutcome ownerLoad = await ownerStore
                .LoadAsync(pathProvider.OwnerRecordPath, pathProvider.QuarantineRootPath, cancellationToken)
                .ConfigureAwait(false);
            if (ownerLoad.Error is not null)
            {
                await Console.Error
                    .WriteLineAsync($"[local-router] {ownerLoad.Error.Code}: {ownerLoad.Error.Message}")
                    .ConfigureAwait(false);
                return ConfigErrorExitCode;
            }

            if (ownerLoad.Record is { } existingRecord)
            {
                OwnershipStatus ownershipStatus = new OwnershipVerifier(inspector).Verify(existingRecord);
                switch (ownershipStatus)
                {
                    case OwnershipStatus.LiveOwner:
                        await Console.Error
                            .WriteLineAsync("[local-router] router_already_running: a live owner holds the loopback port.")
                            .ConfigureAwait(false);
                        return ConfigErrorExitCode;

                    case OwnershipStatus.ForeignProcess:
                        // Never kill or modify an unrelated process.
                        await Console.Error
                            .WriteLineAsync("[local-router] ownership_foreign_process: ownership cannot be verified; not starting.")
                            .ConfigureAwait(false);
                        return ConfigErrorExitCode;

                    case OwnershipStatus.StaleOwner:
                    {
                        CleanStaleOutcome cleaned = await ownerStore
                            .CleanStaleAsync(pathProvider.OwnerRecordPath, pathProvider.QuarantineRootPath, cancellationToken)
                            .ConfigureAwait(false);
                        if (!cleaned.IsSuccess)
                        {
                            await Console.Error
                                .WriteLineAsync($"[local-router] {cleaned.Error!.Code}: {cleaned.Error.Message}")
                                .ConfigureAwait(false);
                            return ConfigErrorExitCode;
                        }

                        break;
                    }
                }
            }

            // Resolve the local client token before binding; a missing token
            // fails closed with no listener.
            SecretReference tokenReference = LocalRouterSecrets.CreateTokenReference(snapshot.Config.LocalRouter.ClientAuth.TokenRef);
            SecretResolutionResult token = await secretResolver
                .ResolveAsync(tokenReference, LocalRouterSecrets.ProviderId, cancellationToken)
                .ConfigureAwait(false);
            if (!token.IsSuccess)
            {
                await Console.Error
                    .WriteLineAsync($"[local-router] {token.Error!.Code}: {token.Error.Message}")
                    .ConfigureAwait(false);
                return ConfigErrorExitCode;
            }

            token.Handle?.Dispose();

            IngressRuntimeOptions options = new()
            {
                Host = snapshot.Config.LocalRouter.Host,
                Port = snapshot.Config.LocalRouter.Port,
                Limits = snapshot.Config.LocalRouter.Limits,
                ConfigGeneration = snapshot.ConfigGeneration,
                TokenReferenceName = snapshot.Config.LocalRouter.ClientAuth.TokenRef,
                Clients = snapshot.Config.Clients,
            };

            RouterExecutionResponsesService? productionService = null;
            if (responsesService is null)
            {
                RouterExecutionServiceFactoryResult execution = RouterExecutionServiceFactory.Create(
                    snapshot,
                    secretResolver,
                    clock: clock,
                    passiveHealthPolicy: PassiveHealthPolicy.Default,
                    policySource: new CurrentRouterExecutionPolicySource(currentState),
                    threadModelSelectionSource: threadSelectionStore);
                if (!execution.IsSuccess || execution.Service is null)
                {
                    await Console.Error
                        .WriteLineAsync($"[local-router] {execution.Error!.Code}: {execution.Error.Message}")
                        .ConfigureAwait(false);
                    return ConfigErrorExitCode;
                }

                productionService = execution.Service;
            }

            // Exit code for the steady-state run: 0 after a normal shutdown, 130
            // when the startup window was cancelled before durable READY.
            int startupExitCode = 0;
            using (productionService)
            {
                // PR10B lifecycle control. The only producer that cancels this
                // linked source is the authenticated control channel, and the
                // channel is created after the durable READY commit, so every
                // startup-window exit code below keeps its exact meaning.
                using CancellationTokenSource shutdownSource =
                    CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                IResponsesService service = productionService ?? responsesService!;
                IRouterHealthSnapshotSource? healthSource = productionService?.PassiveHealth is { } passiveHealth
                    ? new PassiveHealthSnapshotSource(passiveHealth, () => clock.UtcNow)
                    : null;
                IngressStartResult start = await ResponsesIngress.StartAsync(
                    options,
                    service,
                    secretResolver,
                    clock,
                    idGenerator,
                    observer: observability.Observer,
                    controlPlane: new ControlPlaneRuntimeServices
                    {
                        Metering = observability.Metering,
                        RequestLog = observability.RequestLog,
                        ConfigOperator = configOperator,
                        CurrentState = currentState,
                        Health = healthSource,
                        RuntimePublicationSink = runtimePublicationSink,
                        ThreadSelection = threadSelectionStore,
                        RuntimeConsistencyGate = runtimeConsistencyGate,
                        ApprovedModelValidator = productionService?.ApprovedModelValidator,
                    },
                    // FIX2C: the production Host defers the public READY state.
                    // Binding the loopback listener is not readiness: READY is
                    // published only after the owner record and the durable
                    // runtime READY state are committed below.
                    shutdownToken: shutdownSource.Token,
                    deferReadyPublication: true).ConfigureAwait(false);
                if (!start.IsSuccess || start.Ingress is null)
                {
                    // A cancelled startup is not a configuration error: it must
                    // keep its own exit code instead of being reported as one.
                    bool cancelled = string.Equals(
                        start.Error?.Code,
                        RouterErrorCode.Cancelled,
                        StringComparison.Ordinal);
                    if (start.Ingress is not null)
                    {
                        await start.Ingress.DisposeAsync().ConfigureAwait(false);
                    }

                    if (cancelled)
                    {
                        return CancelledExitCode;
                    }

                    await Console.Error
                        .WriteLineAsync($"[local-router] {start.Error!.Code}: {start.Error.Message}")
                        .ConfigureAwait(false);
                    return ConfigErrorExitCode;
                }

                await using (start.Ingress)
                {
                    // Durable commit bookkeeping for the startup window. The
                    // cleanup path never guesses from File.Exists: it acts on what
                    // this process actually committed.
                    RouterStateStore stateStore = new(fileSystem, clock);
                    bool ownerCommitted = false;
                    bool durableReadyCommitted = false;
                    // PR10B: the published stop capability, if one could be
                    // created securely. Null means the Host serves without a
                    // stop channel; that is never reported as a capability.
                    RouterHostControlListener? controlListener = null;
                    // PR10B FIX1: a Windows Host that cannot publish its stop
                    // capability must not stay in a READY-but-unmanageable state.
                    bool controlChannelUnavailable = false;
                    try
                    {
                        using Process currentProcess = Process.GetCurrentProcess();
                        DateTimeOffset startTimeUtc = currentProcess.StartTime.ToUniversalTime();
                        OwnerRecord ownerRecord = new()
                        {
                            SchemaVersion = OwnerRecord.CurrentSchemaVersion,
                            Pid = currentProcess.Id,
                            ProcessFingerprint = ProcessFingerprint.Compute(currentProcess.Id, startTimeUtc),
                            ProcessStartTicks = startTimeUtc.Ticks,
                            Host = LoopbackBindPolicy.LoopbackHost,
                            Port = snapshot.Config.LocalRouter.Port,
                            ConfigGeneration = snapshot.ConfigGeneration,
                            CreatedAt = clock.UtcNow,
                            Version = 1,
                        };

                        RouterError? ownerWriteError = await ownerStore
                            .WriteAsync(pathProvider.OwnerRecordPath, ownerRecord, cancellationToken)
                            .ConfigureAwait(false);
                        if (ownerWriteError is not null)
                        {
                            await Console.Error
                                .WriteLineAsync($"[local-router] {ownerWriteError.Code}: {ownerWriteError.Message} phase=owner_record operation={(ownerWriteError.Param == "file_security" ? "file_security" : "atomic_write")}")
                                .ConfigureAwait(false);
                            return ConfigErrorExitCode;
                        }

                        ownerCommitted = true;

                        DateTimeOffset now = clock.UtcNow;
                        RouterRuntimeState readyState = new()
                        {
                            SchemaVersion = RouterRuntimeState.CurrentSchemaVersion,
                            Version = 1,
                            Lifecycle = LifecycleState.Ready.ToWireName(),
                            ConfigGeneration = snapshot.ConfigGeneration,
                            StartedAt = now,
                            UpdatedAt = now,
                            MigrationReceipts = [],
                        };

                        RouterError? stateError = await stateStore
                            .SaveAsync(pathProvider.RuntimeStatePath, readyState, cancellationToken)
                            .ConfigureAwait(false);
                        if (stateError is not null)
                        {
                            await Console.Error
                                .WriteLineAsync($"[local-router] {stateError.Code}: {stateError.Message} phase=ready_state operation=atomic_write")
                                .ConfigureAwait(false);
                            return ConfigErrorExitCode;
                        }

                        // The durable READY commit is the formal boundary between
                        // the startup-abort path (130) and the normal shutdown
                        // path (0). Nothing cancellable may be awaited between this
                        // commit and the READY publication, so a caller that can
                        // observe ready=true can never be inside the window.
                        durableReadyCommitted = true;

                        if (!start.Ingress.TryPublishReady())
                        {
                            await Console.Error
                                .WriteLineAsync("[local-router] lifecycle_ready_publication_failed: the router could not publish READY; not starting.")
                                .ConfigureAwait(false);
                            return ConfigErrorExitCode;
                        }

                        await Console.Out
                            .WriteLineAsync($"[local-router] READY on http://{LoopbackBindPolicy.LoopbackHost}:{start.Ingress.ListenAddress?.Port ?? snapshot.Config.LocalRouter.Port}")
                            .ConfigureAwait(false);

                        // PR10B: publish the host-local stop capability only after
                        // durable READY, so an authenticated stop request can never
                        // reach the startup-abort path. A channel that cannot be
                        // created and protected is not published at all.
                        controlListener = await RouterHostControlListener.TryStartAsync(
                            runtimeDirectory,
                            ownerRecord,
                            snapshot.ConfigGeneration,
                            fileSystem,
                            fileSecurity,
                            clock,
                            shutdownSource.Cancel,
                            shutdownSource.Token).ConfigureAwait(false);

                        if (controlListener is null && OperatingSystem.IsWindows())
                        {
                            // The capability could not be published and protected.
                            // The normal shutdown below still persists STOPPED and
                            // archives the owner record, but this process must not
                            // report a clean stop for a router it cannot stop.
                            await Console.Error
                                .WriteLineAsync($"[local-router] {ControlChannelUnavailableMessage}: the host-local stop capability could not be published and protected; stopping through the normal shutdown path.")
                                .ConfigureAwait(false);
                            controlChannelUnavailable = true;
                            shutdownSource.Cancel();
                        }

                        try
                        {
                            await Task.Delay(Timeout.InfiniteTimeSpan, shutdownSource.Token).ConfigureAwait(false);
                        }
                        catch (OperationCanceledException)
                        {
                            // Normal shutdown signal after durable READY.
                        }

                        // Withdraw the stop capability before the durable stop
                        // begins: no controller may address a Host that is
                        // already stopping, and no stale endpoint is left behind.
                        controlListener?.Dispose();
                        controlListener = null;

                        await start.Ingress.StopAsync(CancellationToken.None).ConfigureAwait(false);

                        // Drain the bounded completion queue with a hard timeout before
                        // final state is persisted. A response that already completed
                        // must never be silently dropped by immediate Router shutdown.
                        if (observability.Observer is { } completionObserver)
                        {
                            using CancellationTokenSource drainCts = new(ProductionCompletionObserver.DefaultShutdownDrainTimeout);
                            await completionObserver.DrainAsync(drainCts.Token).ConfigureAwait(false);
                        }

                        RouterRuntimeState stoppedState = readyState with
                        {
                            Lifecycle = LifecycleState.Stopped.ToWireName(),
                            Version = readyState.Version + 1,
                            UpdatedAt = clock.UtcNow,
                        };
                        RouterError? stoppedWriteError = await stateStore
                            .SaveAsync(pathProvider.RuntimeStatePath, stoppedState, CancellationToken.None)
                            .ConfigureAwait(false);
                        if (stoppedWriteError is not null)
                        {
                            await Console.Error.WriteLineAsync($"[local-router] {stoppedWriteError.Code}: {stoppedWriteError.Message} phase=stopped_state operation=atomic_write")
                                .ConfigureAwait(false);
                            // Keep ownership available for verified stale-owner
                            // recovery; never claim a clean durable stop on failure.
                            return ConfigErrorExitCode;
                        }

                        // Archive the owner record (never delete without a copy).
                        await stateStore
                            .QuarantineAsync(pathProvider.OwnerRecordPath, pathProvider.QuarantineRootPath, "owner_stopped", CancellationToken.None)
                            .ConfigureAwait(false);

                        startupExitCode = controlChannelUnavailable
                            ? ControlChannelUnavailableExitCode
                            : 0;
                    }
                    catch (OperationCanceledException)
                    {
                        // Startup-tail cancellation: the listener may already be
                        // bound, but this process never committed durable READY.
                        // Stop the ingress through the normal STOPPING path, keep
                        // the owner record by archiving it (never delete without a
                        // copy), do not fabricate a STOPPED state for a process
                        // that never became ready, and report the cancellation
                        // with its own exit code.
                        try
                        {
                            await start.Ingress.StopAsync(CancellationToken.None).ConfigureAwait(false);
                        }
                        catch (Exception)
                        {
                            // The listener is released by disposal below even if
                            // the graceful stop itself failed.
                        }

                        if (ownerCommitted && !durableReadyCommitted)
                        {
                            await QuarantineAbortedStartupOwnerAsync(stateStore, pathProvider).ConfigureAwait(false);
                        }

                        startupExitCode = CancelledExitCode;
                    }
                    finally
                    {
                        // Idempotent: the normal shutdown path already withdrew it.
                        controlListener?.Dispose();
                    }
                }
            }

            return startupExitCode;
        }
        catch (RouterStartupGateException error)
        {
            int nativeCode = error.InnerException is System.ComponentModel.Win32Exception native ? native.NativeErrorCode : 0;
            // A cleanup failure is not a startup refusal: it is reported with its
            // own wording and its own non-zero code, so an unrecovered access
            // control is never presented as a clean stop.
            bool cleanupFailure = string.Equals(error.Message, WindowsRouterStartupGate.CleanupFailedMessage, StringComparison.Ordinal);
            string outcome = cleanupFailure
                ? "enabled Host shutdown cleanup failed"
                : "enabled Host startup refused";
            await Console.Error.WriteLineAsync($"[local-router] {error.Message}: {outcome}; stage={error.FailureStage} cause={error.InnerException?.GetType().Name ?? "none"} native={nativeCode}.")
                .ConfigureAwait(false);
            return cleanupFailure ? CleanupFailedExitCode : ConfigErrorExitCode;
        }
        catch (OperationCanceledException)
        {
            return CancelledExitCode;
        }
    }

    /// <summary>
    /// Archives the owner record this process committed during a startup that
    /// never reached durable READY. The record is copied into quarantine before
    /// the live file is removed, so ownership evidence is never lost, and no
    /// process is ever touched. Failure is reported but never escalated into a
    /// second exception: the caller still returns the cancellation exit code.
    /// </summary>
    private static async Task QuarantineAbortedStartupOwnerAsync(
        RouterStateStore stateStore,
        IRouterPathProvider pathProvider)
    {
        try
        {
            await stateStore
                .QuarantineAsync(
                    pathProvider.OwnerRecordPath,
                    pathProvider.QuarantineRootPath,
                    "owner_startup_cancelled",
                    CancellationToken.None)
                .ConfigureAwait(false);
        }
        catch (Exception)
        {
            await Console.Error
                .WriteLineAsync("[local-router] owner_startup_cancelled: the aborted startup owner record could not be archived; the live record was left in place.")
                .ConfigureAwait(false);
        }
    }

    private sealed record HostPathSnapshot(
        string DefaultsPath,
        string UserConfigPath,
        string RuntimeStatePath,
        string OwnerRecordPath,
        string BackupRootPath,
        string QuarantineRootPath,
        string MigrationReceiptDirectory) : IRouterPathProvider;

    private sealed record ProductionObservabilityComponents(
        ProductionCompletionObserver Observer,
        RequestMeteringService Metering,
        DurableRequestLog? RequestLog,
        SafeFailureDiagnosticLog? FailureDiagnosticLog);

    private static ProductionObservabilityComponents BuildProductionObservability(
        IRouterPathProvider pathProvider,
        IClock clock,
        RequestMeteringService? meteringOverride,
        DurableRequestLog? requestLogOverride,
        PricingSnapshot? pricingOverride,
        HostObservabilityProbe? probe)
    {
        RequestMeteringService metering = meteringOverride
            ?? new RequestMeteringService(pricing: pricingOverride ?? TryLoadPricingSnapshot());

        DurableRequestLog? requestLog = requestLogOverride;
        SafeFailureDiagnosticLog? failureDiagnosticLog = null;
        if (requestLog is null)
        {
            try
            {
                string runtimeDirectory = Path.GetDirectoryName(pathProvider.RuntimeStatePath) ?? string.Empty;
                if (!string.IsNullOrWhiteSpace(runtimeDirectory))
                {
                    requestLog = new DurableRequestLog(
                        ObservabilityOptions.Defaults(Path.Combine(runtimeDirectory, "logs")));
                    // DSR7-C-FIX2: local safe failure diagnostics live in their own
                    // Router-owned directory, completely separate from the
                    // redacted request log schema.
                    failureDiagnosticLog = new SafeFailureDiagnosticLog(
                        Path.Combine(runtimeDirectory, "diagnostics"));
                }
            }
            catch (Exception)
            {
                // Observability is best-effort; the router still starts.
            }
        }

        ProductionCompletionObserver observer = new(
            metering,
            requestLog,
            clock,
            failureDiagnosticLog: failureDiagnosticLog);
        if (probe is not null)
        {
            probe.Metering = metering;
            probe.Observer = observer;
            probe.RequestLog = requestLog;
            probe.FailureDiagnosticLog = failureDiagnosticLog;
        }

        return new ProductionObservabilityComponents(observer, metering, requestLog, failureDiagnosticLog);
    }

    private static PricingSnapshot? TryLoadPricingSnapshot()
    {
        try
        {
            string path = Path.Combine(AppContext.BaseDirectory, "model-catalog.json");
            if (!File.Exists(path))
            {
                return null;
            }

            byte[] bytes = File.ReadAllBytes(path);
            CatalogProjectionResult projection = ModelCatalogProjector.Project(bytes, "installer/model-catalog.json");
            projection.Validate();
            PricingProjectionResult pricing = PricingProjector.Project(projection.Projection!, DateTimeOffset.UtcNow);
            return pricing.IsSuccess ? pricing.Snapshot : null;
        }
        catch (Exception)
        {
            return null;
        }
    }
}

/// <summary>
/// Test/diagnostic probe for the observability components Router.Host composes
/// by default. Production never reads this type; tests use it to observe the
/// real default metering service, completion observer, and durable log without
/// replacing any component under test.
/// </summary>
public sealed class HostObservabilityProbe
{
    public RequestMeteringService? Metering { get; internal set; }

    public ProductionCompletionObserver? Observer { get; internal set; }

    public DurableRequestLog? RequestLog { get; internal set; }

    /// <summary>DSR7-C-FIX2 local safe failure diagnostic sink composed by the host.</summary>
    public SafeFailureDiagnosticLog? FailureDiagnosticLog { get; internal set; }
}
