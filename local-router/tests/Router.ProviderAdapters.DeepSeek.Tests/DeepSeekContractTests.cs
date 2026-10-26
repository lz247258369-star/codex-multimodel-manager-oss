using ProviderContractKit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

/// <summary>
/// The direct DeepSeek adapter must pass the exact same Provider Contract Kit as
/// the LR-5 fake adapter and every earlier provider adapter. There is no
/// DeepSeek-specific second suite.
/// </summary>
public sealed class DeepSeekContractTests : ProviderContractSuite
{
    private readonly ProviderContractHarness _harness = new DeepSeekContractHarness();

    protected override ProviderContractHarness Harness => _harness;
}
