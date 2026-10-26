using ProviderContractKit;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.OpenRouter;
using Router.Registries;
using Router.Routing;
using Router.Secrets;

namespace Router.ProviderAdapters.OpenRouter.Tests;

/// <summary>
/// OpenRouter harness for the reusable LR-5 Provider Contract Kit. The exact
/// same suite that tested the fake adapter must pass for mm_openrouter.
/// </summary>
public sealed class OpenRouterContractHarness : ProviderContractHarness
{
    public override IProviderAdapter CreateAdapter()
        => new OpenRouterProviderAdapter();

    public override SecretHandle CreateSecret()
        => SecretHandle.FromValue("test_fake_key_do_not_use");

    public override ResolvedRoute CreateRoute()
    {
        ResolvedRoute route = ContractRouteFactory.CreateFakeRoute();
        return route with
        {
            ProviderRoute = route.ProviderRoute with
            {
                ProviderId = OpenRouterProviderAdapter.ProviderId,
                AdapterId = OpenRouterProviderAdapter.AdapterId,
                AdapterVersion = OpenRouterProviderAdapter.AdapterVersion,
                SecretRef = new SecretReference
                {
                    Resolver = "environment",
                    Name = "OPENROUTER_API_KEY",
                    Scope = SecretScope.UserOrProcess,
                    AllowedProviderIds = [OpenRouterProviderAdapter.ProviderId],
                    Version = 1,
                },
            },
            ModelRoute = route.ModelRoute with
            {
                ProviderId = OpenRouterProviderAdapter.ProviderId,
                ClientModelId = "z-ai/glm-5.3",
                ModelId = "z-ai/glm-5.3",
                UpstreamModelId = "z-ai/glm-5.3",
            },
        };
    }
}
