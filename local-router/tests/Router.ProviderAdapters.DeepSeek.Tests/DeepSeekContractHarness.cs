using ProviderContractKit;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Router.Routing;
using Router.Secrets;

namespace Router.ProviderAdapters.DeepSeek.Tests;

/// <summary>
/// Direct DeepSeek harness for the reusable LR-5 Provider Contract Kit. The
/// exact same suite that tested the fake adapter, mm_openrouter,
/// mm_modelstudio, mm_openai_api, and mm_mimo must pass for the direct
/// <c>deepseek</c> provider; there is no DeepSeek-specific second suite. The
/// loopback endpoint is the provider root because the adapter composes the
/// official <c>/responses</c> path itself.
/// </summary>
public sealed class DeepSeekContractHarness : ProviderContractHarness
{
    public const string UpstreamProModel = "deepseek-v4-pro";
    public const string UpstreamFlashModel = "deepseek-flash";

    public override IProviderAdapter CreateAdapter()
        => new DeepSeekProviderAdapter();

    public override SecretHandle CreateSecret()
        => SecretHandle.FromValue("test_fake_key_do_not_use");

    public override UpstreamEndpoint CreateEndpoint(FakeProviderServer server)
    {
        Result<UpstreamEndpoint, Router.Core.Errors.RouterError> created = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "/"),
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
                ProviderId = DeepSeekProviderAdapter.ProviderId,
                AdapterId = DeepSeekProviderAdapter.AdapterId,
                AdapterVersion = DeepSeekProviderAdapter.AdapterVersion,
                SecretRef = new SecretReference
                {
                    Resolver = "environment",
                    Name = "DEEPSEEK_API_KEY",
                    Scope = SecretScope.UserOrProcess,
                    AllowedProviderIds = [DeepSeekProviderAdapter.ProviderId],
                    Version = 1,
                },
                BaseUrlRef = "provider-config:deepseek.base_url",
            },
            ModelRoute = route.ModelRoute with
            {
                ProviderId = DeepSeekProviderAdapter.ProviderId,
                ClientModelId = UpstreamProModel,
                ModelId = UpstreamProModel,
                UpstreamModelId = UpstreamProModel,
            },
        };
    }
}
