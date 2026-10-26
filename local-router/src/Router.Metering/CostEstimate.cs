namespace Router.Metering;

/// <summary>
/// Informational estimate status. Unknown prices are never zero; missing usage
/// never becomes zero; stale/partial states are explicit.
/// </summary>
public enum CostEstimateStatus
{
    Complete,
    PartialUsage,
    UnknownPrice,
    StalePrice,
    UnsupportedCurrency,
    Unavailable,
}

/// <summary>
/// Typed, versioned informational cost estimate. This is never a billing
/// truth: no invoice, account balance, final fee, or settlement result.
/// </summary>
public sealed record CostEstimate
{
    public const int SchemaVersion = 1;

    public decimal? InputCost { get; init; }

    public decimal? OutputCost { get; init; }

    public decimal? CachedCost { get; init; }

    public decimal? ReasoningCost { get; init; }

    public decimal? TotalCost { get; init; }

    public string? Currency { get; init; }

    public required string PricingSnapshotVersion { get; init; }

    public string? PricingSource { get; init; }

    public DateTimeOffset? EffectiveAt { get; init; }

    public required CostEstimateStatus Status { get; init; }

    public required bool Estimated { get; init; }
}
