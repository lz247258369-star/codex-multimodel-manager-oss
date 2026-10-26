namespace Router.CatalogProjection;

/// <summary>
/// Immutable projection result over the canonical model catalog. It is a
/// metadata projection, never a second canonical catalog.
/// </summary>
public sealed record RouterCatalogProjection
{
    /// <summary>Catalog schema version that produced this projection.</summary>
    public required int SchemaVersion { get; init; }

    public string? PriceBasis { get; init; }

    /// <summary>Stable source identity, for example <c>installer/model-catalog.json:v3</c>.</summary>
    public required string SourceVersion { get; init; }

    /// <summary>Optional source path for provenance; never a secret path.</summary>
    public string? SourcePath { get; init; }

    /// <summary>Lowercase SHA-256 of the source catalog bytes, when supplied.</summary>
    public string? SourceSha256 { get; init; }

    /// <summary>All projected model metadata records, sorted deterministically.</summary>
    public required IReadOnlyList<CatalogModelMetadata> Models { get; init; }

    /// <summary>Provider-scoped index: provider ID to its model records.</summary>
    public required IReadOnlyDictionary<string, IReadOnlyList<CatalogModelMetadata>> ByProvider { get; init; }

    /// <summary>Provider-scoped index: (provider ID, model ID) to metadata.</summary>
    public required IReadOnlyDictionary<(string ProviderId, string ModelId), CatalogModelMetadata> ByProviderModel { get; init; }

    /// <summary>
    /// Returns the projected metadata for an exact provider/model pair, or null
    /// when the pair is not declared in the catalog. Absence never implies that
    /// an explicit Router model route is invalid.
    /// </summary>
    public CatalogModelMetadata? TryGet(string providerId, string modelId)
        => ByProviderModel.TryGetValue((providerId, modelId), out CatalogModelMetadata? metadata) ? metadata : null;
}

/// <summary>Typed projection outcome: exactly one of a projection or an error.</summary>
public sealed record CatalogProjectionResult
{
    public RouterCatalogProjection? Projection { get; init; }

    public Core.Errors.RouterError? Error { get; init; }

    public static CatalogProjectionResult Ok(RouterCatalogProjection projection)
        => new() { Projection = projection };

    public static CatalogProjectionResult Fail(Core.Errors.RouterError error)
        => new() { Error = error };

    /// <summary>Validates the discriminated invariant.</summary>
    public void Validate()
    {
        if ((Projection is null) == (Error is null))
        {
            throw new InvalidOperationException("A CatalogProjectionResult must contain exactly one of projection or error.");
        }
    }
}
