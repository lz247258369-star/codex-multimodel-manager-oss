using Router.Core.Context;
using Router.Core.Errors;
using Router.Registries;

namespace Router.Routing;

/// <summary>
/// Deterministic route resolver. Selection follows the canonical checklist:
/// client -> provider-scoped model mapping -> explicit preference -> enabled
/// states -> placeholder exclusion -> capabilities intersection -> health ->
/// priority -> deterministic weight. Any failing check fails closed with a
/// typed, content-free error. No network request is ever made.
/// </summary>
public sealed class RouteResolver : IRouteResolver
{
    public RouteResolutionResult Resolve(
        RouteRequest request,
        RouterRegistrySnapshot snapshot,
        RouteHealthSnapshot? health = null,
        RequestContext? context = null)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(snapshot);

        // Step 15: immutable config generation. The request context must agree
        // with the snapshot; a reload produces a new snapshot, never drift.
        if (context?.ConfigGeneration is { } contextGeneration
            && !string.Equals(contextGeneration, snapshot.ConfigGeneration, StringComparison.Ordinal))
        {
            return RouteResolutionResult.Failed(RoutingErrors.GenerationMismatch(context?.RequestId.Value));
        }

        // Step 1: client exists and is enabled.
        if (snapshot.TryGetClient(request.ClientId) is not { } client)
        {
            return RouteResolutionResult.Failed(RoutingErrors.UnknownClient(context?.RequestId.Value));
        }

        if (!client.Enabled)
        {
            return RouteResolutionResult.Failed(RoutingErrors.ClientDisabled(context?.RequestId.Value));
        }

        // Routes configured for this client, stable order.
        RouterRouteRegistryEntry[] clientRoutes = snapshot.Routes.Values
            .Where(route => route.ClientIds.Contains(request.ClientId, StringComparer.Ordinal))
            .OrderBy(static route => route.RouteId, StringComparer.Ordinal)
            .ToArray();

        if (clientRoutes.Length == 0)
        {
            return RouteResolutionResult.Failed(RoutingErrors.RouteNotFound(context?.RequestId.Value));
        }

        // Step 2: provider-scoped model mapping. A route is a candidate only
        // when the requested model resolves to exactly that route's model
        // mapping in that route's provider scope.
        var modelMatched = new List<RouterRouteRegistryEntry>();
        foreach (RouterRouteRegistryEntry route in clientRoutes)
        {
            if (snapshot.TryGetModelRoute(route.ModelRouteId) is not { } modelRoute)
            {
                return RouteResolutionResult.Failed(RoutingErrors.UnknownModel(context?.RequestId.Value));
            }

            ModelLookupResult lookup = snapshot.TryResolveModel(modelRoute.ProviderId, request.ClientModelId);
            if (lookup.Error is { } lookupError)
            {
                if (string.Equals(lookupError.Code, RouterErrorCode.AmbiguousModel, StringComparison.Ordinal))
                {
                    return RouteResolutionResult.Failed(RoutingErrors.AmbiguousModel(context?.RequestId.Value));
                }

                continue;
            }

            if (lookup.Entry is { } resolved && string.Equals(resolved.ModelRouteId, route.ModelRouteId, StringComparison.Ordinal))
            {
                modelMatched.Add(route);
            }
        }

        if (modelMatched.Count == 0)
        {
            return RouteResolutionResult.Failed(RoutingErrors.UnknownModel(context?.RequestId.Value));
        }

        // Defensive registry-reference checks: every matched route must resolve
        // its provider/protocol/model route entries before eligibility runs.
        foreach (RouterRouteRegistryEntry route in modelMatched)
        {
            if (snapshot.TryGetProviderRoute(route.ProviderRouteId) is null)
            {
                return RouteResolutionResult.Failed(RoutingErrors.UnknownRoute(context?.RequestId.Value));
            }

            if (snapshot.TryGetProtocolRoute(route.ProtocolRouteId) is null)
            {
                return RouteResolutionResult.Failed(RoutingErrors.UnknownProtocol(context?.RequestId.Value));
            }

            if (snapshot.TryGetModelRoute(route.ModelRouteId) is null)
            {
                return RouteResolutionResult.Failed(RoutingErrors.UnknownModel(context?.RequestId.Value));
            }
        }

        // Step 3: explicit route preference, when allowed.
        if (request.ExplicitRoutePreference is { } preference)
        {
            bool allowed = modelMatched.Any(candidate => string.Equals(candidate.RouteId, preference, StringComparison.Ordinal));
            if (!allowed)
            {
                return RouteResolutionResult.Failed(RoutingErrors.ExplicitRoutePreferenceInvalid(context?.RequestId.Value));
            }
        }

        // Steps 4-11: sequential eligibility filters in canonical order.
        List<RouterRouteRegistryEntry> candidates = modelMatched.ToList();

        // Step 4: route enabled.
        candidates = candidates.Where(static route => route.Enabled).ToList();
        if (candidates.Count == 0)
        {
            return RouteResolutionResult.Failed(RoutingErrors.RouteDisabled(context?.RequestId.Value));
        }

        // Step 5: client allowed to use the route.
        candidates = candidates.Where(route => client.AllowsRoute(route.RouteId)).ToList();
        if (candidates.Count == 0)
        {
            return RouteResolutionResult.Failed(RoutingErrors.RouteNotAllowed(context?.RequestId.Value));
        }

        // Step 6: provider route enabled and has a usable endpoint.
        candidates = candidates
            .Where(route => snapshot.TryGetProviderRoute(route.ProviderRouteId) is { } providerRoute && providerRoute.Enabled)
            .ToList();
        if (candidates.Count == 0)
        {
            return RouteResolutionResult.Failed(RoutingErrors.RouteDisabled(context?.RequestId.Value));
        }

        candidates = candidates
            .Where(route => HasUsableEndpoint(snapshot, route))
            .ToList();
        if (candidates.Count == 0)
        {
            return RouteResolutionResult.Failed(RoutingErrors.InvalidEndpointReference(context?.RequestId.Value));
        }

        // Step 7: protocol route eligible (canonical protocol + registered adapter).
        candidates = candidates
            .Where(route => snapshot.TryGetProtocolRoute(route.ProtocolRouteId) is { } protocolRoute && protocolRoute.IsUsable)
            .ToList();
        if (candidates.Count == 0)
        {
            return RouteResolutionResult.Failed(RoutingErrors.PlaceholderUnavailable(context?.RequestId.Value));
        }

        // Step 8: model route enabled.
        candidates = candidates
            .Where(route => snapshot.TryGetModelRoute(route.ModelRouteId) is { } modelRoute && modelRoute.Enabled)
            .ToList();
        if (candidates.Count == 0)
        {
            return RouteResolutionResult.Failed(RoutingErrors.RouteDisabled(context?.RequestId.Value));
        }

        // Step 9: placeholder providers and adapters are not usable.
        candidates = candidates
            .Where(route =>
            {
                if (snapshot.TryGetProviderRoute(route.ProviderRouteId) is not { } providerRoute
                    || snapshot.TryGetProvider(providerRoute.ProviderId) is not { } provider)
                {
                    return false;
                }

                return provider.IsUsable && providerRoute.HasEligibleAdapter;
            })
            .ToList();
        if (candidates.Count == 0)
        {
            bool unknownProvider = modelMatched.Any(route =>
                snapshot.TryGetProviderRoute(route.ProviderRouteId) is { } providerRoute
                && snapshot.TryGetProvider(providerRoute.ProviderId) is null);
            if (unknownProvider)
            {
                return RouteResolutionResult.Failed(RoutingErrors.UnknownProvider(context?.RequestId.Value));
            }

            return RouteResolutionResult.Failed(RoutingErrors.PlaceholderUnavailable(context?.RequestId.Value));
        }

        // Step 10: capabilities intersection. A missing required capability
        // fails closed; no silent downgrade ever occurs.
        candidates = candidates
            .Where(route =>
            {
                CapabilitySet effective = EffectiveCapabilities(snapshot, route, client);
                return effective.ContainsAll(request.RequiredCapabilities);
            })
            .ToList();
        if (candidates.Count == 0)
        {
            string? missing = FindMissingCapability(snapshot, modelMatched, request.RequiredCapabilities, client);
            return RouteResolutionResult.Failed(RoutingErrors.UnsupportedCapability(missing, context?.RequestId.Value));
        }

        // Step 11: health state. UNHEALTHY and DISABLED are not eligible;
        // UNKNOWN follows the local/passive default and is eligible.
        candidates = candidates
            .Where(route => IsHealthEligible(route, health))
            .ToList();
        if (candidates.Count == 0)
        {
            return RouteResolutionResult.Failed(RoutingErrors.RouteIneligible("health", context?.RequestId.Value));
        }

        // Explicit preference, when allowed and eligible, wins directly. A
        // preference that stopped being eligible is a rejected preference, not
        // a silent fallback to another route.
        if (request.ExplicitRoutePreference is { } explicitPreference)
        {
            if (!candidates.Any(route => string.Equals(route.RouteId, explicitPreference, StringComparison.Ordinal)))
            {
                return RouteResolutionResult.Failed(RoutingErrors.ExplicitRoutePreferenceInvalid(context?.RequestId.Value));
            }

            RouterRouteRegistryEntry preferred = candidates.First(route => string.Equals(route.RouteId, explicitPreference, StringComparison.Ordinal));
            return ResolveSelected(request, snapshot, client, preferred, context);
        }

        // Steps 12-13: lowest numeric priority wins; weight applies only among
        // equally-prioritized eligible candidates with deterministic selection.
        int lowestPriority = candidates.Min(static route => route.Priority);
        RouterRouteRegistryEntry[] priorityGroup = candidates
            .Where(route => route.Priority == lowestPriority)
            .OrderBy(static route => route.RouteId, StringComparer.Ordinal)
            .ToArray();

        string? selectedKey = DeterministicWeightSelector.Select(
            priorityGroup.Select(route => new WeightedCandidate(route.RouteId, route.Weight)).ToArray(),
            snapshot.ConfigGeneration,
            BuildSelectionKey(request));

        if (selectedKey is null)
        {
            return RouteResolutionResult.Failed(RoutingErrors.RouteIneligible("weight", context?.RequestId.Value));
        }

        RouterRouteRegistryEntry selected = priorityGroup.First(route => string.Equals(route.RouteId, selectedKey, StringComparison.Ordinal));
        return ResolveSelected(request, snapshot, client, selected, context);
    }

    private static RouteResolutionResult ResolveSelected(
        RouteRequest request,
        RouterRegistrySnapshot snapshot,
        ClientRegistryEntry client,
        RouterRouteRegistryEntry selected,
        Core.Context.RequestContext? context)
    {
        // Build the immutable ResolvedRoute bound to this snapshot generation.
        ProviderRouteRegistryEntry selectedProviderRoute = snapshot.TryGetProviderRoute(selected.ProviderRouteId)!;
        ProtocolRouteRegistryEntry selectedProtocolRoute = snapshot.TryGetProtocolRoute(selected.ProtocolRouteId)!;
        ModelRouteRegistryEntry selectedModelRoute = snapshot.TryGetModelRoute(selected.ModelRouteId)!;
        EndpointRegistryEntry selectedEndpoint = SelectEndpoint(snapshot, selectedProviderRoute, snapshot.ConfigGeneration, BuildSelectionKey(request));

        CapabilitySet effectiveCapabilities = EffectiveCapabilities(snapshot, selected, client);

        ResolvedRoute resolved = new()
        {
            ConfigGeneration = snapshot.ConfigGeneration,
            RouteId = selected.RouteId,
            ClientId = request.ClientId,
            ProviderRoute = selectedProviderRoute,
            ProtocolRoute = selectedProtocolRoute,
            ModelRoute = selectedModelRoute,
            Endpoint = selectedEndpoint,
            EffectiveCapabilities = effectiveCapabilities,
            TimeoutPolicyId = selected.TimeoutPolicyId,
            RetryPolicyId = selected.RetryPolicyId,
            FailoverPolicyId = selected.FailoverPolicyId,
            PricingSnapshotId = selectedModelRoute.PricingRef,
            SecretRef = selectedProviderRoute.SecretRef,
        };

        return RouteResolutionResult.Resolved(resolved);
    }

    private static bool HasUsableEndpoint(RouterRegistrySnapshot snapshot, RouterRouteRegistryEntry route)
    {
        if (snapshot.TryGetProviderRoute(route.ProviderRouteId) is not { } providerRoute)
        {
            return false;
        }

        return providerRoute.EndpointIds.Any(endpointId =>
            snapshot.TryGetEndpoint(endpointId) is { Enabled: true });
    }

    private static EndpointRegistryEntry SelectEndpoint(
        RouterRegistrySnapshot snapshot,
        ProviderRouteRegistryEntry providerRoute,
        string configGeneration,
        string selectionKey)
    {
        EndpointRegistryEntry[] enabled = providerRoute.EndpointIds
            .Select(snapshot.TryGetEndpoint)
            .Where(static endpoint => endpoint is { Enabled: true })
            .Cast<EndpointRegistryEntry>()
            .ToArray();

        if (enabled.Length == 0)
        {
            throw new InvalidOperationException("The provider route has no usable endpoint.");
        }

        int lowestPriority = enabled.Min(static endpoint => endpoint.Priority);
        EndpointRegistryEntry[] priorityGroup = enabled
            .Where(endpoint => endpoint.Priority == lowestPriority)
            .OrderBy(static endpoint => endpoint.EndpointId, StringComparer.Ordinal)
            .ToArray();

        if (priorityGroup.Length == 1)
        {
            return priorityGroup[0];
        }

        string? selectedKey = DeterministicWeightSelector.Select(
            priorityGroup.Select(endpoint => new WeightedCandidate(endpoint.EndpointId, endpoint.Weight)).ToArray(),
            configGeneration,
            selectionKey + "|endpoint");

        return priorityGroup.First(endpoint => string.Equals(endpoint.EndpointId, selectedKey, StringComparison.Ordinal));
    }

    private static bool IsHealthEligible(RouterRouteRegistryEntry route, RouteHealthSnapshot? health)
    {
        // Configuration is the only source of DISABLED; health alone can never
        // enable a configured-disabled route.
        if (route.HealthState == RouteHealthState.Disabled)
        {
            return false;
        }

        RouteHealthState state = health?.TryGet(route.RouteId) ?? route.HealthState;
        return state is RouteHealthState.Unknown or RouteHealthState.Healthy or RouteHealthState.Degraded;
    }

    private static CapabilitySet EffectiveCapabilities(
        RouterRegistrySnapshot snapshot,
        RouterRouteRegistryEntry route,
        ClientRegistryEntry client)
    {
        if (snapshot.TryGetProviderRoute(route.ProviderRouteId) is not { } providerRoute
            || snapshot.TryGetProtocolRoute(route.ProtocolRouteId) is not { } protocolRoute
            || snapshot.TryGetModelRoute(route.ModelRouteId) is not { } modelRoute)
        {
            return CapabilitySet.Empty;
        }

        return CanonicalIngressCapabilities.V1
            .Intersect(client.Capabilities)
            .Intersect(protocolRoute.Capabilities)
            .Intersect(providerRoute.Capabilities)
            .Intersect(modelRoute.Capabilities);
    }

    private static string? FindMissingCapability(
        RouterRegistrySnapshot snapshot,
        IReadOnlyList<RouterRouteRegistryEntry> candidates,
        CapabilitySet required,
        ClientRegistryEntry client)
    {
        foreach (string capability in required.Values)
        {
            bool anySupports = candidates.Any(route => EffectiveCapabilities(snapshot, route, client).Contains(capability));
            if (!anySupports)
            {
                return capability;
            }
        }

        return null;
    }

    private static string BuildSelectionKey(RouteRequest request)
        => request.ClientId + "|" + request.ClientModelId + "|" + (request.ExplicitRoutePreference ?? string.Empty);
}
