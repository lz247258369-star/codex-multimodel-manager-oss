using ProviderContractKit;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.ModelStudio;
using Router.Routing;
using Router.Secrets;

namespace Router.ProviderAdapters.ModelStudio.Tests;

/// <summary>
/// Model Studio harness for the reusable LR-5 Provider Contract Kit. The exact
/// same suite that tested the fake adapter and mm_openrouter must pass for
/// mm_modelstudio; there is no Model Studio-specific second suite.
/// </summary>
public sealed class ModelStudioContractHarness : ProviderContractHarness
{
    public const string UpstreamQwenModel = "qwen3.8-max";
    public const string UpstreamDeepSeekModel = "deepseek-v4-pro";

    public override IProviderAdapter CreateAdapter()
        => new ModelStudioProviderAdapter();

    public override SecretHandle CreateSecret()
        => SecretHandle.FromValue("test_fake_key_do_not_use");

    public override UpstreamEndpoint CreateEndpoint(FakeProviderServer server)
    {
        Result<UpstreamEndpoint, Router.Core.Errors.RouterError> created = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "compatible-mode/v1"),
            tlsRequired: false,
            loopbackTestOnly: true);
        if (created.Error is not null)
        {
            throw new InvalidOperationException("Test endpoint must be valid.");
        }

        return created.Value!;
    }

    public override ResolvedRoute CreateRoute()
    {
        ResolvedRoute route = ContractRouteFactory.CreateFakeRoute();
        return route with
        {
            ProviderRoute = route.ProviderRoute with
            {
                ProviderId = ModelStudioProviderAdapter.ProviderId,
                AdapterId = ModelStudioProviderAdapter.AdapterId,
                AdapterVersion = ModelStudioProviderAdapter.AdapterVersion,
                SecretRef = new SecretReference
                {
                    Resolver = "environment",
                    Name = "CODEX_DASHSCOPE_API_KEY",
                    Scope = SecretScope.UserOrProcess,
                    AllowedProviderIds = [ModelStudioProviderAdapter.ProviderId],
                    Version = 1,
                },
                BaseUrlRef = "provider-config:mm_modelstudio.base_url",
            },
            ModelRoute = route.ModelRoute with
            {
                ProviderId = ModelStudioProviderAdapter.ProviderId,
                ClientModelId = UpstreamQwenModel,
                ModelId = UpstreamQwenModel,
                UpstreamModelId = UpstreamQwenModel,
            },
        };
    }
}
