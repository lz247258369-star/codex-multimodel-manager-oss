using System.Net;
using System.Text.Json;
using Router.Configuration;
using Router.Ingress.Tests.Support;
using Xunit;

namespace Router.Ingress.Tests;

public sealed class IngressAuthTests
{
    private const string Body = """{"model":"gpt-test","input":"hi"}""";

    [Fact]
    public async Task Missing_authorization_is_401_authentication_required()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();
        using HttpClient anonymous = server.CreateAnonymousClient();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        using HttpResponseMessage response = await anonymous.SendAsync(request);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        string body = await server.GetBodyAsync(response);
        Assert.Contains("\"code\":\"authentication_required\"", body, StringComparison.Ordinal);
        Assert.Contains("\"type\":\"router_error\"", body, StringComparison.Ordinal);
        Assert.Contains("\"retryable\":false", body, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("Basic abc")]
    [InlineData("Bearer")]
    [InlineData("Bearer ")]
    [InlineData("bearer token")]
    public async Task Malformed_authorization_is_401_authentication_invalid(string authorization)
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        request.Headers.TryAddWithoutValidation("Authorization", authorization);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        string body = await server.GetBodyAsync(response);
        Assert.Contains("\"code\":\"authentication_invalid\"", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Wrong_token_is_401_authentication_invalid()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", "wrong-token");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        string body = await server.GetBodyAsync(response);
        Assert.Contains("\"code\":\"authentication_invalid\"", body, StringComparison.Ordinal);
        Assert.DoesNotContain("wrong-token", body, StringComparison.Ordinal);
        Assert.DoesNotContain(IngressTestServer.TestToken, body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Correct_token_succeeds()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task Token_never_appears_in_any_response()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();
        var paths = new[] { "/health", "/v1/router/status" };

        foreach (string path in paths)
        {
            using HttpResponseMessage response = await server.SendAsync(new HttpRequestMessage(HttpMethod.Get, path));
            string body = await server.GetBodyAsync(response);
            Assert.DoesNotContain(IngressTestServer.TestToken, body, StringComparison.Ordinal);
        }

        using HttpRequestMessage good = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        using HttpResponseMessage goodResponse = await server.SendAsync(good);
        Assert.DoesNotContain(IngressTestServer.TestToken, await server.GetBodyAsync(goodResponse), StringComparison.Ordinal);

        using HttpRequestMessage bad = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        bad.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", "wrong-token");
        using HttpResponseMessage badResponse = await server.SendAsync(bad);
        Assert.DoesNotContain("wrong-token", await server.GetBodyAsync(badResponse), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Wrong_token_lengths_return_identical_envelope()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        string shortBody = await SendWithTokenAsync(server, "x");
        string longBody = await SendWithTokenAsync(server, new string('z', 300));

        using JsonDocument shortDoc = JsonDocument.Parse(shortBody);
        using JsonDocument longDoc = JsonDocument.Parse(longBody);
        Assert.Equal(
            shortDoc.RootElement.GetProperty("error").GetProperty("code").GetString(),
            longDoc.RootElement.GetProperty("error").GetProperty("code").GetString());
        Assert.Equal(
            shortDoc.RootElement.GetProperty("error").GetProperty("message").GetString(),
            longDoc.RootElement.GetProperty("error").GetProperty("message").GetString());
        Assert.Null(shortDoc.RootElement.GetProperty("error").GetProperty("param").GetString());
        Assert.Null(longDoc.RootElement.GetProperty("error").GetProperty("param").GetString());
    }

    [Fact]
    public async Task Scope_denied_when_client_does_not_grant_responses_invoke()
    {
        IReadOnlyList<ClientConfig> clients =
        [
            new ClientConfig
            {
                ClientId = "client.local_status",
                AdapterId = "adapter.client.local_status.responses.v1",
                Enabled = true,
                AuthScope = "router:status",
                Version = 1,
            },
        ];
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Clients = clients);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        string body = await server.GetBodyAsync(response);
        Assert.Contains("\"code\":\"scope_denied\"", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Scope_denied_for_status_when_scope_missing()
    {
        IReadOnlyList<ClientConfig> clients =
        [
            new ClientConfig
            {
                ClientId = "client.local_test",
                AdapterId = "adapter.client.local_test.responses.v1",
                Enabled = true,
                AuthScope = "responses:invoke",
                Version = 1,
            },
        ];
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Clients = clients);

        using HttpResponseMessage response = await server.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/v1/router/status"));

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        Assert.Contains("\"code\":\"scope_denied\"", await server.GetBodyAsync(response), StringComparison.Ordinal);
    }

    [Fact]
    public async Task No_clients_means_fail_closed()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Clients = []);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        Assert.Contains("\"code\":\"scope_denied\"", await server.GetBodyAsync(response), StringComparison.Ordinal);
    }

    private static async Task<string> SendWithTokenAsync(IngressTestServer server, string token)
    {
        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", Body);
        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
        using HttpResponseMessage response = await server.SendAsync(request);
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        return await server.GetBodyAsync(response);
    }
}
