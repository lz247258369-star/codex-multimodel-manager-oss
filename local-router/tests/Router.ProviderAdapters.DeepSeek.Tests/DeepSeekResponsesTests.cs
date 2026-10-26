using ProviderContractKit;
using Router.ClientAdapters.Responses;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

public sealed class DeepSeekResponsesTests
{
    [Fact]
    public async Task Non_stream_response_is_decoded_with_text_output()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, DeepSeekFixtures.NonStreamJson("deepseek synthetic answer")));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.Equal("resp_deepseek_nonstream", result.Response!.Id);
        MessageOutputItem message = Assert.IsType<MessageOutputItem>(Assert.Single(result.Response.Output));
        OutputTextPart part = Assert.Single(message.Content);
        Assert.Equal("deepseek synthetic answer", part.Text);
    }

    [Fact]
    public async Task Non_stream_usage_maps_input_output_and_total_tokens()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, DeepSeekFixtures.UsageJson()));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.Equal(100, result.Response!.Usage!.InputTokens);
        Assert.Equal(50, result.Response.Usage.OutputTokens);
        Assert.Equal(150, result.Response.Usage.TotalTokens);
        Assert.Equal(30, result.Response.Usage.CachedTokens);
        Assert.Equal(12, result.Response.Usage.ReasoningTokens);
    }

    [Fact]
    public async Task Usage_without_details_keeps_optional_fields_null()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, DeepSeekFixtures.UsageWithoutDetailsJson()));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.Null(result.Response!.Usage!.CachedTokens);
        Assert.Null(result.Response.Usage.ReasoningTokens);
    }

    [Fact]
    public async Task Missing_usage_stays_null()
    {
        string response = """
            {"id":"resp_deepseek_no_usage","object":"response","created_at":1752000000,"status":"completed","model":"deepseek-v4-pro","output":[],"usage":null}
            """;
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, response));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.Null(result.Response!.Usage);
    }
}
