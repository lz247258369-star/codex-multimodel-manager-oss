using ProviderContractKit;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.MiMo;
using Xunit;

namespace Router.ProviderAdapters.MiMo.Tests;

public sealed class MiMoUsageTests
{
    [Fact]
    public async Task Non_stream_usage_maps_input_output_and_total_tokens()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, MiMoFixtures.UsageJson()));

        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.Equal(100, result.Response!.Usage!.InputTokens);
        Assert.Equal(50, result.Response.Usage.OutputTokens);
        Assert.Equal(150, result.Response.Usage.TotalTokens);
    }

    [Fact]
    public async Task Non_stream_usage_maps_nested_cached_and_reasoning_tokens()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, MiMoFixtures.UsageJson()));

        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.Equal(30, result.Response!.Usage!.CachedTokens);
        Assert.Equal(12, result.Response.Usage.ReasoningTokens);
    }

    [Fact]
    public async Task Usage_without_details_keeps_optional_fields_null()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, MiMoFixtures.UsageWithoutDetailsJson()));

        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.Equal(100, result.Response!.Usage!.InputTokens);
        Assert.Equal(50, result.Response.Usage.OutputTokens);
        Assert.Equal(150, result.Response.Usage.TotalTokens);
        Assert.Null(result.Response.Usage.CachedTokens);
        Assert.Null(result.Response.Usage.ReasoningTokens);
    }

    [Fact]
    public async Task Missing_usage_stays_null()
    {
        string response = """
            {"id":"resp_mimo_no_usage","object":"response","created_at":1752000000,"status":"completed","model":"mimo-v2.5-pro","output":[],"usage":null}
            """;
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, response));

        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.Null(result.Response!.Usage);
    }
}
