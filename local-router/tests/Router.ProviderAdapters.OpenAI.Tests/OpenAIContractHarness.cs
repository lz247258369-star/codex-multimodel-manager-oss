using ProviderContractKit;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.OpenAI;
using Router.Routing;
using Router.Secrets;

namespace Router.ProviderAdapters.OpenAI.Tests;

/// <summary>
/// OpenAI API harness for the reusable LR-5 Provider Contract Kit. The exact
/// same suite that tested the fake adapter, mm_openrouter, and mm_modelstudio
/// must pass for mm_openai_api; there is no OpenAI-specific second suite.
/// </summary>
public sealed class OpenAIContractHarness : ProviderContractHarness
{
    public const string UpstreamGpt56Model = "gpt-5.6";
    public const string UpstreamTerraModel = "gpt-5.6-terra";

    public override IProviderAdapter CreateAdapter()
        => new OpenAIProviderAdapter();

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
                ProviderId = OpenAIProviderAdapter.ProviderId,
                AdapterId = OpenAIProviderAdapter.AdapterId,
                AdapterVersion = OpenAIProviderAdapter.AdapterVersion,
                SecretRef = new SecretReference
                {
                    Resolver = "environment",
                    Name = "CODEX_OPENAI_API_KEY",
                    Scope = SecretScope.UserOrProcess,
                    AllowedProviderIds = [OpenAIProviderAdapter.ProviderId],
                    Version = 1,
                },
                BaseUrlRef = "provider-config:mm_openai_api.base_url",
            },
            ModelRoute = route.ModelRoute with
            {
                ProviderId = OpenAIProviderAdapter.ProviderId,
                ClientModelId = UpstreamGpt56Model,
                ModelId = UpstreamGpt56Model,
                UpstreamModelId = UpstreamGpt56Model,
            },
        };
    }
}
