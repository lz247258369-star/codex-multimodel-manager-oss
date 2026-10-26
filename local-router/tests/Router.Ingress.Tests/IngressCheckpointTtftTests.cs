using Router.Core.Lifecycle;
using Router.Ingress.Fakes;
using Router.Ingress.Tests.Support;
using Xunit;

namespace Router.Ingress.Tests;

public sealed class IngressCheckpointTtftTests
{
    [Fact]
    public async Task Immediate_non_stream_response_has_ttft()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        using HttpResponseMessage response = await server.SendAsync(request);
        Assert.True(response.IsSuccessStatusCode);

        RequestExecutionResult result = Assert.Single(server.Observer.Results);
        Assert.Equal(RequestState.Completed, result.State);
        Assert.NotNull(result.Ttft);
        Assert.True(result.Ttft >= TimeSpan.Zero);
    }

    [Fact]
    public async Task Delayed_first_output_measures_ttft()
    {
        FakeResponsesService service = new();
        service.WithDelay(TimeSpan.FromMilliseconds(150));
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi","stream":true}""");
        using HttpResponseMessage response = await server.SendAsync(request);
        Assert.True(response.IsSuccessStatusCode);

        RequestExecutionResult result = Assert.Single(server.Observer.Results);
        Assert.Equal(RequestState.Completed, result.State);
        Assert.NotNull(result.Ttft);
        Assert.True(result.Ttft >= TimeSpan.FromMilliseconds(100), $"TTFT was {result.Ttft}");
    }

    [Fact]
    public async Task Cancelled_before_output_has_no_ttft()
    {
        FakeResponsesService service = new();
        service.WithDelay(TimeSpan.FromSeconds(5));
        await using IngressTestServer server = await IngressTestServer.StartAsync(options =>
        {
            options.RequestTimeout = TimeSpan.FromMilliseconds(60);
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

        await WaitUntilAsync(() => server.Observer.Results.Count == 1, TimeSpan.FromSeconds(5));
        RequestExecutionResult result = Assert.Single(server.Observer.Results);
        Assert.Equal(RequestState.Cancelled, result.State);
        Assert.Null(result.Ttft);
    }

    [Fact]
    public async Task Exception_before_output_records_failed_without_ttft()
    {
        FakeResponsesService service = new();
        service.WithException(new InvalidOperationException());
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        using HttpResponseMessage response = await server.SendAsync(request);
        Assert.Equal(500, (int)response.StatusCode);

        RequestExecutionResult result = Assert.Single(server.Observer.Results);
        Assert.Equal(RequestState.Failed, result.State);
        Assert.Null(result.Ttft);
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
}
