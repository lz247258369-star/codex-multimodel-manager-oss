using System.Net;
using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.Ingress.Fakes;
using Router.Ingress.Tests.Support;
using Xunit;

namespace Router.Ingress.Tests;

public sealed class IngressSseTests
{
    private static readonly string[] ExpectedSequence =
    [
        "response.created",
        "response.output_item.added",
        "response.output_text.delta",
        "response.output_text.done",
        "response.output_item.done",
        "response.completed",
    ];

    [Fact]
    public async Task Stream_response_uses_event_stream_content_type_and_canonical_frames()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi","stream":true}""");
        using HttpResponseMessage response = await server.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("text/event-stream", response.Content.Headers.ContentType!.MediaType);

        string body = await response.Content.ReadAsStringAsync();
        IReadOnlyList<SseFrame> frames = SseFrameParser.Parse(body);

        Assert.Equal(ExpectedSequence, frames.Select(static f => f.Event));
        foreach (SseFrame frame in frames)
        {
            using JsonDocument data = JsonDocument.Parse(frame.Data);
            Assert.Equal(frame.Event, data.RootElement.GetProperty("type").GetString());
        }
    }

    [Fact]
    public async Task Fragmented_producer_still_emits_correct_frames()
    {
        FakeResponsesService service = new();
        service.WithFragmented(true);
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi","stream":true}""");
        using HttpResponseMessage response = await server.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);

        string body = await response.Content.ReadAsStringAsync();
        IReadOnlyList<SseFrame> frames = SseFrameParser.Parse(body);
        Assert.Equal("response.created", frames[0].Event);
        Assert.Equal("response.completed", frames[^1].Event);
        Assert.Equal(6, frames.Count);
        Assert.All(frames, static frame => Assert.False(frame.Data.Contains('\n')));
    }

    [Fact]
    public async Task Terminal_event_is_emitted_at_most_once()
    {
        FakeResponsesService service = new();
        service.UseHandler((_, _, _) =>
        {
            var events = new[]
            {
                CanonicalEvent.Create("response.completed", new { type = "response.completed" }),
                CanonicalEvent.Create("response.completed", new { type = "response.completed" }),
                CanonicalEvent.Create("response.output_text.delta", new { type = "response.output_text.delta", delta = "late" }),
            };
            return Task.FromResult(ResponsesServiceResult.Stream(EnumerableAsync(events)));
        });
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi","stream":true}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        IReadOnlyList<SseFrame> frames = SseFrameParser.Parse(await server.GetBodyAsync(response));
        Assert.Single(frames);
        Assert.Equal("response.completed", frames[0].Event);
    }

    [Fact]
    public async Task Error_before_first_output_returns_http_error_envelope()
    {
        FakeResponsesService service = new();
        service.WithError(RouterError.InternalError());
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi","stream":true}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.InternalServerError, response.StatusCode);
        Assert.Equal("application/json", response.Content.Headers.ContentType!.MediaType);
        Assert.Contains("\"code\":\"internal_error\"", await server.GetBodyAsync(response), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Error_after_first_output_emits_safe_error_event()
    {
        FakeResponsesService service = new();
        service.UseHandler((_, _, _) =>
        {
            var events = new[]
            {
                CanonicalEvent.Create("response.created", new { type = "response.created" }),
            };
            return Task.FromResult(ResponsesServiceResult.Stream(ThrowAfterAsync(events)));
        });
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi","stream":true}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        string body = await server.GetBodyAsync(response);
        IReadOnlyList<SseFrame> frames = SseFrameParser.Parse(body);
        Assert.Equal("response.created", frames[0].Event);
        Assert.Equal("error", frames[1].Event);
        using JsonDocument errorData = JsonDocument.Parse(frames[1].Data);
        Assert.Equal("internal_error", errorData.RootElement.GetProperty("code").GetString());
        Assert.DoesNotContain("boom", body, StringComparison.Ordinal);

        RequestExecutionResult result = Assert.Single(server.Observer.Results);
        Assert.Equal(Router.Core.Lifecycle.RequestState.Failed, result.State);
    }

    [Fact]
    public async Task Slow_producer_is_forwarded_without_corruption()
    {
        FakeResponsesService service = new();
        service.WithDelay(TimeSpan.FromMilliseconds(80)).WithFragmented(true);
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi","stream":true}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        IReadOnlyList<SseFrame> frames = SseFrameParser.Parse(await server.GetBodyAsync(response));
        Assert.Equal(6, frames.Count);
        Assert.Equal("response.completed", frames[^1].Event);
    }

    private static async IAsyncEnumerable<CanonicalEvent> EnumerableAsync(IEnumerable<CanonicalEvent> events)
    {
        foreach (CanonicalEvent evt in events)
        {
            yield return evt;
            await Task.Yield();
        }
    }

    private static async IAsyncEnumerable<CanonicalEvent> ThrowAfterAsync(IEnumerable<CanonicalEvent> events)
    {
        foreach (CanonicalEvent evt in events)
        {
            yield return evt;
            await Task.Yield();
        }

        throw new InvalidOperationException("boom");
    }
}
