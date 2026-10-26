using ProviderContractKit;

namespace Router.ProviderAdapters.OpenAI.Tests;

/// <summary>
/// The OpenAI API adapter must pass the exact same Provider Contract Kit as
/// the LR-5 fake adapter, mm_openrouter, and mm_modelstudio. There is no
/// OpenAI-specific second suite.
/// </summary>
public sealed class OpenAIContractTests : ProviderContractSuite
{
    private readonly ProviderContractHarness _harness = new OpenAIContractHarness();

    protected override ProviderContractHarness Harness => _harness;
}
