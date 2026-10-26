using ProviderContractKit;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

public sealed class DeepSeekErrorFixtureTests
{
    [Theory]
    [InlineData(400)]
    [InlineData(401)]
    [InlineData(403)]
    [InlineData(404)]
    [InlineData(408)]
    [InlineData(409)]
    public async Task DeepSeek_4xx_statuses_are_normalized(int statusCode)
    {
        ProviderAdapterResult result = await RunStatusAsync(statusCode);

        result.Validate();
        Assert.NotNull(result.Error);
        Assert.Equal(RouterErrorCode.Provider4xx, result.Error!.Code);
    }

    [Fact]
    public async Task DeepSeek_429_is_rate_limited()
    {
        ProviderAdapterResult result = await RunStatusAsync(429);

        result.Validate();
        // The adapter normalizes the status only; it never selects another
        // provider or retries on its own (failover is policy-layer owned and
        // cross-model failover stays off by default).
        Assert.Equal(RouterErrorCode.RateLimited, result.Error!.Code);
    }

    [Theory]
    [InlineData(500)]
    [InlineData(502)]
    [InlineData(503)]
    [InlineData(504)]
    public async Task DeepSeek_5xx_statuses_are_normalized(int statusCode)
    {
        ProviderAdapterResult result = await RunStatusAsync(statusCode);

        result.Validate();
        Assert.Equal(RouterErrorCode.Provider5xx, result.Error!.Code);
    }

    [Fact]
    public async Task Authorization_failures_never_leak_headers_or_secrets()
    {
        foreach (int status in new[] { 401, 403 })
        {
            await using var server = new FakeProviderServer();
            await server.StartAsync();
            server.SetScenario(FakeProviderScenario.Json(status, """{"error":{"message":"denied"}}"""));

            ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
                DeepSeekInvocationFactory.CreateInvocation(
                    server,
                    ContractRouteFactory.CreateRequest(),
                    secretValue: "test-fake-secret-value-never-real"),
                CancellationToken.None);

            result.Validate();
            Assert.Equal(RouterErrorCode.Provider4xx, result.Error!.Code);
            Assert.DoesNotContain("test-fake-secret-value-never-real", result.Error.Message, StringComparison.Ordinal);
            Assert.DoesNotContain("Authorization", result.Error.Message, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("Bearer", result.Error.Message, StringComparison.OrdinalIgnoreCase);
        }
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

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.Equal(RouterErrorCode.InvalidResponse, result.Error!.Code);
    }

    private static async Task<ProviderAdapterResult> RunStatusAsync(int statusCode)
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(statusCode, "{}"));

        return await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);
    }
}
