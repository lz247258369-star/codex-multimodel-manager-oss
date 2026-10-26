namespace Router.CircuitBreaker;

/// <summary>
/// Exact breaker key from the architecture contract: provider route + endpoint
/// + model route. Breakers never share state across providers, endpoints,
/// models, or credential scopes.
/// </summary>
public sealed record CircuitBreakerKey
{
    public required string ProviderRouteId { get; init; }

    public required string EndpointId { get; init; }

    public required string ModelRouteId { get; init; }

    public static CircuitBreakerKey Create(string providerRouteId, string endpointId, string modelRouteId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(providerRouteId);
        ArgumentException.ThrowIfNullOrWhiteSpace(endpointId);
        ArgumentException.ThrowIfNullOrWhiteSpace(modelRouteId);
        return new CircuitBreakerKey
        {
            ProviderRouteId = providerRouteId,
            EndpointId = endpointId,
            ModelRouteId = modelRouteId,
        };
    }
}
