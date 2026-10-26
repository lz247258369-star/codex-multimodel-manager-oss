using System.Net;
using System.Text;
using ProviderContractKit;
using Router.ClientAdapters.Responses;
using Router.Configuration;
using Router.Core.Abstractions;
using Router.Core.Context;
using Router.Core.Ids;
using Router.Core.Support;
using Router.Policies;
using Router.Secrets;
using Xunit;

namespace Router.Execution.Tests;

public sealed class RouterExecutionPolicySafetyTests
{
    [Fact]
    public async Task Retry_engine_produces_bounded_pre_output_attempts_on_same_request()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenAiApi;
        string generation = SafeHasher.Sha256Hex("retry-e2e");
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            generation);

        var handler = new CountingSequenceHandler(call =>
            call == 1
                ? JsonResponse(HttpStatusCode.ServiceUnavailable, string.Empty)
                : JsonResponse(HttpStatusCode.OK, SseFixtureBuilder.NonStreamJson("retry-ok")));
        await using ServiceHarness harness = CreateHarness(snapshot, spec, handler, secretValue: "retry-secret");

        ResponsesServiceResult result = await harness.InvokeAsync(spec.ClientModelId);

        Assert.Null(result.Error);
        Assert.Equal(2, handler.Calls);
        Assert.Equal(2, handler.Bodies.Length);
        Assert.Equal(handler.Bodies[0], handler.Bodies[1]);
        Assert.Equal(2, result.Execution!.AttemptCount);
        MessageOutputItem output = Assert.IsType<MessageOutputItem>(result.Response!.Output.Single());
        Assert.Equal("retry-ok", output.Content.Single().Text);
    }

    [Fact]
    public async Task Post_output_provider_error_never_retries()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.MiMo;
        string generation = SafeHasher.Sha256Hex("post-output-e2e");
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            generation);

        const string sse = """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"partial"}

            event: error
            data: {"type":"error","code":"provider_error","message":"safe provider error"}

            """;

        var handler = new CountingSequenceHandler(_ => JsonResponse(HttpStatusCode.OK, sse, "text/event-stream"));
        var outcomeSink = new CollectingOutcomeSink();
        await using ServiceHarness harness = CreateHarness(snapshot, spec, handler, secretValue: "stream-secret", outcomeSink: outcomeSink);

        ResponsesServiceResult result = await harness.InvokeAsync(spec.ClientModelId, stream: true);
        var events = new List<CanonicalEvent>();
        Assert.NotNull(result.EventStream);
        Assert.NotNull(result.Execution);
        Assert.Equal(spec.ProviderId, result.Execution!.ProviderId);
        Assert.Equal(spec.RouteId, result.Execution.RouteId);
        Assert.Equal(spec.ModelRouteId, result.Execution.ModelRouteId);
        Assert.Equal(spec.UpstreamModelId, result.Execution.UpstreamModelId);
        Assert.Null(result.Execution.CompletedAt);
        Assert.Empty(outcomeSink.Executed);
        await foreach (CanonicalEvent canonicalEvent in result.EventStream!)
        {
            events.Add(canonicalEvent);
        }

        Assert.Equal(2, events.Count);
        Assert.Equal("response.output_text.delta", events[0].Type);
        Assert.True(events[1].IsTerminal);
        Assert.Equal(1, handler.Calls);
        ResponsesExecutionMetadata terminal = Assert.Single(outcomeSink.Executed);
        Assert.Equal(1, terminal.AttemptCount);
        Assert.Equal(spec.ProviderId, terminal.ProviderId);
        Assert.Equal(spec.RouteId, terminal.RouteId);
        Assert.Equal(spec.ModelRouteId, terminal.ModelRouteId);
        Assert.Equal(spec.UpstreamModelId, terminal.UpstreamModelId);
        Assert.NotNull(terminal.CompletedAt);
    }

    [Fact]
    public async Task Failover_default_off_never_calls_alternate_same_model_route()
    {
        ProviderExecutionSpec primary = ExecutionTestConfigFactory.OpenAiApi;
        ProviderExecutionSpec alternate = ExecutionTestConfigFactory.OpenRouter;
        string generation = SafeHasher.Sha256Hex("failover-default-e2e");
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [
                ExecutionTestConfigFactory.Route(primary.ProviderId, "route.openai-shared", priority: 1),
                ExecutionTestConfigFactory.Route(alternate.ProviderId, "route.openrouter-alt", priority: 2),
            ],
            generation,
            new Dictionary<string, ModelRouteTestOverride>(StringComparer.Ordinal)
            {
                [primary.ModelRouteId] = new("shared-client-model", "shared-catalog-openai", "upstream-openai-shared"),
                [alternate.ModelRouteId] = new("shared-client-model", "shared-catalog-openrouter", "upstream-openrouter-shared"),
            });

        var handler = new CountingSequenceHandler(_ => JsonResponse(HttpStatusCode.ServiceUnavailable, string.Empty));
        await using ServiceHarness harness = CreateHarness(snapshot, [primary, alternate], handler, secretValue: "failover-secret");

        ResponsesServiceResult result = await harness.InvokeAsync("shared-client-model");

        Assert.NotNull(result.Error);
        Assert.Equal("provider_5xx", result.Error!.Code);
        Assert.Equal(2, handler.Calls);
        Assert.DoesNotContain(handler.Bodies, static body => BodyText(body).Contains("upstream-openrouter-shared", StringComparison.Ordinal));
        Assert.Equal(2, result.Execution!.AttemptCount);
    }

    [Fact]
    public async Task Cross_model_route_is_never_selected_even_when_failover_enabled()
    {
        ProviderExecutionSpec primary = ExecutionTestConfigFactory.OpenAiApi;
        ProviderExecutionSpec otherModel = ExecutionTestConfigFactory.OpenRouter;
        string generation = SafeHasher.Sha256Hex("cross-model-e2e");
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [
                ExecutionTestConfigFactory.Route(primary.ProviderId, "route.openai-shared", priority: 1),
                ExecutionTestConfigFactory.Route(otherModel.ProviderId, "route.openrouter-other-model", priority: 2),
            ],
            generation,
            new Dictionary<string, ModelRouteTestOverride>(StringComparer.Ordinal)
            {
                [primary.ModelRouteId] = new("shared-client-model", "shared-catalog-openai", "upstream-openai-shared"),
                [otherModel.ModelRouteId] = new("other-client-model", "other-catalog-openrouter", "upstream-openrouter-other"),
            });

        RouterExecutionPolicySet policies = new()
        {
            Failover = FailoverPolicy.Create(
                allowSameModelAlternateEndpoint: true,
                allowSameModelAlternateProvider: false,
                allowCrossModelFallback: false),
        };

        var handler = new CountingSequenceHandler(_ => JsonResponse(HttpStatusCode.ServiceUnavailable, string.Empty));
        await using ServiceHarness harness = CreateHarness(snapshot, [primary, otherModel], handler, "cross-secret", policies);

        ResponsesServiceResult result = await harness.InvokeAsync("shared-client-model");

        Assert.NotNull(result.Error);
        Assert.Equal("provider_5xx", result.Error!.Code);
        Assert.Equal(2, handler.Calls);
        Assert.DoesNotContain(handler.Bodies, static body => BodyText(body).Contains("upstream-openrouter-other", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Missing_provider_secret_fails_closed_with_zero_outbound()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.ModelStudio;
        string generation = SafeHasher.Sha256Hex("missing-secret-e2e");
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            generation);

        var handler = new CountingSequenceHandler(_ => JsonResponse(HttpStatusCode.OK, SseFixtureBuilder.NonStreamJson("never")));
        await using ServiceHarness harness = CreateHarness(snapshot, spec, handler, secretValue: null);

        ResponsesServiceResult result = await harness.InvokeAsync(spec.ClientModelId);

        Assert.NotNull(result.Error);
        Assert.Equal("secret_missing", result.Error!.Code);
        Assert.Equal(0, handler.Calls);
        Assert.Null(result.Execution);
    }

    [Fact]
    public async Task Unknown_model_fails_before_any_outbound_call()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        string generation = SafeHasher.Sha256Hex("unknown-model-e2e");
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            generation);

        var handler = new CountingSequenceHandler(_ => JsonResponse(HttpStatusCode.OK, SseFixtureBuilder.NonStreamJson("never")));
        await using ServiceHarness harness = CreateHarness(snapshot, spec, handler, secretValue: "secret");

        ResponsesServiceResult result = await harness.InvokeAsync("model-that-does-not-exist");

        Assert.NotNull(result.Error);
        Assert.Equal("unknown_model", result.Error!.Code);
        Assert.Equal(0, handler.Calls);
    }

    [Fact]
    public async Task Disabled_route_fails_before_any_outbound_call()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenAiApi;
        string generation = SafeHasher.Sha256Hex("disabled-route-e2e");
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId, enabled: false)],
            generation);

        var handler = new CountingSequenceHandler(_ => JsonResponse(HttpStatusCode.OK, SseFixtureBuilder.NonStreamJson("never")));
        await using ServiceHarness harness = CreateHarness(snapshot, spec, handler, secretValue: "secret");

        ResponsesServiceResult result = await harness.InvokeAsync(spec.ClientModelId);

        Assert.NotNull(result.Error);
        Assert.Equal("route_disabled", result.Error!.Code);
        Assert.Equal(0, handler.Calls);
    }

    [Fact]
    public async Task Health_ineligible_route_fails_before_any_outbound_call()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.MiMo;
        string generation = SafeHasher.Sha256Hex("health-ineligible-e2e");
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId, healthState: "UNHEALTHY")],
            generation);

        var handler = new CountingSequenceHandler(_ => JsonResponse(HttpStatusCode.OK, SseFixtureBuilder.NonStreamJson("never")));
        await using ServiceHarness harness = CreateHarness(snapshot, spec, handler, secretValue: "secret");

        ResponsesServiceResult result = await harness.InvokeAsync(spec.ClientModelId);

        Assert.NotNull(result.Error);
        Assert.Equal("route_ineligible", result.Error!.Code);
        Assert.Equal(0, handler.Calls);
    }

    [Fact]
    public async Task Unauthorized_client_route_fails_before_any_outbound_call()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        string generation = SafeHasher.Sha256Hex("unauthorized-client-e2e");
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            generation,
            clientAllowedRouteIds: ["route.some-other-route"]);

        var handler = new CountingSequenceHandler(_ => JsonResponse(HttpStatusCode.OK, SseFixtureBuilder.NonStreamJson("never")));
        await using ServiceHarness harness = CreateHarness(snapshot, spec, handler, secretValue: "secret");

        ResponsesServiceResult result = await harness.InvokeAsync(spec.ClientModelId);

        Assert.NotNull(result.Error);
        Assert.Equal("route_not_allowed", result.Error!.Code);
        Assert.Equal(0, handler.Calls);
    }

    [Fact]
    public async Task Capability_mismatch_fails_before_any_outbound_call()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.ModelStudio;
        string generation = SafeHasher.Sha256Hex("capability-mismatch-e2e");
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            generation,
            new Dictionary<string, ModelRouteTestOverride>(StringComparer.Ordinal)
            {
                [spec.ModelRouteId] = new(spec.ClientModelId, Capabilities: ["text", "usage"]),
            });

        var handler = new CountingSequenceHandler(_ => JsonResponse(HttpStatusCode.OK, SseFixtureBuilder.NonStreamJson("never")));
        await using ServiceHarness harness = CreateHarness(snapshot, spec, handler, secretValue: "secret");

        ResponsesServiceResult result = await harness.InvokeAsync(spec.ClientModelId, stream: true);

        Assert.NotNull(result.Error);
        Assert.Equal("unsupported_capability", result.Error!.Code);
        Assert.Equal(0, handler.Calls);
    }

    [Fact]
    public void Ambiguous_model_mapping_fails_closed_at_registry_build()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        string generation = SafeHasher.Sha256Hex("ambiguous-model-e2e");
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [
                ExecutionTestConfigFactory.Route(spec.ProviderId, "route.openrouter-exact", priority: 1),
                ExecutionTestConfigFactory.Route(spec.ProviderId, "route.openrouter-alias", priority: 2, instance: "mm-openrouter-alias"),
            ],
            generation,
            new Dictionary<string, ModelRouteTestOverride>(StringComparer.Ordinal)
            {
                [spec.ModelRouteId] = new("exact-client-model"),
                ["model-route.mm-openrouter-alias"] = new("alias-client-model", Aliases: ["exact-client-model"]),
            });

        RouterExecutionServiceFactoryResult result = RouterExecutionServiceFactory.Create(
            snapshot,
            new FakeSecretResolver(),
            transportHandler: new CountingSequenceHandler(_ => JsonResponse(HttpStatusCode.OK, "{}")));

        Assert.False(result.IsSuccess);
        Assert.Equal("ambiguous_model", result.Error!.Code);
    }

    [Fact]
    public async Task Metadata_reports_resolved_route_not_config_order()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        string routeB = "route.openrouter-b-selected";
        string generation = SafeHasher.Sha256Hex("authoritative-selection-e2e");
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [
                ExecutionTestConfigFactory.Route(spec.ProviderId, "route.openrouter-a-config-first", priority: 10),
                ExecutionTestConfigFactory.Route(spec.ProviderId, routeB, priority: 5),
            ],
            generation);

        var handler = new CountingSequenceHandler(_ => JsonResponse(HttpStatusCode.OK, SseFixtureBuilder.NonStreamJson("selected-b")));
        await using ServiceHarness harness = CreateHarness(snapshot, spec, handler, secretValue: "selection-secret");

        ResponsesServiceResult result = await harness.InvokeAsync(spec.ClientModelId);

        Assert.Null(result.Error);
        Assert.Equal(routeB, result.Execution!.RouteId);
        Assert.Equal(spec.ProviderId, result.Execution.ProviderId);
        Assert.Equal(1, handler.Calls);
    }

    private static ServiceHarness CreateHarness(
        EffectiveRouterConfigSnapshot snapshot,
        ProviderExecutionSpec spec,
        CountingSequenceHandler handler,
        string? secretValue,
        RouterExecutionPolicySet? policies = null,
        CollectingOutcomeSink? outcomeSink = null)
        => CreateHarness(snapshot, [spec], handler, secretValue, policies, outcomeSink);

    private static ServiceHarness CreateHarness(
        EffectiveRouterConfigSnapshot snapshot,
        IReadOnlyList<ProviderExecutionSpec> specs,
        CountingSequenceHandler handler,
        string? secretValue,
        RouterExecutionPolicySet? policies = null,
        CollectingOutcomeSink? outcomeSink = null)
    {
        var resolver = new FakeSecretResolver();
        foreach (ProviderExecutionSpec spec in specs)
        {
            resolver.Configure(spec.ProviderId, spec.SecretEnvironmentName, secretValue);
        }

        var overrides = new Dictionary<string, string>(StringComparer.Ordinal);
        int port = 9;
        foreach (ProviderExecutionSpec spec in specs)
        {
            overrides[spec.EndpointBaseUrlReference] = new Uri(
                new Uri("http://127.0.0.1:" + port++ + "/", UriKind.Absolute),
                spec.FakeBasePath).ToString();
        }

        RouterExecutionServiceFactoryResult result = RouterExecutionServiceFactory.Create(
            snapshot,
            resolver,
            transportHandler: handler,
            policies: policies,
            endpointOverrides: overrides,
            outcomeSink: outcomeSink);
        Assert.True(result.IsSuccess, result.Error?.Code + ": " + result.Error?.Message + " (" + result.Error?.Param + ")");
        return new ServiceHarness(result.Service!, snapshot);
    }

    private static HttpResponseMessage JsonResponse(HttpStatusCode status, string body, string contentType = "application/json")
        => new(status)
        {
            Content = new StringContent(body, Encoding.UTF8, contentType),
        };

    private static string BodyText(byte[] body)
        => Encoding.UTF8.GetString(body);

    private sealed class ServiceHarness : IAsyncDisposable
    {
        public ServiceHarness(
            RouterExecutionResponsesService service,
            EffectiveRouterConfigSnapshot snapshot)
        {
            Service = service;
            Snapshot = snapshot;
        }

        public RouterExecutionResponsesService Service { get; }

        public EffectiveRouterConfigSnapshot Snapshot { get; }

        public async Task<ResponsesServiceResult> InvokeAsync(string model, bool stream = false)
        {
            UuidV7 uuid = UuidV7.Parse("018f4a9b-0000-7000-8000-000000000002");
            using CancellationTokenSource cancellation = new();
            RequestContext requestContext = RequestContext.Create(
                RequestId.Create(uuid),
                TraceId.Create(uuid),
                ExecutionTestConfigFactory.ClientId,
                DateTimeOffset.UnixEpoch,
                "responses:invoke",
                configGeneration: Snapshot.ConfigGeneration,
                cancellationToken: cancellation.Token);
            CanonicalResponsesRequest request = new()
            {
                Model = model,
                Input = [],
                Stream = stream,
            };
            return await Service.InvokeAsync(request, requestContext, cancellation.Token);
        }

        public ValueTask DisposeAsync()
        {
            Service.Dispose();
            return ValueTask.CompletedTask;
        }
    }

    private sealed class CountingSequenceHandler : HttpMessageHandler
    {
        private readonly Func<int, HttpResponseMessage> _responseFactory;
        private readonly object _sync = new();
        private readonly List<byte[]> _bodies = [];
        private int _calls;

        public CountingSequenceHandler(Func<int, HttpResponseMessage> responseFactory)
        {
            _responseFactory = responseFactory ?? throw new ArgumentNullException(nameof(responseFactory));
        }

        public int Calls
        {
            get
            {
                lock (_sync)
                {
                    return _calls;
                }
            }
        }

        public byte[][] Bodies
        {
            get
            {
                lock (_sync)
                {
                    return [.. _bodies];
                }
            }
        }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            if (request.RequestUri is not { } uri
                || !ProviderAdapters.Abstractions.UpstreamEndpoint.IsLoopbackHost(uri.Host))
            {
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadGateway)
                {
                    ReasonPhrase = "network-guard: non-loopback target rejected",
                });
            }

            byte[]? body = request.Content is null ? null : ReadBody(request.Content);
            int call;
            lock (_sync)
            {
                _calls++;
                call = _calls;
                if (body is not null)
                {
                    _bodies.Add(body);
                }
            }

            return Task.FromResult(_responseFactory(call));
        }

        private static byte[] ReadBody(HttpContent content)
        {
            using MemoryStream stream = new();
            using (Stream source = content.ReadAsStream())
            {
                source.CopyTo(stream);
            }

            return stream.ToArray();
        }
    }
}
