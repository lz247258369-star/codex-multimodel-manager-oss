namespace Router.Registries;

/// <summary>
/// Immutable provider registry entry. Identity is an existing Manager provider
/// ID; the adapter identity is a placeholder until an eligible adapter
/// registration exists.
/// </summary>
public sealed record ProviderDescriptor
{
    /// <summary>Existing Manager provider identity, for example <c>mm_openrouter</c>.</summary>
    public required string ProviderId { get; init; }

    /// <summary>Registry disposition (DirectOnly, Planned, Placeholder, Eligible).</summary>
    public required ProviderAvailability Availability { get; init; }

    /// <summary>Adapter identity; a placeholder must never become an eligible route.</summary>
    public required string AdapterId { get; init; }

    public required string AdapterVersion { get; init; }

    /// <summary>True only when an explicit eligible adapter registration matches.</summary>
    public required bool HasEligibleAdapter { get; init; }

    public IReadOnlyList<string> Capabilities { get; init; } = [];

    public required int Version { get; init; }

    /// <summary>True when this provider may serve a route in the current snapshot.</summary>
    public bool IsUsable => HasEligibleAdapter && Availability == ProviderAvailability.Eligible;
}
