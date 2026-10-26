using Router.Registries;
using Router.Secrets;

namespace Router.Routing;

/// <summary>
/// Immutable result of route resolution. It is bound to the snapshot's
/// <c>config_generation</c> and never drifts during the request lifetime, even
/// if configuration reloads.
/// </summary>
public sealed record ResolvedRoute
{
    /// <summary>Immutable effective-config generation the resolution is bound to.</summary>
    public required string ConfigGeneration { get; init; }

    public required string RouteId { get; init; }

    public required string ClientId { get; init; }

    public required ProviderRouteRegistryEntry ProviderRoute { get; init; }

    public required ProtocolRouteRegistryEntry ProtocolRoute { get; init; }

    public required ModelRouteRegistryEntry ModelRoute { get; init; }

    public required EndpointRegistryEntry Endpoint { get; init; }

    public required CapabilitySet EffectiveCapabilities { get; init; }

    /// <summary>Policy references only; policy bodies arrive with LR-11.</summary>
    public required string TimeoutPolicyId { get; init; }

    public required string RetryPolicyId { get; init; }

    public required string FailoverPolicyId { get; init; }

    /// <summary>Pricing snapshot reference, when the model route declares one.</summary>
    public string? PricingSnapshotId { get; init; }

    /// <summary>Secret reference only; never a secret value.</summary>
    public SecretReference? SecretRef { get; init; }
}
