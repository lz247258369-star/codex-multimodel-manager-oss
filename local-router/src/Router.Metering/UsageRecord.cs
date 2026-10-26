namespace Router.Metering;

/// <summary>
/// Typed, versioned normalized usage record. Unknown provider-reported fields
/// stay null and <c>estimated=false</c> is always explicit; token counts are
/// never guessed or derived from characters.
/// </summary>
public sealed record UsageRecord
{
    public const int SchemaVersion = 1;

    public required string RequestId { get; init; }

    public required string ProviderId { get; init; }

    public required string ModelId { get; init; }

    public int? InputTokens { get; init; }

    public int? OutputTokens { get; init; }

    public int? TotalTokens { get; init; }

    public int? CachedTokens { get; init; }

    public int? ReasoningTokens { get; init; }

    public required bool Estimated { get; init; }

    public string Source { get; init; } = "provider_response";

    public required DateTimeOffset RecordedAt { get; init; }
}
