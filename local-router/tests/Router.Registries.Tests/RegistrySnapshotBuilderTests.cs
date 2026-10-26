using Router.CatalogProjection;
using Router.Configuration;
using Router.Core.Errors;
using Router.TestSupport;
using Xunit;

namespace Router.Registries.Tests;

public sealed class RegistrySnapshotBuilderTests
{
    [Fact]
    public void Standard_config_builds_an_immutable_snapshot()
    {
        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(TestRouterConfigFactory.StandardConfig()),
            catalogProjection: TestRouterConfigFactory.StandardCatalogProjection(),
            adapterRegistrations: TestRouterConfigFactory.StandardAdapterRegistrations());

        result.Validate();
        Assert.NotNull(result.Snapshot);
        Assert.Equal(TestRouterConfigFactory.TestGeneration, result.Snapshot!.ConfigGeneration);
        Assert.Equal(1, result.Snapshot.Version);
        Assert.Single(result.Snapshot.Routes);
        Assert.Single(result.Snapshot.ModelRoutes);
        Assert.Single(result.Snapshot.Endpoints);
        foreach (string providerId in new[] { "chatgpt", "mm_openai_api", "mm_modelstudio", "mm_openrouter", "mm_mimo" })
        {
            Assert.True(result.Snapshot.Providers.ContainsKey(providerId));
        }
    }

    [Fact]
    public void Snapshot_binds_the_exact_config_generation()
    {
        RegistrySnapshotBuildResult first = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(TestRouterConfigFactory.StandardConfig(), "1111111111111111111111111111111111111111111111111111111111111111"));
        RegistrySnapshotBuildResult second = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(TestRouterConfigFactory.StandardConfig(), "2222222222222222222222222222222222222222222222222222222222222222"));

        first.Validate();
        second.Validate();
        Assert.Equal("1111111111111111111111111111111111111111111111111111111111111111", first.Snapshot!.ConfigGeneration);
        Assert.Equal("2222222222222222222222222222222222222222222222222222222222222222", second.Snapshot!.ConfigGeneration);
    }

    [Fact]
    public void Unknown_client_in_route_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            Routes = [TestRouterConfigFactory.Route(clientIds: ["client.missing"])],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(TestRouterConfigFactory.Snapshot(config));

        result.Validate();
        Assert.Null(result.Snapshot);
        Assert.Equal(RouterErrorCode.UnknownClient, result.Error!.Code);
    }

    [Fact]
    public void Unknown_policy_reference_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            Routes = [TestRouterConfigFactory.Route(timeoutPolicyId: "policy.nope")],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(TestRouterConfigFactory.Snapshot(config));

        result.Validate();
        Assert.Null(result.Snapshot);
        Assert.Equal(RouterErrorCode.InvalidRegistry, result.Error!.Code);
    }

    [Fact]
    public void Unknown_provider_route_reference_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            Routes = [TestRouterConfigFactory.Route(providerRouteId: "provider-route.missing")],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(TestRouterConfigFactory.Snapshot(config));

        result.Validate();
        Assert.Null(result.Snapshot);
        Assert.Equal(RouterErrorCode.UnknownRoute, result.Error!.Code);
    }

    [Fact]
    public void Unknown_endpoint_reference_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ProviderRoutes = [TestRouterConfigFactory.ProviderRoute(endpointIds: ["endpoint.missing"])],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(TestRouterConfigFactory.Snapshot(config));

        result.Validate();
        Assert.Null(result.Snapshot);
        Assert.Equal(RouterErrorCode.UnknownEndpoint, result.Error!.Code);
    }

    [Fact]
    public void Cross_provider_model_relation_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ModelRoutes = [TestRouterConfigFactory.ModelRoute(providerId: "mm_mimo", clientModelId: "mimo-v2.5-pro", modelId: "mimo-v2.5-pro")],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(TestRouterConfigFactory.Snapshot(config));

        result.Validate();
        Assert.Null(result.Snapshot);
        Assert.Equal(RouterErrorCode.InvalidProviderModelRelation, result.Error!.Code);
    }

    [Fact]
    public void Duplicate_provider_scoped_client_model_id_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ModelRoutes =
            [
                TestRouterConfigFactory.ModelRoute(),
                TestRouterConfigFactory.ModelRoute(
                    modelRouteId: "model-route.glm53-openrouter-b",
                    clientModelId: TestRouterConfigFactory.ClientModelId,
                    modelId: "z-ai/glm-5.3-b"),
            ],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(TestRouterConfigFactory.Snapshot(config));

        result.Validate();
        Assert.Null(result.Snapshot);
        Assert.Equal(RouterErrorCode.DuplicateRegistryKey, result.Error!.Code);
    }

    [Fact]
    public void Ambiguous_alias_within_provider_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ModelRoutes =
            [
                TestRouterConfigFactory.ModelRoute(aliases: ["alias-glm"]),
                TestRouterConfigFactory.ModelRoute(
                    modelRouteId: "model-route.glm53-openrouter-b",
                    clientModelId: "z-ai/glm-5.3-alt",
                    modelId: "z-ai/glm-5.3-alt",
                    aliases: ["alias-glm"]),
            ],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(TestRouterConfigFactory.Snapshot(config));

        result.Validate();
        Assert.Null(result.Snapshot);
        Assert.Equal(RouterErrorCode.AmbiguousModel, result.Error!.Code);
    }

    [Fact]
    public void Alias_colliding_with_exact_mapping_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ModelRoutes =
            [
                TestRouterConfigFactory.ModelRoute(aliases: [TestRouterConfigFactory.ClientModelId]),
            ],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(TestRouterConfigFactory.Snapshot(config));

        result.Validate();
        Assert.Null(result.Snapshot);
        Assert.Equal(RouterErrorCode.AmbiguousModel, result.Error!.Code);
    }

    [Fact]
    public void Unknown_fallback_route_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            Routes = [TestRouterConfigFactory.Route(fallbackRouteIds: ["route.missing"])],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(TestRouterConfigFactory.Snapshot(config));

        result.Validate();
        Assert.Null(result.Snapshot);
        Assert.Equal(RouterErrorCode.UnknownRoute, result.Error!.Code);
    }

    [Fact]
    public void Self_fallback_route_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            Routes = [TestRouterConfigFactory.Route(fallbackRouteIds: [TestRouterConfigFactory.RouteId])],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(TestRouterConfigFactory.Snapshot(config));

        result.Validate();
        Assert.Null(result.Snapshot);
        Assert.Equal(RouterErrorCode.UnknownRoute, result.Error!.Code);
    }

    [Fact]
    public void Direct_only_provider_route_builds_but_is_not_usable()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ProviderRoutes = [TestRouterConfigFactory.ProviderRoute(providerId: "chatgpt", adapterId: "adapter.provider.chatgpt.responses.v1")],
            ModelRoutes = [TestRouterConfigFactory.ModelRoute(providerId: "chatgpt", clientModelId: "gpt-5.6-sol", modelId: "gpt-5.6-sol")],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config),
            adapterRegistrations:
            [
                AdapterRegistration.Protocol("adapter.protocol.responses-compatible.v1", "protocol.openai.responses.v1", TestRouterConfigFactory.FullCapabilities()),
            ]);

        result.Validate();
        ProviderDescriptor chatgpt = result.Snapshot!.Providers["chatgpt"];
        Assert.Equal(ProviderAvailability.DirectOnly, chatgpt.Availability);
        Assert.False(chatgpt.IsUsable);
    }

    [Fact]
    public void Placeholder_protocol_is_registered_but_never_eligible()
    {
        ProtocolDescriptor anthropic = BuiltInProtocols.All["protocol.anthropic.messages.v1"];

        Assert.True(anthropic.IsPlaceholder);
        Assert.False(anthropic.IsEligibleProtocol);
    }

    [Fact]
    public void Catalog_projection_enriches_explicit_model_routes_only()
    {
        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(TestRouterConfigFactory.StandardConfig()),
            catalogProjection: TestRouterConfigFactory.StandardCatalogProjection(),
            adapterRegistrations: TestRouterConfigFactory.StandardAdapterRegistrations());

        result.Validate();
        ModelRouteRegistryEntry modelRoute = result.Snapshot!.ModelRoutes[TestRouterConfigFactory.ModelRouteId];
        Assert.NotNull(modelRoute.CatalogMetadata);
        Assert.Equal("mm_openrouter", modelRoute.CatalogMetadata!.ProviderId);
        Assert.Equal("z-ai/glm-5.3", modelRoute.CatalogMetadata.ModelId);
    }

    [Fact]
    public void Absent_catalog_metadata_never_invalidates_an_explicit_route()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ModelRoutes = [TestRouterConfigFactory.ModelRoute(clientModelId: "not-in-catalog", modelId: "not-in-catalog")],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config),
            catalogProjection: TestRouterConfigFactory.StandardCatalogProjection(),
            adapterRegistrations: TestRouterConfigFactory.StandardAdapterRegistrations());

        result.Validate();
        Assert.Null(result.Snapshot!.ModelRoutes[TestRouterConfigFactory.ModelRouteId].CatalogMetadata);
    }

    [Fact]
    public void Adapter_registration_must_match_provider_identity()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config),
            adapterRegistrations:
            [
                AdapterRegistration.Protocol("adapter.protocol.responses-compatible.v1", "protocol.openai.responses.v1", TestRouterConfigFactory.FullCapabilities()),
                AdapterRegistration.Provider("adapter.provider.mm_openrouter.responses.v1", "mm_mimo", TestRouterConfigFactory.FullCapabilities()),
            ]);

        result.Validate();
        ProviderRouteRegistryEntry providerRoute = result.Snapshot!.ProviderRoutes[TestRouterConfigFactory.ProviderRouteId];
        Assert.False(providerRoute.HasEligibleAdapter);
    }

    [Fact]
    public void Model_lookup_is_exact_then_explicit_alias_within_provider_scope()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ModelRoutes = [TestRouterConfigFactory.ModelRoute(aliases: ["glm-alias"])],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(TestRouterConfigFactory.Snapshot(config));
        result.Validate();

        ModelLookupResult exact = result.Snapshot!.TryResolveModel("mm_openrouter", TestRouterConfigFactory.ClientModelId);
        exact.Validate();
        Assert.True(exact.IsFound);
        Assert.Equal(TestRouterConfigFactory.ModelRouteId, exact.Entry!.ModelRouteId);

        ModelLookupResult alias = result.Snapshot.TryResolveModel("mm_openrouter", "glm-alias");
        alias.Validate();
        Assert.True(alias.IsFound);
        Assert.Equal(TestRouterConfigFactory.ModelRouteId, alias.Entry!.ModelRouteId);

        ModelLookupResult otherProvider = result.Snapshot.TryResolveModel("mm_mimo", TestRouterConfigFactory.ClientModelId);
        otherProvider.Validate();
        Assert.False(otherProvider.IsFound);
        Assert.Equal(RouterErrorCode.UnknownModel, otherProvider.Error!.Code);
    }

    [Fact]
    public void Same_model_string_in_different_providers_is_never_merged()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ProviderRoutes =
            [
                TestRouterConfigFactory.ProviderRoute(),
                TestRouterConfigFactory.ProviderRoute(
                    providerRouteId: "provider-route.mimo-primary",
                    providerId: "mm_mimo",
                    adapterId: "adapter.provider.mm_mimo.responses.v1"),
            ],
            Endpoints =
            [
                TestRouterConfigFactory.Endpoint(),
                TestRouterConfigFactory.Endpoint(endpointId: "endpoint.mimo-primary"),
            ],
            ModelRoutes =
            [
                TestRouterConfigFactory.ModelRoute(),
                TestRouterConfigFactory.ModelRoute(
                    modelRouteId: "model-route.mimo-glm53",
                    providerId: "mm_mimo",
                    clientModelId: TestRouterConfigFactory.ClientModelId,
                    modelId: TestRouterConfigFactory.ClientModelId,
                    pricingRef: "pricing.mm_mimo.z-ai-glm-5-3"),
            ],
            Routes =
            [
                TestRouterConfigFactory.Route(),
                TestRouterConfigFactory.Route(
                    routeId: "route.mimo-glm53",
                    providerRouteId: "provider-route.mimo-primary",
                    modelRouteId: "model-route.mimo-glm53"),
            ],
        };

        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config),
            adapterRegistrations: TestRouterConfigFactory.StandardAdapterRegistrations());

        result.Validate();
        ModelLookupResult openrouter = result.Snapshot!.TryResolveModel("mm_openrouter", TestRouterConfigFactory.ClientModelId);
        ModelLookupResult mimo = result.Snapshot.TryResolveModel("mm_mimo", TestRouterConfigFactory.ClientModelId);

        openrouter.Validate();
        mimo.Validate();
        Assert.Equal("model-route.glm53-openrouter", openrouter.Entry!.ModelRouteId);
        Assert.Equal("model-route.mimo-glm53", mimo.Entry!.ModelRouteId);
    }
}
