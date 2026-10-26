using System.Net;
using System.Text.Json;
using Router.Ingress.Tests.Support;
using Xunit;

namespace Router.Ingress.Tests;

public sealed class IngressRoutingSurfaceTests
{
    [Fact]
    public async Task Health_is_public_and_minimal()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = new(HttpMethod.Get, "/health");
        request.Headers.Authorization = null;
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("application/json", response.Content.Headers.ContentType!.MediaType);
        string body = await server.GetBodyAsync(response);
        using JsonDocument document = JsonDocument.Parse(body);
        JsonElement root = document.RootElement;
        Assert.Equal(1, root.GetProperty("schema_version").GetInt32());
        Assert.Equal("READY", root.GetProperty("lifecycle").GetString());
        Assert.True(root.GetProperty("ready").GetBoolean());
        Assert.Equal(3, root.EnumerateObject().Count());
    }

    [Fact]
    public async Task Status_requires_auth_and_returns_redacted_state()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpResponseMessage response = await server.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/v1/router/status"));
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        string body = await server.GetBodyAsync(response);
        using JsonDocument document = JsonDocument.Parse(body);
        JsonElement root = document.RootElement;
        Assert.Equal(1, root.GetProperty("schema_version").GetInt32());
        Assert.Equal("READY", root.GetProperty("lifecycle").GetString());
        Assert.True(root.GetProperty("ready").GetBoolean());
        Assert.Equal(new string('a', 64), root.GetProperty("config_generation").GetString());
        // The status request itself is admitted, so in-flight count is at least 1.
        Assert.True(root.GetProperty("in_flight_count").GetInt32() >= 1);
        Assert.True(root.GetProperty("local_router_enabled").GetBoolean());
        Assert.Equal("responses/v1", Assert.Single(root.GetProperty("supported_contracts").EnumerateArray()).GetString());
        Assert.Empty(root.GetProperty("routes").EnumerateArray());
    }

    [Fact]
    public async Task Status_without_auth_is_401()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();
        using HttpClient anonymous = server.CreateAnonymousClient();

        using HttpRequestMessage request = new(HttpMethod.Get, "/v1/router/status");
        using HttpResponseMessage response = await anonymous.SendAsync(request);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        string body = await server.GetBodyAsync(response);
        Assert.Contains("\"code\":\"authentication_required\"", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Post_responses_exists()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task Wrong_method_returns_405()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = new(HttpMethod.Get, "/v1/responses");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.MethodNotAllowed, response.StatusCode);
    }

    [Theory]
    [InlineData("/v1/chat/completions")]
    [InlineData("/v1/completions")]
    [InlineData("/v1/models")]
    [InlineData("/v1/responses/resp_1/cancel")]
    [InlineData("/admin")]
    [InlineData("/debug")]
    [InlineData("/metrics")]
    [InlineData("/provider/openrouter")]
    [InlineData("/routes")]
    [InlineData("/config")]
    [InlineData("/nope")]
    public async Task Forbidden_paths_return_404(string path)
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, path, """{"model":"gpt-test","input":"hi"}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }
}
