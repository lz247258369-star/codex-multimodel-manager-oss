using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
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
using Router.Ingress.ControlPlane;
using Router.Metering;
using Router.Observability;
using Router.Secrets;
using Xunit;

namespace Router.Execution.Tests;

/// <summary>
/// LR-14P production composition E2E. A real canonical request flows through
/// RouteResolver + provider harness + loopback fake upstream into
/// ProductionCompletionObserver; the control-plane usage and recent-request
/// endpoints must observe the exact same store/log instances that production
/// writes. No manual store.Add is ever used to satisfy an E2E.
/// </summary>
public sealed class ControlPlaneProductionE2ETests
{
    private const string Sentinel = "CONTROL_PLANE_SECRET_SENTINEL_123";
    private const string MeteredCatalogModelId = "z-ai/glm-5.3";

    private static readonly JsonSerializerOptions ConfigWriteOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        WriteIndented = true,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    [Fact]
    public async Task Real_request_is_visible_in_control_plane_usage_and_recent_requests()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        ControlPlaneProductionContext context = await StartAsync(
            snapshot: EnabledSnapshotWithControlClients(spec),
            scenario: FakeProviderScenario.Json(200, NonStreamJsonWithUsage100_25()));
        await using (context)
        {
            using HttpResponseMessage response = await context.PostAsync(
                $$"""{"model":"{{spec.ClientModelId}}","input":"{{Sentinel}}"}""");
            string body = await response.Content.ReadAsStringAsync();
            Assert.True(response.IsSuccessStatusCode, body);

            RequestMeteringRecord record = await WaitForMeteringRecordAsync(context.Metering, TimeSpan.FromSeconds(10));

            using HttpResponseMessage usageResponse = await context.GetControlAsync("/v1/router/control-plane/usage?limit=20");
            string usageBody = await usageResponse.Content.ReadAsStringAsync();
            Assert.True(usageResponse.IsSuccessStatusCode, usageBody);
            Assert.Contains(record.RequestId, usageBody, StringComparison.Ordinal);
            Assert.DoesNotContain(Sentinel, usageBody, StringComparison.Ordinal);

            await WaitForRecentRequestAsync(context, record.RequestId, TimeSpan.FromSeconds(10));

            using HttpResponseMessage v1Status = await context.GetStatusAsync("/v1/router/status");
            string v1Body = await v1Status.Content.ReadAsStringAsync();
            Assert.True(v1Status.IsSuccessStatusCode, v1Body);
            Assert.Contains("\"schema_version\":1", v1Body, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task Streaming_real_request_produces_one_logical_usage_and_recent_record()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        ControlPlaneProductionContext context = await StartAsync(
            snapshot: EnabledSnapshotWithControlClients(spec),
            scenario: FakeProviderScenario.Sse(200, StreamWithDeltasAndCompletedUsage100_25()));
        await using (context)
        {
            using HttpResponseMessage response = await context.PostAsync(
                $$"""{"model":"{{spec.ClientModelId}}","input":"{{Sentinel}}","stream":true}""");
            string body = await response.Content.ReadAsStringAsync();
            Assert.True(response.IsSuccessStatusCode, body);
            Assert.Contains("response.completed", body, StringComparison.Ordinal);

            RequestMeteringRecord record = await WaitForMeteringRecordAsync(context.Metering, TimeSpan.FromSeconds(10));
            await Task.Delay(TimeSpan.FromMilliseconds(300));
            Assert.Single(context.Metering.Store.Recent(50));

            using HttpResponseMessage usageResponse = await context.GetControlAsync("/v1/router/control-plane/usage?limit=50");
            string usageBody = await usageResponse.Content.ReadAsStringAsync();
            Assert.True(usageResponse.IsSuccessStatusCode, usageBody);
            using JsonDocument usageJson = JsonDocument.Parse(usageBody);
            Assert.Equal(1, usageJson.RootElement.GetProperty("record_count").GetInt32());
            Assert.Equal(1, usageJson.RootElement.GetProperty("records").GetArrayLength());
            Assert.Contains(record.RequestId, usageBody, StringComparison.Ordinal);
            Assert.DoesNotContain(Sentinel, usageBody, StringComparison.Ordinal);

            await WaitForRecentRequestAsync(context, record.RequestId, TimeSpan.FromSeconds(10));
            using HttpResponseMessage recentResponse = await context.GetControlAsync("/v1/router/control-plane/requests?limit=50");
            string recentBody = await recentResponse.Content.ReadAsStringAsync();
            using JsonDocument recentJson = JsonDocument.Parse(recentBody);
            Assert.Equal(1, recentJson.RootElement.GetProperty("record_count").GetInt32());
            Assert.DoesNotContain(Sentinel, recentBody, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task Completed_request_without_provider_usage_stays_null_not_zero()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        ControlPlaneProductionContext context = await StartAsync(
            snapshot: EnabledSnapshotWithControlClients(spec),
            scenario: FakeProviderScenario.Json(200, NonStreamJsonWithoutUsage()));
        await using (context)
        {
            using HttpResponseMessage response = await context.PostAsync(
                $$"""{"model":"{{spec.ClientModelId}}","input":"hi"}""");
            Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());

            RequestMeteringRecord record = await WaitForMeteringRecordAsync(context.Metering, TimeSpan.FromSeconds(10));
            Assert.Equal(RequestMeteringStatus.UsageMissing, record.Status);
            Assert.NotNull(record.Usage);
            Assert.Null(record.Usage.InputTokens);
            Assert.Null(record.Usage.OutputTokens);
            Assert.Null(record.Usage.TotalTokens);

            using HttpResponseMessage usageResponse = await context.GetControlAsync("/v1/router/control-plane/usage?limit=20");
            string usageBody = await usageResponse.Content.ReadAsStringAsync();
            Assert.True(usageResponse.IsSuccessStatusCode, usageBody);
            using JsonDocument usageJson = JsonDocument.Parse(usageBody);
            JsonElement recordJson = usageJson.RootElement.GetProperty("records")[0];
            Assert.Equal("usage_missing", recordJson.GetProperty("metering_status").GetString());
            Assert.Equal(JsonValueKind.Null, recordJson.GetProperty("usage").ValueKind);
            Assert.Equal(JsonValueKind.Null, recordJson.GetProperty("cost_estimate").ValueKind);
            Assert.DoesNotContain("\"input_tokens\":0", usageBody, StringComparison.Ordinal);
            Assert.DoesNotContain("\"total_cost\":0", usageBody, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task Live_policy_mutation_changes_the_running_services_effective_policy_without_restart()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        EffectiveRouterConfigSnapshot initialSnapshot = EnabledSnapshotWithControlClients(spec);
        string defaultsJson = JsonSerializer.Serialize(
            initialSnapshot.Config,
            ConfigWriteOptions);

        MemoryExecutionFileSystem fileSystem = new();
        fileSystem.SeedFile(MemoryExecutionFileSystem.DefaultsPath, defaultsJson);
        LocalRouterConfigOperator configOperator = new(
            fileSystem,
            new SystemClock(),
            MemoryExecutionFileSystem.DefaultsPath,
            MemoryExecutionFileSystem.UserConfigPath);

        var transportHandler = new ResettableCountingTransportHandler();
        ControlPlaneProductionContext context = await StartAsync(
            snapshot: initialSnapshot,
            scenario: null,
            transportHandler: transportHandler,
            endpointOverrides: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                [spec.EndpointBaseUrlReference] = "http://127.0.0.1:9033",
            },
            configOperator: configOperator);
        await using (context)
        {
            transportHandler.FailuresForNextRequest = 1;
            using HttpResponseMessage response = await context.PostAsync(
                $$"""{"model":"{{spec.ClientModelId}}","input":"hi"}""");
            Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());
            ResponsesExecutionMetadata executed = Assert.Single(context.Sink.Executed);
            Assert.Equal(2, executed.AttemptCount);

            string generation0 = await context.ReadControlGenerationAsync();
            using HttpResponseMessage policyRead = await context.GetControlAsync("/v1/router/control-plane/policy");
            string policyBody = await policyRead.Content.ReadAsStringAsync();
            Assert.True(policyRead.IsSuccessStatusCode, policyBody);
            Assert.Contains("\"effective_retry_source\":\"safe_defaults\"", policyBody, StringComparison.Ordinal);

            using HttpResponseMessage mutationResponse = await context.PutJsonAsync(
                "/v1/router/control-plane/policy",
                RetryMutationBody(generation0, maxAttempts: 3));
            string mutationBody = await mutationResponse.Content.ReadAsStringAsync();
            Assert.True(mutationResponse.IsSuccessStatusCode, mutationBody);
            Assert.Contains("\"max_attempts\":3", mutationBody, StringComparison.Ordinal);

            transportHandler.FailuresForNextRequest = 2;
            using HttpResponseMessage secondResponse = await context.PostAsync(
                $$"""{"model":"{{spec.ClientModelId}}","input":"hi"}""");
            Assert.True(secondResponse.IsSuccessStatusCode, await secondResponse.Content.ReadAsStringAsync());
            Assert.Equal(2, context.Sink.Executed.Count);
            Assert.Equal(3, context.Sink.Executed[1].AttemptCount);

            using HttpResponseMessage updatedPolicyRead = await context.GetControlAsync("/v1/router/control-plane/policy");
            string updatedPolicyBody = await updatedPolicyRead.Content.ReadAsStringAsync();
            Assert.True(updatedPolicyRead.IsSuccessStatusCode, updatedPolicyBody);
            Assert.Contains("\"max_attempts\":3", updatedPolicyBody, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task Live_feature_disable_fails_closed_and_re_enable_resumes_the_same_host()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        EffectiveRouterConfigSnapshot initialSnapshot = EnabledSnapshotWithControlClients(spec);
        string defaultsJson = JsonSerializer.Serialize(initialSnapshot.Config, ConfigWriteOptions);
        MemoryExecutionFileSystem fileSystem = new();
        fileSystem.SeedFile(MemoryExecutionFileSystem.DefaultsPath, defaultsJson);
        LocalRouterConfigOperator configOperator = new(
            fileSystem,
            new SystemClock(),
            MemoryExecutionFileSystem.DefaultsPath,
            MemoryExecutionFileSystem.UserConfigPath);
        var transportHandler = new CountingTransportHandler();
        ControlPlaneProductionContext context = await StartAsync(
            snapshot: initialSnapshot,
            scenario: null,
            transportHandler: transportHandler,
            endpointOverrides: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                [spec.EndpointBaseUrlReference] = "http://127.0.0.1:9034",
            },
            configOperator: configOperator);
        await using (context)
        {
            using HttpResponseMessage first = await context.PostAsync(
                $$"""{"model":"{{spec.ClientModelId}}","input":"hi"}""");
            Assert.True(first.IsSuccessStatusCode, await first.Content.ReadAsStringAsync());
            int callsAfterFirst = transportHandler.Calls;
            Assert.Equal(1, callsAfterFirst);

            string generation0 = await context.ReadControlGenerationAsync();
            using HttpResponseMessage disableResponse = await context.PutJsonAsync(
                "/v1/router/control-plane/feature",
                FeatureBody(generation0, enabled: false));
            string disableBody = await disableResponse.Content.ReadAsStringAsync();
            Assert.True(disableResponse.IsSuccessStatusCode, disableBody);

            using HttpResponseMessage statusResponse = await context.GetControlAsync("/v1/router/control-plane/status");
            string statusBody = await statusResponse.Content.ReadAsStringAsync();
            using JsonDocument statusJson = JsonDocument.Parse(statusBody);
            Assert.False(statusJson.RootElement.GetProperty("local_router_enabled").GetBoolean());

            using HttpResponseMessage blocked = await context.PostAsync(
                $$"""{"model":"{{spec.ClientModelId}}","input":"hi"}""");
            string blockedBody = await blocked.Content.ReadAsStringAsync();
            Assert.Equal(HttpStatusCode.ServiceUnavailable, blocked.StatusCode);
            Assert.Contains("router_disabled", blockedBody, StringComparison.Ordinal);
            Assert.Equal(callsAfterFirst, transportHandler.Calls);

            string generation1 = context.CurrentGeneration;
            using HttpResponseMessage enableResponse = await context.PutJsonAsync(
                "/v1/router/control-plane/feature",
                FeatureBody(generation1, enabled: true));
            Assert.True(enableResponse.IsSuccessStatusCode, await enableResponse.Content.ReadAsStringAsync());

            using HttpResponseMessage resumed = await context.PostAsync(
                $$"""{"model":"{{spec.ClientModelId}}","input":"hi"}""");
            Assert.True(resumed.IsSuccessStatusCode, await resumed.Content.ReadAsStringAsync());
            Assert.Equal(callsAfterFirst + 1, transportHandler.Calls);
        }
    }

    [Fact]
    public async Task Live_control_plane_reflects_real_passive_health_and_breaker_gap()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        var transportHandler = new CountingTransportHandler(failuresPerRequest: 999);
        ControlPlaneProductionContext context = await StartAsync(
            snapshot: EnabledSnapshotWithControlClients(spec),
            scenario: null,
            transportHandler: transportHandler,
            endpointOverrides: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                [spec.EndpointBaseUrlReference] = "http://127.0.0.1:9035",
            });
        await using (context)
        {
            // Three provider failures trip the default passive-health threshold
            // (FailureThreshold = 3) through the real production execution path.
            for (int index = 0; index < 3; index++)
            {
                using HttpResponseMessage failed = await context.PostAsync(
                    $$"""{"model":"{{spec.ClientModelId}}","input":"hi"}""");
                Assert.False(failed.IsSuccessStatusCode);
            }

            using HttpResponseMessage statusResponse = await context.GetControlAsync("/v1/router/control-plane/status");
            string statusBody = await statusResponse.Content.ReadAsStringAsync();
            Assert.True(statusResponse.IsSuccessStatusCode, statusBody);
            using JsonDocument statusJson = JsonDocument.Parse(statusBody);
            JsonElement health = statusJson.RootElement.GetProperty("health_summary");
            Assert.True(health.GetProperty("available").GetBoolean());
            Assert.True(health.GetProperty("unhealthy_count").GetInt32() >= 1);
            Assert.Contains("CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP", statusBody, StringComparison.Ordinal);

            using HttpResponseMessage policyResponse = await context.GetControlAsync("/v1/router/control-plane/policy");
            string policyBody = await policyResponse.Content.ReadAsStringAsync();
            Assert.True(policyResponse.IsSuccessStatusCode, policyBody);
            Assert.Contains("\"effective_state\":\"disabled\"", policyBody, StringComparison.Ordinal);
            Assert.Contains("\"mutation_available\":false", policyBody, StringComparison.Ordinal);
        }
    }

    private static async Task<ControlPlaneProductionContext> StartAsync(
        EffectiveRouterConfigSnapshot snapshot,
        FakeProviderScenario? scenario,
        HttpMessageHandler? transportHandler = null,
        IReadOnlyDictionary<string, string>? endpointOverrides = null,
        LocalRouterConfigOperator? configOperator = null)
    {
        if (configOperator is not null)
        {
            LocalRouterConfigReadResult operatorRead = await configOperator
                .ReadAsync(CancellationToken.None)
                .ConfigureAwait(false);
            Assert.True(operatorRead.IsSuccess, operatorRead.Error?.Code);
            snapshot = snapshot with
            {
                Config = operatorRead.View!.Config,
                ConfigGeneration = operatorRead.View.ConfigGeneration,
            };
        }

        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        FakeProviderServer? server = null;
        if (scenario is not null)
        {
            server = new FakeProviderServer();
            await server.StartAsync();
            server.SetScenario(scenario);
        }

        var sink = new CollectingOutcomeSink();
        var resolver = new FakeSecretResolver();
        resolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", "lr14p-control-token");
        resolver.Configure(spec.ProviderId, spec.SecretEnvironmentName, "lr14p-control-upstream-secret");

        var overrides = new Dictionary<string, string>(
            endpointOverrides ?? new Dictionary<string, string>(StringComparer.Ordinal),
            StringComparer.Ordinal);
        if (server is not null)
        {
            overrides[spec.EndpointBaseUrlReference] = server.BaseUri.ToString();
        }

        CurrentRouterState currentState = new(
            PublishedRouterState.From(snapshot.Config, snapshot.ConfigGeneration));
        configOperator = configOperator?.WithPublicationSink(currentState);
        RouterExecutionServiceFactoryResult serviceResult = RouterExecutionServiceFactory.Create(
            snapshot,
            resolver,
            transportHandler: transportHandler ?? new LoopbackOnlyHandler(),
            endpointOverrides: overrides,
            passiveHealthPolicy: PassiveHealthPolicy.Default,
            outcomeSink: sink,
            policySource: new CurrentRouterExecutionPolicySource(currentState));
        Assert.True(serviceResult.IsSuccess, serviceResult.Error?.Code);
        RouterExecutionResponsesService service = serviceResult.Service!;

        SystemClock clock = new();
        IRouterHealthSnapshotSource? healthSource = service.PassiveHealth is { } passiveHealth
            ? new PassiveHealthSnapshotSource(passiveHealth, () => clock.UtcNow)
            : null;
        RequestMeteringService metering = new(pricing: LoadPricingSnapshot());
        MemoryObservabilityFileSystem logFileSystem = new();
        DurableRequestLog requestLog = new(
            ObservabilityOptions.Create(@"C:\lr14p-e2e\logs", 256 * 1024, 16, TimeSpan.FromDays(7), 64),
            logFileSystem,
            () => clock.UtcNow);
        ProductionCompletionObserver observer = new(metering, requestLog, clock);

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
            observer: observer,
            controlPlane: new ControlPlaneRuntimeServices
            {
                Metering = metering,
                RequestLog = requestLog,
                ConfigOperator = configOperator,
                CurrentState = currentState,
                Health = healthSource,
            });
        Assert.True(start.IsSuccess, start.Error?.Code);
        return new ControlPlaneProductionContext(
            server,
            service,
            start.Ingress!,
            observer,
            metering,
            requestLog,
            sink,
            start.Ingress!.ListenAddress!.Port,
            currentState);
    }

    private static EffectiveRouterConfigSnapshot EnabledSnapshotWithControlClients(ProviderExecutionSpec spec)
    {
        EffectiveRouterConfigSnapshot snapshot = SnapshotWithControlClients(spec);
        return snapshot with
        {
            Config = snapshot.Config with
            {
                Mode = RouterMode.Router,
                LocalRouter = snapshot.Config.LocalRouter with { Enabled = true },
            },
        };
    }

    private static EffectiveRouterConfigSnapshot SnapshotWithControlClients(ProviderExecutionSpec spec)
        => ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            Router.Core.Support.SafeHasher.Sha256Hex("lr14p-control-" + spec.ProviderId),
            new Dictionary<string, ModelRouteTestOverride>(StringComparer.Ordinal)
            {
                [spec.ModelRouteId] = new ModelRouteTestOverride(
                    spec.ClientModelId,
                    MeteredCatalogModelId,
                    MeteredCatalogModelId),
            },
            additionalClients:
            [
                new ClientConfig
                {
                    ClientId = "client.control_plane",
                    AdapterId = "adapter.client.control_plane.responses.v1",
                    Enabled = true,
                    AuthScope = "router:control-plane",
                    Capabilities = ["responses"],
                    Version = 1,
                },
                new ClientConfig
                {
                    ClientId = "client.local_status",
                    AdapterId = "adapter.client.local_status.responses.v1",
                    Enabled = true,
                    AuthScope = "router:status",
                    Capabilities = ["responses"],
                    Version = 1,
                },
            ]);

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

    private static async Task WaitForRecentRequestAsync(
        ControlPlaneProductionContext context,
        string requestId,
        TimeSpan timeout)
    {
        using CancellationTokenSource deadline = new(timeout);
        while (!deadline.IsCancellationRequested)
        {
            using HttpResponseMessage response = await context.GetControlAsync("/v1/router/control-plane/requests?limit=50");
            string body = await response.Content.ReadAsStringAsync();
            Assert.True(response.IsSuccessStatusCode, body);
            if (body.Contains(requestId, StringComparison.Ordinal))
            {
                return;
            }

            await Task.Delay(TimeSpan.FromMilliseconds(100), deadline.Token).ConfigureAwait(false);
        }

        Assert.Fail("Recent durable request endpoint never exposed the real request id before timeout.");
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
        => """{"id":"resp_lr14p","object":"response","created_at":1752000000,"status":"completed","model":"fake-model","output":[],"usage":{"input_tokens":100,"output_tokens":25,"total_tokens":125}}""";

    private static string NonStreamJsonWithoutUsage()
        => """{"id":"resp_lr14p_no_usage","object":"response","created_at":1752000000,"status":"completed","model":"fake-model","output":[],"usage":null}""";

    private static string StreamWithDeltasAndCompletedUsage100_25()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + """{"type":"response.created","response":{"id":"resp_lr14p_stream","object":"response","status":"in_progress","model":"fake-model","output":[],"usage":null}}""",
            "event: response.output_text.delta\ndata: " + """{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"a"}""",
            "event: response.output_text.delta\ndata: " + """{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"b"}""",
            "event: response.completed\ndata: " + """{"type":"response.completed","response":{"id":"resp_lr14p_stream","object":"response","status":"completed","model":"fake-model","output":[],"usage":{"input_tokens":100,"output_tokens":25,"total_tokens":125}}}""",
        ]) + "\n\n";

    private static string RetryMutationBody(string generation, int maxAttempts)
        => "{\"schema_version\":1,\"expected_generation\":\"" + generation
            + "\",\"policy_id\":\"policy.retry-safe-default\",\"retry\":{\"schema_version\":1,\"max_attempts\":"
            + maxAttempts
            + ",\"base_delay_ms\":50,\"max_delay_ms\":500,\"jitter\":0,\"respect_retry_after\":false,\"max_retry_after_ms\":1000}}";

    private static string FeatureBody(string generation, bool enabled)
        => "{\"schema_version\":1,\"expected_generation\":\"" + generation
            + "\",\"enabled\":" + (enabled ? "true" : "false") + "}";

    private sealed class ControlPlaneProductionContext : IAsyncDisposable
    {
        private readonly FakeProviderServer? _server;
        private readonly RouterExecutionResponsesService _service;
        private readonly ResponsesIngress _ingress;
        private readonly ProductionCompletionObserver _observer;
        private readonly HttpClient _client;
        private bool _disposed;

        public ControlPlaneProductionContext(
            FakeProviderServer? server,
            RouterExecutionResponsesService service,
            ResponsesIngress ingress,
            ProductionCompletionObserver observer,
            RequestMeteringService metering,
            DurableRequestLog requestLog,
            CollectingOutcomeSink sink,
            int port,
            CurrentRouterState currentState)
        {
            _server = server;
            _service = service;
            _ingress = ingress;
            _observer = observer;
            Metering = metering;
            RequestLog = requestLog;
            Sink = sink;
            Port = port;
            CurrentState = currentState;
            _client = new HttpClient();
        }

        public RequestMeteringService Metering { get; }

        public DurableRequestLog RequestLog { get; }

        public CollectingOutcomeSink Sink { get; }

        public int Port { get; }

        public CurrentRouterState CurrentState { get; }

        public string CurrentGeneration => CurrentState.Snapshot.ConfigGeneration;

        public async Task<HttpResponseMessage> PostAsync(string json)
        {
            using HttpRequestMessage request = new(HttpMethod.Post, $"http://127.0.0.1:{Port}/v1/responses")
            {
                Content = new StringContent(json, Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "lr14p-control-token");
            return await _client.SendAsync(request);
        }

        public async Task<HttpResponseMessage> GetControlAsync(string pathAndQuery)
            => await SendAsync(HttpMethod.Get, pathAndQuery, null);

        public async Task<HttpResponseMessage> GetStatusAsync(string pathAndQuery)
            => await SendAsync(HttpMethod.Get, pathAndQuery, null);

        public async Task<HttpResponseMessage> PutJsonAsync(string path, string json)
            => await SendAsync(HttpMethod.Put, path, json);

        public async Task<string> ReadControlGenerationAsync()
        {
            using HttpResponseMessage response = await GetControlAsync("/v1/router/control-plane/status");
            string body = await response.Content.ReadAsStringAsync();
            Assert.True(response.IsSuccessStatusCode, body);
            using JsonDocument json = JsonDocument.Parse(body);
            return json.RootElement.GetProperty("config_generation").GetString()!;
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
            await _observer.DrainAsync(CancellationToken.None).ConfigureAwait(false);
            _service.Dispose();
            if (_server is not null)
            {
                await _server.DisposeAsync().ConfigureAwait(false);
            }
        }

        private async Task<HttpResponseMessage> SendAsync(HttpMethod method, string pathAndQuery, string? json)
        {
            using HttpRequestMessage request = new(method, $"http://127.0.0.1:{Port}{pathAndQuery}");
            if (json is not null)
            {
                request.Content = new StringContent(json, Encoding.UTF8, "application/json");
            }

            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "lr14p-control-token");
            return await _client.SendAsync(request);
        }
    }

    private sealed class CountingTransportHandler : HttpMessageHandler
    {
        private readonly int _failuresPerRequest;
        private int _calls;

        public CountingTransportHandler(int failuresPerRequest = 0)
        {
            _failuresPerRequest = failuresPerRequest;
        }

        public int Calls => Volatile.Read(ref _calls);

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Assert.True(request.RequestUri!.IsLoopback, "Policy E2E transport must stay loopback.");
            _ = Interlocked.Increment(ref _calls);
            bool failed = _failuresPerRequest > 0;
            HttpResponseMessage message = failed
                ? new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
                {
                    Content = new ByteArrayContent([]),
                }
                : new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(NonStreamJsonWithUsage100_25(), Encoding.UTF8, "application/json"),
            };
            return Task.FromResult(message);
        }
    }

    private sealed class ResettableCountingTransportHandler : HttpMessageHandler
    {
        private int _calls;
        private int _failuresForNextRequest;

        public int Calls => Volatile.Read(ref _calls);

        public int FailuresForNextRequest
        {
            get => Volatile.Read(ref _failuresForNextRequest);
            set => Volatile.Write(ref _failuresForNextRequest, value);
        }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Assert.True(request.RequestUri!.IsLoopback, "Policy E2E transport must stay loopback.");
            _ = Interlocked.Increment(ref _calls);
            bool failed = Interlocked.Decrement(ref _failuresForNextRequest) >= 0;
            HttpResponseMessage message = failed
                ? new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
                {
                    Content = new ByteArrayContent([]),
                }
                : new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent(NonStreamJsonWithUsage100_25(), Encoding.UTF8, "application/json"),
                };
            return Task.FromResult(message);
        }
    }
}

/// <summary>In-memory IFileSystem for LR-14P operator-backed E2E config roots.</summary>
internal sealed class MemoryExecutionFileSystem : IFileSystem
{
    public const string DefaultsPath = @"C:\lr14p-e2e\config\defaults.json";
    public const string UserConfigPath = @"C:\lr14p-e2e\config\user.json";

    private readonly Dictionary<string, byte[]> _files = new(StringComparer.Ordinal);
    private readonly object _sync = new();

    public void SeedFile(string path, string content)
    {
        lock (_sync)
        {
            _files[path] = Encoding.UTF8.GetBytes(content);
        }
    }

    public bool FileExists(string path)
    {
        lock (_sync)
        {
            return _files.ContainsKey(path);
        }
    }

    public bool DirectoryExists(string path) => FileExists(path);

    public void CreateDirectory(string path)
    {
    }

    public IEnumerable<string> EnumerateFiles(string directory, string pattern)
        => _files.Keys.ToArray();

    public void DeleteFile(string path)
    {
        lock (_sync)
        {
            _files.Remove(path);
        }
    }

    public void CopyFile(string sourcePath, string destinationPath, bool overwrite)
        => throw new NotSupportedException();

    public void MoveFile(string sourcePath, string destinationPath, bool overwrite)
    {
        lock (_sync)
        {
            if (!_files.TryGetValue(sourcePath, out byte[]? content))
            {
                throw new FileNotFoundException(sourcePath);
            }

            _files.Remove(sourcePath);
            _files[destinationPath] = content;
        }
    }

    public void ReplaceFile(string sourcePath, string destinationPath)
    {
        lock (_sync)
        {
            if (!_files.TryGetValue(sourcePath, out byte[]? content))
            {
                throw new FileNotFoundException(sourcePath);
            }

            _files.Remove(sourcePath);
            _files[destinationPath] = content;
        }
    }

    public Task<string> ReadAllTextAsync(string path, CancellationToken cancellationToken)
    {
        lock (_sync)
        {
            return Task.FromResult(
                _files.TryGetValue(path, out byte[]? content)
                    ? Encoding.UTF8.GetString(content)
                    : throw new FileNotFoundException(path));
        }
    }

    public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken)
    {
        lock (_sync)
        {
            return Task.FromResult(
                _files.TryGetValue(path, out byte[]? content)
                    ? content.ToArray()
                    : throw new FileNotFoundException(path));
        }
    }

    public Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken)
    {
        lock (_sync)
        {
            if (_files.ContainsKey(path))
            {
                throw new IOException("Temp path already exists.");
            }

            _files[path] = content.ToArray();
        }

        return Task.CompletedTask;
    }

    public string CreateTempPath(string directory)
        => Path.Combine(directory, ".tmp-" + Guid.NewGuid().ToString("N"));
}

/// <summary>In-memory IObservabilityFileSystem for durable-log composition E2E.</summary>
internal sealed class MemoryObservabilityFileSystem : IObservabilityFileSystem
{
    private readonly Dictionary<string, byte[]> _contents = new(StringComparer.Ordinal);

    public bool FileExists(string path) => _contents.ContainsKey(path);

    public bool DirectoryExists(string path)
        => _contents.Keys.Any(key => key.StartsWith(path.TrimEnd('\\') + "\\", StringComparison.Ordinal));

    public void CreateDirectory(string path)
    {
    }

    public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken)
        => Task.FromResult(_contents[path]);

    public Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken)
    {
        _contents[path] = content;
        return Task.CompletedTask;
    }

    public string CreateTempPath(string directory)
        => Path.Combine(directory, ".tmp-" + Guid.NewGuid().ToString("N"));

    public void MoveFile(string sourcePath, string destinationPath, bool overwrite)
    {
        if (_contents.Remove(sourcePath, out byte[]? content))
        {
            _contents[destinationPath] = content;
        }
    }

    public void DeleteFile(string path)
    {
        _contents.Remove(path);
    }

    public IEnumerable<string> EnumerateFiles(string directory, string pattern)
        => _contents.Keys.Where(key =>
            key.StartsWith(directory.TrimEnd('\\') + "\\", StringComparison.Ordinal)
            && key.EndsWith(".json", StringComparison.Ordinal));

    public long GetFileSize(string path)
        => _contents.TryGetValue(path, out byte[]? content) ? content.LongLength : 0;

    public DateTimeOffset GetLastWriteTimeUtc(string path) => DateTimeOffset.UtcNow;
}
