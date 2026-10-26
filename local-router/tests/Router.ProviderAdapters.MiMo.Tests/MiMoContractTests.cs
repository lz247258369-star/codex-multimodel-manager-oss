using ProviderContractKit;

namespace Router.ProviderAdapters.MiMo.Tests;

/// <summary>
/// The Xiaomi MiMo adapter must pass the exact same Provider Contract Kit as
/// the LR-5 fake adapter and every earlier provider adapter. There is no
/// MiMo-specific second suite.
/// </summary>
public sealed class MiMoContractTests : ProviderContractSuite
{
    private readonly ProviderContractHarness _harness = new MiMoContractHarness();

    protected override ProviderContractHarness Harness => _harness;
}
