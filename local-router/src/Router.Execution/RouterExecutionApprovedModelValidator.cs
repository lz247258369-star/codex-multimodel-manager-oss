using Router.Core.Context;
using Router.Registries;

namespace Router.Execution;

/// <summary>
/// Static approved-model check for the thread-selection control plane, bound to
/// the exact immutable registry snapshot that production execution resolves
/// against. Approval is a structural, config-only question: client, model
/// mapping, route, provider, protocol, adapter, and endpoint eligibility are
/// evaluated with the existing registry primitives.
///
/// This validator deliberately performs no provider request, no network call,
/// no catalog lookup, and no health evaluation, and it never considers the
/// per-request capability set (tools, reasoning, streaming) - that remains the
/// existing RouteResolver's decision for the real turn.
/// </summary>
public sealed class RouterExecutionApprovedModelValidator : IApprovedModelValidator
{
    private readonly RouterRegistrySnapshot _snapshot;

    public RouterExecutionApprovedModelValidator(RouterRegistrySnapshot snapshot)
    {
        _snapshot = snapshot ?? throw new ArgumentNullException(nameof(snapshot));
    }

    /// <inheritdoc />
    public bool IsApprovedForClient(string clientId, string clientModelId)
    {
        if (string.IsNullOrWhiteSpace(clientId) || string.IsNullOrWhiteSpace(clientModelId))
        {
            return false;
        }

        if (_snapshot.TryGetClient(clientId) is not { } client || !client.Enabled)
        {
            return false;
        }

        foreach (RouterRouteRegistryEntry route in _snapshot.Routes.Values)
        {
            if (!route.ClientIds.Contains(clientId, StringComparer.Ordinal))
            {
                continue;
            }

            if (_snapshot.TryGetModelRoute(route.ModelRouteId) is not { } modelRoute)
            {
                continue;
            }

            // Provider-scoped model mapping: the requested model must resolve to
            // exactly this route's mapping in that provider's scope.
            ModelLookupResult lookup = _snapshot.TryResolveModel(modelRoute.ProviderId, clientModelId);
            if (!lookup.IsFound
                || lookup.Entry is null
                || !string.Equals(lookup.Entry.ModelRouteId, route.ModelRouteId, StringComparison.Ordinal))
            {
                continue;
            }

            if (IsStructurallyEligible(route, client))
            {
                return true;
            }
        }

        return false;
    }

    private bool IsStructurallyEligible(RouterRouteRegistryEntry route, ClientRegistryEntry client)
    {
        if (!route.Enabled || !client.AllowsRoute(route.RouteId))
        {
            return false;
        }

        if (_snapshot.TryGetProviderRoute(route.ProviderRouteId) is not { } providerRoute
            || !providerRoute.Enabled
            || !providerRoute.HasEligibleAdapter)
        {
            return false;
        }

        if (_snapshot.TryGetProvider(providerRoute.ProviderId) is not { } provider || !provider.IsUsable)
        {
            return false;
        }

        if (_snapshot.TryGetProtocolRoute(route.ProtocolRouteId) is not { } protocolRoute || !protocolRoute.IsUsable)
        {
            return false;
        }

        if (_snapshot.TryGetModelRoute(route.ModelRouteId) is not { } modelRoute || !modelRoute.Enabled)
        {
            return false;
        }

        return providerRoute.EndpointIds.Any(endpointId =>
            _snapshot.TryGetEndpoint(endpointId) is { Enabled: true });
    }
}
