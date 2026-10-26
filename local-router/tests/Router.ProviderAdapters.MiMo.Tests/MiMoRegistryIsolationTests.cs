using Router.Configuration;
using Router.ProviderAdapters.MiMo;
using Router.Registries;
using Router.TestSupport;
using Xunit;

namespace Router.ProviderAdapters.MiMo.Tests;

public sealed class MiMoRegistryIsolationTests
{
    [Fact]
    public void Mimo_adapter_registration_marks_only_mm_mimo_eligible()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config),
            adapterRegistrations:
            [
                AdapterRegistration.Protocol("adapter.protocol.responses-compatible.v1", "protocol.openai.responses.v1", TestRouterConfigFactory.FullCapabilities()),
                AdapterRegistration.Provider(MiMoProviderAdapter.AdapterId, "mm_mimo", TestRouterConfigFactory.FullCapabilities()),
            ]);

        result.Validate();
        ProviderDescriptor mimo = result.Snapshot!.Providers["mm_mimo"];
        Assert.Equal(ProviderAvailability.Eligible, mimo.Availability);
        Assert.True(mimo.IsUsable);

        ProviderDescriptor openai = result.Snapshot.Providers["mm_openai_api"];
        Assert.Equal(ProviderAvailability.Planned, openai.Availability);
        Assert.False(openai.IsUsable);

        ProviderDescriptor modelStudio = result.Snapshot.Providers["mm_modelstudio"];
        Assert.Equal(ProviderAvailability.Planned, modelStudio.Availability);
        Assert.False(modelStudio.IsUsable);

        ProviderDescriptor chatgpt = result.Snapshot.Providers["chatgpt"];
        Assert.Equal(ProviderAvailability.DirectOnly, chatgpt.Availability);
        Assert.False(chatgpt.IsUsable);
    }

    [Fact]
    public void Other_provider_routes_cannot_use_the_mimo_adapter()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ProviderRoutes =
            [
                TestRouterConfigFactory.ProviderRoute(
                    providerRouteId: "provider-route.openai-primary",
                    providerId: "mm_openai_api",
                    adapterId: "adapter.provider.mm_openai_api.responses.v1"),
            ],
            ModelRoutes =
            [
                TestRouterConfigFactory.ModelRoute(
                    modelRouteId: "model-route.openai-primary",
                    providerId: "mm_openai_api",
                    clientModelId: "gpt-5.6",
                    modelId: "gpt-5.6",
                    upstreamModelId: "gpt-5.6",
                    pricingRef: null),
            ],
            Routes =
            [
                TestRouterConfigFactory.Route(
                    routeId: "route.openai-primary",
                    providerRouteId: "provider-route.openai-primary",
                    modelRouteId: "model-route.openai-primary"),
            ],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config),
            adapterRegistrations:
            [
                AdapterRegistration.Protocol("adapter.protocol.responses-compatible.v1", "protocol.openai.responses.v1", TestRouterConfigFactory.FullCapabilities()),
                AdapterRegistration.Provider(MiMoProviderAdapter.AdapterId, "mm_mimo", TestRouterConfigFactory.FullCapabilities()),
            ]);

        result.Validate();
        ProviderRouteRegistryEntry openaiRoute = result.Snapshot!.ProviderRoutes["provider-route.openai-primary"];
        Assert.False(openaiRoute.HasEligibleAdapter);
        Assert.Equal("mm_openai_api", openaiRoute.ProviderId);

        ProviderDescriptor mimo = result.Snapshot.Providers["mm_mimo"];
        Assert.Equal(ProviderAvailability.Eligible, mimo.Availability);
        Assert.True(mimo.IsUsable);
    }
}
