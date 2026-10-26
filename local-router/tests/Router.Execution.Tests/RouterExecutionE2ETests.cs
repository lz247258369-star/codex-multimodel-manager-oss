using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using ProviderContractKit;
using Router.ClientAdapters.Responses;
using Router.Configuration;
using Router.Core.Abstractions;
using Router.Core.Context;
using Router.Core.Ids;
using Router.FakeProvider;
using Router.Health;
using Router.Ingress;
using Router.Secrets;
using Xunit;

namespace Router.Execution.Tests;

public sealed class RouterExecutionE2ETests
{
    [Fact]
    public async Task OpenRouter_production_composition_e2e_non_stream()
        => await AssertProductionCompositionAsync(ExecutionTestConfigFactory.OpenRouter);

    [Fact]
    public async Task ModelStudio_production_composition_e2e_non_stream()
        => await AssertProductionCompositionAsync(ExecutionTestConfigFactory.ModelStudio);

    [Fact]
    public async Task OpenAiApi_production_composition_e2e_non_stream()
        => await AssertProductionCompositionAsync(ExecutionTestConfigFactory.OpenAiApi);

    [Fact]
    public async Task MiMo_production_composition_e2e_non_stream()
        => await AssertProductionCompositionAsync(ExecutionTestConfigFactory.MiMo);

    [Fact]
    public async Task Streaming_e2e_preserves_text_usage_and_authoritative_identity()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        await using ExecutionRouterContext context = await StartRouterAsync(
            spec,
            FakeProviderScenario.Sse(200, SseFixtureBuilder.BasicStream("streamed-execution-ok")));
        try
        {
            using HttpResponseMessage response = await context.PostAsync(
                "{\"model\":\"" + spec.ClientModelId + "\",\"input\":\"hi\",\"stream\":true}");
            string body = await response.Content.ReadAsStringAsync();

            Assert.True(response.IsSuccessStatusCode, body);
            Assert.Contains("streamed-execution-ok", body);
            Assert.Contains("response.completed", body);
            Assert.Contains("\"input_tokens\":7", body);

            ResponsesExecutionMetadata metadata = Assert.Single(context.Sink.Executed);
            AssertAuthoritativeIdentity(metadata, spec);
            Assert.Equal(1, metadata.AttemptCount);
            Assert.Equal(ExpectedUpstreamPath(spec), context.Server.LastRequestPath);
            Assert.Contains(spec.UpstreamModelId, Encoding.UTF8.GetString(context.Server.LastRequestBody!));
        }
        finally
        {
            await context.DisposeAsync();
        }
    }

    [Fact]
    public async Task Cancellation_propagates_without_retry_or_provider_failure_signal()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenAiApi;
        var delayed = new FakeProviderScenario
        {
            StatusCode = 200,
            Body = Encoding.UTF8.GetBytes(SseFixtureBuilder.NonStreamJson("cancelled-late")),
            ContentType = "application/json",
            DelayBeforeFirstByte = TimeSpan.FromSeconds(3),
        };
        await using ExecutionRouterContext context = await StartRouterAsync(spec, delayed);
        try
        {
            using CancellationTokenSource cancellation = new();
            cancellation.CancelAfter(TimeSpan.FromMilliseconds(120));

            RequestContext requestContext = context.CreateRequestContext(cancellation.Token);
            var request = new CanonicalResponsesRequest
            {
                Model = spec.ClientModelId,
                Input = [],
                Stream = false,
            };

            ResponsesServiceResult result = await context.Service.InvokeAsync(request, requestContext, cancellation.Token);
            Assert.NotNull(result.Error);
            Assert.Equal("cancelled", result.Error!.Code);
            Assert.NotNull(result.Execution);
            Assert.Equal(1, result.Execution!.AttemptCount);
        }
        finally
        {
            await context.DisposeAsync();
        }
    }

    private static async Task AssertProductionCompositionAsync(ProviderExecutionSpec spec)
    {
        await using ExecutionRouterContext context = await StartRouterAsync(
            spec,
            FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson("production-" + spec.ProviderId)));
        try
        {
            using HttpResponseMessage response = await context.PostAsync(
                "{\"model\":\"" + spec.ClientModelId + "\",\"input\":\"hi\"}");
            string body = await response.Content.ReadAsStringAsync();

            Assert.True(response.IsSuccessStatusCode, body);
            using JsonDocument document = JsonDocument.Parse(body);
            Assert.Equal("completed", document.RootElement.GetProperty("status").GetString());
            Assert.Equal(12, document.RootElement.GetProperty("usage").GetProperty("total_tokens").GetInt32());

            ResponsesExecutionMetadata metadata = Assert.Single(context.Sink.Executed);
            AssertAuthoritativeIdentity(metadata, spec);
            Assert.Equal(1, metadata.AttemptCount);

            Assert.Equal(ExpectedUpstreamPath(spec), context.Server.LastRequestPath);
            Assert.Contains(spec.UpstreamModelId, Encoding.UTF8.GetString(context.Server.LastRequestBody!));
        }
        finally
        {
            await context.DisposeAsync();
        }
    }

    private static void AssertAuthoritativeIdentity(ResponsesExecutionMetadata metadata, ProviderExecutionSpec spec)
    {
        Assert.Equal(spec.ProviderId, metadata.ProviderId);
        Assert.Equal(spec.RouteId, metadata.RouteId);
        Assert.Equal(spec.ProviderRouteId, metadata.ProviderRouteId);
        Assert.Equal(spec.ModelRouteId, metadata.ModelRouteId);
        Assert.Equal(spec.ClientModelId, metadata.ClientModelId);
        Assert.Equal(spec.CatalogModelId, metadata.CatalogModelId);
        Assert.Equal(spec.UpstreamModelId, metadata.UpstreamModelId);
        Assert.Equal(spec.EndpointId, metadata.EndpointId);
        Assert.Equal(ExecutionTestConfigFactory.ClientId, metadata.ClientId);
    }

    private static string ExpectedUpstreamPath(ProviderExecutionSpec spec)
        => spec.ProviderId switch
        {
            "mm_openrouter" => "/api/v1/responses",
            "mm_modelstudio" => "/compatible-mode/v1/responses",
            _ => "/v1/responses",
        };

    private static async Task<ExecutionRouterContext> StartRouterAsync(
        ProviderExecutionSpec spec,
        FakeProviderScenario scenario)
    {
        var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(scenario);

        var sink = new CollectingOutcomeSink();
        var resolver = new FakeSecretResolver();
        resolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", "execution-test-token");
        resolver.Configure(spec.ProviderId, spec.SecretEnvironmentName, "execution-test-upstream-secret");

        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            spec.Generation);

        var overrides = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [spec.EndpointBaseUrlReference] = new Uri(server.BaseUri, spec.FakeBasePath).ToString(),
        };

        RouterExecutionServiceFactoryResult serviceResult = RouterExecutionServiceFactory.Create(
            snapshot,
            resolver,
            transportHandler: new LoopbackOnlyHandler(),
            endpointOverrides: overrides,
            passiveHealthPolicy: PassiveHealthPolicy.Default,
            outcomeSink: sink);
        Assert.True(serviceResult.IsSuccess, serviceResult.Error?.Code + ": " + serviceResult.Error?.Message + " (" + serviceResult.Error?.Param + ")");
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
            TokenReferenceName = "CODEX_LOCAL_ROUTER_TOKEN",
            Clients = snapshot.Config.Clients,
        };

        IngressStartResult start = await ResponsesIngress.StartAsync(
            options,
            service,
            resolver,
            new SystemClock(),
            new UuidV7IdGenerator(new SystemClock()));
        Assert.True(start.IsSuccess);

        return new ExecutionRouterContext(server, service, start.Ingress!, sink, snapshot, start.Ingress!.ListenAddress!.Port);
    }

    private sealed class ExecutionRouterContext : IAsyncDisposable
    {
        private readonly ResponsesIngress _ingress;
        private readonly HttpClient _client;

        public ExecutionRouterContext(
            FakeProviderServer server,
            RouterExecutionResponsesService service,
            ResponsesIngress ingress,
            CollectingOutcomeSink sink,
            EffectiveRouterConfigSnapshot snapshot,
            int port)
        {
            Server = server;
            Service = service;
            _ingress = ingress;
            Sink = sink;
            Snapshot = snapshot;
            Port = port;
            _client = new HttpClient();
        }

        public FakeProviderServer Server { get; }

        public RouterExecutionResponsesService Service { get; }

        public CollectingOutcomeSink Sink { get; }

        public EffectiveRouterConfigSnapshot Snapshot { get; }

        public int Port { get; }

        public RequestContext CreateRequestContext(CancellationToken cancellationToken)
        {
            UuidV7 uuid = UuidV7.Parse("018f4a9b-0000-7000-8000-000000000001");
            return RequestContext.Create(
                RequestId.Create(uuid),
                TraceId.Create(uuid),
                ExecutionTestConfigFactory.ClientId,
                DateTimeOffset.UnixEpoch,
                "responses:invoke",
                configGeneration: Snapshot.ConfigGeneration,
                cancellationToken: cancellationToken);
        }

        public async Task<HttpResponseMessage> PostAsync(string json)
        {
            using HttpRequestMessage request = new(HttpMethod.Post, $"http://127.0.0.1:{Port}/v1/responses")
            {
                Content = new StringContent(json, Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "execution-test-token");
            return await _client.SendAsync(request);
        }

        public async ValueTask DisposeAsync()
        {
            _client.Dispose();
            await _ingress.DisposeAsync();
            Service.Dispose();
            await Server.DisposeAsync();
        }
    }
}

/// <summary>Thread-safe execution metadata collector for tests.</summary>
public sealed class CollectingOutcomeSink : IExecutionOutcomeSink
{
    private readonly object _sync = new();
    private readonly List<ResponsesExecutionMetadata> _executed = [];

    public IReadOnlyList<ResponsesExecutionMetadata> Executed
    {
        get
        {
            lock (_sync)
            {
                return _executed.ToArray();
            }
        }
    }

    public void OnExecuted(ResponsesExecutionMetadata metadata)
    {
        lock (_sync)
        {
            _executed.Add(metadata);
        }
    }
}
