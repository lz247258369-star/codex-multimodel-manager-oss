using System.Net;
using Router.Core.Lifecycle;
using Router.Ingress;
using Router.Ingress.Fakes;
using Router.Ingress.Tests.Support;
using Xunit;

namespace Router.Ingress.Tests;

public sealed class IngressParsingCapabilityTests
{
    [Theory]
    [InlineData("""{"model":"gpt-test","input":"hello"}""")]
    [InlineData("""{"model":"gpt-test","input":"hi","instructions":"be brief"}""")]
    [InlineData("""{"model":"gpt-test","input":"hi","reasoning":{"effort":"medium","summary":"auto"}}""")]
    [InlineData("""{"model":"gpt-test","input":"hi","tools":[{"type":"function","name":"f","parameters":{"type":"object","properties":{}}}]}""")]
    [InlineData("""{"model":"gpt-test","input":[{"type":"function_call_output","call_id":"c1","output":"42"}]}""")]
    [InlineData("""{"model":"gpt-test","input":"hi","metadata":{"k":"v"},"stream":false}""")]
    public async Task Supported_request_shapes_succeed(string body)
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", body);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    // DSR7-C-FIX1: the 422 envelope must also carry the SAFE field path of the
    // rejected capability, and the request must never reach the response service.
    [Theory]
    [InlineData("""{"model":"gpt-test","input":"hi","background":true}""", "unsupported_capability", "background")]
    [InlineData("""{"model":"gpt-test","input":"hi","store":true}""", "unsupported_capability", "store")]
    [InlineData("""{"model":"gpt-test","input":"hi","modalities":["image"]}""", "unsupported_capability", "modalities")]
    [InlineData("""{"model":"gpt-test","input":"hi","previous_response_id":"resp_1"}""", "unsupported_capability", "previous_response_id")]
    [InlineData("""{"model":"gpt-test","input":[{"type":"message","role":"user","content":[{"type":"input_image","image_url":"https://x/y.png"}]}]}""", "unsupported_capability", "input[0].content[0].type")]
    [InlineData("""{"model":"gpt-test","input":[{"type":"item_reference","id":"i1"}]}""", "unsupported_capability", "input[0].type")]
    [InlineData("""{"model":"gpt-test","input":"hi","tools":[{"type":"web_search","name":"s"}]}""", "unsupported_capability", "tools[0].type")]
    [InlineData("""{"model":"gpt-test","input":"hi","tools":[{"type":"function","name":"f","parameters":{"type":"object"}},{"type":"file_search","name":"s2"}]}""", "unsupported_capability", "tools[1].type")]
    [InlineData("""{"model":"gpt-test","input":"hi","tool_choice":{"type":"web_search","name":"s"}}""", "unsupported_capability", "tool_choice.type")]
    public async Task Deferred_capabilities_return_422(string body, string expectedCode, string expectedParam)
    {
        FakeResponsesService service = new();
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", body);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.UnprocessableEntity, response.StatusCode);
        string responseBody = await server.GetBodyAsync(response);
        Assert.Contains("\"code\":\"" + expectedCode + "\"", responseBody, StringComparison.Ordinal);
        Assert.Contains("\"param\":\"" + expectedParam + "\"", responseBody, StringComparison.Ordinal);
        Assert.Contains("\"request_id\":\"req_", responseBody, StringComparison.Ordinal);
        Assert.Empty(service.Calls);
        // The parse rejection still produces exactly one observed request result;
        // what matters is that the response service (and therefore any provider
        // attempt) was never invoked.
        Assert.True(server.Observer.Results.Count <= 1);
    }

    // DSR7-C-FIX1 privacy contract: the diagnostic answers "which field", never
    // "what content", and the request is rejected before any provider attempt.
    [Fact]
    public async Task Unsupported_tool_diagnostic_never_leaks_request_content()
    {
        const string body =
            """{"model":"gpt-test","input":"DO_NOT_LEAK_12345","tools":[{"type":"web_search","name":"never_log_me","description":"DO_NOT_LEAK_12345"}]}""";

        FakeResponsesService service = new();
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", body);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.UnprocessableEntity, response.StatusCode);
        string responseBody = await server.GetBodyAsync(response);
        Assert.Contains("\"code\":\"unsupported_capability\"", responseBody, StringComparison.Ordinal);
        Assert.Contains("\"param\":\"tools[0].type\"", responseBody, StringComparison.Ordinal);
        Assert.DoesNotContain("web_search", responseBody, StringComparison.Ordinal);
        Assert.DoesNotContain("never_log_me", responseBody, StringComparison.Ordinal);
        Assert.DoesNotContain("DO_NOT_LEAK_12345", responseBody, StringComparison.Ordinal);
        Assert.DoesNotContain("gpt-test", responseBody, StringComparison.Ordinal);
        Assert.Empty(service.Calls);
    }

    // DSR7-C-FIX2: the failure path must hand the safe capability field path to
    // the in-process observer so the local diagnostic can be written, while a
    // successful request never synthesizes one.
    [Fact]
    public async Task Failure_path_carries_the_safe_capability_path_to_the_observer()
    {
        FakeResponsesService service = new();
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(
            HttpMethod.Post,
            "/v1/responses",
            """{"model":"gpt-test","input":"hi","tools":[{"type":"web_search","name":"never_log_me"}]}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.UnprocessableEntity, response.StatusCode);
        RequestExecutionResult result = Assert.Single(server.Observer.Results);
        Assert.Equal(RequestState.Failed, result.State);
        Assert.Equal("unsupported_capability", result.ErrorCode);
        Assert.Equal("tools[0].type", result.ErrorParam);
        Assert.Empty(service.Calls);
    }

    [Fact]
    public async Task Successful_request_carries_no_error_param()
    {
        FakeResponsesService service = new();
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", """{"model":"gpt-test","input":"hello"}""");
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        RequestExecutionResult result = Assert.Single(server.Observer.Results);
        Assert.Null(result.ErrorParam);
    }

    [Theory]
    [InlineData("""{"model":"gpt-test","input":"hi","temperature":0.7}""", "unsupported_parameter")]
    [InlineData("""{"model":"gpt-test","input":"hi","future_standard_field":1}""", "unsupported_parameter")]
    [InlineData("""{"model":"gpt-test","input":"hi","stream_options":{"include_usage":true}}""", "unsupported_parameter")]
    public async Task Unknown_or_unsupported_parameters_return_400(string body, string expectedCode)
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", body);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("\"code\":\"" + expectedCode + "\"", await server.GetBodyAsync(response), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("{ not json", "invalid_request")]
    [InlineData("""{"input":"hi"}""", "invalid_request")]
    [InlineData("""{"model":"gpt-test"}""", "invalid_request")]
    public async Task Malformed_or_missing_required_fields_return_400(string body, string expectedCode)
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        using HttpRequestMessage request = TestHttp.JsonRequest(HttpMethod.Post, "/v1/responses", body);
        using HttpResponseMessage response = await server.SendAsync(request);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("\"code\":\"" + expectedCode + "\"", await server.GetBodyAsync(response), StringComparison.Ordinal);
    }
}
