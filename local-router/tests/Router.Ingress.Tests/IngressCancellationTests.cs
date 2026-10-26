using System.Net;
using System.Runtime.CompilerServices;
using Router.ClientAdapters.Responses;
using Router.Core.Lifecycle;
using Router.Ingress.Fakes;
using Router.Ingress.Tests.Support;
using Xunit;

namespace Router.Ingress.Tests;

public sealed class IngressCancellationTests
{
    [Fact]
    public async Task Client_disconnect_cancels_the_service_and_records_cancelled()
    {
        TaskCompletionSource<CancellationToken> serviceToken = new(TaskCreationOptions.RunContinuationsAsynchronously);
        FakeResponsesService service = new();
        service.UseHandler((_, context, _) =>
        {
            serviceToken.TrySetResult(context.CancellationToken);
            return Task.FromResult(ResponsesServiceResult.Stream(HeldStreamAsync(context.CancellationToken)));
        });
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using CancellationTokenSource clientCts = new();
        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi","stream":true}""");
        Task<HttpResponseMessage> sendTask = server.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, clientCts.Token);

        CancellationToken serviceCancellation = await serviceToken.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(serviceCancellation.IsCancellationRequested);

        clientCts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => sendTask);
        await WaitUntilAsync(() => serviceCancellation.IsCancellationRequested, TimeSpan.FromSeconds(5));
        await WaitUntilAsync(
            () => server.Observer.Results.Any(static r => r.State == RequestState.Cancelled),
            TimeSpan.FromSeconds(5));

        RequestExecutionResult result = Assert.Single(server.Observer.Results);
        Assert.Equal(RequestState.Cancelled, result.State);
        Assert.Equal(Router.Core.Errors.RouterErrorCode.Cancelled, result.ErrorCode);
    }

    [Fact]
    public async Task Request_deadline_cancels_a_delayed_service()
    {
        FakeResponsesService service = new();
        service.WithDelay(TimeSpan.FromSeconds(5));
        await using IngressTestServer server = await IngressTestServer.StartAsync(options =>
        {
            options.RequestTimeout = TimeSpan.FromMilliseconds(100);
            options.Service = service;
        });

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        try
        {
            using HttpResponseMessage response = await server.SendAsync(request);
            _ = response;
        }
        catch (OperationCanceledException)
        {
            // Transport-level cancellation may surface as a client exception.
        }

        await WaitUntilAsync(
            () => server.Observer.Results.Any(static r => r.State == RequestState.Cancelled),
            TimeSpan.FromSeconds(5));

        RequestExecutionResult result = Assert.Single(server.Observer.Results);
        Assert.Equal(RequestState.Cancelled, result.State);
        Assert.Null(result.Ttft);
    }

    [Fact]
    public async Task Shutdown_cancels_an_active_stream_and_reaches_stopped()
    {
        TaskCompletionSource<CancellationToken> serviceToken = new(TaskCreationOptions.RunContinuationsAsynchronously);
        FakeResponsesService service = new();
        service.UseHandler((_, context, _) =>
        {
            serviceToken.TrySetResult(context.CancellationToken);
            return Task.FromResult(ResponsesServiceResult.Stream(HeldStreamAsync(context.CancellationToken)));
        });
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi","stream":true}""");
        Task<HttpResponseMessage> sendTask = server.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);

        CancellationToken serviceCancellation = await serviceToken.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await server.Ingress.StopAsync();

        await WaitUntilAsync(() => serviceCancellation.IsCancellationRequested, TimeSpan.FromSeconds(5));
        await WaitUntilAsync(
            () => server.Observer.Results.Any(static r => r.State == RequestState.Cancelled),
            TimeSpan.FromSeconds(5));
        Assert.Equal(LifecycleState.Stopped, server.Ingress.LifecycleState);

        try
        {
            await sendTask;
        }
        catch (Exception)
        {
            // The connection is gone after shutdown; either outcome is safe.
        }
    }

    [Fact]
    public async Task Late_completion_is_discarded_after_cancellation()
    {
        FakeResponsesService service = new();
        service.UseHandler(async (request, _, cancellationToken) =>
        {
            await Task.Delay(TimeSpan.FromMilliseconds(500), cancellationToken);
            return ResponsesServiceResult.NonStream(Echo(request));
        });
        await using IngressTestServer server = await IngressTestServer.StartAsync(options =>
        {
            options.RequestTimeout = TimeSpan.FromMilliseconds(80);
            options.Service = service;
        });

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        try
        {
            using HttpResponseMessage response = await server.SendAsync(request);
            _ = response;
        }
        catch (OperationCanceledException)
        {
            // Transport-level cancellation may surface as a client exception.
        }

        await WaitUntilAsync(
            () => server.Observer.Results.Any(static r => r.State == RequestState.Cancelled),
            TimeSpan.FromSeconds(5));

        await Task.Delay(TimeSpan.FromMilliseconds(200));
        RequestExecutionResult result = Assert.Single(server.Observer.Results);
        Assert.Equal(RequestState.Cancelled, result.State);
    }

    [Fact]
    public async Task Cancel_complete_race_has_exactly_one_terminal_state()
    {
        FakeResponsesService service = new();
        service.WithDelay(TimeSpan.FromMilliseconds(40));
        await using IngressTestServer server = await IngressTestServer.StartAsync(options =>
        {
            options.RequestTimeout = TimeSpan.FromMilliseconds(20);
            options.Service = service;
        });

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        try
        {
            using HttpResponseMessage response = await server.SendAsync(request);
            Assert.True(response.IsSuccessStatusCode);
        }
        catch (OperationCanceledException)
        {
            // Either terminal outcome is valid; exactly one must be recorded.
        }

        await WaitUntilAsync(() => server.Observer.Results.Count == 1, TimeSpan.FromSeconds(5));
        RequestExecutionResult result = Assert.Single(server.Observer.Results);
        Assert.True(
            result.State is RequestState.Completed or RequestState.Cancelled,
            $"Unexpected terminal state {result.State}");
    }

    [Fact]
    public async Task Shutdown_releases_the_socket_for_restart()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();
        Uri address = server.BaseUri;

        await server.Ingress.StopAsync();

        IngressRuntimeOptions options = new()
        {
            Host = "127.0.0.1",
            Port = address.Port,
            Limits = new Router.Configuration.LimitsConfig
            {
                MaxRequestBytes = 16_777_216,
                MaxHeaderBytes = 32_768,
                MaxConnections = 32,
                ShutdownGraceMs = 15_000,
            },
            ConfigGeneration = new string('a', 64),
            TokenReferenceName = "CODEX_LOCAL_ROUTER_TOKEN",
            Clients = IngressTestServer.DefaultClients,
        };
        server.SecretResolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", IngressTestServer.TestToken);

        IngressStartResult restarted = await ResponsesIngress.StartAsync(
            options,
            new FakeResponsesService(),
            server.SecretResolver,
            new Router.Core.Abstractions.SystemClock(),
            new Router.Core.Ids.UuidV7IdGenerator(new Router.Core.Abstractions.SystemClock()));

        Assert.True(restarted.IsSuccess);
        Assert.Equal(address.Port, restarted.Ingress!.ListenAddress!.Port);
        await restarted.Ingress.DisposeAsync();
    }

    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        DateTimeOffset deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (condition())
            {
                return;
            }

            await Task.Delay(25);
        }

        Assert.True(condition(), "Condition was not satisfied within the timeout.");
    }

    private static async IAsyncEnumerable<CanonicalEvent> HeldStreamAsync([EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        yield break;
    }

    private static CanonicalResponsesResponse Echo(CanonicalResponsesRequest request)
        => new()
        {
            Id = "resp_00000000-0000-7000-8000-000000000001",
            ObjectType = "response",
            CreatedAt = 1,
            Status = "completed",
            Model = request.Model,
            Output = [],
        };
}
