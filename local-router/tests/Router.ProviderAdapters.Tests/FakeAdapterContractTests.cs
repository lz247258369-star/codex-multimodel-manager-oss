using ProviderContractKit;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.Responses;

namespace Router.ProviderAdapters.Tests;

/// <summary>
/// The fake Responses adapter must pass the exact same Provider Contract Kit
/// that LR-6/7/7A/7B adapters will inherit. There is no second suite.
/// </summary>
public sealed class FakeAdapterContractTests : ProviderContractSuite
{
    private readonly ProviderContractHarness _harness = new FakeHarness();

    protected override ProviderContractHarness Harness => _harness;

    private sealed class FakeHarness : ProviderContractHarness
    {
        public override IProviderAdapter CreateAdapter()
            => new FakeResponsesProviderAdapter();
    }
}
