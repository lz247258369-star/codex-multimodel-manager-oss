namespace Router.CatalogProjection;

/// <summary>
/// Explicit, immutable mapping from catalog provider IDs to existing Manager
/// provider identities. Provider identity is never inferred from model names,
/// brands, or stealth names; an unknown catalog provider fails closed.
/// </summary>
public static class CatalogProviderMapping
{
    /// <summary>Canonical catalog schema version this projection understands.</summary>
    public const int CanonicalCatalogVersion = 3;

    /// <summary>Stable source identity used for provenance.</summary>
    public const string SourceVersion = "installer/model-catalog.json:v3";

    private static readonly IReadOnlyDictionary<string, string> ByCatalogId = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["chatgpt"] = "chatgpt",
        ["modelstudio"] = "mm_modelstudio",
        ["openrouter"] = "mm_openrouter",
        ["mimo"] = "mm_mimo",
        // DSR2 added the direct DeepSeek official provider to the canonical
        // catalog. The identity is explicit and identical to the adapter's
        // ProviderId ("deepseek") and to the Router bootstrap provider table.
        // Without this entry the whole v3 projection fails closed and the host
        // silently loads no pricing at all.
        ["deepseek"] = "deepseek",
    };

    /// <summary>Returns the Manager provider ID for a catalog provider ID, or null when unknown.</summary>
    public static string? TryMap(string catalogProviderId)
        => ByCatalogId.TryGetValue(catalogProviderId, out string? managerId) ? managerId : null;

    /// <summary>All known catalog provider IDs.</summary>
    public static IReadOnlyCollection<string> CatalogProviderIds => ByCatalogId.Keys.ToArray();
}
