using System.Net;
using System.Net.Http.Headers;
using System.Text;
using ProviderContractKit;
using Router.CatalogProjection;
using Router.ClientAdapters.Responses;
using Router.Configuration;
using Router.Core.Abstractions;
using Router.Core.Ids;
using Router.Execution;
using Router.FakeProvider;
using Router.Health;
using Router.Host;
using Router.Ingress;
using Router.Metering;
using Router.Policies;
using Router.Secrets;
using Xunit;

namespace Router.Execution.Tests;

/// <summary>
/// LR-10R production metering E2E: the real Router execution stack
/// (RouteResolver + ProviderAdapterRegistry + provider harness + loopback fake
/// upstream) feeds canonical usage through the Responses ingress into
/// ProductionCompletionObserver and RequestMeteringService. Identity must come
/// exclusively from ResponsesServiceResult.Execution; no config/provider/model
/// guessing exists anywhere in the path.
/// </summary>
public sealed class Lr10RProductionExecutionMeteringE2ETests
{
    private const string MeteredCatalogModelId = "z-ai/glm-5.3";

    [Fact]
    public async Task Non_stream_real_execution_attributes_authoritative_usage_and_cost()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        await using ProductionRouterContext context = await StartAsync(
            spec,
            scenario: FakeProviderScenario.Json(200, NonStreamJsonWithUsage100_25()));
        try
        {
            using HttpResponseMessage response = await context.PostAsync(
                """{"model":"client-model-openrouter","input":"hi"}""");
            string body = await response.Content.ReadAsStringAsync();
            Assert.True(response.IsSuccessStatusCode, body);
            Assert.Contains("\"status\":\"completed\"", body, StringComparison.Ordinal);

            RequestMeteringRecord record = await WaitForMeteringRecordAsync(context.Metering, TimeSpan.FromSeconds(10));
            await AssertSingleRecordAsync(context.Metering);
            AssertMeteredRecord(record, spec, stream: false);

            ResponsesExecutionMetadata executed = Assert.Single(context.Sink.Executed);
            AssertMeteredExecution(executed, spec);
        }
        finally
        {
            await context.DisposeAsync();
        }
    }

    [Fact]
    public async Task Streaming_real_execution_binds_terminal_usage_to_pre_stream_identity_exactly_once()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        await using ProductionRouterContext context = await StartAsync(
            spec,
            scenario: FakeProviderScenario.Sse(200, StreamWithDeltasAndCompletedUsage100_25()));
        try
        {
            using HttpResponseMessage response = await context.PostAsync(
                """{"model":"client-model-openrouter","input":"hi","stream":true}""");
            string body = await response.Content.ReadAsStringAsync();
            Assert.True(response.IsSuccessStatusCode, body);
            Assert.Contains("response.completed", body, StringComparison.Ordinal);
            Assert.Contains("\"input_tokens\":100", body, StringComparison.Ordinal);
            Assert.Contains("\"output_tokens\":25", body, StringComparison.Ordinal);

            RequestMeteringRecord record = await WaitForMeteringRecordAsync(context.Metering, TimeSpan.FromSeconds(10));
            await AssertSingleRecordAsync(context.Metering);
            AssertMeteredRecord(record, spec, stream: true);

            ResponsesExecutionMetadata terminal = Assert.Single(context.Sink.Executed);
            AssertMeteredExecution(terminal, spec);
            Assert.NotNull(terminal.CompletedAt);
            Assert.True(terminal.ExecutionStartedAt <= terminal.CompletedAt!.Value);
        }
        finally
        {
            await context.DisposeAsync();
        }
    }

    [Fact]
    public async Task Interrupted_stream_without_final_usage_never_fabricates_zero_usage_or_cost()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        await using ProductionRouterContext context = await StartAsync(
            spec,
            scenario: FakeProviderScenario.Sse(200, StreamWithTerminalFailureWithoutUsage()));
        try
        {
            using HttpResponseMessage response = await context.PostAsync(
                """{"model":"client-model-openrouter","input":"hi","stream":true}""");
            _ = await response.Content.ReadAsStringAsync();

            // Give any (incorrect) completion path time to write a record.
            await Task.Delay(TimeSpan.FromMilliseconds(400));
            Assert.Empty(context.Metering.Store.Recent(20));
            Assert.Equal(0, context.Observer.DroppedJobCount);
        }
        finally
        {
            await context.DisposeAsync();
        }
    }

    [Fact]
    public async Task Retried_real_execution_records_one_logical_request_with_final_usage()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        var handler = new SequenceTransportHandler(
            [
                TransportResponse.UpstreamFailure(),
                TransportResponse.Success(NonStreamJsonWithUsage100_25()),
            ]);

        await using ProductionRouterContext context = await StartAsync(
            spec,
            scenario: null,
            transportHandler: handler,
            endpointOverrides: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                [spec.EndpointBaseUrlReference] = "http://127.0.0.1:9033",
            });
        try
        {
            using HttpResponseMessage response = await context.PostAsync(
                """{"model":"client-model-openrouter","input":"hi"}""");
            string body = await response.Content.ReadAsStringAsync();
            Assert.True(response.IsSuccessStatusCode, body);
            Assert.Contains("\"status\":\"completed\"", body, StringComparison.Ordinal);

            RequestMeteringRecord record = await WaitForMeteringRecordAsync(context.Metering, TimeSpan.FromSeconds(10));
            await AssertSingleRecordAsync(context.Metering);
            AssertMeteredRecord(record, spec, stream: false);

            ResponsesExecutionMetadata executed = Assert.Single(context.Sink.Executed);
            Assert.Equal(spec.ProviderId, executed.ProviderId);
            Assert.Equal(spec.RouteId, executed.RouteId);
            Assert.Equal(2, executed.AttemptCount);
            Assert.Equal(2, handler.Calls);
        }
        finally
        {
            await context.DisposeAsync();
        }
    }

    [Fact]
    public async Task Same_model_failover_metering_uses_only_the_final_successful_execution_identity()
    {
        ProviderExecutionSpec primary = ExecutionTestConfigFactory.OpenAiApi;
        ProviderExecutionSpec alternate = ExecutionTestConfigFactory.OpenRouter;
        const string clientModel = "shared-client-model";

        RouterRouteConfig routePrimary = ExecutionTestConfigFactory.Route(
            primary.ProviderId,
            "route.lr10r-failover-primary",
            priority: 1,
            healthState: "HEALTHY");
        RouterRouteConfig routeAlternate = ExecutionTestConfigFactory.Route(
            alternate.ProviderId,
            "route.lr10r-failover-alternate",
            priority: 2,
            healthState: "HEALTHY");

        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [routePrimary, routeAlternate],
            SafeHasherSha("lr10r-failover-metering"),
            new Dictionary<string, ModelRouteTestOverride>(StringComparer.Ordinal)
            {
                [routePrimary.ModelRouteId] = new ModelRouteTestOverride(clientModel, MeteredCatalogModelId, MeteredCatalogModelId),
                [routeAlternate.ModelRouteId] = new ModelRouteTestOverride(clientModel, MeteredCatalogModelId, MeteredCatalogModelId),
            });

        var handler = new PortRoutingTransportHandler(
            primaryPort: 9031,
            alternatePort: 9032);
        RouterExecutionPolicySet policies = new()
        {
            Failover = FailoverPolicy.Create(
                allowSameModelAlternateEndpoint: false,
                allowSameModelAlternateProvider: true,
                allowCrossModelFallback: false),
        };

        await using ProductionRouterContext context = await StartAsync(
            spec: null,
            scenario: null,
            snapshot: snapshot,
            policies: policies,
            transportHandler: handler,
            endpointOverrides: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                [ExecutionTestConfigFactory.EndpointBaseUrlReferenceFor(routePrimary.ProviderRouteId)] = "http://127.0.0.1:9031/v1",
                [ExecutionTestConfigFactory.EndpointBaseUrlReferenceFor(routeAlternate.ProviderRouteId)] = "http://127.0.0.1:9032",
            });
        try
        {
            using HttpResponseMessage response = await context.PostAsync(
                $$"""{"model":"{{clientModel}}","input":"hi"}""");
            string body = await response.Content.ReadAsStringAsync();
            Assert.True(response.IsSuccessStatusCode, body);

            RequestMeteringRecord record = await WaitForMeteringRecordAsync(context.Metering, TimeSpan.FromSeconds(10));
            await AssertSingleRecordAsync(context.Metering);
            Assert.Equal(alternate.ProviderId, record.ProviderId);
            Assert.Equal(routeAlternate.RouteId, record.RouteId);
            Assert.Equal(alternate.ModelRouteId, record.ModelRouteId);
            Assert.Equal(MeteredCatalogModelId, record.ModelId);
            Assert.Equal(MeteredCatalogModelId, record.UpstreamModelId);
            Assert.Equal(100, record.Usage!.InputTokens);
            Assert.Equal(25, record.Usage.OutputTokens);
            Assert.NotNull(record.CostEstimate);
            Assert.Equal(CostEstimateStatus.Complete, record.CostEstimate!.Status);

            ResponsesExecutionMetadata executed = Assert.Single(context.Sink.Executed);
            Assert.Equal(routeAlternate.RouteId, executed.RouteId);
            Assert.Equal(alternate.ProviderId, executed.ProviderId);
            Assert.Equal(alternate.ProviderRouteId, executed.ProviderRouteId);
            Assert.Equal(alternate.ModelRouteId, executed.ModelRouteId);
        }
        finally
        {
            await context.DisposeAsync();
        }
    }

    private static async Task<ProductionRouterContext> StartAsync(
        ProviderExecutionSpec? spec,
        FakeProviderScenario? scenario,
        EffectiveRouterConfigSnapshot? snapshot = null,
        RouterExecutionPolicySet? policies = null,
        HttpMessageHandler? transportHandler = null,
        IReadOnlyDictionary<string, string>? endpointOverrides = null)
    {
        FakeProviderServer? server = null;
        if (scenario is not null)
        {
            server = new FakeProviderServer();
            await server.StartAsync();
            server.SetScenario(scenario);
        }

        if (snapshot is null)
        {
            snapshot = ExecutionTestConfigFactory.Snapshot(
                [ExecutionTestConfigFactory.Route(spec!.ProviderId, spec.RouteId)],
                SafeHasherSha("lr10r-metering-e2e-" + spec.ProviderId),
                new Dictionary<string, ModelRouteTestOverride>(StringComparer.Ordinal)
                {
                    [spec.ModelRouteId] = new ModelRouteTestOverride(
                        spec.ClientModelId,
                        MeteredCatalogModelId,
                        MeteredCatalogModelId),
                });
        }

        var sink = new CollectingOutcomeSink();
        var resolver = new FakeSecretResolver();
        resolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", "lr10r-metering-token");
        if (spec is not null)
        {
            resolver.Configure(spec.ProviderId, spec.SecretEnvironmentName, "lr10r-metering-upstream-secret");
        }
        else
        {
            foreach (ProviderExecutionSpec providerSpec in ExecutionTestConfigFactory.AllSpecs)
            {
                resolver.Configure(
                    providerSpec.ProviderId,
                    providerSpec.SecretEnvironmentName,
                    "lr10r-metering-upstream-secret");
            }
        }

        var overrides = new Dictionary<string, string>(endpointOverrides ?? new Dictionary<string, string>(StringComparer.Ordinal), StringComparer.Ordinal);
        if (spec is not null && server is not null)
        {
            overrides[spec.EndpointBaseUrlReference] = new Uri(server.BaseUri, spec.FakeBasePath).ToString();
        }

        RouterExecutionServiceFactoryResult serviceResult = RouterExecutionServiceFactory.Create(
            snapshot,
            resolver,
            transportHandler: transportHandler ?? new LoopbackOnlyHandler(),
            policies: policies,
            endpointOverrides: overrides,
            passiveHealthPolicy: PassiveHealthPolicy.Default,
            outcomeSink: sink);
        Assert.True(
            serviceResult.IsSuccess,
            serviceResult.Error?.Code + ": " + serviceResult.Error?.Message + " (" + serviceResult.Error?.Param + ")");
        RouterExecutionResponsesService service = serviceResult.Service!;

        SystemClock clock = new();
        RequestMeteringService metering = new(pricing: LoadPricingSnapshot());
        ProductionCompletionObserver observer = new(metering, requestLog: null, clock);

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
            TokenReferenceName = "CODEX_LOCAL_ROUTER_TOKEN",
            Clients = snapshot.Config.Clients,
        };

        IngressStartResult start = await ResponsesIngress.StartAsync(
            options,
            service,
            resolver,
            clock,
            new UuidV7IdGenerator(clock),
            observer: observer);
        Assert.True(start.IsSuccess, start.Error?.Code);
        return new ProductionRouterContext(server, service, start.Ingress!, observer, metering, sink, start.Ingress!.ListenAddress!.Port);
    }

    private static void AssertMeteredRecord(RequestMeteringRecord record, ProviderExecutionSpec spec, bool stream)
    {
        Assert.Equal(RequestMeteringStatus.Recorded, record.Status);
        Assert.Equal(spec.ProviderId, record.ProviderId);
        Assert.Equal(spec.RouteId, record.RouteId);
        Assert.Equal(spec.ModelRouteId, record.ModelRouteId);
        Assert.Equal(MeteredCatalogModelId, record.ModelId);
        Assert.Equal(MeteredCatalogModelId, record.UpstreamModelId);
        Assert.Equal(100, record.Usage!.InputTokens);
        Assert.Equal(25, record.Usage.OutputTokens);
        Assert.Equal(125, record.Usage.TotalTokens);
        Assert.Equal(stream, record.Stream);
        Assert.NotNull(record.CostEstimate);
        Assert.Equal(0.0005m, record.CostEstimate!.InputCost);
        Assert.Equal(0.00075m, record.CostEstimate.OutputCost);
        Assert.Equal(0.00125m, record.CostEstimate.TotalCost);
        Assert.Equal(CostEstimateStatus.Complete, record.CostEstimate.Status);
        Assert.StartsWith("req_", record.RequestId, StringComparison.Ordinal);
        Assert.StartsWith("trc_", record.TraceId, StringComparison.Ordinal);
        Assert.True(record.DurationMs >= 0);
    }

    private static void AssertMeteredExecution(ResponsesExecutionMetadata metadata, ProviderExecutionSpec spec)
    {
        Assert.Equal(ExecutionTestConfigFactory.ClientId, metadata.ClientId);
        Assert.Equal(spec.RouteId, metadata.RouteId);
        Assert.Equal(spec.ProviderId, metadata.ProviderId);
        Assert.Equal(spec.ProviderRouteId, metadata.ProviderRouteId);
        Assert.Equal(spec.ModelRouteId, metadata.ModelRouteId);
        Assert.Equal(MeteredCatalogModelId, metadata.CatalogModelId);
        Assert.Equal(MeteredCatalogModelId, metadata.UpstreamModelId);
        Assert.Equal(spec.EndpointId, metadata.EndpointId);
        Assert.Equal(1, metadata.AttemptCount);
    }

    private static async Task AssertSingleRecordAsync(RequestMeteringService metering)
    {
        // Allow any duplicate completion attempt to land, then prove the
        // bounded store kept exactly one logical request.
        await Task.Delay(TimeSpan.FromMilliseconds(200)).ConfigureAwait(false);
        Assert.Single(metering.Store.Recent(50));
    }

    private static async Task<RequestMeteringRecord> WaitForMeteringRecordAsync(
        RequestMeteringService metering,
        TimeSpan timeout)
    {
        using CancellationTokenSource deadline = new(timeout);
        while (!deadline.IsCancellationRequested)
        {
            IReadOnlyList<RequestMeteringRecord> records = metering.Store.Recent(20);
            if (records.Count > 0)
            {
                return records[^1];
            }

            await Task.Delay(TimeSpan.FromMilliseconds(50), deadline.Token).ConfigureAwait(false);
        }

        Assert.Fail("No production metering record was written before timeout.");
        return null!;
    }

    private static PricingSnapshot LoadPricingSnapshot()
    {
        string fixture = Path.Combine(
            AppContext.BaseDirectory,
            "fixtures",
            "local-router",
            "v1",
            "metering",
            "catalog.v3.metering.json");
        byte[] bytes = File.ReadAllBytes(fixture);
        CatalogProjectionResult projection = ModelCatalogProjector.Project(bytes, "catalog.v3.metering.json", "test-sha");
        projection.Validate();
        PricingProjectionResult pricing = PricingProjector.Project(projection.Projection!, DateTimeOffset.UtcNow);
        Assert.True(pricing.IsSuccess);
        return pricing.Snapshot!;
    }

    private static string NonStreamJsonWithUsage100_25()
        => """
            {"id":"resp_lr10r_nonstream","object":"response","created_at":1752000000,"status":"completed","model":"fake-model","output":[],"usage":{"input_tokens":100,"output_tokens":25,"total_tokens":125}}
            """;

    private static string StreamWithDeltasAndCompletedUsage100_25()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + """{"type":"response.created","response":{"id":"resp_lr10r_stream","object":"response","status":"in_progress","model":"fake-model","output":[],"usage":null}}""",
            "event: response.output_text.delta\ndata: " + """{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"a"}""",
            "event: response.output_text.delta\ndata: " + """{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"b"}""",
            "event: response.completed\ndata: " + """{"type":"response.completed","response":{"id":"resp_lr10r_stream","object":"response","status":"completed","model":"fake-model","output":[],"usage":{"input_tokens":100,"output_tokens":25,"total_tokens":125}}}""",
        ]) + "\n\n";

    private static string StreamWithTerminalFailureWithoutUsage()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + """{"type":"response.created","response":{"id":"resp_lr10r_failed","object":"response","status":"in_progress","model":"fake-model","output":[],"usage":null}}""",
            "event: response.output_text.delta\ndata: " + """{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"partial"}""",
            "event: response.failed\ndata: " + """{"type":"response.failed","response":{"id":"resp_lr10r_failed","object":"response","status":"failed","model":"fake-model","output":[],"usage":null}}""",
        ]) + "\n\n";

    private static string SafeHasherSha(string value)
        => Router.Core.Support.SafeHasher.Sha256Hex(value);

    private sealed class ProductionRouterContext : IAsyncDisposable
    {
        private readonly FakeProviderServer? _server;
        private readonly RouterExecutionResponsesService _service;
        private readonly ResponsesIngress _ingress;
        private readonly HttpClient _client;
        private bool _disposed;

        public ProductionRouterContext(
            FakeProviderServer? server,
            RouterExecutionResponsesService service,
            ResponsesIngress ingress,
            ProductionCompletionObserver observer,
            RequestMeteringService metering,
            CollectingOutcomeSink sink,
            int port)
        {
            _server = server;
            _service = service;
            _ingress = ingress;
            Observer = observer;
            Metering = metering;
            Sink = sink;
            Port = port;
            _client = new HttpClient();
        }

        public ProductionCompletionObserver Observer { get; }

        public RequestMeteringService Metering { get; }

        public CollectingOutcomeSink Sink { get; }

        public int Port { get; }

        public async Task<HttpResponseMessage> PostAsync(string json)
        {
            using HttpRequestMessage request = new(HttpMethod.Post, $"http://127.0.0.1:{Port}/v1/responses")
            {
                Content = new StringContent(json, Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "lr10r-metering-token");
            return await _client.SendAsync(request);
        }

        public async ValueTask DisposeAsync()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _client.Dispose();
            await _ingress.DisposeAsync().ConfigureAwait(false);
            await Observer.DrainAsync(CancellationToken.None).ConfigureAwait(false);
            _service.Dispose();
            if (_server is not null)
            {
                await _server.DisposeAsync().ConfigureAwait(false);
            }
        }
    }

    private sealed class TransportResponse
    {
        private TransportResponse()
        {
        }

        public HttpStatusCode StatusCode { get; private init; }

        public string? JsonBody { get; private init; }

        public static TransportResponse Success(string json)
            => new() { StatusCode = HttpStatusCode.OK, JsonBody = json };

        public static TransportResponse UpstreamFailure()
            => new() { StatusCode = HttpStatusCode.ServiceUnavailable, JsonBody = null };
    }

    private sealed class SequenceTransportHandler : HttpMessageHandler
    {
        private readonly IReadOnlyList<TransportResponse> _responses;
        private int _calls;

        public SequenceTransportHandler(IReadOnlyList<TransportResponse> responses)
        {
            _responses = responses;
        }

        public int Calls => Volatile.Read(ref _calls);

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Assert.True(request.RequestUri!.IsLoopback, "Retry E2E transport must stay loopback.");
            int call = Interlocked.Increment(ref _calls) - 1;
            TransportResponse response = _responses[Math.Min(call, _responses.Count - 1)];
            HttpResponseMessage message = new(response.StatusCode)
            {
                Content = response.JsonBody is null
                    ? new ByteArrayContent([])
                    : new StringContent(response.JsonBody, Encoding.UTF8, "application/json"),
            };
            return Task.FromResult(message);
        }
    }

    private sealed class PortRoutingTransportHandler : HttpMessageHandler
    {
        private readonly int _primaryPort;
        private readonly int _alternatePort;

        public PortRoutingTransportHandler(int primaryPort, int alternatePort)
        {
            _primaryPort = primaryPort;
            _alternatePort = alternatePort;
        }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Assert.True(request.RequestUri!.IsLoopback, "Failover E2E transport must stay loopback.");
            bool alternate = request.RequestUri.Port == _alternatePort;
            Assert.True(
                request.RequestUri.Port == _primaryPort || alternate,
                "Unexpected endpoint port: " + request.RequestUri.Port);

            HttpResponseMessage message = alternate
                ? new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent(NonStreamJsonWithUsage100_25(), Encoding.UTF8, "application/json"),
                }
                : new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
                {
                    Content = new ByteArrayContent([]),
                };
            return Task.FromResult(message);
        }
    }
}
