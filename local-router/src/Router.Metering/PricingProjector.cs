using Router.CatalogProjection;

namespace Router.Metering;

/// <summary>
/// Versioned pricing projection. The canonical <c>installer/model-catalog.json</c>
/// remains the only price source; this projector never creates a second price
/// table and never fetches prices.
/// </summary>
public static class PricingProjector
{
    public const string ErrorCurrencyMismatch = "currency_mismatch";

    public static PricingProjectionResult Project(
        RouterCatalogProjection catalog,
        DateTimeOffset? projectionTime = null)
    {
        ArgumentNullException.ThrowIfNull(catalog);

        string? currency = null;
        var byProviderModel = new Dictionary<(string ProviderId, string ModelId), ModelPricing>(catalog.Models.Count);
        DateTimeOffset? firstEffective = null;

        foreach (CatalogModelMetadata metadata in catalog.Models)
        {
            if (!string.IsNullOrWhiteSpace(metadata.PriceCurrency))
            {
                currency ??= metadata.PriceCurrency;
                if (!string.Equals(currency, metadata.PriceCurrency, StringComparison.Ordinal))
                {
                    return new PricingProjectionResult { ErrorCode = ErrorCurrencyMismatch };
                }
            }

            DateTimeOffset? effective = ParseEffectiveDate(metadata.PriceUpdatedAt);
            firstEffective ??= effective;

            byProviderModel[(metadata.ProviderId, metadata.ModelId)] = new ModelPricing
            {
                ProviderId = metadata.ProviderId,
                ModelId = metadata.ModelId,
                InputPrice = metadata.PriceInput,
                OutputPrice = metadata.PriceOutput,
                Currency = string.IsNullOrWhiteSpace(metadata.PriceCurrency) ? currency : metadata.PriceCurrency,
                PriceSource = metadata.PriceSource,
                PriceUpdatedAt = metadata.PriceUpdatedAt,
                EffectiveAt = effective,
                SourceVersion = metadata.SourceVersion,
                PricingVersion = catalog.SourceVersion + "@1",
            };
        }

        var snapshot = new PricingSnapshot
        {
            SchemaVersion = ModelPricing.SchemaVersion,
            SnapshotVersion = catalog.SourceVersion + "@" + (projectionTime?.ToUnixTimeSeconds() ?? 1),
            SourceVersion = catalog.SourceVersion,
            PriceBasis = catalog.PriceBasis,
            ByProviderModel = byProviderModel,
        };
        _ = firstEffective;

        return new PricingProjectionResult { Snapshot = snapshot };
    }

    private static DateTimeOffset? ParseEffectiveDate(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        string text = value.Length >= 10 ? value[..10] : value;
        return DateTimeOffset.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal, out DateTimeOffset parsed)
            ? parsed
            : null;
    }
}
