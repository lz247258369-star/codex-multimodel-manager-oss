namespace Router.Health;

/// <summary>
/// Immutable passive-health key. The key follows the architecture contract:
/// provider route + endpoint + model route. Provider/model identity is never
/// guessed from model names or endpoint URLs.
/// </summary>
public sealed record HealthKey
{
    public required string ProviderRouteId { get; init; }

    public required string EndpointId { get; init; }

    public required string ModelRouteId { get; init; }

    public static HealthKey Create(string providerRouteId, string endpointId, string modelRouteId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(providerRouteId);
        ArgumentException.ThrowIfNullOrWhiteSpace(endpointId);
        ArgumentException.ThrowIfNullOrWhiteSpace(modelRouteId);
        return new HealthKey
        {
            ProviderRouteId = providerRouteId,
            EndpointId = endpointId,
            ModelRouteId = modelRouteId,
        };
    }
}

/// <summary>Immutable route-level health key (config route id only).</summary>
public sealed record RouteHealthKey
{
    public required string RouteId { get; init; }

    public static RouteHealthKey Create(string routeId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(routeId);
        return new RouteHealthKey { RouteId = routeId };
    }
}
