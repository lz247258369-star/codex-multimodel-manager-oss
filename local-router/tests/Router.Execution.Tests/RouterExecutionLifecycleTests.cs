using System.Net;
using System.Text;
using System.Text.Json;
using ProviderContractKit;
using Router.CircuitBreaker;
using Router.ClientAdapters.Responses;
using Router.Configuration;
using Router.Core.Abstractions;
using Router.Core.Context;
using Router.Core.Errors;
using Router.Core.Ids;
using Router.Core.Support;
using Router.Health;
using Router.Policies;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.OpenRouter;
using Router.Registries;
using Router.Secrets;
using Xunit;

namespace Router.Execution.Tests;

/// <summary>
/// Real-behavior execution lifecycle tests. Every request goes through the
/// production execution service (route resolver, registries, harness, and
/// upstream transport over an explicit loopback-only handler); no real
/// provider, key, or network access exists.
/// </summary>
public sealed class RouterExecutionLifecycleTests
{
    private const string NetworkGuardPhrase = "network-guard: non-loopback target rejected";

    [Fact]
    public void OpenRouter_production_endpoint_resolves_without_override_to_exact_responses_uri()
    {
        // Production OpenRouter endpoint resolution must not depend on any test
        // override, and this contract check never sends a request: it resolves
        // the repository-approved base URL and composes the adapter request
        // path exactly as the transport would.
        var source = new RouterExecutionEndpointSource();
        var endpoint = new EndpointRegistryEntry
        {
            EndpointId = "endpoint.openrouter-production",
            BaseUrlRef = RouterExecutionEndpoints.OpenRouterBaseUrlReference,
            Enabled = true,
            DataBoundary = "provider-default",
            TlsRequired = true,
            Priority = 100,
            Weight = 100,
            Version = 1,
        };

        Result<UpstreamEndpoint, RouterError> resolved = source.Resolve(endpoint);
        Assert.True(resolved.IsSuccess, resolved.Error?.Code + ": " + resolved.Error?.Message);
        Assert.False(resolved.Value!.LoopbackTestOnly);

        UpstreamRequest request = UpstreamRequest.Create("POST", resolved.Value, OpenRouterCapabilities.UpstreamPath);
        Assert.Equal("https://openrouter.ai/api/v1/responses", request.FullUri.AbsoluteUri);
    }

    [Fact]
    public async Task Passive_health_feedback_moves_unhealthy_route_out_of_resolution()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        RouterRouteConfig routeA = ExecutionTestConfigFactory.Route(
            spec.ProviderId,
            "route.openrouter-health-a",
            priority: 1,
            healthState: "HEALTHY",
            instance: "mm-openrouter-a");
        RouterRouteConfig routeB = ExecutionTestConfigFactory.Route(
            spec.ProviderId,
            "route.openrouter-health-b",
            priority: 2,
            healthState: "HEALTHY",
            instance: "mm-openrouter-b") with { ModelRouteId = routeA.ModelRouteId };

        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [routeA, routeB],
            SafeHasher.Sha256Hex("health-feedback-e2e"));

        int portA = 9011;
        int portB = 9012;
        RouterExecutionPolicySet policies = new()
        {
            Retry = RetryPolicy.Create(
                maxAttempts: 1,
                baseDelay: TimeSpan.FromMilliseconds(100),
                maxDelay: TimeSpan.FromMilliseconds(100),
                jitter: 0m,
                respectRetryAfter: false,
                maxRetryAfter: TimeSpan.FromMilliseconds(100)),
        };
        var handler = new LifecycleHandler((uri, _) =>
            uri.Port == portA
                ? JsonResponse(HttpStatusCode.ServiceUnavailable, string.Empty)
                : JsonResponse(HttpStatusCode.OK, SseFixtureBuilder.NonStreamJson("healthy-b")));
        await using LifecycleContext context = CreateContext(
            snapshot,
            [spec],
            handler,
            secretValue: "health-secret",
            policies: policies,
            endpointOverrides: Overrides(
                (routeA.ProviderRouteId, portA),
                (routeB.ProviderRouteId, portB)));

        ResponsesServiceResult first = await context.InvokeAsync(spec.ClientModelId);
        ResponsesServiceResult second = await context.InvokeAsync(spec.ClientModelId);
        ResponsesServiceResult third = await context.InvokeAsync(spec.ClientModelId);

        Assert.Equal(routeA.RouteId, first.Execution!.RouteId);
        Assert.Equal(routeA.RouteId, second.Execution!.RouteId);
        Assert.Equal(routeA.RouteId, third.Execution!.RouteId);

        RouteHealthProjectionEntry unhealthyA = RouteEntry(context, routeA.RouteId);
        Assert.Equal(RouteHealthState.Unhealthy, unhealthyA.State);
        Assert.Equal(3, unhealthyA.FailureCount);

        ResponsesServiceResult fourth = await context.InvokeAsync(spec.ClientModelId);
        Assert.Null(fourth.Error);
        Assert.Equal(routeB.RouteId, fourth.Execution!.RouteId);
        Assert.Equal(routeB.ProviderRouteId, fourth.Execution.ProviderRouteId);
        Assert.Equal(routeB.ModelRouteId, fourth.Execution.ModelRouteId);
        Assert.Equal(4, handler.Calls);

        RouteHealthProjectionEntry healthyB = RouteEntry(context, routeB.RouteId);
        Assert.Equal(RouteHealthState.Healthy, healthyB.State);
        Assert.Equal(1, healthyB.SuccessCount);
    }

    [Fact]
    public async Task Streaming_completion_records_terminal_success_exactly_once()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenAiApi;
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            SafeHasher.Sha256Hex("stream-success-e2e"));

        var handler = new LifecycleHandler((_, _) => JsonResponse(HttpStatusCode.OK, SseFixtureBuilder.BasicStream("case-a"), "text/event-stream"));
        await using LifecycleContext context = CreateContext(
            snapshot,
            [spec],
            handler,
            secretValue: "stream-secret",
            passiveHealth: PassiveHealthPolicy.Default,
            breaker: CircuitBreakerPolicy.Create(enabled: true, failureThreshold: 2, cooldown: TimeSpan.FromSeconds(1), halfOpenMaxTrials: 1));

        ResponsesServiceResult result = await context.InvokeAsync(spec.ClientModelId, stream: true);
        Assert.NotNull(result.EventStream);
        Assert.NotNull(result.Execution);
        AssertAuthoritativeIdentity(result.Execution!, spec);
        Assert.Null(result.Execution!.CompletedAt);
        Assert.Empty(context.Sink.Executed);

        int events = 0;
        await foreach (CanonicalEvent _ in result.EventStream!)
        {
            events++;
        }

        Assert.True(events > 0);
        Assert.Equal(1, handler.Calls);
        RouteHealthProjectionEntry entry = RouteEntry(context, spec.RouteId);
        Assert.Equal(RouteHealthState.Healthy, entry.State);
        Assert.Equal(1, entry.SuccessCount);
        Assert.Equal(0, entry.FailureCount);
        Assert.Equal(0, BreakerEntry(context, spec).FailureCount);
        ResponsesExecutionMetadata terminal = Assert.Single(context.Sink.Executed);
        AssertSameIdentity(result.Execution!, terminal);
        Assert.Equal(1, terminal.AttemptCount);
        Assert.NotNull(terminal.CompletedAt);
        Assert.True(terminal.ExecutionStartedAt <= terminal.CompletedAt!.Value);
    }

    [Fact]
    public async Task Streaming_terminal_error_records_failure_without_retry_or_failover()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenAiApi;
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            SafeHasher.Sha256Hex("stream-failure-e2e"));

        const string sse = """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"partial"}

            event: error
            data: {"type":"error","code":"provider_error","message":"safe provider error"}

            """;

        var handler = new LifecycleHandler((_, _) => JsonResponse(HttpStatusCode.OK, sse, "text/event-stream"));
        await using LifecycleContext context = CreateContext(
            snapshot,
            [spec],
            handler,
            secretValue: "stream-secret",
            passiveHealth: PassiveHealthPolicy.Create(2, 1, TimeSpan.Zero, TimeSpan.FromMinutes(5)),
            breaker: CircuitBreakerPolicy.Create(enabled: true, failureThreshold: 2, cooldown: TimeSpan.FromSeconds(1), halfOpenMaxTrials: 1));

        ResponsesServiceResult result = await context.InvokeAsync(spec.ClientModelId, stream: true);
        Assert.NotNull(result.Execution);
        AssertAuthoritativeIdentity(result.Execution!, spec);
        Assert.Null(result.Execution!.CompletedAt);
        Assert.Empty(context.Sink.Executed);
        var events = new List<CanonicalEvent>();
        await foreach (CanonicalEvent canonicalEvent in result.EventStream!)
        {
            events.Add(canonicalEvent);
        }

        Assert.Equal(2, events.Count);
        Assert.Equal("response.output_text.delta", events[0].Type);
        Assert.True(events[1].IsTerminal);
        Assert.Equal(1, handler.Calls);

        RouteHealthProjectionEntry entry = RouteEntry(context, spec.RouteId);
        Assert.Equal(RouteHealthState.Degraded, entry.State);
        Assert.Equal(1, entry.FailureCount);
        Assert.Equal(0, entry.SuccessCount);
        Assert.Equal(1, BreakerEntry(context, spec).FailureCount);
        Assert.Equal(CircuitBreakerState.Closed, BreakerEntry(context, spec).State);

        ResponsesExecutionMetadata terminal = Assert.Single(context.Sink.Executed);
        AssertSameIdentity(result.Execution!, terminal);
        Assert.Equal(1, terminal.AttemptCount);
        Assert.NotNull(terminal.CompletedAt);
    }

    [Fact]
    public async Task Streaming_client_cancellation_never_pollutes_passive_health()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenAiApi;
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            SafeHasher.Sha256Hex("stream-cancel-e2e"));

        string frameOne = "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_cancel\",\"status\":\"in_progress\",\"model\":\"fake-model\",\"output\":[]}}\n\n";
        string frameTwo = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"partial\"}\n\n";
        var handler = new CancelAfterContentHandler(
            [Encoding.UTF8.GetBytes(frameOne), Encoding.UTF8.GetBytes(frameTwo)],
            SseFixtureBuilder.NonStreamJson("after-cancel-ok"));
        await using LifecycleContext context = CreateContext(
            snapshot,
            [spec],
            handler,
            secretValue: "stream-secret",
            passiveHealth: PassiveHealthPolicy.Default,
            policies: new RouterExecutionPolicySet
            {
                Timeout = TimeoutPolicy.Create(
                    connectTimeout: TimeSpan.FromMilliseconds(100),
                    firstByteTimeout: TimeSpan.FromMilliseconds(200),
                    idleTimeout: TimeSpan.FromMilliseconds(1500),
                    attemptTimeout: TimeSpan.FromSeconds(30),
                    totalTimeout: TimeSpan.FromMinutes(10)),
            });

        using CancellationTokenSource cancellation = new();
        RequestContext requestContext = context.CreateRequestContext(cancellation.Token);
        ResponsesServiceResult result = await context.Service.InvokeAsync(
            new CanonicalResponsesRequest { Model = spec.ClientModelId, Input = [], Stream = true },
            requestContext,
            cancellation.Token);
        Assert.NotNull(result.EventStream);
        Assert.NotNull(result.Execution);
        AssertAuthoritativeIdentity(result.Execution!, spec);
        Assert.Null(result.Execution!.CompletedAt);
        Assert.Empty(context.Sink.Executed);

        await using IAsyncEnumerator<CanonicalEvent> enumerator = result.EventStream!.GetAsyncEnumerator();
        Assert.True(await enumerator.MoveNextAsync());
        Assert.True(await enumerator.MoveNextAsync());
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => enumerator.MoveNextAsync().AsTask());
        await enumerator.DisposeAsync();

        RouteHealthProjectionEntry entry = RouteEntry(context, spec.RouteId);
        Assert.Equal(RouteHealthState.Unknown, entry.State);
        Assert.Equal(0, entry.FailureCount);
        Assert.Equal(0, entry.SuccessCount);
        ResponsesExecutionMetadata cancelled = Assert.Single(context.Sink.Executed);
        AssertSameIdentity(result.Execution!, cancelled);
        Assert.NotNull(cancelled.CompletedAt);

        using CancellationTokenSource secondToken = new();
        ResponsesServiceResult second = await context.InvokeAsync(spec.ClientModelId, secondToken.Token, stream: false);
        Assert.Null(second.Error);
        Assert.Equal(spec.RouteId, second.Execution!.RouteId);
        Assert.Equal(0, RouteEntry(context, spec.RouteId).FailureCount);
    }

    [Fact]
    public async Task Protocol_mapping_failure_normalizes_safe_terminal_failure()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.MiMo;
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            SafeHasher.Sha256Hex("stream-map-failure-e2e"));

        const string sse = """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"partial"}

            event: response.unknown_event
            data: {"type":"response.unknown_event"}

            """;

        var handler = new LifecycleHandler((_, _) => JsonResponse(HttpStatusCode.OK, sse, "text/event-stream"));
        await using LifecycleContext context = CreateContext(
            snapshot,
            [spec],
            handler,
            secretValue: "stream-secret",
            passiveHealth: PassiveHealthPolicy.Create(2, 1, TimeSpan.Zero, TimeSpan.FromMinutes(5)));

        ResponsesServiceResult result = await context.InvokeAsync(spec.ClientModelId, stream: true);
        var events = new List<CanonicalEvent>();
        await using IAsyncEnumerator<CanonicalEvent> enumerator = result.EventStream!.GetAsyncEnumerator();
        Assert.True(await enumerator.MoveNextAsync());
        events.Add(enumerator.Current);
        await Assert.ThrowsAnyAsync<ProtocolEventMappingException>(() => enumerator.MoveNextAsync().AsTask());

        Assert.Equal("response.output_text.delta", events[0].Type);
        Assert.Equal(1, handler.Calls);
        RouteHealthProjectionEntry entry = RouteEntry(context, spec.RouteId);
        Assert.Equal(RouteHealthState.Degraded, entry.State);
        Assert.Equal(1, entry.FailureCount);
        ResponsesExecutionMetadata terminal = Assert.Single(context.Sink.Executed);
        Assert.Equal(1, terminal.AttemptCount);
    }

    [Fact]
    public async Task Same_model_alternate_endpoint_executes_when_policy_allows()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenRouter;
        RouterRouteConfig routeA = ExecutionTestConfigFactory.Route(
            spec.ProviderId,
            "route.openrouter-endpoint-a",
            priority: 1,
            healthState: "HEALTHY",
            instance: "mm-openrouter-a");
        RouterRouteConfig routeB = ExecutionTestConfigFactory.Route(
            spec.ProviderId,
            "route.openrouter-endpoint-b",
            priority: 2,
            healthState: "HEALTHY",
            instance: "mm-openrouter-b") with { ModelRouteId = routeA.ModelRouteId };

        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [routeA, routeB],
            SafeHasher.Sha256Hex("alternate-endpoint-e2e"));

        int portA = 9021;
        int portB = 9022;
        RouterExecutionPolicySet policies = new()
        {
            Failover = FailoverPolicy.Create(
                allowSameModelAlternateEndpoint: true,
                allowSameModelAlternateProvider: false,
                allowCrossModelFallback: false),
        };
        var handler = new LifecycleHandler((uri, _) =>
            uri.Port == portA
                ? JsonResponse(HttpStatusCode.ServiceUnavailable, string.Empty)
                : JsonResponse(HttpStatusCode.OK, SseFixtureBuilder.NonStreamJson("alternate-endpoint-ok")));
        await using LifecycleContext context = CreateContext(
            snapshot,
            [spec],
            handler,
            secretValue: "failover-secret",
            policies: policies,
            endpointOverrides: Overrides(
                (routeA.ProviderRouteId, portA),
                (routeB.ProviderRouteId, portB)));

        ResponsesServiceResult result = await context.InvokeAsync(spec.ClientModelId);

        Assert.Null(result.Error);
        Assert.Equal(routeB.RouteId, result.Execution!.RouteId);
        Assert.Equal(routeB.ProviderRouteId, result.Execution.ProviderRouteId);
        Assert.Equal(EndpointIdFor(routeB.ProviderRouteId), result.Execution.EndpointId);
        Assert.Equal(3, result.Execution.AttemptCount);
        Assert.Equal(3, handler.Calls);
    }

    [Fact]
    public async Task Same_model_alternate_provider_executes_only_when_explicitly_approved()
    {
        ProviderExecutionSpec primary = ExecutionTestConfigFactory.OpenAiApi;
        ProviderExecutionSpec alternate = ExecutionTestConfigFactory.OpenRouter;
        RouterRouteConfig routePrimary = ExecutionTestConfigFactory.Route(primary.ProviderId, "route.openai-alt-provider", priority: 1, healthState: "HEALTHY");
        RouterRouteConfig routeAlternate = ExecutionTestConfigFactory.Route(alternate.ProviderId, "route.openrouter-alt-provider", priority: 2, healthState: "HEALTHY");
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [
                routePrimary,
                routeAlternate,
            ],
            SafeHasher.Sha256Hex("alternate-provider-e2e"),
            new Dictionary<string, ModelRouteTestOverride>(StringComparer.Ordinal)
            {
                [primary.ModelRouteId] = new("shared-client-model", "shared-catalog-model", "shared-upstream-model"),
                [alternate.ModelRouteId] = new("shared-client-model", "shared-catalog-model", "shared-upstream-model"),
            });

        int portA = 9031;
        int portB = 9032;
        RouterExecutionPolicySet policies = new()
        {
            Failover = FailoverPolicy.Create(
                allowSameModelAlternateEndpoint: false,
                allowSameModelAlternateProvider: true,
                allowCrossModelFallback: false),
        };
        var handler = new LifecycleHandler((uri, _) =>
            uri.Port == portA
                ? JsonResponse(HttpStatusCode.ServiceUnavailable, string.Empty)
                : JsonResponse(HttpStatusCode.OK, SseFixtureBuilder.NonStreamJson("alternate-provider-ok")));
        await using LifecycleContext context = CreateContext(
            snapshot,
            [primary, alternate],
            handler,
            secretValue: "failover-secret",
            policies: policies,
            endpointOverrides: Overrides(
                (primary.ProviderRouteId, portA),
                (alternate.ProviderRouteId, portB)));

        ResponsesServiceResult result = await context.InvokeAsync("shared-client-model");

        Assert.Null(result.Error);
        Assert.Equal(routeAlternate.RouteId, result.Execution!.RouteId);
        Assert.Equal(alternate.ProviderId, result.Execution.ProviderId);
        Assert.Equal(alternate.ProviderRouteId, result.Execution.ProviderRouteId);
        Assert.Equal(EndpointIdFor(alternate.ProviderRouteId), result.Execution.EndpointId);
        Assert.Equal(3, result.Execution.AttemptCount);
        Assert.Equal(3, handler.Calls);
    }

    [Fact]
    public async Task Retry_delay_never_exceeds_the_deadline_that_remains_after_the_attempt()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenAiApi;
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            SafeHasher.Sha256Hex("deadline-bounded-retry-e2e"));

        var clock = new StepClock(DateTimeOffset.Parse("2026-09-07T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal));
        RouterExecutionPolicySet policies = new()
        {
            Retry = RetryPolicy.Create(
                maxAttempts: 3,
                baseDelay: TimeSpan.FromMilliseconds(200),
                maxDelay: TimeSpan.FromMilliseconds(200),
                jitter: 0m,
                respectRetryAfter: false,
                maxRetryAfter: TimeSpan.FromMilliseconds(200)),
            Timeout = TimeoutPolicy.Create(
                connectTimeout: TimeSpan.FromMilliseconds(50),
                firstByteTimeout: TimeSpan.FromMilliseconds(100),
                idleTimeout: TimeSpan.FromMilliseconds(100),
                attemptTimeout: TimeSpan.FromMilliseconds(250),
                totalTimeout: TimeSpan.FromMilliseconds(300)),
        };
        var handler = new DeadlineAdvancingHandler(clock);
        await using LifecycleContext context = CreateContext(
            snapshot,
            [spec],
            handler,
            secretValue: "deadline-secret",
            policies: policies,
            clock: clock);

        ResponsesServiceResult result = await context.InvokeAsync(spec.ClientModelId);

        Assert.NotNull(result.Error);
        Assert.True(
            string.Equals(result.Error!.Code, "provider_5xx", StringComparison.Ordinal),
            "unexpected: " + result.Error.Code + " / " + result.Error.Message + " / " + result.Error.Param);
        Assert.Equal(1, handler.Calls);
        Assert.Equal(1, result.Execution!.AttemptCount);
        Assert.Equal(clock.UtcNow, result.Execution!.CompletedAt!.Value);
    }

    [Fact]
    public async Task Streamed_execution_metadata_completed_at_is_terminal_not_stream_return()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenAiApi;
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            SafeHasher.Sha256Hex("terminal-metadata-e2e"));

        var handler = new ChunkedDelayHandler(
            SseFixtureBuilder.BasicStream("terminal-timing"),
            TimeSpan.FromMilliseconds(600));
        await using LifecycleContext context = CreateContext(
            snapshot,
            [spec],
            handler,
            secretValue: "timing-secret",
            passiveHealth: PassiveHealthPolicy.Default);

        DateTimeOffset returnedAt = DateTimeOffset.UtcNow;
        ResponsesServiceResult result = await context.InvokeAsync(spec.ClientModelId, stream: true);
        Assert.NotNull(result.EventStream);
        Assert.NotNull(result.Execution);
        AssertAuthoritativeIdentity(result.Execution!, spec);
        Assert.Null(result.Execution!.CompletedAt);
        Assert.Empty(context.Sink.Executed);

        int events = 0;
        await foreach (CanonicalEvent _ in result.EventStream!)
        {
            events++;
        }

        Assert.True(events > 0);
        ResponsesExecutionMetadata terminal = Assert.Single(context.Sink.Executed);
        AssertSameIdentity(result.Execution!, terminal);
        Assert.NotNull(terminal.CompletedAt);
        Assert.True(terminal.ExecutionStartedAt <= terminal.CompletedAt!.Value);
        Assert.True(terminal.CompletedAt!.Value >= returnedAt.AddMilliseconds(300), "CompletedAt must be the true stream terminal instant, not the stream-return instant.");
    }

    [Fact]
    public async Task Streaming_consumer_binds_terminal_usage_to_pre_enumerated_authoritative_identity()
    {
        // PR #85 (LR-10R) rebase contract: a future metering consumer can read
        // the full authoritative identity from result.Execution BEFORE the
        // stream is enumerated, then pair the terminal usage carried by
        // response.completed with that same identity. The execution service
        // must never force the consumer to re-read configuration or guess the
        // provider.
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenAiApi;
        EffectiveRouterConfigSnapshot snapshot = ExecutionTestConfigFactory.Snapshot(
            [ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId)],
            SafeHasher.Sha256Hex("metering-identity-e2e"));

        var handler = new LifecycleHandler((_, _) => JsonResponse(HttpStatusCode.OK, SseFixtureBuilder.BasicStream("metered"), "text/event-stream"));
        await using LifecycleContext context = CreateContext(
            snapshot,
            [spec],
            handler,
            secretValue: "metering-secret",
            passiveHealth: PassiveHealthPolicy.Default);

        ResponsesServiceResult result = await context.InvokeAsync(spec.ClientModelId, stream: true);
        Assert.NotNull(result.EventStream);
        Assert.NotNull(result.Execution);

        ResponsesExecutionMetadata identity = result.Execution!;
        AssertAuthoritativeIdentity(identity, spec);
        Assert.Null(identity.CompletedAt);
        Assert.Empty(context.Sink.Executed);

        int? totalTokens = null;
        await foreach (CanonicalEvent canonicalEvent in result.EventStream!)
        {
            if (!canonicalEvent.IsTerminal
                || canonicalEvent.Data.ValueKind != JsonValueKind.Object
                || !canonicalEvent.Data.TryGetProperty("response", out JsonElement response)
                || response.ValueKind != JsonValueKind.Object
                || !response.TryGetProperty("usage", out JsonElement usage)
                || usage.ValueKind != JsonValueKind.Object
                || !usage.TryGetProperty("total_tokens", out JsonElement tokens)
                || tokens.ValueKind != JsonValueKind.Number)
            {
                continue;
            }

            totalTokens = tokens.GetInt32();
        }

        Assert.Equal(12, totalTokens);
        Assert.Equal(1, handler.Calls);

        ResponsesExecutionMetadata terminal = Assert.Single(context.Sink.Executed);
        AssertSameIdentity(identity, terminal);
        Assert.NotNull(terminal.CompletedAt);
        Assert.Equal("mm_openai_api", terminal.ProviderId);
        Assert.Equal(spec.RouteId, terminal.RouteId);
    }

    private static RouteHealthProjectionEntry RouteEntry(LifecycleContext context, string routeId)
    {
        RouteHealthProjection projection = context.Service.PassiveHealth!.ProjectRoutes(DateTimeOffset.UtcNow);
        return Assert.Single(projection.Routes, entry => string.Equals(entry.RouteId, routeId, StringComparison.Ordinal));
    }

    private static void AssertAuthoritativeIdentity(ResponsesExecutionMetadata metadata, ProviderExecutionSpec spec)
    {
        Assert.Equal(ExecutionTestConfigFactory.ClientId, metadata.ClientId);
        Assert.Equal(spec.RouteId, metadata.RouteId);
        Assert.Equal(spec.ProviderId, metadata.ProviderId);
        Assert.Equal(spec.ProviderRouteId, metadata.ProviderRouteId);
        Assert.Equal(spec.ModelRouteId, metadata.ModelRouteId);
        Assert.Equal(spec.ClientModelId, metadata.ClientModelId);
        Assert.Equal(spec.CatalogModelId, metadata.CatalogModelId);
        Assert.Equal(spec.UpstreamModelId, metadata.UpstreamModelId);
        Assert.Equal(spec.EndpointId, metadata.EndpointId);
    }

    private static void AssertSameIdentity(ResponsesExecutionMetadata expected, ResponsesExecutionMetadata actual)
    {
        Assert.Equal(expected.ConfigGeneration, actual.ConfigGeneration);
        Assert.Equal(expected.ClientId, actual.ClientId);
        Assert.Equal(expected.RouteId, actual.RouteId);
        Assert.Equal(expected.ProviderId, actual.ProviderId);
        Assert.Equal(expected.ProviderRouteId, actual.ProviderRouteId);
        Assert.Equal(expected.ModelRouteId, actual.ModelRouteId);
        Assert.Equal(expected.ClientModelId, actual.ClientModelId);
        Assert.Equal(expected.CatalogModelId, actual.CatalogModelId);
        Assert.Equal(expected.UpstreamModelId, actual.UpstreamModelId);
        Assert.Equal(expected.EndpointId, actual.EndpointId);
    }

    private static BreakerSnapshot BreakerEntry(LifecycleContext context, ProviderExecutionSpec spec)
        => context.Service.CircuitBreaker.Snapshot(
            CircuitBreakerKey.Create(
                spec.ProviderRouteId,
                spec.EndpointId,
                spec.ModelRouteId),
            DateTimeOffset.UtcNow);

    private static LifecycleContext CreateContext(
        EffectiveRouterConfigSnapshot snapshot,
        IReadOnlyList<ProviderExecutionSpec> specs,
        HttpMessageHandler handler,
        string? secretValue,
        RouterExecutionPolicySet? policies = null,
        PassiveHealthPolicy? passiveHealth = null,
        CircuitBreakerPolicy? breaker = null,
        IClock? clock = null,
        IReadOnlyDictionary<string, string>? endpointOverrides = null,
        bool addDefaultLoopbackOverrides = true)
    {
        var resolver = new FakeSecretResolver();
        foreach (ProviderExecutionSpec spec in specs)
        {
            resolver.Configure(spec.ProviderId, spec.SecretEnvironmentName, secretValue);
        }

        var resolvedOverrides = new Dictionary<string, string>(StringComparer.Ordinal);
        if (addDefaultLoopbackOverrides)
        {
            int port = 9100;
            foreach (ProviderExecutionSpec spec in specs)
            {
                resolvedOverrides.TryAdd(
                    spec.EndpointBaseUrlReference,
                    LoopbackBase(port++, spec));
            }
        }

        if (endpointOverrides is not null)
        {
            foreach (KeyValuePair<string, string> pair in endpointOverrides)
            {
                resolvedOverrides[pair.Key] = pair.Value;
            }
        }

        var sink = new CollectingOutcomeSink();
        RouterExecutionServiceFactoryResult result = RouterExecutionServiceFactory.Create(
            snapshot,
            resolver,
            transportHandler: handler,
            policies: policies,
            endpointOverrides: resolvedOverrides,
            clock: clock,
            circuitBreakerPolicy: breaker,
            passiveHealthPolicy: passiveHealth ?? PassiveHealthPolicy.Default,
            outcomeSink: sink);
        Assert.True(result.IsSuccess, result.Error?.Code + ": " + result.Error?.Message + " (" + result.Error?.Param + ")");
        return new LifecycleContext(result.Service!, snapshot, sink);
    }

    private static Dictionary<string, string> Overrides(params (string ProviderRouteId, int Port)[] routes)
    {
        var overrides = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach ((string providerRouteId, int port) in routes)
        {
            overrides[ExecutionTestConfigFactory.EndpointBaseUrlReferenceFor(providerRouteId)] =
                LoopbackBase(port, SpecFor(providerRouteId));
        }

        return overrides;
    }

    private static string LoopbackBase(int port, ProviderExecutionSpec spec)
    {
        Uri root = new("http://127.0.0.1:" + port + "/", UriKind.Absolute);
        return string.IsNullOrEmpty(spec.FakeBasePath)
            ? root.ToString()
            : new Uri(root, spec.FakeBasePath).ToString();
    }

    private static ProviderExecutionSpec SpecFor(string providerRouteId)
    {
        ProviderExecutionSpec[] all = [ExecutionTestConfigFactory.OpenRouter, ExecutionTestConfigFactory.ModelStudio, ExecutionTestConfigFactory.OpenAiApi, ExecutionTestConfigFactory.MiMo];
        ProviderExecutionSpec? exact = all.FirstOrDefault(spec =>
            string.Equals(spec.ProviderRouteId, providerRouteId, StringComparison.Ordinal));
        if (exact is not null)
        {
            return exact;
        }

        foreach (ProviderExecutionSpec spec in all)
        {
            if (providerRouteId.StartsWith("provider-route." + spec.Slug + "-", StringComparison.Ordinal))
            {
                return spec;
            }
        }

        throw new ArgumentOutOfRangeException(nameof(providerRouteId), providerRouteId, "No provider execution spec matches the provider route.");
    }

    private static string EndpointIdFor(string providerRouteId)
    {
        const string prefix = "provider-route.";
        return "endpoint." + providerRouteId[prefix.Length..];
    }

    private static HttpResponseMessage JsonResponse(HttpStatusCode status, string body, string contentType = "application/json")
        => new(status)
        {
            Content = new StringContent(body, Encoding.UTF8, contentType),
        };

    private static string BodyText(byte[] body)
        => Encoding.UTF8.GetString(body);

    private sealed class LifecycleContext : IAsyncDisposable
    {
        public LifecycleContext(
            RouterExecutionResponsesService service,
            EffectiveRouterConfigSnapshot snapshot,
            CollectingOutcomeSink sink)
        {
            Service = service;
            Snapshot = snapshot;
            Sink = sink;
        }

        public RouterExecutionResponsesService Service { get; }

        public EffectiveRouterConfigSnapshot Snapshot { get; }

        public CollectingOutcomeSink Sink { get; }

        public RequestContext CreateRequestContext(CancellationToken cancellationToken)
        {
            UuidV7 uuid = UuidV7.Parse("018f4a9b-0000-7000-8000-000000000003");
            return RequestContext.Create(
                RequestId.Create(uuid),
                TraceId.Create(uuid),
                ExecutionTestConfigFactory.ClientId,
                DateTimeOffset.UnixEpoch,
                "responses:invoke",
                configGeneration: Snapshot.ConfigGeneration,
                cancellationToken: cancellationToken);
        }

        public async Task<ResponsesServiceResult> InvokeAsync(
            string model,
            CancellationToken? cancellationToken = null,
            bool stream = false)
        {
            using CancellationTokenSource owned = cancellationToken is null ? new CancellationTokenSource() : new();
            CancellationToken effective = cancellationToken ?? owned.Token;
            RequestContext requestContext = CreateRequestContext(effective);
            CanonicalResponsesRequest request = new()
            {
                Model = model,
                Input = [],
                Stream = stream,
            };
            return await Service.InvokeAsync(request, requestContext, effective);
        }

        public async ValueTask DisposeAsync()
        {
            Service.Dispose();
            await Task.CompletedTask;
        }
    }

    /// <summary>Loopback-only lifecycle transport handler with request counting.</summary>
    private sealed class LifecycleHandler : HttpMessageHandler
    {
        private readonly Func<Uri, int, HttpResponseMessage> _respond;
        private readonly object _sync = new();
        private readonly List<byte[]> _bodies = [];
        private int _calls;

        public LifecycleHandler(Func<Uri, int, HttpResponseMessage> respond)
        {
            _respond = respond ?? throw new ArgumentNullException(nameof(respond));
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
                || !UpstreamEndpoint.IsLoopbackHost(uri.Host))
            {
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadGateway)
                {
                    ReasonPhrase = NetworkGuardPhrase,
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

            return Task.FromResult(_respond(uri, call));
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

    /// <summary>First call returns a stalling stream; later calls return a normal response.</summary>
    private sealed class CancelAfterContentHandler : HttpMessageHandler
    {
        private readonly byte[][] _segments;
        private readonly string _laterBody;
        private int _calls;

        public CancelAfterContentHandler(byte[][] segments, string laterBody)
        {
            _segments = segments;
            _laterBody = laterBody;
        }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            int call = Interlocked.Increment(ref _calls);
            if (call == 1)
            {
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StreamContent(new SegmentedStream(_segments)),
                });
            }

            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(_laterBody, Encoding.UTF8, "application/json"),
            });
        }
    }

    /// <summary>Stream that returns each segment once, then waits forever until cancelled.</summary>
    private sealed class SegmentedStream : Stream
    {
        private readonly byte[][] _segments;
        private int _segment;
        private int _offset;

        public SegmentedStream(byte[][] segments)
        {
            _segments = segments;
        }

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override int Read(byte[] buffer, int offset, int count)
            => throw new NotSupportedException();

        public override async ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            while (_segment < _segments.Length && _offset >= _segments[_segment].Length)
            {
                _segment++;
                _offset = 0;
            }

            if (_segment < _segments.Length)
            {
                byte[] payload = _segments[_segment];
                int available = Math.Min(payload.Length - _offset, buffer.Length);
                payload.AsMemory(_offset, available).CopyTo(buffer);
                _offset += available;
                return available;
            }

            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return 0;
        }

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin)
            => throw new NotSupportedException();

        public override void SetLength(long value)
            => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count)
            => throw new NotSupportedException();
    }

    /// <summary>Advances a step clock when the first upstream attempt arrives.</summary>
    private sealed class DeadlineAdvancingHandler : HttpMessageHandler
    {
        private readonly StepClock _clock;
        private int _calls;

        public DeadlineAdvancingHandler(StepClock clock)
        {
            _clock = clock;
        }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            if (request.RequestUri is not { } uri
                || !UpstreamEndpoint.IsLoopbackHost(uri.Host))
            {
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadGateway)
                {
                    ReasonPhrase = NetworkGuardPhrase,
                });
            }

            Interlocked.Increment(ref _calls);
            _clock.Advance(TimeSpan.FromMilliseconds(250));
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable));
        }

        public int Calls => Volatile.Read(ref _calls);
    }

    /// <summary>Returns the full body in chunks with a delay before the terminal event chunk.</summary>
    private sealed class ChunkedDelayHandler : HttpMessageHandler
    {
        private readonly byte[] _body;
        private readonly int _split;
        private readonly TimeSpan _delay;

        public ChunkedDelayHandler(string sse, TimeSpan delay)
        {
            _body = Encoding.UTF8.GetBytes(sse);
            int index = sse.IndexOf("event: response.completed", StringComparison.Ordinal);
            _split = index < 0 ? _body.Length : Encoding.UTF8.GetByteCount(sse[..index]);
            _delay = delay;
        }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            if (request.RequestUri is not { } uri
                || !UpstreamEndpoint.IsLoopbackHost(uri.Host))
            {
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadGateway)
                {
                    ReasonPhrase = NetworkGuardPhrase,
                });
            }

            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StreamContent(new SlowTerminalStream(_body, _split, _delay)),
            });
        }
    }

    private sealed class SlowTerminalStream : Stream
    {
        private readonly byte[] _body;
        private readonly int _split;
        private readonly TimeSpan _delay;
        private int _offset;
        private bool _delayed;

        public SlowTerminalStream(byte[] body, int split, TimeSpan delay)
        {
            _body = body;
            _split = split;
            _delay = delay;
        }

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override int Read(byte[] buffer, int offset, int count)
            => throw new NotSupportedException();

        public override async ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            if (_offset >= _body.Length)
            {
                return 0;
            }

            if (_offset > 0 && !_delayed)
            {
                _delayed = true;
                await Task.Delay(_delay, cancellationToken);
            }

            int end = _offset < _split ? _split : _body.Length;
            if (end <= _offset)
            {
                _delayed = true;
                end = _body.Length;
            }

            int available = Math.Min(end - _offset, buffer.Length);
            _body.AsMemory(_offset, available).CopyTo(buffer);
            _offset += available;
            return available;
        }

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin)
            => throw new NotSupportedException();

        public override void SetLength(long value)
            => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count)
            => throw new NotSupportedException();
    }

    /// <summary>Deterministic manually advanced clock.</summary>
    private sealed class StepClock : IClock
    {
        private readonly object _sync = new();
        private DateTimeOffset _now;

        public StepClock(DateTimeOffset start)
        {
            _now = start;
        }

        public DateTimeOffset UtcNow
        {
            get
            {
                lock (_sync)
                {
                    return _now;
                }
            }
        }

        public void Advance(TimeSpan by)
        {
            lock (_sync)
            {
                _now += by;
            }
        }
    }

}
