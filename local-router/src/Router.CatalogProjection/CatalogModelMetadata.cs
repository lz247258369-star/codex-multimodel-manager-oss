namespace Router.CatalogProjection;

/// <summary>
/// Immutable, provider-scoped model metadata projected from the canonical v3
/// catalog. Identities are explicit; aliases are never invented. Routing
/// enablement comes exclusively from explicit Router configuration.
/// </summary>
public sealed record CatalogModelMetadata
{
    /// <summary>Existing Manager provider identity, for example <c>mm_openrouter</c>.</summary>
    public required string ProviderId { get; init; }

    /// <summary>Catalog provider ID that produced this record, for example <c>openrouter</c>.</summary>
    public required string CatalogProviderId { get; init; }

    public required string CatalogProviderLabel { get; init; }

    /// <summary>Environment-variable reference name only; never a value.</summary>
    public string? EnvKeyReference { get; init; }

    /// <summary>Provider-scoped canonical model identity from the catalog.</summary>
    public required string ModelId { get; init; }

    /// <summary>Client-facing model ID for this provider (catalog model ID).</summary>
    public required string ClientModelId { get; init; }

    public string? Label { get; init; }

    public string? Brand { get; init; }

    public string? Vendor { get; init; }

    public string? Family { get; init; }

    public string? Variant { get; init; }

    public IReadOnlyList<string> PerformanceLevels { get; init; } = [];

    /// <summary>Raw catalog <c>status</c>; no routing semantics are inferred.</summary>
    public required string Status { get; init; }

    /// <summary>Explicit tier projected from <see cref="Status"/> (metadata only).</summary>
    public required CatalogAvailabilityTier AvailabilityTier { get; init; }

    public decimal? PriceInput { get; init; }

    public decimal? PriceOutput { get; init; }

    public string? PriceCurrency { get; init; }

    public string? PriceSource { get; init; }

    public string? PriceUpdatedAt { get; init; }

    public string? PriceBasis { get; init; }

    /// <summary>Stable metadata reference into this projection record.</summary>
    public required string MetadataRef { get; init; }

    /// <summary>Stable source identity, for example <c>installer/model-catalog.json:v3</c>.</summary>
    public required string SourceVersion { get; init; }

    /// <summary>Lowercase SHA-256 of the source catalog bytes, when supplied.</summary>
    public string? SourceSha256 { get; init; }

    /// <summary>Always empty from the catalog; aliases exist only when explicitly configured.</summary>
    public IReadOnlyList<string> Aliases { get; init; } = [];
}
