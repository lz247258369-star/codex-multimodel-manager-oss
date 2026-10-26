using System.Net;
using System.Net.Sockets;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Router.ClientAdapters.Responses;
using Router.Configuration;
using Router.Core.Abstractions;
using Router.Core.Errors;
using Router.Core.Lifecycle;
using Router.Ingress.Handlers;
using Router.Ingress.Middleware;
using Router.Secrets;

namespace Router.Ingress;

/// <summary>
/// Loopback-only Responses ingress backed by Kestrel. Binds strictly to
/// 127.0.0.1, enforces hard limits, and reports stable startup errors
/// (router_port_in_use) instead of silently changing the port.
/// </summary>
public sealed class ResponsesIngress : IAsyncDisposable
{
    public const int MaxRequestHeaderCount = 100;

    private readonly IngressRuntimeOptions _options;
    private readonly IResponsesService _service;
    private readonly ISecretResolver _secretResolver;
    private readonly IClock _clock;
    private readonly IIdGenerator _idGenerator;
    private readonly IngressRequestObserver? _observer;
    private readonly ControlPlaneRuntimeServices? _controlPlane;
    private readonly RouterLifecycle _lifecycle = new();
    private readonly ConnectionLimiter _limiter;
    private readonly ClientScopeRegistry _scopeRegistry;
    private readonly CancellationTokenSource _shutdownCts = new();
    private WebApplication? _app;
    private bool _disposed;

    private ResponsesIngress(
        IngressRuntimeOptions options,
        IResponsesService service,
        ISecretResolver secretResolver,
        IClock clock,
        IIdGenerator idGenerator,
        IngressRequestObserver? observer,
        ControlPlaneRuntimeServices? controlPlane)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _service = service ?? throw new ArgumentNullException(nameof(service));
        _secretResolver = secretResolver ?? throw new ArgumentNullException(nameof(secretResolver));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _idGenerator = idGenerator ?? throw new ArgumentNullException(nameof(idGenerator));
        _observer = observer;
        _controlPlane = controlPlane;
        _limiter = new ConnectionLimiter(Math.Min(options.Limits.MaxConnections, ConfigLimitCeilings.MaxConnectionsCeiling));
        _scopeRegistry = new ClientScopeRegistry(options.Clients);
    }

    public LifecycleState LifecycleState => _lifecycle.State;

    public Uri? ListenAddress { get; private set; }

    public int InFlightCount => _limiter.InFlightCount;

    public IReadOnlyCollection<string> AllowedScopes => _scopeRegistry.AllowedScopes;

    public static Task<IngressStartResult> StartAsync(
        IngressRuntimeOptions options,
        IResponsesService service,
        ISecretResolver secretResolver,
        IClock clock,
        IIdGenerator idGenerator,
        IngressRequestObserver? observer = null,
        ControlPlaneRuntimeServices? controlPlane = null,
        bool deferReadyPublication = false,
        CancellationToken shutdownToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(service);
        ArgumentNullException.ThrowIfNull(secretResolver);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(idGenerator);

        ResponsesIngress ingress = new(options, service, secretResolver, clock, idGenerator, observer, controlPlane);
        return ingress.StartCoreAsync(deferReadyPublication, shutdownToken);
    }

    /// <summary>
    /// Publishes the public READY state after the caller has completed the work
    /// that READY promises (owner intent committed, durable runtime READY
    /// committed). Only the legal STARTING -> READY transition is attempted, so
    /// a concurrent STOPPING/STOPPED/FAILED state is never overwritten, and the
    /// caller always learns whether the publication actually happened.
    /// </summary>
    public bool TryPublishReady()
        => _lifecycle.TryTransition(LifecycleState.Starting, LifecycleState.Ready);

    private async Task<IngressStartResult> StartCoreAsync(bool deferReadyPublication, CancellationToken shutdownToken)
    {
        if (!_lifecycle.TryTransition(LifecycleState.Stopped, LifecycleState.Starting))
        {
            return IngressStartResult.Failure(RouterError.AlreadyRunning());
        }

        RouterError? bindPolicyError = _options.Port == 0 ? null : LoopbackBindPolicy.Validate(_options.Host, _options.Port);
        if (bindPolicyError is not null)
        {
            return FailStart(bindPolicyError);
        }

        SecretReference tokenReference = LocalRouterSecrets.CreateTokenReference(_options.TokenReferenceName);
        SecretResolutionResult token;
        try
        {
            token = await _secretResolver.ResolveAsync(tokenReference, LocalRouterSecrets.ProviderId, shutdownToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return FailStart(RouterError.Cancelled());
        }

        if (!token.IsSuccess || token.Handle is null)
        {
            token.Handle?.Dispose();
            return FailStart(token.Error ?? SecretErrors.Missing(_options.TokenReferenceName));
        }

        token.Handle.Dispose();

        try
        {
            WebApplicationBuilder builder = WebApplication.CreateSlimBuilder();
            builder.Logging.ClearProviders();
            builder.WebHost.ConfigureKestrel(kestrel =>
            {
                kestrel.Listen(IPAddress.Loopback, _options.Port, static listen => listen.Protocols = HttpProtocols.Http1);

                // Hard implementation ceilings: configuration can never weaken them.
                kestrel.Limits.MaxRequestBodySize = null; // bounded by the explicit read path
                kestrel.Limits.MaxRequestHeadersTotalSize = Math.Min(_options.Limits.MaxHeaderBytes, ConfigLimitCeilings.MaxHeaderBytesCeiling);
                kestrel.Limits.MaxRequestHeaderCount = MaxRequestHeaderCount;
                // The socket layer enforces the hard ceiling; the configured
                // max_connections is enforced by the admission limiter, which
                // returns a stable 429 instead of dropping connections.
                kestrel.Limits.MaxConcurrentConnections = ConfigLimitCeilings.MaxConnectionsCeiling;
            });

            builder.Services.AddSingleton(_options);
            builder.Services.AddSingleton(_service);
            builder.Services.AddSingleton(_secretResolver);
            builder.Services.AddSingleton(_clock);
            builder.Services.AddSingleton(_idGenerator);
            builder.Services.AddSingleton(_lifecycle);
            builder.Services.AddSingleton(_limiter);
            builder.Services.AddSingleton(_scopeRegistry);
            builder.Services.AddSingleton(new TokenAuthenticator(_secretResolver, tokenReference));
            builder.Services.AddSingleton(new IngressServices
            {
                Options = _options,
                Service = _service,
                Clock = _clock,
                IdGenerator = _idGenerator,
                Limiter = _limiter,
                ScopeRegistry = _scopeRegistry,
                Lifecycle = _lifecycle,
                Observer = _observer,
                ShutdownCts = _shutdownCts,
                ControlPlane = _controlPlane,
            });

            WebApplication app = builder.Build();
            app.UseMiddleware<ExceptionHandlingMiddleware>();
            app.UseMiddleware<HostValidationMiddleware>();
            app.UseMiddleware<OriginPolicyMiddleware>();
            app.UseMiddleware<CorrelationMiddleware>();
            app.UseMiddleware<BodyLimitMiddleware>();
            app.UseWhen(static context => !IsHealthPath(context), static branch => branch.UseMiddleware<AuthenticationMiddleware>());
            app.UseWhen(static context => !IsHealthPath(context), static branch => branch.UseMiddleware<ConnectionLimitMiddleware>());
            app.UseWhen(IsResponsesInvokePath, static branch => branch.UseMiddleware<FeatureGateMiddleware>());

            app.MapGet("/health", HealthHandler.HandleAsync);
            app.MapGet("/v1/router/status", StatusHandler.HandleAsync);
            app.MapGet("/v1/router/control-plane/status", ControlPlaneHandlers.StatusAsync);
            app.MapGet("/v1/router/control-plane/usage", ControlPlaneHandlers.UsageAsync);
            app.MapGet("/v1/router/control-plane/requests", ControlPlaneHandlers.RecentRequestsAsync);
            app.MapGet("/v1/router/control-plane/policy", ControlPlaneHandlers.PolicyReadAsync);
            app.MapPut("/v1/router/control-plane/policy", ControlPlaneHandlers.PolicyMutateAsync);
            app.MapPut("/v1/router/control-plane/feature", ControlPlaneHandlers.FeatureAsync);

            // HS-1B thread-selection surface. Literal segments ("selections",
            // "capture") always outrank the "{threadRef}" parameter segment, so
            // the fixed routes can never be swallowed by the thread route.
            app.MapGet("/v1/router/control-plane/thread-selection-feature", ControlPlaneHandlers.ThreadSelectionFeatureReadAsync);
            app.MapPut("/v1/router/control-plane/thread-selection-feature", ControlPlaneHandlers.ThreadSelectionFeatureMutateAsync);
            app.MapGet("/v1/router/control-plane/threads", ControlPlaneHandlers.ThreadsAsync);
            app.MapDelete("/v1/router/control-plane/threads/selections", ControlPlaneHandlers.ThreadSelectionsClearAllAsync);
            app.MapPost("/v1/router/control-plane/threads/capture", ControlPlaneHandlers.ThreadCaptureOpenAsync);
            app.MapGet("/v1/router/control-plane/threads/capture/{token}", ControlPlaneHandlers.ThreadCaptureReadAsync);
            app.MapDelete("/v1/router/control-plane/threads/capture/{token}", ControlPlaneHandlers.ThreadCaptureCancelAsync);
            app.MapGet("/v1/router/control-plane/threads/{threadRef}/selection", ControlPlaneHandlers.ThreadSelectionReadAsync);
            app.MapPut("/v1/router/control-plane/threads/{threadRef}/selection", ControlPlaneHandlers.ThreadSelectionMutateAsync);
            app.MapDelete("/v1/router/control-plane/threads/{threadRef}/selection", ControlPlaneHandlers.ThreadSelectionClearAsync);

            app.MapPost("/v1/responses", ResponsesHandler.HandleAsync);

            await app.StartAsync(shutdownToken).ConfigureAwait(false);
            _app = app;

            IServer server = app.Services.GetRequiredService<IServer>();
            IServerAddressesFeature? addresses = server.Features.Get<IServerAddressesFeature>();
            string? bound = addresses?.Addresses.FirstOrDefault(static address =>
                address.StartsWith("http://127.0.0.1:", StringComparison.Ordinal));
            if (bound is null)
            {
                await DisposeAppAsync().ConfigureAwait(false);
                return FailStart(RouterError.InternalError());
            }

            ListenAddress = new Uri(bound);
            _options.ActualPort = ListenAddress.Port;
        }
        catch (IOException)
        {
            await DisposeAppAsync().ConfigureAwait(false);
            return FailStart(RouterError.PortInUse());
        }
        catch (SocketException)
        {
            await DisposeAppAsync().ConfigureAwait(false);
            return FailStart(RouterError.PortInUse());
        }
        catch (OperationCanceledException)
        {
            await DisposeAppAsync().ConfigureAwait(false);
            return FailStart(RouterError.Cancelled());
        }
        catch (Exception)
        {
            await DisposeAppAsync().ConfigureAwait(false);
            return FailStart(RouterError.InternalError());
        }

        // The loopback listener is bound and can accept connections here, but the
        // lifecycle only becomes READY when either this component owns that
        // decision (standalone/component callers, the historical behaviour) or
        // the production Host explicitly publishes it after the durable
        // owner/READY commit. /health, /v1/router/status and the control-plane
        // status all read this one state, so they stay STARTING until then.
        if (!deferReadyPublication)
        {
            _lifecycle.TryTransition(LifecycleState.Starting, LifecycleState.Ready);
        }

        return IngressStartResult.Success(this);
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (_app is null)
        {
            _lifecycle.TryTransition(LifecycleState.Failed, LifecycleState.Stopped);
            return;
        }

        if (_lifecycle.State == LifecycleState.Failed)
        {
            await DisposeAppAsync().ConfigureAwait(false);
            _lifecycle.TryTransition(LifecycleState.Failed, LifecycleState.Stopped);
            return;
        }

        _lifecycle.TryTransitionTo(LifecycleState.Stopping);
        _shutdownCts.Cancel();

        TimeSpan grace = TimeSpan.FromMilliseconds(
            Math.Min(_options.Limits.ShutdownGraceMs, ConfigLimitCeilings.MaxShutdownGraceMsCeiling));
        using CancellationTokenSource graceCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        graceCts.CancelAfter(grace);
        try
        {
            await _app.StopAsync(graceCts.Token).ConfigureAwait(false);
        }
        finally
        {
            await DisposeAppAsync().ConfigureAwait(false);
        }

        _lifecycle.TryTransition(LifecycleState.Stopping, LifecycleState.Stopped);
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _shutdownCts.Cancel();
        await DisposeAppAsync().ConfigureAwait(false);
        _shutdownCts.Dispose();
        GC.SuppressFinalize(this);
    }

    private IngressStartResult FailStart(RouterError error)
    {
        _lifecycle.TryTransition(LifecycleState.Starting, LifecycleState.Failed);
        return IngressStartResult.Failure(error, this);
    }

    private async Task DisposeAppAsync()
    {
        if (_app is not null)
        {
            await _app.DisposeAsync().ConfigureAwait(false);
            _app = null;
            ListenAddress = null;
        }
    }

    private static bool IsHealthPath(HttpContext context)
        => string.Equals(context.Request.Path.Value, "/health", StringComparison.Ordinal);

    private static bool IsResponsesInvokePath(HttpContext context)
        => string.Equals(context.Request.Method, HttpMethods.Post, StringComparison.Ordinal)
            && string.Equals(context.Request.Path.Value, "/v1/responses", StringComparison.Ordinal);
}

/// <summary>Startup result: a running ingress or a normalized startup error.</summary>
public sealed record IngressStartResult(ResponsesIngress? Ingress, RouterError? Error)
{
    public bool IsSuccess => Ingress is not null && Error is null;

    public static IngressStartResult Success(ResponsesIngress ingress)
        => new(ingress, null);

    public static IngressStartResult Failure(RouterError error, ResponsesIngress? ingress = null)
        => new(ingress, error);
}
