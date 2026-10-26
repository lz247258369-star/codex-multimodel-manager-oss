namespace Router.Registries;

/// <summary>
/// Immutable protocol registry entry. Only canonical Responses semantics are
/// eligible; future protocol placeholders are never selectable.
/// </summary>
public sealed record ProtocolDescriptor
{
    /// <summary>Versioned protocol identity, for example <c>protocol.openai.responses.v1</c>.</summary>
    public required string ProtocolId { get; init; }

    /// <summary>True only for the canonical Responses protocol family.</summary>
    public required bool IsEligibleProtocol { get; init; }

    /// <summary>True when this entry is a reserved future placeholder.</summary>
    public required bool IsPlaceholder { get; init; }

    public IReadOnlyList<string> Capabilities { get; init; } = [];

    public required int Version { get; init; }
}
