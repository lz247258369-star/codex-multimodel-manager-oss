using ProviderContractKit;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.OpenAI;
using Xunit;

namespace Router.ProviderAdapters.OpenAI.Tests;

public sealed class OpenAIErrorFixtureTests
{
    [Theory]
    [InlineData(400)]
    [InlineData(401)]
    [InlineData(403)]
    [InlineData(404)]
    [InlineData(408)]
    [InlineData(409)]
    public async Task OpenAI_4xx_statuses_are_normalized(int statusCode)
    {
        ProviderAdapterResult result = await RunStatusAsync(statusCode);

        result.Validate();
        Assert.NotNull(result.Error);
        Assert.Equal(statusCode == 429 ? RouterErrorCode.RateLimited : RouterErrorCode.Provider4xx, result.Error!.Code);
    }

    [Fact]
    public async Task OpenAI_429_is_rate_limited()
    {
        ProviderAdapterResult result = await RunStatusAsync(429);

        result.Validate();
        Assert.Equal(RouterErrorCode.RateLimited, result.Error!.Code);
    }

    [Theory]
    [InlineData(500)]
    [InlineData(502)]
    [InlineData(503)]
    public async Task OpenAI_5xx_statuses_are_normalized(int statusCode)
    {
        ProviderAdapterResult result = await RunStatusAsync(statusCode);

        result.Validate();
        Assert.Equal(RouterErrorCode.Provider5xx, result.Error!.Code);
    }

    [Fact]
    public async Task Malformed_body_is_invalid_response()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(new FakeProviderScenario
        {
            StatusCode = 200,
            Body = "{ nope"u8.ToArray(),
            ContentType = "application/json",
        });

        ProviderAdapterResult result = await new OpenAIProviderAdapter().InvokeAsync(
            OpenAIInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.Equal(RouterErrorCode.InvalidResponse, result.Error!.Code);
    }

    private static async Task<ProviderAdapterResult> RunStatusAsync(int statusCode)
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(statusCode, "{}"));

        return await new OpenAIProviderAdapter().InvokeAsync(
            OpenAIInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);
    }
}
