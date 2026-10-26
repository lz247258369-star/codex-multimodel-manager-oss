using Router.CatalogProjection;
using Router.Core.Errors;

namespace Router.Registries;

/// <summary>
/// Immutable registry snapshot bound to one effective config generation. A
/// snapshot never changes during a request; reload produces a new generation
/// and a new snapshot.
/// </summary>
public sealed record RouterRegistrySnapshot
{
    public const int CurrentVersion = 1;

    /// <summary>Immutable effective-config generation that produced this snapshot.</summary>
    public required string ConfigGeneration { get; init; }

    public required IReadOnlyDictionary<string, ClientRegistryEntry> Clients { get; init; }

    public required IReadOnlyDictionary<string, ProviderDescriptor> Providers { get; init; }

    public required IReadOnlyDictionary<string, ProviderRouteRegistryEntry> ProviderRoutes { get; init; }

    public required IReadOnlyDictionary<string, ProtocolDescriptor> Protocols { get; init; }

    public required IReadOnlyDictionary<string, ProtocolRouteRegistryEntry> ProtocolRoutes { get; init; }

    public required IReadOnlyDictionary<string, ModelRouteRegistryEntry> ModelRoutes { get; init; }

    public required IReadOnlyDictionary<string, RouterRouteRegistryEntry> Routes { get; init; }

    public required IReadOnlyDictionary<string, EndpointRegistryEntry> Endpoints { get; init; }

    public required IReadOnlyDictionary<string, PolicyRegistryEntry> Policies { get; init; }

    /// <summary>Optional read-only projection of the canonical model catalog.</summary>
    public RouterCatalogProjection? CatalogProjection { get; init; }

    public int Version { get; init; } = CurrentVersion;

    /// <summary>Immutable provider-scoped model index built by <see cref="Create"/>.</summary>
    public IReadOnlyDictionary<string, ProviderModelIndex> ByProviderModel { get; private init; } = new Dictionary<string, ProviderModelIndex>(StringComparer.Ordinal);

    public ClientRegistryEntry? TryGetClient(string clientId)
        => Clients.TryGetValue(clientId, out ClientRegistryEntry? entry) ? entry : null;

    public ProviderDescriptor? TryGetProvider(string providerId)
        => Providers.TryGetValue(providerId, out ProviderDescriptor? entry) ? entry : null;

    public RouterRouteRegistryEntry? TryGetRoute(string routeId)
        => Routes.TryGetValue(routeId, out RouterRouteRegistryEntry? entry) ? entry : null;

    public ProviderRouteRegistryEntry? TryGetProviderRoute(string providerRouteId)
        => ProviderRoutes.TryGetValue(providerRouteId, out ProviderRouteRegistryEntry? entry) ? entry : null;

    public ProtocolRouteRegistryEntry? TryGetProtocolRoute(string protocolRouteId)
        => ProtocolRoutes.TryGetValue(protocolRouteId, out ProtocolRouteRegistryEntry? entry) ? entry : null;

    public ModelRouteRegistryEntry? TryGetModelRoute(string modelRouteId)
        => ModelRoutes.TryGetValue(modelRouteId, out ModelRouteRegistryEntry? entry) ? entry : null;

    public EndpointRegistryEntry? TryGetEndpoint(string endpointId)
        => Endpoints.TryGetValue(endpointId, out EndpointRegistryEntry? entry) ? entry : null;

    public PolicyRegistryEntry? TryGetPolicy(string policyId)
        => Policies.TryGetValue(policyId, out PolicyRegistryEntry? entry) ? entry : null;

    /// <summary>
    /// Resolves a provider-scoped model mapping. Matching is exact on
    /// <c>client_model_id</c> or an explicitly configured alias; identity is
    /// never inferred and cross-provider lookup is impossible by construction.
    /// </summary>
    public ModelLookupResult TryResolveModel(string providerId, string clientModelId)
    {
        if (!ByProviderModel.TryGetValue(providerId, out ProviderModelIndex? index))
        {
            return ModelLookupResult.NotFound(RegistryErrors.UnknownModel("model"));
        }

        bool exact = index.TryGetExact(clientModelId, out ModelRouteRegistryEntry? exactEntry);
        bool aliases = index.TryGetAliases(clientModelId, out IReadOnlyList<ModelRouteRegistryEntry>? aliasEntries);

        if (exact && aliases)
        {
            return ModelLookupResult.Ambiguous(RegistryErrors.AmbiguousModel("model"));
        }

        if (exact)
        {
            return ModelLookupResult.Found(exactEntry!);
        }

        if (aliases)
        {
            if (aliasEntries!.Count != 1)
            {
                return ModelLookupResult.Ambiguous(RegistryErrors.AmbiguousModel("model"));
            }

            return ModelLookupResult.Found(aliasEntries[0]);
        }

        return ModelLookupResult.NotFound(RegistryErrors.UnknownModel("model"));
    }

    /// <summary>Builds the immutable provider-scoped model index.</summary>
    public static RouterRegistrySnapshot Create(
        string configGeneration,
        IReadOnlyDictionary<string, ClientRegistryEntry> clients,
        IReadOnlyDictionary<string, ProviderDescriptor> providers,
        IReadOnlyDictionary<string, ProviderRouteRegistryEntry> providerRoutes,
        IReadOnlyDictionary<string, ProtocolDescriptor> protocols,
        IReadOnlyDictionary<string, ProtocolRouteRegistryEntry> protocolRoutes,
        IReadOnlyDictionary<string, ModelRouteRegistryEntry> modelRoutes,
        IReadOnlyDictionary<string, RouterRouteRegistryEntry> routes,
        IReadOnlyDictionary<string, EndpointRegistryEntry> endpoints,
        IReadOnlyDictionary<string, PolicyRegistryEntry> policies,
        RouterCatalogProjection? catalogProjection)
    {
        ArgumentNullException.ThrowIfNull(configGeneration);
        ArgumentNullException.ThrowIfNull(clients);
        ArgumentNullException.ThrowIfNull(providers);
        ArgumentNullException.ThrowIfNull(providerRoutes);
        ArgumentNullException.ThrowIfNull(protocols);
        ArgumentNullException.ThrowIfNull(protocolRoutes);
        ArgumentNullException.ThrowIfNull(modelRoutes);
        ArgumentNullException.ThrowIfNull(routes);
        ArgumentNullException.ThrowIfNull(endpoints);
        ArgumentNullException.ThrowIfNull(policies);

        var byProvider = new Dictionary<string, ProviderModelIndex>(StringComparer.Ordinal);
        foreach (ModelRouteRegistryEntry entry in modelRoutes.Values)
        {
            if (!byProvider.TryGetValue(entry.ProviderId, out ProviderModelIndex? index))
            {
                index = new ProviderModelIndex();
                byProvider.Add(entry.ProviderId, index);
            }

            index.AddExact(entry);
            foreach (string alias in entry.Aliases)
            {
                index.AddAlias(alias, entry);
            }
        }

        return new RouterRegistrySnapshot
        {
            ConfigGeneration = configGeneration,
            Clients = clients,
            Providers = providers,
            ProviderRoutes = providerRoutes,
            Protocols = protocols,
            ProtocolRoutes = protocolRoutes,
            ModelRoutes = modelRoutes,
            Routes = routes,
            Endpoints = endpoints,
            Policies = policies,
            CatalogProjection = catalogProjection,
            ByProviderModel = byProvider,
        };
    }

    /// <summary>
    /// Immutable per-provider exact and alias model index. Mutation happens
    /// only while <see cref="Create"/> builds the snapshot.
    /// </summary>
    public sealed class ProviderModelIndex
    {
        private readonly Dictionary<string, ModelRouteRegistryEntry> _exact = new(StringComparer.Ordinal);
        private readonly Dictionary<string, List<ModelRouteRegistryEntry>> _aliases = new(StringComparer.Ordinal);

        internal void AddExact(ModelRouteRegistryEntry entry)
            => _exact.Add(entry.ClientModelId, entry);

        internal void AddAlias(string alias, ModelRouteRegistryEntry entry)
        {
            if (!_aliases.TryGetValue(alias, out List<ModelRouteRegistryEntry>? matches))
            {
                matches = [];
                _aliases.Add(alias, matches);
            }

            matches.Add(entry);
        }

        /// <summary>Exact client_model_id lookup within this provider scope.</summary>
        public bool TryGetExact(string clientModelId, out ModelRouteRegistryEntry? entry)
            => _exact.TryGetValue(clientModelId, out entry);

        /// <summary>Explicit alias lookup within this provider scope.</summary>
        public bool TryGetAliases(string alias, out IReadOnlyList<ModelRouteRegistryEntry>? matches)
        {
            if (_aliases.TryGetValue(alias, out List<ModelRouteRegistryEntry>? list))
            {
                matches = list.ToArray();
                return true;
            }

            matches = null;
            return false;
        }
    }
}
