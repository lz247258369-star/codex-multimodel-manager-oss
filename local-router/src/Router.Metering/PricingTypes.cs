namespace Router.Metering;

/// <summary>
/// Versioned model pricing projected from the canonical model catalog. All
/// monetary values are decimal; unknown prices are null and never become zero.
/// </summary>
public sealed record ModelPricing
{
    public const int SchemaVersion = 1;
    public const string Unit = "per_1m_tokens";

    public required string ProviderId { get; init; }

    public required string ModelId { get; init; }

    public decimal? InputPrice { get; init; }

    public decimal? OutputPrice { get; init; }

    /// <summary>No cached-input price exists in catalog v3; null means unknown, never free.</summary>
    public decimal? CachedInputPrice { get; init; }

    /// <summary>No reasoning-output price exists in catalog v3; null means unknown, never free.</summary>
    public decimal? ReasoningOutputPrice { get; init; }

    public string? Currency { get; init; }

    public string? PriceSource { get; init; }

    public string? PriceUpdatedAt { get; init; }

    public DateTimeOffset? EffectiveAt { get; init; }

    public required string SourceVersion { get; init; }

    public required string PricingVersion { get; init; }
}

/// <summary>
/// Provider-scoped pricing view. Provider isolation is exact: the same model
/// string under a different provider resolves only to that provider's record.
/// </summary>
public sealed record ProviderPricing
{
    public required string ProviderId { get; init; }

    public required string ModelId { get; init; }

    public required ModelPricing Model { get; init; }
}

/// <summary>Immutable pricing snapshot bound to one catalog source version.</summary>
public sealed record PricingSnapshot
{
    public required int SchemaVersion { get; init; }

    public required string SnapshotVersion { get; init; }

    public required string SourceVersion { get; init; }

    public string? PriceBasis { get; init; }

    public required IReadOnlyDictionary<(string ProviderId, string ModelId), ModelPricing> ByProviderModel { get; init; }

    public ModelPricing? TryGet(string providerId, string modelId)
        => ByProviderModel.TryGetValue((providerId, modelId), out ModelPricing? pricing) ? pricing : null;
}

/// <summary>Typed projection outcome for pricing snapshots.</summary>
public sealed record PricingProjectionResult
{
    public PricingSnapshot? Snapshot { get; init; }

    public string? ErrorCode { get; init; }

    public bool IsSuccess => Snapshot is not null;
}
