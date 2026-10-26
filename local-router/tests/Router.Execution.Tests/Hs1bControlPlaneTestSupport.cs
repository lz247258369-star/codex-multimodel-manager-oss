using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using ProviderContractKit;
using Router.Configuration;
using Router.Core.Abstractions;
using Router.Core.Concurrency;
using Router.Core.Ids;
using Router.Execution;
using Router.FakeProvider;
using Router.Health;
using Router.Host;
using Router.Ingress;
using Router.ProviderAdapters.Abstractions;
using Router.Secrets;
using Router.ThreadSelection;
using Xunit;

namespace Router.Execution.Tests;

/// <summary>
/// Explicitly controllable test clock: TTL boundaries are exercised by moving
/// time, never by sleeping.
/// </summary>
internal sealed class MutableTestClock : IClock
{
    private DateTimeOffset _now;

    public MutableTestClock(DateTimeOffset now)
    {
        _now = now;
    }

    public DateTimeOffset UtcNow => _now;

    public void Advance(TimeSpan delta) => _now = _now.Add(delta);
}

/// <summary>
/// Counting loopback transport for the HS-1B control-plane E2E. It proves both
/// invariants at once: no test may ever reach a non-loopback target, and every
/// provider attempt is counted so "control-plane operations make zero provider
/// calls" is an assertion instead of a claim.
/// </summary>
internal sealed class CountingLoopbackHandler : DelegatingHandler
{
    private int _calls;
    private int _failuresForNextRequest;

    public CountingLoopbackHandler()
        : base(new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            ConnectTimeout = TimeSpan.FromSeconds(2),
        })
    {
    }

    public int Calls => Volatile.Read(ref _calls);

    /// <summary>
    /// Number of consecutive upstream attempts to fail before letting a request
    /// through. Used to prove that a live policy mutation through the composite
    /// publication sink reaches the running execution boundary.
    /// </summary>
    public int FailuresForNextRequest
    {
        get => Volatile.Read(ref _failuresForNextRequest);
        set => Volatile.Write(ref _failuresForNextRequest, value);
    }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Assert.True(
            request.RequestUri is { } uri && UpstreamEndpoint.IsLoopbackHost(uri.Host),
            "HS-1B E2E transport must stay loopback; a real provider host is never contacted.");

        _ = Interlocked.Increment(ref _calls);
        if (Interlocked.Decrement(ref _failuresForNextRequest) >= 0)
        {
            return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.ServiceUnavailable)
            {
                Content = new ByteArrayContent([]),
            });
        }

        return base.SendAsync(request, cancellationToken);
    }
}

/// <summary>
/// Production-shaped HS-1B control-plane harness: durable config over an
/// in-memory file system, the composite runtime publication sink, ONE
/// thread-selection store shared by execution and the control plane, the
/// production execution service (with its own approved-model validator bound to
/// the same registry snapshot), and a real loopback ingress.
///
/// This is deliberately the same composition the Host bootstrap builds, so the
/// tests exercise the real publication ordering instead of a re-implementation.
/// </summary>
internal sealed class Hs1bControlPlaneHarness : IAsyncDisposable
{
    public const string LocalToken = Hs1bRouterContext.LocalToken;

    private static readonly JsonSerializerOptions ConfigWriteOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly HttpClient _client;
    private readonly ResponsesIngress _ingress;

    private Hs1bControlPlaneHarness(
        FakeProviderServer server,
        RouterExecutionResponsesService service,
        ResponsesIngress ingress,
        CollectingOutcomeSink sink,
        ThreadSelectionStore store,
        CurrentRouterState currentState,
        RouterRuntimePublicationSink publicationSink,
        LocalRouterConfigOperator configOperator,
        CountingLoopbackHandler transport,
        IRouterRuntimeConsistencyGate consistencyGate,
        MutableTestClock clock,
        int port)
    {
        Server = server;
        Service = service;
        _ingress = ingress;
        Sink = sink;
        Store = store;
        CurrentState = currentState;
        PublicationSink = publicationSink;
        ConfigOperator = configOperator;
        Transport = transport;
        ConsistencyGate = consistencyGate;
        Clock = clock;
        Port = port;
        _client = new HttpClient();
    }

    public FakeProviderServer Server { get; }

    public RouterExecutionResponsesService Service { get; }

    public CollectingOutcomeSink Sink { get; }

    public ThreadSelectionStore Store { get; }

    public CurrentRouterState CurrentState { get; }

    public RouterRuntimePublicationSink PublicationSink { get; }

    public LocalRouterConfigOperator ConfigOperator { get; }

    public CountingLoopbackHandler Transport { get; }

    /// <summary>The one runtime consistency boundary this harness composed.</summary>
    public IRouterRuntimeConsistencyGate ConsistencyGate { get; }

    /// <summary>The harness clock; advancing it exercises TTL boundaries.</summary>
    public MutableTestClock Clock { get; }

    public int Port { get; }

    public string Generation => CurrentState.Snapshot.ConfigGeneration;

    public string UpstreamBody
        => Server.LastRequestBody is { } body ? Encoding.UTF8.GetString(body) : string.Empty;

    public static async Task<Hs1bControlPlaneHarness> StartAsync(
        bool threadSelectionEnabled = false,
        bool localRouterEnabled = true,
        bool bindForeignPublicationSink = false,
        IRouterRuntimeConsistencyGate? consistencyGate = null,
        Func<ThreadSelectionStore, IRouterRuntimeFeatureState>? featureStateFactory = null,
        MutableTestClock? clock = null)
    {
        var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson("hs1b-control-plane-ok")));

        // Durable config root: the initial effective document is seeded as the
        // defaults file, so the operator's generation is the real loader
        // generation and stays consistent with every later CAS.
        EffectiveRouterConfigSnapshot seeded = Hs1bRuntimeConfig.Snapshot(
            threadSelectionEnabled,
            localRouterEnabled,
            [Hs1bRuntimeConfig.ControlPlaneClient()]);
        var fileSystem = new MemoryExecutionFileSystem();
        fileSystem.SeedFile(
            MemoryExecutionFileSystem.DefaultsPath,
            JsonSerializer.Serialize(seeded.Config, ConfigWriteOptions));

        clock ??= new MutableTestClock(DateTimeOffset.UtcNow);
        var offlineOperator = new LocalRouterConfigOperator(
            fileSystem,
            clock,
            MemoryExecutionFileSystem.DefaultsPath,
            MemoryExecutionFileSystem.UserConfigPath);
        LocalRouterConfigReadResult read = await offlineOperator.ReadAsync(CancellationToken.None);
        Assert.True(read.IsSuccess, read.Error?.Code + ": " + read.Error?.Message);

        EffectiveRouterConfigSnapshot snapshot = seeded with
        {
            Config = read.View!.Config,
            ConfigGeneration = read.View.ConfigGeneration,
        };

        CurrentRouterState currentState = new(
            PublishedRouterState.From(snapshot.Config, snapshot.ConfigGeneration));

        // ONE runtime consistency boundary and ONE store per process. The
        // effective capability is router feature AND thread feature.
        IRouterRuntimeConsistencyGate gate = consistencyGate ?? new RouterRuntimeConsistencyGate();
        var store = new ThreadSelectionStore(
            Hs1bRuntimeConfig.Options(),
            clock,
            snapshot.Config.LocalRouter.Enabled && snapshot.Config.LocalRouter.ThreadSelection.Enabled,
            gate);

        // The publication path applies the capability transition through the
        // same feature state the store exposes; tests may wrap it to pause
        // deterministically inside the exclusive publication section.
        IRouterRuntimeFeatureState featureState = featureStateFactory?.Invoke(store) ?? store;
        var runtimePublicationSink = new RouterRuntimePublicationSink(currentState, featureState, gate);
        LocalRouterConfigOperator configOperator = bindForeignPublicationSink
            // A live-looking sink that does NOT belong to this runtime: the
            // ownership check must reject mutations through it.
            ? offlineOperator.WithPublicationSink(new RouterRuntimePublicationSink(currentState, featureState, gate))
            : offlineOperator.WithPublicationSink(runtimePublicationSink);

        var sink = new CollectingOutcomeSink();
        var resolver = new FakeSecretResolver();
        resolver.Configure("local_router", Hs1bRuntimeConfig.LocalTokenReferenceName, LocalToken);
        resolver.Configure(Hs1bRuntimeConfig.ProviderId, Hs1bRuntimeConfig.UpstreamSecretName, Hs1bRouterContext.UpstreamSecret);

        var transport = new CountingLoopbackHandler();
        var overrides = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [Hs1bRuntimeConfig.BaseUrlReference] = server.BaseUri.ToString(),
        };

        RouterExecutionServiceFactoryResult serviceResult = RouterExecutionServiceFactory.Create(
            snapshot,
            resolver,
            transportHandler: transport,
            endpointOverrides: overrides,
            passiveHealthPolicy: PassiveHealthPolicy.Default,
            outcomeSink: sink,
            // Same live policy boundary as the Host: a published policy change
            // is visible to the running execution service without a restart.
            policySource: new CurrentRouterExecutionPolicySource(currentState),
            threadModelSelectionSource: store);
        Assert.True(
            serviceResult.IsSuccess,
            serviceResult.Error?.Code + ": " + serviceResult.Error?.Message + " (" + serviceResult.Error?.Param + ")");
        RouterExecutionResponsesService service = serviceResult.Service!;

        IngressRuntimeOptions options = new()
        {
            Host = "127.0.0.1",
            Port = 0,
            Limits = new LimitsConfig
            {
                MaxRequestBytes = 16_777_216,
                MaxHeaderBytes = 32_768,
                MaxConnections = 32,
                ShutdownGraceMs = 15_000,
            },
            ConfigGeneration = snapshot.ConfigGeneration,
            TokenReferenceName = Hs1bRuntimeConfig.LocalTokenReferenceName,
            Clients = snapshot.Config.Clients,
        };

        IngressStartResult start = await ResponsesIngress.StartAsync(
            options,
            service,
            resolver,
            clock,
            new UuidV7IdGenerator(clock),
            controlPlane: new ControlPlaneRuntimeServices
            {
                ConfigOperator = configOperator,
                CurrentState = currentState,
                RuntimePublicationSink = runtimePublicationSink,
                ThreadSelection = store,
                RuntimeConsistencyGate = gate,
                ApprovedModelValidator = service.ApprovedModelValidator,
            });
        Assert.True(start.IsSuccess, start.Error?.Code);

        return new Hs1bControlPlaneHarness(
            server,
            service,
            start.Ingress!,
            sink,
            store,
            currentState,
            runtimePublicationSink,
            configOperator,
            transport,
            gate,
            clock,
            start.Ingress!.ListenAddress!.Port);
    }

    /// <summary>Real Responses turn carrying the Codex thread identity headers.</summary>
    public Task<HttpResponseMessage> PostTurnAsync(string model, string threadId, string requestKind = "turn")
        => SendAsync(HttpMethod.Post, "/v1/responses", Hs1bRouterContext.RequestBody(model), LocalToken, threadId, requestKind);

    public Task<HttpResponseMessage> ControlGetAsync(string pathAndQuery, string? token = null)
        => SendAsync(HttpMethod.Get, pathAndQuery, null, token ?? LocalToken, null, null);

    public Task<HttpResponseMessage> ControlPutAsync(string path, string json, string? token = null)
        => SendAsync(HttpMethod.Put, path, json, token ?? LocalToken, null, null);

    public Task<HttpResponseMessage> ControlPostAsync(string path, string json, string? token = null)
        => SendAsync(HttpMethod.Post, path, json, token ?? LocalToken, null, null);

    public Task<HttpResponseMessage> ControlDeleteAsync(string path, string? json = null, string? token = null)
        => SendAsync(HttpMethod.Delete, path, json, token ?? LocalToken, null, null);

    /// <summary>Sends an unauthenticated request (no Authorization header at all).</summary>
    public Task<HttpResponseMessage> SendUnauthenticatedAsync(HttpMethod method, string path, string? json = null)
        => SendAsync(method, path, json, token: string.Empty, threadId: null, requestKind: null);

    public async ValueTask DisposeAsync()
    {
        _client.Dispose();
        await _ingress.DisposeAsync();
        Service.Dispose();
        await Server.DisposeAsync();
    }

    public static async Task<string> BodyAsync(HttpResponseMessage response)
        => await response.Content.ReadAsStringAsync();

    public static async Task<string> ErrorCodeAsync(HttpResponseMessage response)
    {
        using JsonDocument document = JsonDocument.Parse(await BodyAsync(response));
        return document.RootElement.GetProperty("error").GetProperty("code").GetString()!;
    }

    public static async Task<string> PropertyAsync(HttpResponseMessage response, string property)
    {
        using JsonDocument document = JsonDocument.Parse(await BodyAsync(response));
        return document.RootElement.GetProperty(property).GetString()!;
    }

    public static string FeatureBody(string generation, bool enabled)
        => "{\"schema_version\":1,\"expected_generation\":\"" + generation
            + "\",\"enabled\":" + (enabled ? "true" : "false") + "}";

    public static string RouterFeatureBody(string generation, bool enabled)
        => FeatureBody(generation, enabled);

    public static string SetSelectionBody(ulong expectedGeneration, string model)
        => "{\"schema_version\":1,\"expected_generation\":" + expectedGeneration
            + ",\"model\":\"" + model + "\"}";

    public static string ClearSelectionBody(ulong expectedGeneration)
        => "{\"schema_version\":1,\"expected_generation\":" + expectedGeneration + "}";

    private async Task<HttpResponseMessage> SendAsync(
        HttpMethod method,
        string pathAndQuery,
        string? json,
        string token,
        string? threadId,
        string? requestKind)
    {
        using HttpRequestMessage request = new(method, $"http://127.0.0.1:{Port}{pathAndQuery}");
        if (json is not null)
        {
            request.Content = new StringContent(json, Encoding.UTF8, "application/json");
        }

        if (!string.IsNullOrEmpty(token))
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        }

        if (threadId is not null)
        {
            request.Headers.TryAddWithoutValidation(
                Router.Core.Context.ThreadIdentityParser.ThreadIdHeaderName,
                threadId);
            request.Headers.TryAddWithoutValidation(
                Router.Core.Context.ThreadIdentityParser.TurnMetadataHeaderName,
                Hs1bRouterContext.Metadata(threadId, requestKind ?? "turn"));
        }

        return await _client.SendAsync(request);
    }
}
