using System.Text.Json;
using Router.Core.Errors;
using Router.Core.Support;

namespace Router.CatalogProjection;

/// <summary>
/// Deterministic, offline projection of the canonical v3 model catalog into
/// provider-scoped Router metadata. Performs no network access, no model
/// discovery, no approval, and no identity inference.
/// </summary>
public static class ModelCatalogProjector
{
    private static readonly JsonSerializerOptions DocumentOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        AllowTrailingCommas = false,
    };

    /// <summary>
    /// Projects catalog JSON bytes into an immutable <see cref="CatalogProjection"/>.
    /// </summary>
    public static CatalogProjectionResult Project(ReadOnlySpan<byte> catalogJson, string? sourcePath = null, string? sourceSha256 = null)
    {
        try
        {
            ModelCatalogDocument? document;
            try
            {
                document = JsonSerializer.Deserialize<ModelCatalogDocument>(catalogJson, DocumentOptions);
            }
            catch (JsonException)
            {
                return CatalogProjectionResult.Fail(CatalogProjectionErrors.Invalid());
            }

            if (document is null)
            {
                return CatalogProjectionResult.Fail(CatalogProjectionErrors.Invalid());
            }

            return Build(document, sourcePath, sourceSha256);
        }
        catch (Exception)
        {
            return CatalogProjectionResult.Fail(CatalogProjectionErrors.Invalid());
        }
    }

    /// <summary>Projects catalog JSON text into an immutable projection.</summary>
    public static CatalogProjectionResult Project(string catalogJson, string? sourcePath = null, string? sourceSha256 = null)
        => Project(System.Text.Encoding.UTF8.GetBytes(catalogJson), sourcePath, sourceSha256);

    private static CatalogProjectionResult Build(ModelCatalogDocument document, string? sourcePath, string? sourceSha256)
    {
        if (document.Version != CatalogProviderMapping.CanonicalCatalogVersion)
        {
            return CatalogProjectionResult.Fail(CatalogProjectionErrors.UnsupportedVersion());
        }

        if (document.Providers.Count == 0)
        {
            return CatalogProjectionResult.Fail(CatalogProjectionErrors.Invalid("providers"));
        }

        var records = new List<CatalogModelMetadata>();
        foreach (CatalogProvider provider in document.Providers)
        {
            string? managerId = CatalogProviderMapping.TryMap(provider.Id);
            if (managerId is null)
            {
                return CatalogProjectionResult.Fail(CatalogProjectionErrors.UnknownProvider("providers.id"));
            }

            var seenModels = new HashSet<string>(StringComparer.Ordinal);
            foreach (CatalogModel model in provider.Models)
            {
                if (string.IsNullOrWhiteSpace(model.Id) || !seenModels.Add(model.Id))
                {
                    return CatalogProjectionResult.Fail(CatalogProjectionErrors.DuplicateModel("providers.models.id"));
                }

                string status = string.IsNullOrWhiteSpace(model.Status) ? "unknown" : model.Status;
                records.Add(new CatalogModelMetadata
                {
                    ProviderId = managerId,
                    CatalogProviderId = provider.Id,
                    CatalogProviderLabel = string.IsNullOrWhiteSpace(provider.Label) ? provider.Id : provider.Label,
                    EnvKeyReference = string.IsNullOrWhiteSpace(provider.EnvKey) ? null : provider.EnvKey,
                    ModelId = model.Id,
                    ClientModelId = model.Id,
                    Label = model.Label,
                    Brand = model.Brand,
                    Vendor = model.Vendor,
                    Family = model.Family,
                    Variant = model.Variant,
                    PerformanceLevels = model.PerformanceLevels.ToArray(),
                    Status = status,
                    AvailabilityTier = CatalogAvailabilityTierMapping.Map(status),
                    PriceInput = model.PriceInput,
                    PriceOutput = model.PriceOutput,
                    PriceCurrency = model.PriceCurrency,
                    PriceSource = model.PriceSource,
                    PriceUpdatedAt = model.PriceUpdatedAt,
                    PriceBasis = document.PriceBasis,
                    MetadataRef = DeriveMetadataRef(managerId, model.Id),
                    SourceVersion = CatalogProviderMapping.SourceVersion,
                    SourceSha256 = sourceSha256,
                    Aliases = [],
                });
            }
        }

        var ordered = records
            .OrderBy(static record => record.ProviderId, StringComparer.Ordinal)
            .ThenBy(static record => record.ModelId, StringComparer.Ordinal)
            .ToArray();

        var byProvider = ordered
            .GroupBy(static record => record.ProviderId, StringComparer.Ordinal)
            .ToDictionary(static group => group.Key, static group => (IReadOnlyList<CatalogModelMetadata>)group.ToArray(), StringComparer.Ordinal);

        var byProviderModel = ordered.ToDictionary(
            static record => (record.ProviderId, record.ModelId),
            static record => record);

        var projection = new RouterCatalogProjection
        {
            SchemaVersion = CatalogProviderMapping.CanonicalCatalogVersion,
            PriceBasis = document.PriceBasis,
            SourceVersion = CatalogProviderMapping.SourceVersion,
            SourcePath = sourcePath,
            SourceSha256 = sourceSha256,
            Models = ordered,
            ByProvider = byProvider,
            ByProviderModel = byProviderModel,
        };

        return CatalogProjectionResult.Ok(projection);
    }

    /// <summary>
    /// Stable, explicit metadata reference. The reference is derived from
    /// declared identities only; it never guesses an alias or a real model.
    /// </summary>
    private static string DeriveMetadataRef(string providerId, string modelId)
        => "catalog.metadata.v3." + SanitizeSegment(providerId) + "." + SanitizeSegment(modelId);

    private static string SanitizeSegment(string value)
    {
        var chars = new char[value.Length];
        for (int index = 0; index < value.Length; index++)
        {
            char current = value[index];
            bool allowed = char.IsAsciiLetterOrDigit(current) || current is '.' or '_' or '-';
            chars[index] = allowed ? char.ToLowerInvariant(current) : '-';
        }

        return new string(chars);
    }
}

/// <summary>Loads and projects the canonical catalog file without network access.</summary>
public static class ModelCatalogFileProjector
{
    /// <summary>
    /// Reads a catalog file from disk and projects it. The path is provenance
    /// only; no secrets or user state are read.
    /// </summary>
    public static CatalogProjectionResult ProjectFromFile(string path)
    {
        try
        {
            byte[] bytes = File.ReadAllBytes(path);
            return ModelCatalogProjector.Project(bytes, path, SafeHasher.Sha256Hex(bytes));
        }
        catch (Exception)
        {
            return CatalogProjectionResult.Fail(CatalogProjectionErrors.Invalid());
        }
    }
}
