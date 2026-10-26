using Router.Registries;

namespace Router.Routing;

/// <summary>
/// Canonical route selection input. The selection key is
/// <c>(client_id, client_model_id, explicit route preference if allowed)</c>.
/// Required capabilities describe what the canonical request needs; missing
/// capabilities always fail closed.
/// </summary>
public sealed record RouteRequest
{
    public required string ClientId { get; init; }

    public required string ClientModelId { get; init; }

    public CapabilitySet RequiredCapabilities { get; init; } = CapabilitySet.Empty;

    /// <summary>Optional explicit route preference; honored only when allowed and eligible.</summary>
    public string? ExplicitRoutePreference { get; init; }

    public static RouteRequest Create(
        string clientId,
        string clientModelId,
        CapabilitySet requiredCapabilities,
        string? explicitRoutePreference = null)
    {
        if (string.IsNullOrWhiteSpace(clientId))
        {
            throw new ArgumentException("ClientId must not be empty.", nameof(clientId));
        }

        if (string.IsNullOrWhiteSpace(clientModelId))
        {
            throw new ArgumentException("ClientModelId must not be empty.", nameof(clientModelId));
        }

        ArgumentNullException.ThrowIfNull(requiredCapabilities);

        return new RouteRequest
        {
            ClientId = clientId,
            ClientModelId = clientModelId,
            RequiredCapabilities = requiredCapabilities,
            ExplicitRoutePreference = explicitRoutePreference,
        };
    }
}

/// <summary>
/// Immutable health input consumed by the resolver. Health is an input, never
/// mutated here; UNHEALTHY and DISABLED routes are not eligible, UNKNOWN
/// follows the local/passive default (eligible).
/// </summary>
public sealed record RouteHealthSnapshot
{
    public required DateTimeOffset ObservedAt { get; init; }

    public required IReadOnlyDictionary<string, RouteHealthState> States { get; init; }

    public static RouteHealthSnapshot Empty { get; } = new()
    {
        ObservedAt = DateTimeOffset.UnixEpoch,
        States = new Dictionary<string, RouteHealthState>(StringComparer.Ordinal),
    };

    public RouteHealthState? TryGet(string routeId)
        => States.TryGetValue(routeId, out RouteHealthState state) ? state : null;
}
