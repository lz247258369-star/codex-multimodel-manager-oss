using System.Text.Json;
using Router.Core.Errors;
using Xunit;

namespace Router.CatalogProjection.Tests;

public sealed class CatalogProjectionTests
{
    private static readonly string FixtureRoot = Path.Combine(AppContext.BaseDirectory, "fixtures", "local-router", "v1", "catalog");

    [Fact]
    public void Representative_v3_catalog_projects_all_provider_scoped_models()
    {
        CatalogProjectionResult result = ProjectFixture("catalog.v3.representative.json");

        result.Validate();
        Assert.NotNull(result.Projection);

        RouterCatalogProjection projection = result.Projection!;
        Assert.Equal(3, projection.SchemaVersion);
        Assert.Equal(CatalogProviderMapping.SourceVersion, projection.SourceVersion);
        Assert.Equal("USD per 1M tokens", projection.PriceBasis);

        string[] providerIds = projection.Models.Select(static model => model.ProviderId).Distinct().OrderBy(static value => value, StringComparer.Ordinal).ToArray();
        Assert.Equal(["chatgpt", "mm_mimo", "mm_modelstudio", "mm_openrouter"], providerIds);

        Assert.Equal(6, projection.Models.Count);
    }

    [Fact]
    public void Same_model_string_across_providers_stays_provider_scoped()
    {
        CatalogProjectionResult result = ProjectInline("""
            {
              "version": 3,
              "providers": [
                {
                  "id": "openrouter",
                  "models": [ { "id": "shared-name", "status": "official" } ]
                },
                {
                  "id": "modelstudio",
                  "models": [ { "id": "shared-name", "status": "verified" } ]
                }
              ]
            }
            """);

        result.Validate();
        CatalogModelMetadata openrouter = result.Projection!.TryGet("mm_openrouter", "shared-name")!;
        CatalogModelMetadata modelstudio = result.Projection.TryGet("mm_modelstudio", "shared-name")!;

        Assert.NotNull(openrouter);
        Assert.NotNull(modelstudio);
        Assert.Equal("mm_openrouter", openrouter.ProviderId);
        Assert.Equal("mm_modelstudio", modelstudio.ProviderId);
        Assert.NotEqual(openrouter.MetadataRef, modelstudio.MetadataRef);
    }

    [Fact]
    public void V4_schema_v3_model_projection_is_regression_safe()
    {
        CatalogProjectionResult result = ProjectFixture("catalog.v3.representative.json");

        result.Validate();
        CatalogModelMetadata glm = result.Projection!.TryGet("mm_openrouter", "z-ai/glm-5.3")!;
        Assert.NotNull(glm);
        Assert.Equal("z-ai/glm-5.3", glm.ModelId);
        Assert.Equal("z-ai/glm-5.3", glm.ClientModelId);
        Assert.Equal("Z.ai / GLM", glm.Brand);
        Assert.Equal("Z.ai", glm.Vendor);
        Assert.Equal("GLM", glm.Family);
        Assert.Equal("5.3", glm.Variant);
        Assert.Equal("credit", glm.Status);
        Assert.Equal(CatalogAvailabilityTier.Caution, glm.AvailabilityTier);
        Assert.Empty(glm.Aliases);
    }

    [Fact]
    public void V4_pricing_metadata_projection_is_regression_safe()
    {
        CatalogProjectionResult result = ProjectFixture("catalog.v3.representative.json");

        result.Validate();
        CatalogModelMetadata gpt = result.Projection!.TryGet("chatgpt", "gpt-5.6-sol")!;
        Assert.NotNull(gpt);
        Assert.Equal(5.0m, gpt.PriceInput);
        Assert.Equal(30.0m, gpt.PriceOutput);
        Assert.Equal("USD", gpt.PriceCurrency);
        Assert.Equal("OpenAI API pricing", gpt.PriceSource);
        Assert.Equal("2026-08-25", gpt.PriceUpdatedAt);
        Assert.Equal("USD per 1M tokens", gpt.PriceBasis);

        CatalogModelMetadata qwen = result.Projection.TryGet("mm_modelstudio", "qwen3-coder-plus")!;
        Assert.Null(qwen.PriceInput);
        Assert.Null(qwen.PriceOutput);
        Assert.Equal("provider-dynamic", qwen.PriceSource);
        Assert.Null(qwen.PriceUpdatedAt);
    }

    [Fact]
    public void Status_tier_mapping_is_explicit_and_content_free()
    {
        Assert.Equal(CatalogAvailabilityTier.Available, CatalogAvailabilityTierMapping.Map("recommended"));
        Assert.Equal(CatalogAvailabilityTier.Available, CatalogAvailabilityTierMapping.Map("official"));
        Assert.Equal(CatalogAvailabilityTier.Available, CatalogAvailabilityTierMapping.Map("verified"));
        Assert.Equal(CatalogAvailabilityTier.Configured, CatalogAvailabilityTierMapping.Map("configured"));
        Assert.Equal(CatalogAvailabilityTier.Caution, CatalogAvailabilityTierMapping.Map("experimental"));
        Assert.Equal(CatalogAvailabilityTier.Caution, CatalogAvailabilityTierMapping.Map("credit"));
        Assert.Equal(CatalogAvailabilityTier.Unknown, CatalogAvailabilityTierMapping.Map("mystery-status"));
    }

    [Fact]
    public void Projection_never_invents_aliases_or_upstream_ids()
    {
        CatalogProjectionResult result = ProjectFixture("catalog.v3.representative.json");

        result.Validate();
        foreach (CatalogModelMetadata metadata in result.Projection!.Models)
        {
            Assert.Empty(metadata.Aliases);
        }
    }

    [Fact]
    public void Stealth_model_name_is_preserved_but_never_mapped_to_a_real_model()
    {
        CatalogProjectionResult result = ProjectFixture("catalog.v3.representative.json");

        result.Validate();
        CatalogModelMetadata stealth = result.Projection!.TryGet("mm_openrouter", "stealth/ox-alpha")!;
        Assert.NotNull(stealth);
        Assert.Equal("stealth/ox-alpha", stealth.ModelId);
        Assert.Equal(CatalogAvailabilityTier.Caution, stealth.AvailabilityTier);
    }

    [Fact]
    public void Unknown_catalog_provider_fails_closed()
    {
        CatalogProjectionResult result = ProjectFixture("catalog.v3.unknown-provider.json");

        result.Validate();
        Assert.Null(result.Projection);
        Assert.Equal(RouterErrorCode.UnknownProvider, result.Error!.Code);
    }

    [Fact]
    public void Duplicate_provider_scoped_model_id_fails_closed()
    {
        CatalogProjectionResult result = ProjectFixture("catalog.v3.duplicate-model.json");

        result.Validate();
        Assert.Null(result.Projection);
        Assert.Equal(RouterErrorCode.DuplicateRegistryKey, result.Error!.Code);
    }

    [Fact]
    public void Unsupported_catalog_version_fails_closed()
    {
        CatalogProjectionResult result = ProjectFixture("catalog.v3.unsupported-version.json");

        result.Validate();
        Assert.Null(result.Projection);
        Assert.Equal(RouterErrorCode.CatalogUnsupportedVersion, result.Error!.Code);
    }

    [Fact]
    public void Corrupt_catalog_json_fails_closed()
    {
        CatalogProjectionResult result = ModelCatalogProjector.Project("{ not json ]");

        result.Validate();
        Assert.Null(result.Projection);
        Assert.Equal(RouterErrorCode.CatalogInvalid, result.Error!.Code);
    }

    [Fact]
    public void Projection_is_deterministic_across_runs()
    {
        string text = File.ReadAllText(FixturePath("catalog.v3.representative.json"));
        CatalogProjectionResult first = ModelCatalogProjector.Project(text);
        CatalogProjectionResult second = ModelCatalogProjector.Project(text);

        first.Validate();
        second.Validate();
        string firstJson = JsonSerializer.Serialize(first.Projection!.Models);
        string secondJson = JsonSerializer.Serialize(second.Projection!.Models);
        Assert.Equal(firstJson, secondJson);
    }

    [Fact]
    public void Source_sha256_is_stable_and_lowercase_hex()
    {
        byte[] bytes = File.ReadAllBytes(FixturePath("catalog.v3.representative.json"));
        string sha = Router.Core.Support.SafeHasher.Sha256Hex(bytes);

        CatalogProjectionResult result = ModelCatalogProjector.Project(bytes, "tests/fixtures/local-router/v1/catalog/catalog.v3.representative.json", sha);

        result.Validate();
        Assert.Equal(sha, result.Projection!.SourceSha256);
        Assert.Matches("^[0-9a-f]{64}$", result.Projection.SourceSha256);
    }

    [Fact]
    public void Metadata_refs_are_stable_and_provider_scoped()
    {
        CatalogProjectionResult result = ProjectFixture("catalog.v3.representative.json");

        result.Validate();
        CatalogModelMetadata glm = result.Projection!.TryGet("mm_openrouter", "z-ai/glm-5.3")!;
        Assert.Equal("catalog.metadata.v3.mm_openrouter.z-ai-glm-5.3", glm.MetadataRef);
        CatalogModelMetadata qwen = result.Projection.TryGet("mm_modelstudio", "qwen3-coder-plus")!;
        Assert.Equal("catalog.metadata.v3.mm_modelstudio.qwen3-coder-plus", qwen.MetadataRef);
    }

    [Fact]
    public void Env_key_is_reference_name_only()
    {
        CatalogProjectionResult result = ProjectFixture("catalog.v3.representative.json");

        result.Validate();
        CatalogModelMetadata openrouter = result.Projection!.Models.First(static model => model.ProviderId == "mm_openrouter");
        Assert.Equal("OPENROUTER_API_KEY", openrouter.EnvKeyReference);
    }

    private static CatalogProjectionResult ProjectFixture(string name)
        => ModelCatalogProjector.Project(File.ReadAllBytes(FixturePath(name)), FixturePath(name), Router.Core.Support.SafeHasher.Sha256Hex(File.ReadAllBytes(FixturePath(name))));

    private static CatalogProjectionResult ProjectInline(string json)
        => ModelCatalogProjector.Project(json);

    private static string FixturePath(string name) => Path.Combine(FixtureRoot, name);
}
