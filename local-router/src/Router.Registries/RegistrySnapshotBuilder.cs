using Router.CatalogProjection;
using Router.Configuration;
using Router.Core.Errors;

namespace Router.Registries;

/// <summary>
/// Deterministic builder that turns an immutable effective config snapshot
/// (plus optional catalog projection and explicit adapter registrations) into
/// an immutable <see cref="RouterRegistrySnapshot"/>. Every invariant violation
/// fails closed with a typed error.
/// </summary>
public static class RegistrySnapshotBuilder
{
    /// <summary>Builds the immutable snapshot. Adapter registrations may be empty.</summary>
    public static RegistrySnapshotBuildResult Build(
        EffectiveRouterConfigSnapshot effectiveConfig,
        RouterCatalogProjection? catalogProjection = null,
        IReadOnlyCollection<AdapterRegistration>? adapterRegistrations = null)
    {
        ArgumentNullException.ThrowIfNull(effectiveConfig);

        if (effectiveConfig.Config is not { } config)
        {
            return RegistrySnapshotBuildResult.Fail(RegistryErrors.Invalid());
        }

        RouterError? configError = RouterConfigValidator.Validate(config);
        if (configError is not null)
        {
            return RegistrySnapshotBuildResult.Fail(configError);
        }

        try
        {
            return BuildCore(effectiveConfig.ConfigGeneration, config, catalogProjection, adapterRegistrations);
        }
        catch (RegistryBuildException exception)
        {
            return RegistrySnapshotBuildResult.Fail(exception.Error);
        }
    }

    private static RegistrySnapshotBuildResult BuildCore(
        string configGeneration,
        RouterConfig config,
        RouterCatalogProjection? catalogProjection,
        IReadOnlyCollection<AdapterRegistration>? adapterRegistrations)
    {
        var registrations = (adapterRegistrations ?? []).ToArray();

        var clients = new Dictionary<string, ClientRegistryEntry>(StringComparer.Ordinal);
        foreach (ClientConfig client in config.Clients)
        {
            if (!clients.TryAdd(
                    client.ClientId,
                    new ClientRegistryEntry
                    {
                        ClientId = client.ClientId,
                        AdapterId = client.AdapterId,
                        Enabled = client.Enabled,
                        AuthScope = client.AuthScope,
                        AllowedRouteIds = client.AllowedRouteIds.ToArray(),
                        Capabilities = CapabilitySet.From(client.Capabilities),
                        Version = client.Version,
                    }))
            {
                return RegistrySnapshotBuildResult.Fail(RegistryErrors.Duplicate("clients.client_id"));
            }
        }

        var endpoints = new Dictionary<string, EndpointRegistryEntry>(StringComparer.Ordinal);
        foreach (EndpointConfig endpoint in config.Endpoints)
        {
            if (!endpoints.TryAdd(
                    endpoint.EndpointId,
                    new EndpointRegistryEntry
                    {
                        EndpointId = endpoint.EndpointId,
                        BaseUrlRef = endpoint.BaseUrlRef,
                        Enabled = endpoint.Enabled,
                        DataBoundary = endpoint.DataBoundary,
                        TlsRequired = endpoint.TlsRequired,
                        Priority = endpoint.Priority,
                        Weight = endpoint.Weight,
                        Version = endpoint.Version,
                    }))
            {
                return RegistrySnapshotBuildResult.Fail(RegistryErrors.Duplicate("endpoints.endpoint_id"));
            }
        }

        var protocols = new Dictionary<string, ProtocolDescriptor>(BuiltInProtocols.All, StringComparer.Ordinal);
        var protocolRoutes = new Dictionary<string, ProtocolRouteRegistryEntry>(StringComparer.Ordinal);
        foreach (ProtocolRouteConfig route in config.ProtocolRoutes)
        {
            if (!protocolRoutes.TryAdd(
                    route.ProtocolRouteId,
                    BuildProtocolRoute(route, registrations, protocols)))
            {
                return RegistrySnapshotBuildResult.Fail(RegistryErrors.Duplicate("protocol_routes.protocol_route_id"));
            }
        }

        var providers = new Dictionary<string, ProviderDescriptor>(BuiltInProviders.All, StringComparer.Ordinal);
        ApplyProviderAdapters(providers, registrations);

        var providerRoutes = new Dictionary<string, ProviderRouteRegistryEntry>(StringComparer.Ordinal);
        foreach (ProviderRouteConfig route in config.ProviderRoutes)
        {
            if (!providers.TryGetValue(route.ProviderId, out ProviderDescriptor? provider))
            {
                return RegistrySnapshotBuildResult.Fail(RegistryErrors.UnknownProvider("provider_routes.provider_id"));
            }

            foreach (string endpointId in route.EndpointIds)
            {
                if (!endpoints.ContainsKey(endpointId))
                {
                    return RegistrySnapshotBuildResult.Fail(RegistryErrors.UnknownEndpoint("provider_routes.endpoint_ids"));
                }
            }

            if (!providerRoutes.TryAdd(
                    route.ProviderRouteId,
                    BuildProviderRoute(route, provider, registrations)))
            {
                return RegistrySnapshotBuildResult.Fail(RegistryErrors.Duplicate("provider_routes.provider_route_id"));
            }
        }

        var modelRoutes = new Dictionary<string, ModelRouteRegistryEntry>(StringComparer.Ordinal);
        var providerScopedKeys = new HashSet<string>(StringComparer.Ordinal);
        foreach (ModelRouteConfig route in config.ModelRoutes)
        {
            if (!providers.ContainsKey(route.ProviderId))
            {
                return RegistrySnapshotBuildResult.Fail(RegistryErrors.UnknownProvider("model_routes.provider_id"));
            }

            string providerScopedKey = route.ProviderId + "\u001f" + route.ClientModelId;
            if (!providerScopedKeys.Add(providerScopedKey))
            {
                return RegistrySnapshotBuildResult.Fail(RegistryErrors.Duplicate("model_routes.provider_scoped_key"));
            }

            if (!modelRoutes.TryAdd(
                    route.ModelRouteId,
                    BuildModelRoute(route, catalogProjection)))
            {
                return RegistrySnapshotBuildResult.Fail(RegistryErrors.Duplicate("model_routes.model_route_id"));
            }
        }

        ValidateModelMappingUniqueness(modelRoutes);

        var policies = new Dictionary<string, PolicyRegistryEntry>(StringComparer.Ordinal);
        foreach (PolicyConfig policy in config.Policies)
        {
            if (!policies.TryAdd(
                    policy.PolicyId,
                    new PolicyRegistryEntry { PolicyId = policy.PolicyId, Version = policy.Version }))
            {
                return RegistrySnapshotBuildResult.Fail(RegistryErrors.Duplicate("policies.policy_id"));
            }
        }

        var routes = new Dictionary<string, RouterRouteRegistryEntry>(StringComparer.Ordinal);
        foreach (RouterRouteConfig route in config.Routes)
        {
            if (!routes.TryAdd(route.RouteId, BuildRoute(route, clients, providerRoutes, protocolRoutes, modelRoutes, policies)))
            {
                return RegistrySnapshotBuildResult.Fail(RegistryErrors.Duplicate("routes.route_id"));
            }
        }

        ValidateFallbackReferences(routes);

        RouterRegistrySnapshot snapshot = RouterRegistrySnapshot.Create(
            configGeneration,
            clients,
            providers,
            providerRoutes,
            protocols,
            protocolRoutes,
            modelRoutes,
            routes,
            endpoints,
            policies,
            catalogProjection);

        return RegistrySnapshotBuildResult.Ok(snapshot);
    }

    private static void ValidateFallbackReferences(IReadOnlyDictionary<string, RouterRouteRegistryEntry> routes)
    {
        foreach (RouterRouteRegistryEntry route in routes.Values)
        {
            foreach (string fallbackRouteId in route.FallbackRouteIds)
            {
                if (!routes.ContainsKey(fallbackRouteId) || string.Equals(fallbackRouteId, route.RouteId, StringComparison.Ordinal))
                {
                    throw new RegistryBuildException(RegistryErrors.UnknownRoute("routes.fallback_route_ids"));
                }
            }
        }
    }

    private static ProtocolRouteRegistryEntry BuildProtocolRoute(
        ProtocolRouteConfig route,
        IReadOnlyList<AdapterRegistration> registrations,
        Dictionary<string, ProtocolDescriptor> protocols)
    {
        bool ingressKnown = protocols.TryGetValue(route.IngressProtocol, out ProtocolDescriptor? ingress);
        bool upstreamKnown = protocols.TryGetValue(route.UpstreamProtocol, out ProtocolDescriptor? upstream);

        if (!ingressKnown || !upstreamKnown)
        {
            throw new RegistryBuildException(RegistryErrors.UnknownProtocol("protocol_routes.protocol"));
        }

        AdapterRegistration? adapter = FindAdapter(registrations, route.AdapterId, route.AdapterVersion, AdapterKind.Protocol);
        bool adapterMatchesProtocol = adapter is not null
            && (adapter.ProtocolId is null || string.Equals(adapter.ProtocolId, route.IngressProtocol, StringComparison.Ordinal));
        bool hasEligibleAdapter = adapter is { Eligible: true } && adapterMatchesProtocol;

        CapabilitySet capabilities = CapabilitySet.From(route.Capabilities);
        if (hasEligibleAdapter)
        {
            capabilities = capabilities.Intersect(CapabilitySet.From(adapter!.Capabilities));
        }

        return new ProtocolRouteRegistryEntry
        {
            ProtocolRouteId = route.ProtocolRouteId,
            IngressProtocol = route.IngressProtocol,
            UpstreamProtocol = route.UpstreamProtocol,
            AdapterId = route.AdapterId,
            AdapterVersion = route.AdapterVersion,
            Capabilities = capabilities,
            LossPolicy = route.LossPolicy,
            Version = route.Version,
            HasEligibleAdapter = hasEligibleAdapter,
            IsEligibleProtocol = ingress!.IsEligibleProtocol && upstream!.IsEligibleProtocol,
        };
    }

    private static ProviderRouteRegistryEntry BuildProviderRoute(
        ProviderRouteConfig route,
        ProviderDescriptor provider,
        IReadOnlyList<AdapterRegistration> registrations)
    {
        AdapterRegistration? adapter = FindAdapter(registrations, route.AdapterId, route.AdapterVersion, AdapterKind.Provider);
        bool adapterMatchesProvider = adapter is not null
            && (adapter.ProviderId is null || string.Equals(adapter.ProviderId, route.ProviderId, StringComparison.Ordinal));
        bool hasEligibleAdapter = adapter is { Eligible: true } && adapterMatchesProvider;

        CapabilitySet capabilities = CapabilitySet.From(route.Capabilities);
        if (hasEligibleAdapter)
        {
            capabilities = capabilities.Intersect(CapabilitySet.From(adapter!.Capabilities));
        }

        return new ProviderRouteRegistryEntry
        {
            ProviderRouteId = route.ProviderRouteId,
            ProviderId = route.ProviderId,
            AdapterId = route.AdapterId,
            AdapterVersion = route.AdapterVersion,
            EndpointIds = route.EndpointIds.ToArray(),
            SecretRef = route.SecretRef,
            BaseUrlRef = route.BaseUrlRef,
            Enabled = route.Enabled,
            Capabilities = capabilities,
            Version = route.Version,
            HasEligibleAdapter = hasEligibleAdapter,
        };
    }

    private static ModelRouteRegistryEntry BuildModelRoute(ModelRouteConfig route, RouterCatalogProjection? catalogProjection)
    {
        CatalogModelMetadata? metadata = catalogProjection?.TryGet(route.ProviderId, route.ModelId);
        return new ModelRouteRegistryEntry
        {
            ModelRouteId = route.ModelRouteId,
            ProviderId = route.ProviderId,
            ClientModelId = route.ClientModelId,
            ModelId = route.ModelId,
            UpstreamModelId = route.UpstreamModelId,
            Aliases = route.Aliases.ToArray(),
            Capabilities = CapabilitySet.From(route.Capabilities),
            PricingRef = route.PricingRef,
            IdentityVerification = route.IdentityVerification,
            Enabled = route.Enabled,
            Version = route.Version,
            CatalogMetadata = metadata,
        };
    }

    private static void ValidateModelMappingUniqueness(Dictionary<string, ModelRouteRegistryEntry> modelRoutes)
    {
        // Two passes on purpose (LR15-G1). The previous single pass compared an
        // alias only against the exact client_model_id values it had already
        // seen, so an alias that collided with a later-declared route was
        // accepted and only failed (if at all) at resolve time. Alias safety must
        // not depend on declaration order.
        var exactIdsByProvider = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
        var aliasesByProvider = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);

        // Pass 1: the complete set of exact client_model_id values per provider.
        // Duplicate exact ids are already rejected by the provider-scoped key
        // check above, so this pass only collects.
        foreach (ModelRouteRegistryEntry entry in modelRoutes.Values)
        {
            if (!exactIdsByProvider.TryGetValue(entry.ProviderId, out HashSet<string>? exactIds))
            {
                exactIds = [];
                exactIdsByProvider.Add(entry.ProviderId, exactIds);
            }

            exactIds.Add(entry.ClientModelId);
        }

        // Pass 2: every alias must be unique within its provider and must never
        // collide with any exact client_model_id of that provider - whether that
        // route is declared before or after the alias owner - and never with its
        // own route's client_model_id.
        foreach (ModelRouteRegistryEntry entry in modelRoutes.Values)
        {
            if (!aliasesByProvider.TryGetValue(entry.ProviderId, out HashSet<string>? aliases))
            {
                aliases = [];
                aliasesByProvider.Add(entry.ProviderId, aliases);
            }

            HashSet<string> exactIds = exactIdsByProvider[entry.ProviderId];
            foreach (string alias in entry.Aliases)
            {
                if (!aliases.Add(alias)
                    || string.Equals(alias, entry.ClientModelId, StringComparison.Ordinal)
                    || exactIds.Contains(alias))
                {
                    throw new RegistryBuildException(RegistryErrors.AmbiguousModel("model_routes.aliases"));
                }
            }
        }
    }

    private static RouterRouteRegistryEntry BuildRoute(
        RouterRouteConfig route,
        Dictionary<string, ClientRegistryEntry> clients,
        Dictionary<string, ProviderRouteRegistryEntry> providerRoutes,
        Dictionary<string, ProtocolRouteRegistryEntry> protocolRoutes,
        Dictionary<string, ModelRouteRegistryEntry> modelRoutes,
        Dictionary<string, PolicyRegistryEntry> policies)
    {
        foreach (string clientId in route.ClientIds)
        {
            if (!clients.ContainsKey(clientId))
            {
                throw new RegistryBuildException(RegistryErrors.UnknownClient("routes.client_ids"));
            }
        }

        if (!providerRoutes.TryGetValue(route.ProviderRouteId, out ProviderRouteRegistryEntry? providerRoute))
        {
            throw new RegistryBuildException(RegistryErrors.UnknownRoute("routes.provider_route_id"));
        }

        if (!protocolRoutes.TryGetValue(route.ProtocolRouteId, out ProtocolRouteRegistryEntry? protocolRoute))
        {
            throw new RegistryBuildException(RegistryErrors.UnknownProtocol("routes.protocol_route_id"));
        }

        if (!modelRoutes.TryGetValue(route.ModelRouteId, out ModelRouteRegistryEntry? modelRoute))
        {
            throw new RegistryBuildException(RegistryErrors.UnknownModel("routes.model_route_id"));
        }

        if (!string.Equals(providerRoute.ProviderId, modelRoute.ProviderId, StringComparison.Ordinal))
        {
            throw new RegistryBuildException(RegistryErrors.InvalidProviderModelRelation("routes"));
        }

        foreach (string policyId in new[] { route.TimeoutPolicyId, route.RetryPolicyId, route.FailoverPolicyId })
        {
            if (!policies.ContainsKey(policyId))
            {
                throw new RegistryBuildException(RegistryErrors.UnknownPolicy("routes.policy_references"));
            }
        }

        return new RouterRouteRegistryEntry
        {
            RouteId = route.RouteId,
            ClientIds = route.ClientIds.ToArray(),
            ProviderRouteId = route.ProviderRouteId,
            ProtocolRouteId = route.ProtocolRouteId,
            ModelRouteId = route.ModelRouteId,
            Enabled = route.Enabled,
            Priority = route.Priority,
            Weight = route.Weight,
            HealthState = RouteHealthStateParser.Parse(route.HealthState),
            TimeoutPolicyId = route.TimeoutPolicyId,
            RetryPolicyId = route.RetryPolicyId,
            FailoverPolicyId = route.FailoverPolicyId,
            FallbackRouteIds = route.FallbackRouteIds.ToArray(),
            Version = route.Version,
        };
    }

    private static void ApplyProviderAdapters(
        Dictionary<string, ProviderDescriptor> providers,
        IReadOnlyList<AdapterRegistration> registrations)
    {
        foreach (AdapterRegistration registration in registrations)
        {
            if (registration.Kind != AdapterKind.Provider || registration.ProviderId is null)
            {
                continue;
            }

            if (!providers.TryGetValue(registration.ProviderId, out ProviderDescriptor? descriptor))
            {
                continue;
            }

            if (string.Equals(descriptor.AdapterId, registration.AdapterId, StringComparison.Ordinal)
                && string.Equals(descriptor.AdapterVersion, registration.Version, StringComparison.Ordinal))
            {
                providers[registration.ProviderId] = descriptor with
                {
                    HasEligibleAdapter = registration.Eligible,
                    Availability = registration.Eligible ? ProviderAvailability.Eligible : descriptor.Availability,
                    Capabilities = CapabilitySet.From(registration.Capabilities).Values.ToArray(),
                };
            }
        }
    }

    private static AdapterRegistration? FindAdapter(
        IReadOnlyList<AdapterRegistration> registrations,
        string adapterId,
        string adapterVersion,
        AdapterKind kind)
    {
        foreach (AdapterRegistration registration in registrations)
        {
            if (registration.Kind == kind
                && string.Equals(registration.AdapterId, adapterId, StringComparison.Ordinal)
                && string.Equals(registration.Version, adapterVersion, StringComparison.Ordinal))
            {
                return registration;
            }
        }

        return null;
    }

    /// <summary>Internal control-flow exception carrying a normalized error.</summary>
    internal sealed class RegistryBuildException : Exception
    {
        public RegistryBuildException(RouterError error)
            : base("Registry build failed.")
        {
            Error = error;
        }

        public RouterError Error { get; }
    }
}
