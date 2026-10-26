using ProviderContractKit;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

public sealed class DeepSeekCancellationTests
{
    [Fact]
    public void Descriptor_declares_full_cancellation_support()
    {
        Assert.Equal(CancellationSupport.Full, new DeepSeekProviderAdapter().Descriptor.CancellationSupport);
    }

    [Fact]
    public async Task Pre_cancelled_request_is_normalized_as_cancelled()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, DeepSeekFixtures.NonStreamJson()));

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            cts.Token);

        result.Validate();
        Assert.NotNull(result.Error);
        Assert.Equal(RouterErrorCode.Cancelled, result.Error!.Code);
        Assert.Null(result.Response);
        Assert.Null(result.EventStream);
    }

    [Fact]
    public async Task Un_cancelled_request_completes_normally()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, DeepSeekFixtures.NonStreamJson()));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.Null(result.Error);
    }
}
