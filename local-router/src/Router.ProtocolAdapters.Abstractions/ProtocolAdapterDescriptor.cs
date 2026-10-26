using Router.Registries;

namespace Router.ProtocolAdapters.Abstractions;

/// <summary>
/// Immutable, versioned description of one protocol adapter implementation.
/// Identity is exact: adapter_id + adapter_version + canonical_protocol_id +
/// upstream_protocol_id. Registry lookup never silently upgrades a pinned
/// version and never infers a protocol from providers, models, or URLs.
/// </summary>
public sealed record ProtocolAdapterDescriptor
{
    public required string AdapterId { get; init; }

    public required string AdapterVersion { get; init; }

    /// <summary>Canonical protocol the adapter consumes.</summary>
    public required string CanonicalProtocolId { get; init; }

    /// <summary>Upstream protocol the adapter produces.</summary>
    public required string UpstreamProtocolId { get; init; }

    public CapabilitySet Capabilities { get; init; } = CapabilitySet.Empty;

    public required ProtocolLossPolicy LossPolicy { get; init; }

    /// <summary>True only when the adapter is eligible to serve routes.</summary>
    public required bool Eligible { get; init; }

    /// <summary>True only for reserved future protocol placeholders.</summary>
    public bool IsPlaceholder => !Eligible;

    /// <summary>Human-readable purpose; never contains secrets.</summary>
    public string? Description { get; init; }
}
