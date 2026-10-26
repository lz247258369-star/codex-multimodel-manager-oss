using ProviderContractKit;

namespace Router.ProviderAdapters.OpenRouter.Tests;

/// <summary>
/// The OpenRouter adapter must pass the exact same Provider Contract Kit as the
/// LR-5 fake adapter. There is no OpenRouter-specific second suite.
/// </summary>
public sealed class OpenRouterContractTests : ProviderContractSuite
{
    private readonly ProviderContractHarness _harness = new OpenRouterContractHarness();

    protected override ProviderContractHarness Harness => _harness;
}
