using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using Router.Configuration;
using Router.Core.Abstractions;
using Router.Core.Context;
using Router.Core.Ids;
using Router.Core.Support;
using Router.Execution;
using Router.FakeProvider;
using Router.Health;
using Router.Ingress;
using Router.Secrets;
using Router.ThreadSelection;
using Xunit;

namespace Router.Execution.Tests;

/// <summary>
/// One synthetic client model bound to one synthetic upstream model. All HS-1B
/// runtime and control-plane tests share this model set so a switch is always
/// observable at the loopback fake upstream.
/// </summary>
internal sealed record Hs1bModel(string Slug, string ClientModelId, string UpstreamModelId, bool RouteEnabled = true)
{
    public string CatalogModelId => "catalog-model-" + Slug;

    public string RouteId => "route.hs1b-" + Slug;

    public string ProviderRouteId => "provider-route.hs1b-" + Slug;

    public string ModelRouteId => "model-route.hs1b-" + Slug;

    public string EndpointId => "endpoint.hs1b-" + Slug;
}

/// <summary>Synthetic multi-model Router configuration used by the HS-1B tests.</summary>
internal static class Hs1bRuntimeConfig
{
    public const string ClientId = "client.codex_cli";
    public const string ControlPlaneClientId = "client.control_plane";
    public const string ProviderId = "mm_openrouter";
    public const string AdapterId = "adapter.provider.mm_openrouter.responses.v1";
    public const string UpstreamSecretName = "OPENROUTER_API_KEY";
    public const string LocalTokenReferenceName = "CODEX_LOCAL_ROUTER_TOKEN";
    public const string BaseUrlReference = "provider-config:mm_openrouter.base_url";

    public static Hs1bModel Alpha { get; } = new("alpha", "hot-alpha", "upstream-a1");

    public static Hs1bModel Beta { get; } = new("beta", "hot-beta", "upstream-b2");

    public static Hs1bModel Gamma { get; } = new("gamma", "hot-gamma", "upstream-c3");

    /// <summary>Configured model whose route is disabled: structurally unusable by construction.</summary>
    public static Hs1bModel Delta { get; } = new("delta", "hot-delta", "upstream-d4", RouteEnabled: false);

    public static string Generation { get; } = SafeHasher.Sha256Hex("hs1b-stage2-runtime-wiring");

    public static ThreadSelectionOptions Options() => ThreadSelectionOptions.Create(
        ThreadSelectionOptions.DefaultMaxObservedThreads,
        ThreadSelectionOptions.DefaultEntryIdleTtl,
        TimeSpan.FromMilliseconds(ThreadSelectionConfig.DefaultPendingTtlMs),
        TimeSpan.FromMilliseconds(ThreadSelectionConfig.DefaultActiveIdleTtlMs));

    public static EffectiveRouterConfigSnapshot Snapshot(
        bool threadSelectionEnabled,
        bool localRouterEnabled = true,
        IReadOnlyList<ClientConfig>? additionalClients = null)
    {
        Hs1bModel[] models = [Alpha, Beta, Gamma, Delta];
        RouterConfig config = new()
        {
            SchemaVersion = RouterConfig.CurrentSchemaVersion,
            Version = 1,
            Mode = localRouterEnabled ? RouterMode.Router : RouterMode.Direct,
            LocalRouter = new LocalRouterConfig
            {
                Enabled = localRouterEnabled,
                Host = "127.0.0.1",
                Port = 47821,
                ClientAuth = new ClientAuthConfig { Mode = "bearer_env_ref", TokenRef = LocalTokenReferenceName },
                Limits = new LimitsConfig
                {
                    MaxRequestBytes = 16_777_216,
                    MaxHeaderBytes = 32_768,
                    MaxConnections = 32,
                    ShutdownGraceMs = 15_000,
                },
                ThreadSelection = new ThreadSelectionConfig { Enabled = threadSelectionEnabled },
            },
            Clients = new[] { Client() }.Concat(additionalClients ?? []).ToArray(),
            ProtocolRoutes = [ExecutionTestConfigFactory.ProtocolRoute()],
            ProviderRoutes = models.Select(ProviderRouteFor).ToArray(),
            Endpoints = models.Select(EndpointFor).ToArray(),
            ModelRoutes = models.Select(ModelRouteFor).ToArray(),
            Routes = models.Select(RouteFor).ToArray(),
            Policies =
            [
                new PolicyConfig { PolicyId = ExecutionTestConfigFactory.TimeoutPolicyId, Version = 1 },
                new PolicyConfig { PolicyId = ExecutionTestConfigFactory.RetryPolicyId, Version = 1 },
                new PolicyConfig { PolicyId = ExecutionTestConfigFactory.FailoverPolicyId, Version = 1 },
            ],
            UpdatedAt = DateTimeOffset.Parse(
                "2026-09-14T00:00:00Z",
                CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal),
        };

        return new EffectiveRouterConfigSnapshot
        {
            Config = config,
            ConfigGeneration = Generation,
            LoadedAt = DateTimeOffset.UnixEpoch,
            Source = new ConfigSourceProvenance
            {
                DefaultsPath = "hs1b-runtime-defaults.json",
                HasUserConfig = false,
                DefaultsSha256 = "test",
            },
        };
    }

    /// <summary>Authenticated control-plane client used by the thread-selection surface.</summary>
    public static ClientConfig ControlPlaneClient() => new()
    {
        ClientId = ControlPlaneClientId,
        AdapterId = "adapter.client.control_plane.responses.v1",
        Enabled = true,
        AuthScope = "router:control-plane",
        Capabilities = ["responses"],
        Version = 1,
    };

    private static ClientConfig Client()
        => new()
        {
            ClientId = ClientId,
            AdapterId = "adapter.client.codex_cli.responses.v1",
            Enabled = true,
            AuthScope = "responses:invoke",
            AllowedRouteIds = [],
            Capabilities = ["text", "streaming", "reasoning", "tools", "usage", "cancellation"],
            Version = 1,
        };

    private static ProviderRouteConfig ProviderRouteFor(Hs1bModel model)
        => new()
        {
            ProviderRouteId = model.ProviderRouteId,
            ProviderId = ProviderId,
            AdapterId = AdapterId,
            AdapterVersion = "1.0",
            EndpointIds = [model.EndpointId],
            SecretRef = SecretReference(),
            BaseUrlRef = BaseUrlReference,
            Enabled = true,
            Capabilities = ["responses", "text", "streaming", "reasoning", "tools", "usage", "cancellation"],
            Version = 1,
        };

    private static EndpointConfig EndpointFor(Hs1bModel model)
        => new()
        {
            EndpointId = model.EndpointId,
            BaseUrlRef = BaseUrlReference,
            Enabled = true,
            DataBoundary = "provider-default",
            TlsRequired = true,
            Priority = 100,
            Weight = 100,
            Version = 1,
        };

    private static ModelRouteConfig ModelRouteFor(Hs1bModel model)
        => new()
        {
            ModelRouteId = model.ModelRouteId,
            ProviderId = ProviderId,
            ClientModelId = model.ClientModelId,
            ModelId = model.CatalogModelId,
            UpstreamModelId = model.UpstreamModelId,
            Aliases = [],
            Capabilities = ["text", "streaming", "reasoning", "tools", "usage"],
            PricingRef = "pricing." + ProviderId,
            IdentityVerification = "explicit_config",
            Enabled = true,
            Version = 1,
        };

    private static RouterRouteConfig RouteFor(Hs1bModel model)
        => new()
        {
            RouteId = model.RouteId,
            ClientIds = [ClientId],
            ProviderRouteId = model.ProviderRouteId,
            ProtocolRouteId = ExecutionTestConfigFactory.ProtocolRouteId,
            ModelRouteId = model.ModelRouteId,
            Enabled = model.RouteEnabled,
            Priority = 100,
            Weight = 100,
            HealthState = "UNKNOWN",
            TimeoutPolicyId = ExecutionTestConfigFactory.TimeoutPolicyId,
            RetryPolicyId = ExecutionTestConfigFactory.RetryPolicyId,
            FailoverPolicyId = ExecutionTestConfigFactory.FailoverPolicyId,
            FallbackRouteIds = [],
            CreatedAt = DateTimeOffset.UnixEpoch,
            UpdatedAt = DateTimeOffset.UnixEpoch,
            Version = 1,
        };

    private static SecretReference SecretReference()
        => new()
        {
            Resolver = "environment",
            Name = UpstreamSecretName,
            Scope = SecretScope.UserOrProcess,
            AllowedProviderIds = [ProviderId],
            Version = 1,
        };
}

/// <summary>Derives the external reference a test must use to address one thread.</summary>
internal static class Hs1bTestThreads
{
    public const string One = "01a09dae-3db7-7820-8912-0d86815051a6";
    public const string Two = "01a09dae-3e22-7072-b928-701a84420b82";

    public static string RefOf(string rawThreadId)
    {
        Assert.True(CanonicalThreadId.TryParse(rawThreadId, out CanonicalThreadId? canonical));
        return ThreadRef.From(canonical!);
    }
}

/// <summary>
/// Stage 2 runtime harness: real ingress + production execution + one shared
/// thread-selection store + loopback fake upstream. No real provider, key, or
/// network target is ever used.
/// </summary>
internal sealed class Hs1bRouterContext : IAsyncDisposable
{
    public const string LocalToken = "hs1b-local-token-sentinel";
    public const string UpstreamSecret = "hs1b-upstream-secret-sentinel";

    private readonly HttpClient _client;
    private readonly ResponsesIngress _ingress;

    public Hs1bRouterContext(
        FakeProviderServer server,
        RouterExecutionResponsesService service,
        ResponsesIngress ingress,
        CollectingOutcomeSink sink,
        EffectiveRouterConfigSnapshot snapshot,
        ThreadSelectionStore store,
        int port)
    {
        Server = server;
        Service = service;
        _ingress = ingress;
        Sink = sink;
        Snapshot = snapshot;
        Store = store;
        Port = port;
        _client = new HttpClient();
    }

    public FakeProviderServer Server { get; }

    public RouterExecutionResponsesService Service { get; }

    public CollectingOutcomeSink Sink { get; }

    public EffectiveRouterConfigSnapshot Snapshot { get; }

    public ThreadSelectionStore Store { get; }

    public int Port { get; }

    /// <summary>Most recent upstream request body, or empty when none exists.</summary>
    public string UpstreamBody
        => Server.LastRequestBody is { } body ? Encoding.UTF8.GetString(body) : string.Empty;

    public static async Task<Hs1bRouterContext> StartAsync(bool threadSelectionEnabled = true)
    {
        var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, ProviderContractKit.SseFixtureBuilder.NonStreamJson("hs1b-runtime-ok")));

        var sink = new CollectingOutcomeSink();
        var resolver = new FakeSecretResolver();
        resolver.Configure("local_router", Hs1bRuntimeConfig.LocalTokenReferenceName, LocalToken);
        resolver.Configure(Hs1bRuntimeConfig.ProviderId, Hs1bRuntimeConfig.UpstreamSecretName, UpstreamSecret);

        EffectiveRouterConfigSnapshot snapshot = Hs1bRuntimeConfig.Snapshot(threadSelectionEnabled);
        var overrides = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [Hs1bRuntimeConfig.BaseUrlReference] = server.BaseUri.ToString(),
        };

        var clock = new SystemClock();

        // Exactly one store instance, exactly as the production host composes it.
        var store = new ThreadSelectionStore(Hs1bRuntimeConfig.Options(), clock, threadSelectionEnabled);

        RouterExecutionServiceFactoryResult serviceResult = RouterExecutionServiceFactory.Create(
            snapshot,
            resolver,
            transportHandler: new ProviderContractKit.LoopbackOnlyHandler(),
            endpointOverrides: overrides,
            passiveHealthPolicy: PassiveHealthPolicy.Default,
            outcomeSink: sink,
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
                ThreadSelection = store,
            });
        Assert.True(start.IsSuccess, start.Error?.Code);

        return new Hs1bRouterContext(
            server,
            service,
            start.Ingress!,
            sink,
            snapshot,
            store,
            start.Ingress!.ListenAddress!.Port);
    }

    public RequestContext CreateRequestContext(string threadId)
    {
        Assert.True(CanonicalThreadId.TryParse(threadId, out CanonicalThreadId? canonical));
        UuidV7 uuid = UuidV7.Parse("018f4a9b-0000-7000-8000-000000000001");
        return RequestContext.Create(
            RequestId.Create(uuid),
            TraceId.Create(uuid),
            Hs1bRuntimeConfig.ClientId,
            // Must stay inside the store's live TTL window, because the store
            // projects with its own wall clock.
            DateTimeOffset.UtcNow,
            "responses:invoke",
            configGeneration: Snapshot.ConfigGeneration,
            thread: new ThreadIdentity
            {
                ThreadId = canonical!,
                Ref = ThreadRef.From(canonical!),
                RequestKind = ThreadIdentity.TurnRequestKind,
            });
    }

    public Task<HttpResponseMessage> PostTurnAsync(string model, string threadId, string requestKind = "turn")
        => PostAsync(RequestBody(model), threadId, Metadata(threadId, requestKind));

    public async Task<HttpResponseMessage> PostAsync(string json, string? threadId, string? metadata)
    {
        using HttpRequestMessage request = new(HttpMethod.Post, $"http://127.0.0.1:{Port}/v1/responses")
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", LocalToken);
        if (threadId is not null)
        {
            request.Headers.TryAddWithoutValidation(ThreadIdentityParser.ThreadIdHeaderName, threadId);
        }

        if (metadata is not null)
        {
            request.Headers.TryAddWithoutValidation(ThreadIdentityParser.TurnMetadataHeaderName, metadata);
        }

        return await _client.SendAsync(request);
    }

    public async ValueTask DisposeAsync()
    {
        _client.Dispose();
        await _ingress.DisposeAsync();
        Service.Dispose();
        await Server.DisposeAsync();
    }

    public static string RequestBody(string model) => "{\"model\":\"" + model + "\",\"input\":\"hi\"}";

    public static string Metadata(string threadId, string requestKind)
        => "{\"thread_id\":\"" + threadId + "\",\"request_kind\":\"" + requestKind + "\"}";
}
