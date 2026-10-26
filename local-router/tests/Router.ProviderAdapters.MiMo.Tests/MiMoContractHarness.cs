using ProviderContractKit;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.MiMo;
using Router.Routing;
using Router.Secrets;

namespace Router.ProviderAdapters.MiMo.Tests;

/// <summary>
/// Xiaomi MiMo harness for the reusable LR-5 Provider Contract Kit. The exact
/// same suite that tested the fake adapter, mm_openrouter, mm_modelstudio, and
/// mm_openai_api must pass for mm_mimo; there is no MiMo-specific second
/// suite.
/// </summary>
public sealed class MiMoContractHarness : ProviderContractHarness
{
    public const string UpstreamProModel = "mimo-v2.5-pro";
    public const string UpstreamStandardModel = "mimo-v2.5";

    public override IProviderAdapter CreateAdapter()
        => new MiMoProviderAdapter();

    public override SecretHandle CreateSecret()
        => SecretHandle.FromValue("test_fake_key_do_not_use");

    public override UpstreamEndpoint CreateEndpoint(FakeProviderServer server)
    {
        Result<UpstreamEndpoint, Router.Core.Errors.RouterError> created = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "v1"),
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
                ProviderId = MiMoProviderAdapter.ProviderId,
                AdapterId = MiMoProviderAdapter.AdapterId,
                AdapterVersion = MiMoProviderAdapter.AdapterVersion,
                SecretRef = new SecretReference
                {
                    Resolver = "environment",
                    Name = "MIMO_API_KEY",
                    Scope = SecretScope.UserOrProcess,
                    AllowedProviderIds = [MiMoProviderAdapter.ProviderId],
                    Version = 1,
                },
                BaseUrlRef = "provider-config:mm_mimo.base_url",
            },
            ModelRoute = route.ModelRoute with
            {
                ProviderId = MiMoProviderAdapter.ProviderId,
                ClientModelId = UpstreamProModel,
                ModelId = UpstreamProModel,
                UpstreamModelId = UpstreamProModel,
            },
        };
    }
}
