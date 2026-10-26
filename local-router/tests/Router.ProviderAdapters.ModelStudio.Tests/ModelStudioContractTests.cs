using ProviderContractKit;

namespace Router.ProviderAdapters.ModelStudio.Tests;

/// <summary>
/// The Model Studio adapter must pass the exact same Provider Contract Kit as
/// the LR-5 fake adapter and mm_openrouter. There is no Model Studio-specific
/// second suite.
/// </summary>
public sealed class ModelStudioContractTests : ProviderContractSuite
{
    private readonly ProviderContractHarness _harness = new ModelStudioContractHarness();

    protected override ProviderContractHarness Harness => _harness;
}
