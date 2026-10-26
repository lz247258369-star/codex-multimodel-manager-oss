using Router.Secrets;

namespace Router.Registries;

/// <summary>Immutable client registry entry.</summary>
public sealed record ClientRegistryEntry
{
    public required string ClientId { get; init; }

    public required string AdapterId { get; init; }

    public required bool Enabled { get; init; }

    public required string AuthScope { get; init; }

    public IReadOnlyList<string> AllowedRouteIds { get; init; } = [];

    public CapabilitySet Capabilities { get; init; } = CapabilitySet.Empty;

    public required int Version { get; init; }

    /// <summary>True when this client may use the given route.</summary>
    public bool AllowsRoute(string routeId)
        => AllowedRouteIds.Count == 0 || AllowedRouteIds.Contains(routeId, StringComparer.Ordinal);
}

/// <summary>Immutable protocol route registry entry.</summary>
public sealed record ProtocolRouteRegistryEntry
{
    public required string ProtocolRouteId { get; init; }

    public required string IngressProtocol { get; init; }

    public required string UpstreamProtocol { get; init; }

    public required string AdapterId { get; init; }

    public required string AdapterVersion { get; init; }

    public CapabilitySet Capabilities { get; init; } = CapabilitySet.Empty;

    public required string LossPolicy { get; init; }

    public required int Version { get; init; }

    public required bool HasEligibleAdapter { get; init; }

    public required bool IsEligibleProtocol { get; init; }

    /// <summary>True only when the protocol family and adapter are both eligible.</summary>
    public bool IsUsable => IsEligibleProtocol && HasEligibleAdapter;
}

/// <summary>Immutable provider route registry entry.</summary>
public sealed record ProviderRouteRegistryEntry
{
    public required string ProviderRouteId { get; init; }

    public required string ProviderId { get; init; }

    public required string AdapterId { get; init; }

    public required string AdapterVersion { get; init; }

    public IReadOnlyList<string> EndpointIds { get; init; } = [];

    public SecretReference? SecretRef { get; init; }

    public string? BaseUrlRef { get; init; }

    public required bool Enabled { get; init; }

    public CapabilitySet Capabilities { get; init; } = CapabilitySet.Empty;

    public required int Version { get; init; }

    public required bool HasEligibleAdapter { get; init; }
}

/// <summary>Immutable endpoint registry entry.</summary>
public sealed record EndpointRegistryEntry
{
    public required string EndpointId { get; init; }

    public required string BaseUrlRef { get; init; }

    public required bool Enabled { get; init; }

    public required string DataBoundary { get; init; }

    public required bool TlsRequired { get; init; }

    public required int Priority { get; init; }

    public required int Weight { get; init; }

    public required int Version { get; init; }
}

/// <summary>Immutable provider-scoped model route registry entry.</summary>
public sealed record ModelRouteRegistryEntry
{
    public required string ModelRouteId { get; init; }

    public required string ProviderId { get; init; }

    public required string ClientModelId { get; init; }

    public required string ModelId { get; init; }

    public required string UpstreamModelId { get; init; }

    public IReadOnlyList<string> Aliases { get; init; } = [];

    public CapabilitySet Capabilities { get; init; } = CapabilitySet.Empty;

    public string? PricingRef { get; init; }

    public required string IdentityVerification { get; init; }

    public required bool Enabled { get; init; }

    public required int Version { get; init; }

    /// <summary>Optional catalog metadata enrichment; absence never invalidates the route.</summary>
    public CatalogProjection.CatalogModelMetadata? CatalogMetadata { get; init; }
}

/// <summary>Immutable router route registry entry.</summary>
public sealed record RouterRouteRegistryEntry
{
    public required string RouteId { get; init; }

    public IReadOnlyList<string> ClientIds { get; init; } = [];

    public required string ProviderRouteId { get; init; }

    public required string ProtocolRouteId { get; init; }

    public required string ModelRouteId { get; init; }

    public required bool Enabled { get; init; }

    public required int Priority { get; init; }

    public required int Weight { get; init; }

    public required RouteHealthState HealthState { get; init; }

    public required string TimeoutPolicyId { get; init; }

    public required string RetryPolicyId { get; init; }

    public required string FailoverPolicyId { get; init; }

    public IReadOnlyList<string> FallbackRouteIds { get; init; } = [];

    public required int Version { get; init; }
}

/// <summary>Immutable policy registry entry (reference only; LR-11 defines bodies).</summary>
public sealed record PolicyRegistryEntry
{
    public required string PolicyId { get; init; }

    public required int Version { get; init; }
}
