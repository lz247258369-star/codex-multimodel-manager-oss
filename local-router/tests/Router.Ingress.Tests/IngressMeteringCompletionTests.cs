using System.Diagnostics;
using System.Net;
using Router.ClientAdapters.Responses;
using Router.Core.Lifecycle;
using Router.Ingress.Fakes;
using Router.Ingress.Tests.Support;
using Xunit;

namespace Router.Ingress.Tests;

public sealed class IngressMeteringCompletionTests
{
    private sealed class ThrowingUsageObserver : IngressRequestObserver
    {
        public override Task OnUsageCompletedAsync(
            RequestUsageCompletion completion,
            CancellationToken cancellationToken = default)
            => throw new InvalidOperationException("metering sink exploded");
    }

    private static CanonicalResponsesResponse Response(string model, UsageRecord? usage)
        => new()
        {
            Id = "resp_lr10r",
            ObjectType = "response",
            CreatedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            Status = "completed",
            Model = model,
            Usage = usage,
        };

    private static FakeResponsesService NonStreamService(UsageRecord? usage)
        => NonStreamService(usage, execution: null);

    private static FakeResponsesService NonStreamService(
        UsageRecord? usage,
        ResponsesExecutionMetadata? execution)
    {
        FakeResponsesService service = new();
        service.UseHandler((request, _, _) =>
            Task.FromResult(ResponsesServiceResult.NonStream(Response(request.Model, usage), execution)));
        return service;
    }

    private static ResponsesExecutionMetadata ExecutionIdentity(
        string providerId = "mm_openrouter",
        string catalogModelId = "z-ai/glm-5.3",
        string? routeId = null,
        string? providerRouteId = null,
        string? modelRouteId = null)
        => new()
        {
            ConfigGeneration = "config-generation-test",
            ClientId = "client.local_test",
            RouteId = routeId ?? "route.lr10r",
            ProviderId = providerId,
            ProviderRouteId = providerRouteId ?? "provider-route.lr10r",
            ModelRouteId = modelRouteId ?? "model_route.lr10r",
            ClientModelId = "glm-test",
            CatalogModelId = catalogModelId,
            UpstreamModelId = catalogModelId,
            EndpointId = "endpoint.lr10r",
            ExecutionStartedAt = DateTimeOffset.UnixEpoch,
            CompletedAt = null,
        };

    [Fact]
    public async Task Non_stream_canonical_usage_reaches_production_metering_completion()
    {
        UsageRecord usage = new() { InputTokens = 100, OutputTokens = 25, TotalTokens = 125 };
        await using IngressTestServer server = await IngressTestServer.StartAsync(options =>
        {
            options.Service = NonStreamService(usage, ExecutionIdentity());
        });

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"glm-test","input":"hello"}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        await WaitUntilAsync(() => server.Observer.UsageCompletions.Count == 1, TimeSpan.FromSeconds(5));
        RequestUsageCompletion completion = Assert.Single(server.Observer.UsageCompletions);
        Assert.Equal(100, completion.Usage!.InputTokens);
        Assert.Equal(25, completion.Usage.OutputTokens);
        Assert.Equal(125, completion.Usage.TotalTokens);
        Assert.Equal("mm_openrouter", completion.Identity!.ProviderId);
        Assert.Equal("z-ai/glm-5.3", completion.Identity.CatalogModelId);
        Assert.False(completion.Stream);
        Assert.StartsWith("req_", completion.RequestId, StringComparison.Ordinal);
        Assert.StartsWith("trc_", completion.TraceId, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Execution_identity_is_projected_into_the_completion_exactly()
    {
        UsageRecord usage = new() { InputTokens = 100, OutputTokens = 25, TotalTokens = 125 };
        ResponsesExecutionMetadata execution = ExecutionIdentity(
            "chatgpt",
            "gpt-5.6-terra",
            "route.chatgpt-terra",
            "provider-route.chatgpt-terra",
            "model_route.chatgpt-terra");

        await using IngressTestServer server = await IngressTestServer.StartAsync(options =>
        {
            options.Service = NonStreamService(usage, execution);
        });

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"glm-test","input":"hello"}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        await WaitUntilAsync(() => server.Observer.UsageCompletions.Count == 1, TimeSpan.FromSeconds(5));
        RequestUsageCompletion completion = Assert.Single(server.Observer.UsageCompletions);
        Assert.Equal("chatgpt", completion.Identity!.ProviderId);
        Assert.Equal("route.chatgpt-terra", completion.Identity.RouteId);
        Assert.Equal("model_route.chatgpt-terra", completion.Identity.ModelRouteId);
        Assert.Equal("gpt-5.6-terra", completion.Identity.CatalogModelId);
        Assert.Equal("gpt-5.6-terra", completion.Identity.UpstreamModelId);
    }

    [Fact]
    public async Task Missing_execution_identity_stays_null_and_never_guesses()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync(options =>
        {
            options.Service = NonStreamService(new UsageRecord { InputTokens = 100, OutputTokens = 25, TotalTokens = 125 });
        });

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"glm-test","input":"hello"}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        await WaitUntilAsync(() => server.Observer.UsageCompletions.Count == 1, TimeSpan.FromSeconds(5));
        RequestUsageCompletion completion = Assert.Single(server.Observer.UsageCompletions);
        Assert.Null(completion.Identity);
    }

    [Fact]
    public async Task Missing_usage_is_delivered_as_null_never_zero()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync(options =>
        {
            options.Service = NonStreamService(usage: null, ExecutionIdentity());
        });

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"glm-test","input":"hello"}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        await WaitUntilAsync(() => server.Observer.UsageCompletions.Count == 1, TimeSpan.FromSeconds(5));
        RequestUsageCompletion completion = Assert.Single(server.Observer.UsageCompletions);
        Assert.Null(completion.Usage);
    }

    [Fact]
    public async Task Stream_with_final_usage_produces_exactly_one_metering_completion()
    {
        FakeResponsesService service = new();
        service.UseHandler((request, _, _) =>
        {
            UsageRecord usage = new() { InputTokens = 100, OutputTokens = 25, TotalTokens = 125 };
            CanonicalEvent[] events =
            [
                CanonicalEvent.Create("response.output_text.delta", new { type = "response.output_text.delta", delta = "a" }),
                CanonicalEvent.Create("response.output_text.delta", new { type = "response.output_text.delta", delta = "b" }),
                CanonicalEvent.Create("response.output_text.delta", new { type = "response.output_text.delta", delta = "c" }),
                CanonicalEvent.Create("response.completed", new
                {
                    type = "response.completed",
                    response = new
                    {
                        id = "resp_lr10r",
                        @object = "response",
                        created_at = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                        status = "completed",
                        model = request.Model,
                        output = Array.Empty<object>(),
                        usage,
                    },
                }),
            ];
            return Task.FromResult(ResponsesServiceResult.Stream(EnumerateEventsAsync(events), ExecutionIdentity()));
        });

        await using IngressTestServer server = await IngressTestServer.StartAsync(options =>
        {
            options.Service = service;
        });

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"glm-test","input":"hello","stream":true}""");
        using HttpResponseMessage response = await server.SendAsync(request);
        _ = await server.GetBodyAsync(response);

        await WaitUntilAsync(() => server.Observer.UsageCompletions.Count == 1, TimeSpan.FromSeconds(5));
        RequestUsageCompletion completion = Assert.Single(server.Observer.UsageCompletions);
        Assert.True(completion.Stream);
        Assert.Equal(100, completion.Usage!.InputTokens);
        Assert.Equal(25, completion.Usage.OutputTokens);
        Assert.Equal("mm_openrouter", completion.Identity!.ProviderId);
        Assert.Equal("z-ai/glm-5.3", completion.Identity.CatalogModelId);
    }

    [Fact]
    public async Task Stream_failed_terminal_never_emits_a_usage_completion()
    {
        FakeResponsesService service = new();
        service.UseHandler((request, _, _) =>
        {
            CanonicalEvent[] events =
            [
                CanonicalEvent.Create("response.output_text.delta", new { type = "response.output_text.delta", delta = "a" }),
                CanonicalEvent.Create("response.failed", new
                {
                    type = "response.failed",
                    response = new
                    {
                        id = "resp_lr10r",
                        @object = "response",
                        created_at = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                        status = "failed",
                        model = request.Model,
                    },
                }),
            ];
            return Task.FromResult(ResponsesServiceResult.Stream(EnumerateEventsAsync(events)));
        });

        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);
        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"glm-test","input":"hello","stream":true}""");
        using HttpResponseMessage response = await server.SendAsync(request);
        _ = await server.GetBodyAsync(response);

        Assert.Empty(server.Observer.UsageCompletions);
    }

    [Fact]
    public async Task Client_cancellation_before_final_usage_never_guesses_usage()
    {
        FakeResponsesService service = new();
        service.UseHandler((_, _, _) => Task.FromResult(ResponsesServiceResult.Stream(ThrowAfterDeltaAsync())));
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"glm-test","input":"hi","stream":true}""");
        using HttpResponseMessage response = await server.SendAsync(request);
        _ = await server.GetBodyAsync(response);

        await WaitUntilAsync(
            () => server.Observer.Results.Any(static result => result.State == RequestState.Cancelled),
            TimeSpan.FromSeconds(10));
        Assert.Empty(server.Observer.UsageCompletions);
    }

    [Fact]
    public async Task Metering_sink_failure_never_breaks_a_successful_response()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync(options =>
        {
            options.Service = NonStreamService(new UsageRecord { InputTokens = 100, OutputTokens = 25, TotalTokens = 125 });
            options.Observer = new ThrowingUsageObserver();
        });

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"glm-test","input":"hello"}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        string body = await server.GetBodyAsync(response);
        Assert.Contains("\"status\":\"completed\"", body, StringComparison.Ordinal);
    }

    private static async IAsyncEnumerable<CanonicalEvent> EnumerateEventsAsync(IReadOnlyList<CanonicalEvent> events)
    {
        foreach (CanonicalEvent evt in events)
        {
            yield return evt;
        }

        await Task.CompletedTask;
    }

    private static async IAsyncEnumerable<CanonicalEvent> ThrowAfterDeltaAsync()
    {
        yield return CanonicalEvent.Create("response.output_text.delta", new { type = "response.output_text.delta", delta = "a" });
        await Task.Yield();
        throw new OperationCanceledException();
    }

    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        Stopwatch stopwatch = Stopwatch.StartNew();
        while (!condition())
        {
            if (stopwatch.Elapsed > timeout)
            {
                Assert.True(condition(), "Condition was not met before timeout.");
                return;
            }

            await Task.Delay(TimeSpan.FromMilliseconds(25)).ConfigureAwait(false);
        }
    }
}
