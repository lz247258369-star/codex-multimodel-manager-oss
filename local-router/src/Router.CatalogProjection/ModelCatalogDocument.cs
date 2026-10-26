using System.Text.Json.Serialization;

namespace Router.CatalogProjection;

/// <summary>
/// Read-only projection of the canonical v3 catalog document
/// (<c>installer/model-catalog.json</c>). The catalog remains the source of
/// truth; this model never mutates or duplicates it into a second catalog.
/// </summary>
internal sealed record ModelCatalogDocument
{
    [JsonPropertyName("version")]
    public int Version { get; init; }

    [JsonPropertyName("price_basis")]
    public string? PriceBasis { get; init; }

    [JsonPropertyName("price_note")]
    public string? PriceNote { get; init; }

    [JsonPropertyName("providers")]
    public IReadOnlyList<CatalogProvider> Providers { get; init; } = [];
}

/// <summary>Catalog provider block. Provider identity is mapped explicitly.</summary>
internal sealed record CatalogProvider
{
    [JsonPropertyName("id")]
    public required string Id { get; init; }

    [JsonPropertyName("label")]
    public string? Label { get; init; }

    [JsonPropertyName("env_key")]
    public string? EnvKey { get; init; }

    [JsonPropertyName("models")]
    public IReadOnlyList<CatalogModel> Models { get; init; } = [];
}

/// <summary>Catalog model block (schema v3 fields).</summary>
internal sealed record CatalogModel
{
    [JsonPropertyName("id")]
    public required string Id { get; init; }

    [JsonPropertyName("label")]
    public string? Label { get; init; }

    [JsonPropertyName("brand")]
    public string? Brand { get; init; }

    [JsonPropertyName("vendor")]
    public string? Vendor { get; init; }

    [JsonPropertyName("family")]
    public string? Family { get; init; }

    [JsonPropertyName("variant")]
    public string? Variant { get; init; }

    [JsonPropertyName("performance_levels")]
    public IReadOnlyList<string> PerformanceLevels { get; init; } = [];

    [JsonPropertyName("price_input")]
    public decimal? PriceInput { get; init; }

    [JsonPropertyName("price_output")]
    public decimal? PriceOutput { get; init; }

    [JsonPropertyName("price_currency")]
    public string? PriceCurrency { get; init; }

    [JsonPropertyName("price_source")]
    public string? PriceSource { get; init; }

    [JsonPropertyName("price_updated_at")]
    public string? PriceUpdatedAt { get; init; }

    [JsonPropertyName("status")]
    public string? Status { get; init; }
}
