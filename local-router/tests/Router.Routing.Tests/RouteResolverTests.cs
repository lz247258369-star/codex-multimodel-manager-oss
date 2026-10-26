using Router.CatalogProjection;
using Router.Configuration;
using Router.Core.Context;
using Router.Core.Errors;
using Router.Registries;
using Router.TestSupport;
using Xunit;

namespace Router.Routing.Tests;

public sealed class RouteResolverTests
{
    private readonly RouteResolver _resolver = new();

    private static readonly string[] TwoProviderRouteIds = ["route.openrouter-glm53", "route.mimo-glm53"];
    private static readonly string[] SameProviderRouteIds = ["route.openrouter-primary", "route.openrouter-secondary"];

    [Fact]
    public void Exact_model_mapping_resolves_to_the_configured_route()
    {
        RouterRegistrySnapshot snapshot = Build();

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId);

        result.Validate();
        Assert.True(result.IsResolved);
        Assert.Equal(TestRouterConfigFactory.RouteId, result.Route!.RouteId);
        Assert.Equal(TestRouterConfigFactory.ClientId, result.Route.ClientId);
        Assert.Equal(TestRouterConfigFactory.EndpointId, result.Route.Endpoint.EndpointId);
        Assert.Equal(TestRouterConfigFactory.TimeoutPolicyId, result.Route.TimeoutPolicyId);
        Assert.Equal(TestRouterConfigFactory.RetryPolicyId, result.Route.RetryPolicyId);
        Assert.Equal(TestRouterConfigFactory.FailoverPolicyId, result.Route.FailoverPolicyId);
        Assert.Equal("pricing.mm_openrouter.z-ai-glm-5-3", result.Route.PricingSnapshotId);
        Assert.NotNull(result.Route.SecretRef);
        Assert.Equal("OPENROUTER_API_KEY", result.Route.SecretRef!.Name);
    }

    [Fact]
    public void Explicit_alias_mapping_resolves()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ModelRoutes = [TestRouterConfigFactory.ModelRoute(aliases: ["glm-alias"])],
        };
        RouterRegistrySnapshot snapshot = Build(config);

        RouteResolutionResult result = Resolve(snapshot, "glm-alias");

        result.Validate();
        Assert.True(result.IsResolved);
        Assert.Equal(TestRouterConfigFactory.RouteId, result.Route!.RouteId);
    }

    [Fact]
    public void Provider_scoped_mapping_never_leaks_to_another_provider()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ProviderRoutes =
            [
                TestRouterConfigFactory.ProviderRoute(
                    providerRouteId: "provider-route.mimo-primary",
                    providerId: "mm_mimo",
                    adapterId: "adapter.provider.mm_mimo.responses.v1",
                    endpointIds: ["endpoint.mimo-primary"]),
            ],
            Endpoints = [TestRouterConfigFactory.Endpoint(endpointId: "endpoint.mimo-primary")],
            ModelRoutes = [TestRouterConfigFactory.ModelRoute(
                modelRouteId: "model-route.mimo-pro",
                providerId: "mm_mimo",
                clientModelId: "mimo-v2.5-pro",
                modelId: "mimo-v2.5-pro",
                pricingRef: "pricing.mm_mimo.mimo-v2-5-pro")],
            Routes = [TestRouterConfigFactory.Route(
                routeId: "route.mimo-pro",
                providerRouteId: "provider-route.mimo-primary",
                modelRouteId: "model-route.mimo-pro")],
        };
        RouterRegistrySnapshot snapshot = Build(config, adapters: TwoProviderAdapters());

        RouteResolutionResult mimo = Resolve(snapshot, "mimo-v2.5-pro");
        mimo.Validate();
        Assert.True(mimo.IsResolved);
        Assert.Equal("route.mimo-pro", mimo.Route!.RouteId);

        RouteResolutionResult wrong = Resolve(snapshot, TestRouterConfigFactory.ClientModelId);
        wrong.Validate();
        Assert.False(wrong.IsResolved);
        Assert.Equal(RouterErrorCode.UnknownModel, wrong.Error!.Code);
    }

    [Fact]
    public void Same_model_string_across_providers_is_deterministically_selected()
    {
        (RouterConfig config, IReadOnlyList<AdapterRegistration> adapters) = TwoProvidersConfig();
        RouterRegistrySnapshot snapshot = Build(config, adapters: adapters);

        string? first = null;
        for (int iteration = 0; iteration < 100; iteration++)
        {
            RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId);
            result.Validate();
            Assert.True(result.IsResolved);
            Assert.Contains(result.Route!.RouteId, TwoProviderRouteIds);
            if (first is null)
            {
                first = result.Route.RouteId;
            }
            else
            {
                Assert.Equal(first, result.Route.RouteId);
            }
        }
    }

    [Fact]
    public void Priority_ordering_lowest_numeric_priority_wins()
    {
        (RouterConfig config, IReadOnlyList<AdapterRegistration> adapters) = TwoProvidersConfig();
        config = config with
        {
            Routes =
            [
                TestRouterConfigFactory.Route(priority: 200),
                TestRouterConfigFactory.Route(
                    routeId: "route.mimo-glm53",
                    providerRouteId: "provider-route.mimo-primary",
                    modelRouteId: "model-route.mimo-glm53",
                    priority: 100),
            ],
        };
        RouterRegistrySnapshot snapshot = Build(config, adapters: adapters);

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId);

        result.Validate();
        Assert.Equal("route.mimo-glm53", result.Route!.RouteId);
    }

    [Fact]
    public void Equal_priority_uses_deterministic_weight_selection()
    {
        (RouterConfig config, IReadOnlyList<AdapterRegistration> adapters) = SameProviderTwoRoutesConfig();
        RouterRegistrySnapshot snapshot = Build(config, adapters: adapters);

        string? first = null;
        for (int iteration = 0; iteration < 100; iteration++)
        {
            RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId);
            result.Validate();
            Assert.Contains(result.Route!.RouteId, SameProviderRouteIds);
            first ??= result.Route.RouteId;
            Assert.Equal(first, result.Route.RouteId);
        }
    }

    [Fact]
    public void Explicit_preference_overrides_priority_within_eligible_candidates()
    {
        (RouterConfig config, IReadOnlyList<AdapterRegistration> adapters) = TwoProvidersConfig();
        config = config with
        {
            Routes =
            [
                TestRouterConfigFactory.Route(priority: 100),
                TestRouterConfigFactory.Route(
                    routeId: "route.mimo-glm53",
                    providerRouteId: "provider-route.mimo-primary",
                    modelRouteId: "model-route.mimo-glm53",
                    priority: 200),
            ],
        };
        RouterRegistrySnapshot snapshot = Build(config, adapters: adapters);

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId, preference: "route.mimo-glm53");

        result.Validate();
        Assert.True(result.IsResolved);
        Assert.Equal("route.mimo-glm53", result.Route!.RouteId);
    }

    [Fact]
    public void Disabled_route_rejection_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with { Routes = [TestRouterConfigFactory.Route(enabled: false)] };
        RouterRegistrySnapshot snapshot = Build(config);

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId);

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.RouteDisabled, result.Error!.Code);
    }

    [Fact]
    public void Unhealthy_route_rejection_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        RouterRegistrySnapshot snapshot = Build(config);
        RouteHealthSnapshot health = new()
        {
            ObservedAt = DateTimeOffset.UnixEpoch,
            States = new Dictionary<string, RouteHealthState>(StringComparer.Ordinal)
            {
                [TestRouterConfigFactory.RouteId] = RouteHealthState.Unhealthy,
            },
        };

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId, health: health);

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.RouteIneligible, result.Error!.Code);
    }

    [Fact]
    public void Unknown_health_default_is_eligible_and_never_network_probes()
    {
        RouterRegistrySnapshot snapshot = Build();

        RouteResolutionResult noHealth = Resolve(snapshot, TestRouterConfigFactory.ClientModelId);
        noHealth.Validate();
        Assert.True(noHealth.IsResolved);

        RouteHealthSnapshot unknown = new()
        {
            ObservedAt = DateTimeOffset.UnixEpoch,
            States = new Dictionary<string, RouteHealthState>(StringComparer.Ordinal)
            {
                [TestRouterConfigFactory.RouteId] = RouteHealthState.Unknown,
            },
        };
        RouteResolutionResult withUnknown = Resolve(snapshot, TestRouterConfigFactory.ClientModelId, health: unknown);
        withUnknown.Validate();
        Assert.True(withUnknown.IsResolved);

        RouteHealthSnapshot healthy = new()
        {
            ObservedAt = DateTimeOffset.UnixEpoch,
            States = new Dictionary<string, RouteHealthState>(StringComparer.Ordinal)
            {
                [TestRouterConfigFactory.RouteId] = RouteHealthState.Healthy,
            },
        };
        RouteResolutionResult withHealthy = Resolve(snapshot, TestRouterConfigFactory.ClientModelId, health: healthy);
        withHealthy.Validate();
        Assert.True(withHealthy.IsResolved);
    }

    [Fact]
    public void Configured_disabled_health_cannot_be_enabled_by_health_snapshot()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with { Routes = [TestRouterConfigFactory.Route(healthState: "DISABLED")] };
        RouterRegistrySnapshot snapshot = Build(config);
        RouteHealthSnapshot healthy = new()
        {
            ObservedAt = DateTimeOffset.UnixEpoch,
            States = new Dictionary<string, RouteHealthState>(StringComparer.Ordinal)
            {
                [TestRouterConfigFactory.RouteId] = RouteHealthState.Healthy,
            },
        };

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId, health: healthy);

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.RouteIneligible, result.Error!.Code);
    }

    [Fact]
    public void Effective_capabilities_are_the_explicit_intersection()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            Clients = [TestRouterConfigFactory.Client(capabilities: ["text", "streaming", "tools", "usage", "cancellation"])],
        };
        RouterRegistrySnapshot snapshot = Build(config);

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId);

        result.Validate();
        Assert.True(result.IsResolved);
        Assert.Equal(["streaming", "text", "tools", "usage"], result.Route!.EffectiveCapabilities.Values);
    }

    [Fact]
    public void Unsupported_capability_fails_closed_without_downgrade()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            Clients = [TestRouterConfigFactory.Client(capabilities: ["text", "streaming", "tools", "usage", "cancellation"])],
        };
        RouterRegistrySnapshot snapshot = Build(config);

        RouteResolutionResult result = Resolve(
            snapshot,
            TestRouterConfigFactory.ClientModelId,
            required: CapabilitySet.From(["reasoning"]));

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, result.Error!.Code);
        Assert.Equal("reasoning", result.Error.Param);
    }

    [Fact]
    public void Ambiguity_fails_closed_at_the_registry_boundary()
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

        RegistrySnapshotBuildResult build = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config),
            adapterRegistrations: TestRouterConfigFactory.StandardAdapterRegistrations());

        build.Validate();
        Assert.Null(build.Snapshot);
        Assert.Equal(RouterErrorCode.DuplicateRegistryKey, build.Error!.Code);
    }

    [Fact]
    public void Direct_only_provider_placeholder_is_never_eligible()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ProviderRoutes = [TestRouterConfigFactory.ProviderRoute(
                providerId: "chatgpt",
                adapterId: "adapter.provider.chatgpt.responses.v1")],
            ModelRoutes = [TestRouterConfigFactory.ModelRoute(
                providerId: "chatgpt",
                clientModelId: "gpt-5.6-sol",
                modelId: "gpt-5.6-sol")],
        };
        RouterRegistrySnapshot snapshot = Build(config);

        RouteResolutionResult result = Resolve(snapshot, "gpt-5.6-sol");

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.PlaceholderUnavailable, result.Error!.Code);
    }

    [Fact]
    public void Future_protocol_placeholder_is_never_eligible()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ProtocolRoutes = [TestRouterConfigFactory.ProtocolRoute(
                protocolRouteId: "protocol-route.anthropic-placeholder",
                ingressProtocol: "protocol.anthropic.messages.v1",
                upstreamProtocol: "protocol.anthropic.messages.v1")],
            Routes = [TestRouterConfigFactory.Route(protocolRouteId: "protocol-route.anthropic-placeholder")],
        };
        RouterRegistrySnapshot snapshot = Build(config);

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId);

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.PlaceholderUnavailable, result.Error!.Code);
    }

    [Fact]
    public void Stealth_model_name_never_implies_a_real_model_mapping()
    {
        RouterRegistrySnapshot snapshot = Build(catalog: TestRouterConfigFactory.StandardCatalogProjection());

        RouteResolutionResult result = Resolve(snapshot, "stealth/ox-alpha");

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.UnknownModel, result.Error!.Code);
    }

    [Fact]
    public void Catalog_metadata_never_enables_cross_provider_implicit_routing()
    {
        RouterRegistrySnapshot snapshot = Build(catalog: TestRouterConfigFactory.StandardCatalogProjection());

        RouteResolutionResult result = Resolve(snapshot, "gpt-5.6-sol");

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.UnknownModel, result.Error!.Code);
    }

    [Fact]
    public void Unknown_provider_fails_closed_at_resolution()
    {
        RouterRegistrySnapshot snapshot = Build();
        var providerRoutes = snapshot.ProviderRoutes.ToDictionary(static pair => pair.Key, static pair => pair.Value, StringComparer.Ordinal);
        providerRoutes[TestRouterConfigFactory.ProviderRouteId] = providerRoutes[TestRouterConfigFactory.ProviderRouteId] with { ProviderId = "mm_nope" };
        RouterRegistrySnapshot corrupted = RouterRegistrySnapshot.Create(
            snapshot.ConfigGeneration,
            snapshot.Clients,
            snapshot.Providers,
            providerRoutes,
            snapshot.Protocols,
            snapshot.ProtocolRoutes,
            snapshot.ModelRoutes,
            snapshot.Routes,
            snapshot.Endpoints,
            snapshot.Policies,
            snapshot.CatalogProjection);

        RouteResolutionResult result = Resolve(corrupted, TestRouterConfigFactory.ClientModelId);

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.UnknownProvider, result.Error!.Code);
    }

    [Fact]
    public void Unknown_model_fails_closed()
    {
        RouterRegistrySnapshot snapshot = Build();

        RouteResolutionResult result = Resolve(snapshot, "never-configured-model");

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.UnknownModel, result.Error!.Code);
    }

    [Fact]
    public void Unknown_protocol_route_fails_closed_at_resolution()
    {
        RouterRegistrySnapshot snapshot = Build();
        RouterRegistrySnapshot corrupted = RouterRegistrySnapshot.Create(
            snapshot.ConfigGeneration,
            snapshot.Clients,
            snapshot.Providers,
            snapshot.ProviderRoutes,
            snapshot.Protocols,
            new Dictionary<string, ProtocolRouteRegistryEntry>(StringComparer.Ordinal),
            snapshot.ModelRoutes,
            snapshot.Routes,
            snapshot.Endpoints,
            snapshot.Policies,
            snapshot.CatalogProjection);

        RouteResolutionResult result = Resolve(corrupted, TestRouterConfigFactory.ClientModelId);

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.UnknownProtocol, result.Error!.Code);
    }

    [Fact]
    public void Unauthorized_client_route_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            Clients = [TestRouterConfigFactory.Client(allowedRouteIds: ["route.other"])],
        };
        RouterRegistrySnapshot snapshot = Build(config);

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId);

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.RouteNotAllowed, result.Error!.Code);
    }

    [Fact]
    public void Explicit_route_preference_to_non_matching_route_is_rejected()
    {
        RouterRegistrySnapshot snapshot = Build();

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId, preference: "route.does-not-match");

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.ExplicitRoutePreferenceInvalid, result.Error!.Code);
    }

    [Fact]
    public void Explicit_route_preference_to_ineligible_route_is_rejected()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with { Routes = [TestRouterConfigFactory.Route(enabled: false)] };
        RouterRegistrySnapshot snapshot = Build(config);

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId, preference: TestRouterConfigFactory.RouteId);

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.RouteDisabled, result.Error!.Code);
    }

    [Fact]
    public void Immutable_generation_mismatch_fails_closed()
    {
        RouterRegistrySnapshot snapshot = Build();
        RequestContext mismatched = TestRequestContext.Create(TestRouterConfigFactory.ClientId, configGeneration: "1111111111111111111111111111111111111111111111111111111111111111");

        RouteResolutionResult result = _resolver.Resolve(
            RouteRequest.Create(TestRouterConfigFactory.ClientId, TestRouterConfigFactory.ClientModelId, CapabilitySet.From(["text"])),
            snapshot,
            context: mismatched);

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.InvalidRegistry, result.Error!.Code);
    }

    [Fact]
    public void Matching_generation_context_resolves_normally()
    {
        RouterRegistrySnapshot snapshot = Build();
        RequestContext matching = TestRequestContext.Create(TestRouterConfigFactory.ClientId, configGeneration: snapshot.ConfigGeneration);

        RouteResolutionResult result = _resolver.Resolve(
            RouteRequest.Create(TestRouterConfigFactory.ClientId, TestRouterConfigFactory.ClientModelId, CapabilitySet.From(["text"])),
            snapshot,
            context: matching);

        result.Validate();
        Assert.True(result.IsResolved);
    }

    [Fact]
    public void Direct_mode_default_config_resolves_nothing()
    {
        RouterConfig defaults = TestRouterConfigFactory.StandardConfig() with
        {
            Clients = [],
            ProtocolRoutes = [],
            ProviderRoutes = [],
            Endpoints = [],
            ModelRoutes = [],
            Routes = [],
            Policies = [],
        };
        RouterRegistrySnapshot snapshot = Build(defaults);

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId);

        result.Validate();
        Assert.False(result.IsResolved);
        Assert.Equal(RouterErrorCode.UnknownClient, result.Error!.Code);
    }

    [Fact]
    public void Resolver_is_pure_and_never_requires_router_enabled()
    {
        RouterRegistrySnapshot snapshot = Build();

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId);

        result.Validate();
        Assert.True(result.IsResolved);
    }

    [Fact]
    public void Catalog_projection_enriches_the_resolved_model_route()
    {
        RouterRegistrySnapshot snapshot = Build(catalog: TestRouterConfigFactory.StandardCatalogProjection());

        RouteResolutionResult result = Resolve(snapshot, TestRouterConfigFactory.ClientModelId);

        result.Validate();
        Assert.True(result.IsResolved);
        Assert.NotNull(result.Route!.ModelRoute.CatalogMetadata);
        Assert.Equal("mm_openrouter", result.Route.ModelRoute.CatalogMetadata!.ProviderId);
        Assert.Equal(CatalogAvailabilityTier.Caution, result.Route.ModelRoute.CatalogMetadata.AvailabilityTier);
    }

    private static RouterRegistrySnapshot Build(
        RouterConfig? config = null,
        IReadOnlyList<AdapterRegistration>? adapters = null,
        RouterCatalogProjection? catalog = null,
        string? generation = null)
    {
        RegistrySnapshotBuildResult result = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config ?? TestRouterConfigFactory.StandardConfig(), generation),
            catalog,
            adapters ?? TestRouterConfigFactory.StandardAdapterRegistrations());
        result.Validate();
        return result.Snapshot!;
    }

    private RouteResolutionResult Resolve(
        RouterRegistrySnapshot snapshot,
        string model,
        CapabilitySet? required = null,
        string? preference = null,
        RouteHealthSnapshot? health = null,
        RequestContext? context = null)
        => _resolver.Resolve(
            RouteRequest.Create(TestRouterConfigFactory.ClientId, model, required ?? CapabilitySet.From(["text"]), preference),
            snapshot,
            health,
            context);

    private static (RouterConfig Config, IReadOnlyList<AdapterRegistration> Adapters) TwoProvidersConfig()
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
        return (config, TwoProviderAdapters());
    }

    private static (RouterConfig Config, IReadOnlyList<AdapterRegistration> Adapters) SameProviderTwoRoutesConfig()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        config = config with
        {
            ProviderRoutes =
            [
                TestRouterConfigFactory.ProviderRoute(),
                TestRouterConfigFactory.ProviderRoute(
                    providerRouteId: "provider-route.openrouter-secondary",
                    endpointIds: ["endpoint.openrouter-secondary"]),
            ],
            Endpoints =
            [
                TestRouterConfigFactory.Endpoint(),
                TestRouterConfigFactory.Endpoint(endpointId: "endpoint.openrouter-secondary"),
            ],
            Routes =
            [
                TestRouterConfigFactory.Route(routeId: "route.openrouter-primary"),
                TestRouterConfigFactory.Route(
                    routeId: "route.openrouter-secondary",
                    providerRouteId: "provider-route.openrouter-secondary"),
            ],
        };
        return (config, TestRouterConfigFactory.StandardAdapterRegistrations());
    }

    private static IReadOnlyList<AdapterRegistration> TwoProviderAdapters()
    {
        IReadOnlyList<AdapterRegistration> standard = TestRouterConfigFactory.StandardAdapterRegistrations();
        return
        [
            standard[0],
            standard[1],
            AdapterRegistration.Provider("adapter.provider.mm_mimo.responses.v1", "mm_mimo", TestRouterConfigFactory.FullCapabilities()),
        ];
    }
}
