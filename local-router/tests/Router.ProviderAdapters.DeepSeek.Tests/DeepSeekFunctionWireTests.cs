using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.FakeProvider;
using Router.ProviderAdapters.DeepSeek;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

/// <summary>DSR7-C-FIX5-B1a: the shared codec fix reaches DeepSeek's outbound body.</summary>
public sealed class DeepSeekFunctionWireTests
{
    [Fact]
    public async Task Ordinary_function_tool_is_sent_with_the_function_type()
    {
        await using FakeProviderServer server = await StartServerAsync();
        CanonicalResponsesRequest request = ResponsesRequestParser.TryParse(
            """{"model":"deepseek-flash","input":"hi","tools":[{"type":"function","name":"get_weather","description":"weather lookup","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false},"strict":true}]}""",
            out CanonicalResponsesRequest? parsed) is null ? parsed! : throw new InvalidOperationException("parse failed");

        await new DeepSeekProviderAdapter().InvokeAsync(DeepSeekInvocationFactory.CreateInvocation(server, request), CancellationToken.None);

        JsonElement tools = JsonDocument.Parse(server.LastRequestBody!).RootElement.GetProperty("tools");
        Assert.Equal("function", tools[0].GetProperty("type").GetString());
        Assert.Equal("get_weather", tools[0].GetProperty("name").GetString());
        Assert.Equal("weather lookup", tools[0].GetProperty("description").GetString());
        Assert.True(tools[0].GetProperty("strict").GetBoolean());
        Assert.True(tools[0].GetProperty("parameters").GetProperty("required")[0].GetString() == "city");
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
