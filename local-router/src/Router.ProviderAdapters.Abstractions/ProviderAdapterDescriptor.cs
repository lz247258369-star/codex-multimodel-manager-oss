using Router.Registries;

namespace Router.ProviderAdapters.Abstractions;

/// <summary>
/// Immutable, versioned description of one provider adapter implementation.
/// The identity is exact: adapter_id + adapter_version + provider_id +
/// protocol_id. Registry lookup never silently upgrades a pinned version and
/// never infers an adapter from model names or provider names.
/// </summary>
public sealed record ProviderAdapterDescriptor
{
    public required string AdapterId { get; init; }

    public required string AdapterVersion { get; init; }

    public required string ProviderId { get; init; }

    public required string ProtocolId { get; init; }

    public CapabilitySet Capabilities { get; init; } = CapabilitySet.Empty;

    public required RequestSemantics RequestSemantics { get; init; }

    public required ResponseSemantics ResponseSemantics { get; init; }

    public required EndpointRequirement EndpointRequirement { get; init; }

    public required SecretRequirement SecretRequirement { get; init; }

    public required CancellationSupport CancellationSupport { get; init; }

    public required UsageSupport UsageSupport { get; init; }

    /// <summary>True only when the adapter is eligible to serve routes.</summary>
    public required bool Eligible { get; init; }

    /// <summary>Human-readable purpose; never contains secrets.</summary>
    public string? Description { get; init; }
}
