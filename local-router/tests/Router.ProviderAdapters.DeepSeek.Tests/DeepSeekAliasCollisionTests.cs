using Router.Configuration;
using Router.Core.Errors;
using Router.ProviderAdapters.DeepSeek;
using Router.Registries;
using Router.TestSupport;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

/// <summary>
/// DSR2: the explicit model-route aliases that keep the legacy Codex picker
/// slugs routable must never weaken the existing registry collision safety. An
/// alias that collides with another route's client model id inside the same
/// provider still fails closed; nothing is resolved first-wins.
/// </summary>
public sealed class DeepSeekAliasCollisionTests
{
    [Fact]
    public void Alias_colliding_with_another_routes_client_model_id_fails_closed()
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
                    modelRouteId: "model-route.deepseek-flash",
                    providerId: DeepSeekProviderAdapter.ProviderId,
                    clientModelId: "deepseek-flash",
                    modelId: "deepseek-flash",
                    aliases: ["deepseek-v4-flash"],
                    pricingRef: null),
                TestRouterConfigFactory.ModelRoute(
                    modelRouteId: "model-route.deepseek-legacy-owner",
                    providerId: DeepSeekProviderAdapter.ProviderId,
                    clientModelId: "deepseek-v4-flash",
                    modelId: "deepseek-v4-flash",
                    pricingRef: null),
            ],
            Routes =
            [
                TestRouterConfigFactory.Route(
                    routeId: "route.deepseek-flash",
                    providerRouteId: "provider-route.deepseek-primary",
                    modelRouteId: "model-route.deepseek-flash"),
                TestRouterConfigFactory.Route(
                    routeId: "route.deepseek-legacy-owner",
                    providerRouteId: "provider-route.deepseek-primary",
                    modelRouteId: "model-route.deepseek-legacy-owner"),
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

        Assert.Null(result.Snapshot);
        Assert.NotNull(result.Error);
        Assert.Equal(RouterErrorCode.AmbiguousModel, result.Error!.Code);
    }
}
