using System.Net;
using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.Core.Ids;
using Router.Core.Support;
using Router.Ingress.Fakes;
using Router.Ingress.Tests.Support;
using Xunit;

namespace Router.Ingress.Tests;

public sealed class IngressNonStreamTests
{
    [Fact]
    public async Task Canonical_response_shape_is_emitted()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hello"}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("application/json", response.Content.Headers.ContentType!.MediaType);

        string body = await server.GetBodyAsync(response);
        using JsonDocument document = JsonDocument.Parse(body);
        JsonElement root = document.RootElement;
        Assert.StartsWith("resp_", root.GetProperty("id").GetString(), StringComparison.Ordinal);
        Assert.Equal("response", root.GetProperty("object").GetString());
        Assert.Equal("completed", root.GetProperty("status").GetString());
        Assert.Equal("gpt-test", root.GetProperty("model").GetString());
        Assert.Equal("assistant", root.GetProperty("output")[0].GetProperty("role").GetString());
        Assert.Contains("Synthetic response", root.GetProperty("output")[0].GetProperty("content")[0].GetProperty("text").GetString(), StringComparison.Ordinal);
        Assert.Equal(12, root.GetProperty("usage").GetProperty("total_tokens").GetInt32());
        Assert.False(root.TryGetProperty("error", out _));
    }

    [Fact]
    public async Task Correlation_headers_are_canonical()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        string requestId = response.Headers.GetValues("X-Request-Id").Single();
        string traceId = response.Headers.GetValues("X-Trace-Id").Single();
        Assert.Matches("^req_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", requestId);
        Assert.Matches("^trc_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", traceId);
    }

    [Fact]
    public async Task Valid_request_id_is_echoed_and_invalid_is_replaced()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        const string validId = "req_00000000-0000-7000-8000-000000000001";
        using HttpRequestMessage validRequest = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        validRequest.Headers.TryAddWithoutValidation("X-Request-Id", validId);
        using HttpResponseMessage validResponse = await server.SendAsync(validRequest);
        Assert.Equal(validId, validResponse.Headers.GetValues("X-Request-Id").Single());

        using HttpRequestMessage invalidRequest = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        invalidRequest.Headers.TryAddWithoutValidation("X-Request-Id", "req_evil; rm -rf");
        using HttpResponseMessage invalidResponse = await server.SendAsync(invalidRequest);
        string generated = invalidResponse.Headers.GetValues("X-Request-Id").Single();
        Assert.NotEqual("req_evil; rm -rf", generated);
        Assert.Matches("^req_[0-9a-f-]{36}$", generated);
    }

    [Fact]
    public async Task Overlong_and_unicode_correlation_headers_are_replaced()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage overlong = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        overlong.Headers.TryAddWithoutValidation("X-Request-Id", "req_" + new string('a', 200));
        using HttpResponseMessage overlongResponse = await server.SendAsync(overlong);
        Assert.Matches("^req_[0-9a-f-]{36}$", overlongResponse.Headers.GetValues("X-Request-Id").Single());

        // Unicode and control characters are rejected by the typed-ID contract
        // before they can ever reach a header write path.
        Assert.False(RequestId.TryParse("req_你好", out _));
        Assert.False(RequestId.TryParse("req_00000000-0000-7000-8000-000000000001\r\nX-Evil: 1", out _));
    }

    [Fact]
    public async Task Valid_traceparent_is_accepted_and_invalid_replaced()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        const string validTrace = "trc_00000000-0000-7000-8000-000000000002";
        using HttpRequestMessage validRequest = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        validRequest.Headers.TryAddWithoutValidation("traceparent", validTrace);
        using HttpResponseMessage validResponse = await server.SendAsync(validRequest);
        Assert.Equal(validTrace, validResponse.Headers.GetValues("X-Trace-Id").Single());

        using HttpRequestMessage invalidRequest = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        invalidRequest.Headers.TryAddWithoutValidation("traceparent", "00-00000000000000000000000000000000-0000000000000000-01");
        using HttpResponseMessage invalidResponse = await server.SendAsync(invalidRequest);
        Assert.Matches("^trc_[0-9a-f-]{36}$", invalidResponse.Headers.GetValues("X-Trace-Id").Single());
    }

    [Fact]
    public async Task Idempotency_key_is_hashed_and_never_returned()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        request.Headers.TryAddWithoutValidation("Idempotency-Key", "client-key-123");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        string body = await server.GetBodyAsync(response);
        Assert.DoesNotContain("client-key-123", body, StringComparison.Ordinal);

        RequestExecutionResult result = Assert.Single(server.Observer.Results);
        Assert.Equal(SafeHasher.Sha256Hex("client-key-123"), result.IdempotencyKeyHash);
        Assert.DoesNotContain("client-key-123", JsonSerializer.Serialize(result), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Overlong_idempotency_key_is_rejected()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        request.Headers.TryAddWithoutValidation("Idempotency-Key", new string('k', 300));
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("\"code\":\"invalid_request\"", await server.GetBodyAsync(response), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Service_exception_maps_to_safe_500_envelope()
    {
        FakeResponsesService service = new();
        service.WithException(new InvalidOperationException("secret detail must not leak"));
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.InternalServerError, response.StatusCode);
        string body = await server.GetBodyAsync(response);
        Assert.Contains("\"code\":\"internal_error\"", body, StringComparison.Ordinal);
        Assert.DoesNotContain("secret detail", body, StringComparison.Ordinal);
        Assert.Contains("\"request_id\":\"req_", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Provider_timeout_maps_to_504()
    {
        FakeResponsesService service = new();
        service.WithError(RouterError.ProviderTimeout());
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hi"}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.GatewayTimeout, response.StatusCode);
        Assert.Contains("\"code\":\"provider_timeout\"", await server.GetBodyAsync(response), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Request_content_never_reaches_error_or_response()
    {
        FakeResponsesService service = new();
        service.WithError(RouterError.UnsupportedCapability());
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"sensitive-prompt-content"}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        string body = await server.GetBodyAsync(response);
        Assert.DoesNotContain("sensitive-prompt-content", body, StringComparison.Ordinal);
    }
}
