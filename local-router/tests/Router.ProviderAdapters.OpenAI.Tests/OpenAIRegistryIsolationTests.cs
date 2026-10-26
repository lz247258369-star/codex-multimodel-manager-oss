using Router.Configuration;
using Router.ProviderAdapters.OpenAI;
using Router.Registries;
using Router.TestSupport;
using Xunit;

namespace Router.ProviderAdapters.OpenAI.Tests;

public sealed class OpenAIRegistryIsolationTests
{
    [Fact]
    public void OpenAI_adapter_registration_marks_only_mm_openai_api_eligible()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config),
            adapterRegistrations:
            [
                AdapterRegistration.Protocol("adapter.protocol.responses-compatible.v1", "protocol.openai.responses.v1", TestRouterConfigFactory.FullCapabilities()),
                AdapterRegistration.Provider(OpenAIProviderAdapter.AdapterId, "mm_openai_api", TestRouterConfigFactory.FullCapabilities()),
            ]);

        result.Validate();
        ProviderDescriptor openaiApi = result.Snapshot!.Providers["mm_openai_api"];
        Assert.Equal(ProviderAvailability.Eligible, openaiApi.Availability);
        Assert.True(openaiApi.IsUsable);

        ProviderDescriptor chatgpt = result.Snapshot.Providers["chatgpt"];
        Assert.Equal(ProviderAvailability.DirectOnly, chatgpt.Availability);
        Assert.False(chatgpt.IsUsable);

        ProviderDescriptor mimo = result.Snapshot.Providers["mm_mimo"];
        Assert.Equal(ProviderAvailability.Planned, mimo.Availability);
        Assert.False(mimo.IsUsable);
    }

    [Fact]
    public void ChatGPT_provider_route_never_becomes_usable_through_the_openai_adapter()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ProviderRoutes =
            [
                TestRouterConfigFactory.ProviderRoute(
                    providerRouteId: "provider-route.chatgpt-direct",
                    providerId: "chatgpt",
                    adapterId: "adapter.provider.chatgpt.responses.v1"),
            ],
            ModelRoutes =
            [
                TestRouterConfigFactory.ModelRoute(
                    modelRouteId: "model-route.chatgpt-direct",
                    providerId: "chatgpt",
                    clientModelId: "gpt-5.6",
                    modelId: "gpt-5.6",
                    upstreamModelId: "gpt-5.6",
                    pricingRef: null),
            ],
            Routes =
            [
                TestRouterConfigFactory.Route(
                    routeId: "route.chatgpt-direct",
                    providerRouteId: "provider-route.chatgpt-direct",
                    modelRouteId: "model-route.chatgpt-direct"),
            ],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config),
            adapterRegistrations:
            [
                AdapterRegistration.Protocol("adapter.protocol.responses-compatible.v1", "protocol.openai.responses.v1", TestRouterConfigFactory.FullCapabilities()),
                AdapterRegistration.Provider(OpenAIProviderAdapter.AdapterId, "mm_openai_api", TestRouterConfigFactory.FullCapabilities()),
            ]);

        result.Validate();
        ProviderRouteRegistryEntry providerRoute = result.Snapshot!.ProviderRoutes["provider-route.chatgpt-direct"];
        Assert.False(providerRoute.HasEligibleAdapter);
        Assert.Equal("chatgpt", providerRoute.ProviderId);

        ProviderDescriptor chatgpt = result.Snapshot.Providers["chatgpt"];
        Assert.Equal(ProviderAvailability.DirectOnly, chatgpt.Availability);
        Assert.False(chatgpt.IsUsable);
    }
}
