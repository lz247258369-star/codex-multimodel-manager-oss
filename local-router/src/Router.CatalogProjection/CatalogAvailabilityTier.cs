namespace Router.CatalogProjection;

/// <summary>
/// Explicit availability tier projected from the catalog <c>status</c> field.
/// The mapping mirrors the existing Manager health classification
/// (<c>installer/scripts/controller-health.ps1</c>). This tier is metadata, not
/// a routing decision: a model is eligible to route only when an explicit
/// enabled Router model route exists.
/// </summary>
public enum CatalogAvailabilityTier
{
    /// <summary>PASS tier: recommended, official, verified.</summary>
    Available,

    /// <summary>INFO tier: configured (not yet measured).</summary>
    Configured,

    /// <summary>WARN tier: experimental or quota-limited.</summary>
    Caution,

    /// <summary>Unknown catalog status; never used as a routing signal.</summary>
    Unknown,
}

/// <summary>Explicit status-to-tier mapping table.</summary>
public static class CatalogAvailabilityTierMapping
{
    public static CatalogAvailabilityTier Map(string status)
    {
        return status switch
        {
            "recommended" or "official" or "verified" => CatalogAvailabilityTier.Available,
            "configured" => CatalogAvailabilityTier.Configured,
            "experimental" or "credit" => CatalogAvailabilityTier.Caution,
            _ => CatalogAvailabilityTier.Unknown,
        };
    }
}
