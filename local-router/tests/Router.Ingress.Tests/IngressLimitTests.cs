using System.Net;
using System.Text;
using Router.ClientAdapters.Responses;
using Router.Configuration;
using Router.Ingress.Fakes;
using Router.Ingress.Tests.Support;
using Xunit;

namespace Router.Ingress.Tests;

public sealed class IngressLimitTests
{
    [Fact]
    public async Task Body_exact_boundary_is_accepted()
    {
        const int max = 1024;
        string prefix = "{\"model\":\"gpt-test\",\"input\":\"";
        const string suffix = "\"}";
        string body = prefix + new string('a', max - prefix.Length - suffix.Length) + suffix;
        Assert.Equal(max, Encoding.UTF8.GetByteCount(body));

        await using IngressTestServer server = await IngressTestServer.StartAsync(
            options => options.Limits = options.Limits with { MaxRequestBytes = max });

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", body);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task Body_over_boundary_is_413_request_too_large_before_parse()
    {
        const int max = 1024;
        string body = new('x', max * 2);

        await using IngressTestServer server = await IngressTestServer.StartAsync(
            options => options.Limits = options.Limits with { MaxRequestBytes = max });

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", body);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, response.StatusCode);
        string responseBody = await server.GetBodyAsync(response);
        Assert.Contains("\"code\":\"request_too_large\"", responseBody, StringComparison.Ordinal);
        Assert.DoesNotContain(body, responseBody, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Chunked_body_over_boundary_is_413()
    {
        const int max = 1024;
        byte[] overLimit = Encoding.UTF8.GetBytes(new string('y', max * 2));

        await using IngressTestServer server = await IngressTestServer.StartAsync(
            options => options.Limits = options.Limits with { MaxRequestBytes = max });

        using HttpRequestMessage request = new(HttpMethod.Post, "/v1/responses")
        {
            Content = new StreamContent(new NonSeekableStream(overLimit)),
        };
        request.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", IngressTestServer.TestToken);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, response.StatusCode);
        Assert.Contains("\"code\":\"request_too_large\"", await server.GetBodyAsync(response), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("gzip")]
    [InlineData("br")]
    [InlineData("deflate")]
    public async Task Compressed_request_bodies_are_rejected(string encoding)
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        request.Content!.Headers.ContentEncoding.Add(encoding);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        string body = await server.GetBodyAsync(response);
        Assert.Contains("\"code\":\"unsupported_parameter\"", body, StringComparison.Ordinal);
        Assert.Contains("\"param\":\"content_encoding\"", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Identity_content_encoding_is_accepted()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        request.Content!.Headers.ContentEncoding.Add("identity");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task Header_limit_is_enforced()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync(
            options => options.Limits = options.Limits with { MaxHeaderBytes = 1024 });

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        request.Headers.TryAddWithoutValidation("X-Big", new string('b', 4096));
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(431, (int)response.StatusCode);
    }

    [Fact]
    public async Task Connection_limit_rejects_overflow_with_429()
    {
        TaskCompletionSource gate = new(TaskCreationOptions.RunContinuationsAsynchronously);
        FakeResponsesService service = new();
        service.UseHandler(async (request, context, cancellationToken) =>
        {
            await gate.Task.WaitAsync(cancellationToken);
            return ResponsesServiceResult.NonStream(Echo(request));
        });

        await using IngressTestServer server = await IngressTestServer.StartAsync(options =>
        {
            options.Limits = options.Limits with { MaxConnections = 2 };
            options.Service = service;
        });

        using HttpRequestMessage first = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"a"}""");
        using HttpRequestMessage second = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"b"}""");
        Task<HttpResponseMessage> firstTask = server.SendAsync(first);
        Task<HttpResponseMessage> secondTask = server.SendAsync(second);

        await WaitUntilAsync(() => server.Ingress.InFlightCount >= 2, TimeSpan.FromSeconds(5));

        using HttpRequestMessage third = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"c"}""");
        using HttpResponseMessage thirdResponse = await server.SendAsync(third);

        Assert.Equal(HttpStatusCode.TooManyRequests, thirdResponse.StatusCode);
        Assert.Contains("\"code\":\"rate_limited\"", await server.GetBodyAsync(thirdResponse), StringComparison.Ordinal);

        gate.SetResult();
        using HttpResponseMessage firstResponse = await firstTask;
        using HttpResponseMessage secondResponse = await secondTask;
        Assert.Equal(HttpStatusCode.OK, firstResponse.StatusCode);
        Assert.Equal(HttpStatusCode.OK, secondResponse.StatusCode);
    }

    [Fact]
    public async Task Wrong_content_type_is_rejected()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = new(HttpMethod.Post, "/v1/responses")
        {
            Content = new StringContent("""{"model":"gpt-test","input":"hi"}""", Encoding.UTF8, "text/plain"),
        };
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("\"code\":\"invalid_request\"", await server.GetBodyAsync(response), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Json_content_type_with_charset_is_accepted()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = new(HttpMethod.Post, "/v1/responses")
        {
            Content = new ByteArrayContent(Encoding.UTF8.GetBytes("""{"model":"gpt-test","input":"hi"}""")),
        };
        request.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json") { CharSet = "utf-8" };
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
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
