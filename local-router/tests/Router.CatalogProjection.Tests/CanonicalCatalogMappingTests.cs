using System.Text.Json;
using Xunit;

namespace Router.CatalogProjection.Tests;

/// <summary>
/// LR15-G1: the canonical v3 catalog and the explicit provider identity mapping
/// must never drift apart. An unmapped catalog provider id makes the whole
/// projection fail closed, which silently removes pricing from the Router host
/// (and therefore every cost estimate). The identity mapping is explicit by
/// design and is never inferred from model names or brands, so this test pins
/// the real canonical file rather than a fixture.
/// </summary>
public sealed class CanonicalCatalogMappingTests
{
    /// <summary>Repository root derived from the test output directory layout.</summary>
    private static string RepositoryRoot
        => Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", ".."));

    private static string CanonicalCatalogPath
        => Path.Combine(RepositoryRoot, "installer", "model-catalog.json");

    [Fact]
    public void Canonical_catalog_projects_and_every_provider_id_is_explicitly_mapped()
    {
        string path = CanonicalCatalogPath;
        Assert.True(File.Exists(path), "installer/model-catalog.json was not found from the repository root.");

        byte[] bytes = File.ReadAllBytes(path);
        CatalogProjectionResult result = ModelCatalogProjector.Project(bytes, "installer/model-catalog.json");
        result.Validate();
        Assert.Null(result.Error);
        Assert.NotNull(result.Projection);

        using JsonDocument document = JsonDocument.Parse(bytes);
        Assert.True(
            document.RootElement.TryGetProperty("providers", out JsonElement providers) && providers.ValueKind == JsonValueKind.Array,
            "the canonical catalog must declare a providers array.");

        var unmapped = new List<string>();
        foreach (JsonElement provider in providers.EnumerateArray())
        {
            string catalogId = provider.GetProperty("id").GetString()!;
            if (CatalogProviderMapping.TryMap(catalogId) is null)
            {
                unmapped.Add(catalogId);
            }
        }

        Assert.True(
            unmapped.Count == 0,
            "every catalog provider id needs an explicit identity mapping; unmapped: " + string.Join(", ", unmapped));
    }
}
