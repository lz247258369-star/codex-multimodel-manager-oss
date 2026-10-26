using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.ModelStudio;
using Xunit;

namespace Router.ProviderAdapters.ModelStudio.Tests;

/// <summary>DSR7-C-FIX5-B1a: the shared codec fix reaches Model Studio's outbound body.</summary>
public sealed class ModelStudioFunctionWireTests
{
    [Fact]
    public async Task Ordinary_function_tool_is_sent_with_the_function_type()
    {
        await using FakeProviderServer server = await StartServerAsync();
        CanonicalResponsesRequest request = ResponsesRequestParser.TryParse(
            """{"model":"qwen3-coder-plus","input":"hi","tools":[{"type":"function","name":"get_weather","description":"weather lookup","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false},"strict":true}]}""",
            out CanonicalResponsesRequest? parsed) is null ? parsed! : throw new InvalidOperationException("parse failed");

        await new ModelStudioProviderAdapter().InvokeAsync(ModelStudioInvocationFactory.CreateInvocation(server, request), CancellationToken.None);

        JsonElement tools = JsonDocument.Parse(server.LastRequestBody!).RootElement.GetProperty("tools");
        Assert.Equal("function", tools[0].GetProperty("type").GetString());
        Assert.Equal("get_weather", tools[0].GetProperty("name").GetString());
        Assert.True(tools[0].GetProperty("strict").GetBoolean());
    }

    [Fact]
    public async Task Canonical_apply_patch_tool_fails_closed_and_never_reaches_the_transport()
    {
        await using FakeProviderServer server = await StartServerAsync();
        CanonicalResponsesRequest request = ResponsesRequestParser.TryParse(
            """{"model":"qwen3-coder-plus","input":"hi","tools":[{"type":"custom","name":"apply_patch","format":{"type":"grammar","syntax":"lark","definition":"start: /.+/"}}]}""",
            out CanonicalResponsesRequest? parsed) is null ? parsed! : throw new InvalidOperationException("parse failed");

        var result = await new ModelStudioProviderAdapter().InvokeAsync(
            ModelStudioInvocationFactory.CreateInvocation(server, request),
            CancellationToken.None);

        // DSR7-C-FIX5-B1b-1: the apply_patch request bridge is DeepSeek-only, so
        // every other provider keeps failing closed in the shared adapter base and
        // none of them ever reaches the transport.
        result.Validate();
        Assert.NotNull(result.Error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, result.Error!.Code);
        Assert.Null(server.LastRequestBody);
    }

    private static async Task<FakeProviderServer> StartServerAsync()
    {
        var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(new FakeProviderScenario
        {
            StatusCode = 200,
            Body = System.Text.Encoding.UTF8.GetBytes(
                """{"id":"resp_1","object":"response","created_at":1,"status":"completed","model":"m","output":[]}"""),
            ContentType = "application/json",
        });
        return server;
    }
}
