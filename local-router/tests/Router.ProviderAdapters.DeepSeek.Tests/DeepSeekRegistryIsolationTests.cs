using Router.Configuration;
using Router.ProviderAdapters.DeepSeek;
using Router.Registries;
using Router.TestSupport;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

public sealed class DeepSeekRegistryIsolationTests
{
    [Fact]
    public void DeepSeek_adapter_registration_marks_only_deepseek_eligible()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            Endpoints =
            [
                TestRouterConfigFactory.Endpoint(endpointId: "endpoint.deepseek-primary") with
                {
                    BaseUrlRef = "provider-config:deepseek.base_url",
                },
            ],
            ProviderRoutes =
            [
                TestRouterConfigFactory.ProviderRoute(
                    providerRouteId: "provider-route.deepseek-primary",
                    providerId: DeepSeekProviderAdapter.ProviderId,
                    adapterId: DeepSeekProviderAdapter.AdapterId,
                    endpointIds: ["endpoint.deepseek-primary"]),
            ],
            ModelRoutes =
            [
                TestRouterConfigFactory.ModelRoute(
                    modelRouteId: "model-route.deepseek-v4-pro",
                    providerId: DeepSeekProviderAdapter.ProviderId,
                    clientModelId: "deepseek-v4-pro",
                    modelId: "deepseek-v4-pro",
                    pricingRef: null),
            ],
            Routes =
            [
                TestRouterConfigFactory.Route(
                    routeId: "route.deepseek-v4-pro",
                    providerRouteId: "provider-route.deepseek-primary",
                    modelRouteId: "model-route.deepseek-v4-pro"),
            ],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config),
            adapterRegistrations:
            [
                AdapterRegistration.Protocol(
                    "adapter.protocol.responses-compatible.v1",
                    "protocol.openai.responses.v1",
                    TestRouterConfigFactory.FullCapabilities()),
                AdapterRegistration.Provider(
                    DeepSeekProviderAdapter.AdapterId,
                    DeepSeekProviderAdapter.ProviderId,
                    TestRouterConfigFactory.FullCapabilities()),
            ]);

        result.Validate();
        ProviderDescriptor deepSeek = result.Snapshot!.Providers["deepseek"];
        Assert.Equal(ProviderAvailability.Eligible, deepSeek.Availability);
        Assert.True(deepSeek.IsUsable);
        Assert.True(result.Snapshot.ProviderRoutes["provider-route.deepseek-primary"].HasEligibleAdapter);

        // No other provider identity becomes eligible from this registration.
        Assert.Equal(ProviderAvailability.Planned, result.Snapshot.Providers["mm_openrouter"].Availability);
        Assert.False(result.Snapshot.Providers["mm_openrouter"].IsUsable);
        Assert.False(result.Snapshot.Providers["mm_openai_api"].IsUsable);
        Assert.False(result.Snapshot.Providers["mm_modelstudio"].IsUsable);
        Assert.False(result.Snapshot.Providers["mm_mimo"].IsUsable);
        Assert.Equal(ProviderAvailability.DirectOnly, result.Snapshot.Providers["chatgpt"].Availability);
        // The reserved placeholder identity stays unusable and is never reused.
        Assert.Equal(ProviderAvailability.Placeholder, result.Snapshot.Providers["deepseek_direct"].Availability);
        Assert.False(result.Snapshot.Providers["deepseek_direct"].IsUsable);
    }

    [Fact]
    public void Other_provider_routes_cannot_use_the_deepseek_adapter()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            Endpoints =
            [
                TestRouterConfigFactory.Endpoint(endpointId: "endpoint.modelstudio-primary") with
                {
                    BaseUrlRef = "provider-config:mm_modelstudio.base_url",
                },
            ],
            ProviderRoutes =
            [
                TestRouterConfigFactory.ProviderRoute(
                    providerRouteId: "provider-route.modelstudio-primary",
                    providerId: "mm_modelstudio",
                    adapterId: "adapter.provider.mm_modelstudio.responses.v1",
                    endpointIds: ["endpoint.modelstudio-primary"]),
            ],
            ModelRoutes =
            [
                TestRouterConfigFactory.ModelRoute(
                    modelRouteId: "model-route.modelstudio-deepseek",
                    providerId: "mm_modelstudio",
                    clientModelId: "deepseek-v4-pro",
                    modelId: "deepseek-v4-pro",
                    pricingRef: null),
            ],
            Routes =
            [
                TestRouterConfigFactory.Route(
                    routeId: "route.modelstudio-deepseek",
                    providerRouteId: "provider-route.modelstudio-primary",
                    modelRouteId: "model-route.modelstudio-deepseek"),
            ],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config),
            adapterRegistrations:
            [
                AdapterRegistration.Protocol(
                    "adapter.protocol.responses-compatible.v1",
                    "protocol.openai.responses.v1",
                    TestRouterConfigFactory.FullCapabilities()),
                AdapterRegistration.Provider(
                    DeepSeekProviderAdapter.AdapterId,
                    DeepSeekProviderAdapter.ProviderId,
                    TestRouterConfigFactory.FullCapabilities()),
            ]);

        result.Validate();
        ProviderRouteRegistryEntry modelStudioRoute = result.Snapshot!.ProviderRoutes["provider-route.modelstudio-primary"];
        Assert.False(modelStudioRoute.HasEligibleAdapter);
        Assert.Equal("mm_modelstudio", modelStudioRoute.ProviderId);

        // Registering the DeepSeek adapter never makes the Model Studio
        // identity usable, and it never borrows another provider's route.
        Assert.False(result.Snapshot.Providers["mm_modelstudio"].IsUsable);
        Assert.Equal(ProviderAvailability.Eligible, result.Snapshot.Providers["deepseek"].Availability);
        Assert.True(result.Snapshot.Providers["deepseek"].IsUsable);
    }
}
