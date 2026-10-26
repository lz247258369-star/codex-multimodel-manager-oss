using System.Net;
using Router.Ingress.Tests.Support;
using Xunit;

namespace Router.Ingress.Tests;

public sealed class IngressOriginHostTests
{
    private const string Body = """{"model":"gpt-test","input":"hi"}""";

    [Fact]
    public async Task Native_request_without_origin_is_allowed()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Theory]
    [InlineData("http://evil.example")]
    [InlineData("null")]
    [InlineData("*")]
    [InlineData("http://")]
    [InlineData("https://127.0.0.1:47821")]
    public async Task Origin_bearing_requests_are_rejected_by_default(string origin)
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        request.Headers.TryAddWithoutValidation("Origin", origin);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        string body = await server.GetBodyAsync(response);
        Assert.Contains("\"code\":\"origin_forbidden\"", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Origin_cannot_bypass_auth()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        request.Headers.TryAddWithoutValidation("Origin", "http://evil.example");
        request.Headers.Authorization = null;
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    [Fact]
    public async Task Preflight_options_is_rejected()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = new(HttpMethod.Options, "/v1/responses");
        request.Headers.TryAddWithoutValidation("Origin", "http://evil.example");
        request.Headers.TryAddWithoutValidation("Access-Control-Request-Method", "POST");
        request.Headers.TryAddWithoutValidation("Access-Control-Request-Headers", "authorization");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    [Fact]
    public async Task No_wildcard_cors_header_is_ever_emitted()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();
        string[] paths = ["/health", "/v1/router/status", "/v1/responses"];

        foreach (string path in paths)
        {
            using HttpRequestMessage request = path == "/v1/responses"
                ? TestHttp.JsonRequest(HttpMethod.Post, path, Body)
                : new HttpRequestMessage(HttpMethod.Get, path);
            using HttpResponseMessage response = await server.SendAsync(request);

            Assert.False(response.Headers.Contains("Access-Control-Allow-Origin"));
            Assert.False(response.Headers.Contains("Access-Control-Allow-Credentials"));
        }
    }

    [Fact]
    public async Task Explicit_allowlist_permits_exact_origin_only()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync(
            options => options.AllowedOrigins = ["http://trusted.local"]);

        using HttpRequestMessage allowed = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        allowed.Headers.TryAddWithoutValidation("Origin", "http://trusted.local");
        using HttpResponseMessage allowedResponse = await server.SendAsync(allowed);
        Assert.Equal(HttpStatusCode.OK, allowedResponse.StatusCode);

        using HttpRequestMessage denied = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        denied.Headers.TryAddWithoutValidation("Origin", "http://trusted.local.evil");
        using HttpResponseMessage deniedResponse = await server.SendAsync(denied);
        Assert.Equal(HttpStatusCode.Forbidden, deniedResponse.StatusCode);
    }

    [Fact]
    public async Task Wildcard_in_allowlist_is_never_honored()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync(
            options => options.AllowedOrigins = ["*"]);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        request.Headers.TryAddWithoutValidation("Origin", "http://evil.example");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    [Theory]
    [InlineData("evil.com")]
    [InlineData("localhost")]
    public async Task Alternate_host_header_is_rejected(string host)
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        request.Headers.Host = host;
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("\"code\":\"invalid_request\"", await server.GetBodyAsync(response), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Wrong_port_host_header_is_rejected()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        request.Headers.Host = "127.0.0.1:1";
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Correct_host_with_port_is_accepted()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        request.Headers.Host = server.BaseUri.Authority;
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }
}
