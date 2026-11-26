using System.Text.Json;
using Router.CatalogProjection;
using Router.Metering;
using Xunit;
using CanonicalUsage = Router.ClientAdapters.Responses.UsageRecord;

namespace Router.Metering.Tests;

public sealed class MeteringTests
{
    private static readonly JsonSerializerOptions JsonOptions = new();
    private static readonly DateTimeOffset RecordedAt = DateTimeOffset.Parse("2026-09-03T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal);
    private static readonly DateTimeOffset AsOf = RecordedAt;

    private static string FixtureRoot
        => Path.Combine(AppContext.BaseDirectory, "fixtures", "local-router", "v1", "metering");

    private static PricingSnapshot Snapshot()
    {
        byte[] bytes = File.ReadAllBytes(Path.Combine(FixtureRoot, "catalog.v3.metering.json"));
        CatalogProjectionResult projection = ModelCatalogProjector.Project(bytes, "catalog.v3.metering.json", "test-sha");
        projection.Validate();
        PricingProjectionResult pricing = PricingProjector.Project(projection.Projection!, AsOf);
        Assert.True(pricing.IsSuccess);
        return pricing.Snapshot!;
    }

    [Fact]
    public void Catalog_fixture_is_versioned_and_source_of_truth()
    {
        CatalogProjectionResult projection = ModelCatalogProjector.Project(
            File.ReadAllBytes(Path.Combine(FixtureRoot, "catalog.v3.metering.json")),
            "catalog.v3.metering.json");
        projection.Validate();

        Assert.Equal(3, projection.Projection!.SchemaVersion);
        Assert.Equal("USD per 1M tokens", projection.Projection.PriceBasis);
    }

    [Fact]
    public void Pricing_projection_is_provider_and_model_exact()
    {
        PricingSnapshot snapshot = Snapshot();

        ModelPricing glm = snapshot.TryGet("mm_openrouter", "z-ai/glm-5.3")!;
        Assert.Equal(5.0m, glm.InputPrice);
        Assert.Equal(30.0m, glm.OutputPrice);
        Assert.Null(snapshot.TryGet("mm_mimo", "z-ai/glm-5.3"));
    }

    [Fact]
    public void Same_model_under_different_provider_has_different_price()
    {
        PricingSnapshot snapshot = Snapshot();

        ModelPricing openrouter = snapshot.TryGet("mm_openrouter", "shared-model")!;
        ModelPricing mimo = snapshot.TryGet("mm_mimo", "shared-model")!;

        Assert.Equal(1.0m, openrouter.InputPrice);
        Assert.Equal(5.0m, mimo.InputPrice);
    }

    [Fact]
    public void Missing_usage_stays_null_and_never_estimated()
    {
        UsageRecord record = UsageNormalizer.Normalize(null, "req_1", "mm_openrouter", "z-ai/glm-5.3", RecordedAt);

        Assert.Null(record.InputTokens);
        Assert.Null(record.OutputTokens);
        Assert.Null(record.TotalTokens);
        Assert.False(record.Estimated);
    }

    [Fact]
    public void Normalized_usage_preserves_provider_reported_counts_only()
    {
        var canonical = new CanonicalUsage
        {
            InputTokens = 7,
            OutputTokens = 5,
            TotalTokens = 12,
            CachedTokens = 2,
            ReasoningTokens = 1,
        };

        UsageRecord record = UsageNormalizer.Normalize(canonical, "req_2", "mm_openrouter", "z-ai/glm-5.3", RecordedAt);

        Assert.Equal(7, record.InputTokens);
        Assert.Equal(5, record.OutputTokens);
        Assert.Equal(12, record.TotalTokens);
        Assert.Equal(2, record.CachedTokens);
        Assert.Equal(1, record.ReasoningTokens);
        Assert.False(record.Estimated);
    }

    [Fact]
    public void Decimal_cost_math_is_exact()
    {
        UsageRecord usage = Usage(1000, 500);
        CostEstimate estimate = CostEstimator.Estimate(usage, Snapshot(), "mm_openrouter", "z-ai/glm-5.3", AsOf);

        Assert.Equal(0.005m, estimate.InputCost);
        Assert.Equal(0.015m, estimate.OutputCost);
        Assert.Equal(0.02m, estimate.TotalCost);
        Assert.Equal(CostEstimateStatus.Complete, estimate.Status);
    }

    [Fact]
    public void Large_usage_calculation_is_precise()
    {
        UsageRecord usage = Usage(2_000_000, 0);
        CostEstimate estimate = CostEstimator.Estimate(usage, Snapshot(), "mm_openrouter", "shared-model", AsOf);

        Assert.Equal(2.0m, estimate.InputCost);
        Assert.Equal(CostEstimateStatus.Complete, estimate.Status);
    }

    [Fact]
    public void Unknown_price_never_becomes_zero()
    {
        UsageRecord usage = Usage(10_000, 0);
        CostEstimate estimate = CostEstimator.Estimate(usage, Snapshot(), "mm_modelstudio", "qwen3.8-max", AsOf);

        Assert.Equal(CostEstimateStatus.UnknownPrice, estimate.Status);
        Assert.Null(estimate.InputCost);
        Assert.Null(estimate.OutputCost);
        Assert.Null(estimate.TotalCost);
    }

    [Fact]
    public void Missing_usage_yields_unavailable_not_zero()
    {
        UsageRecord usage = UsageNormalizer.Normalize(null, "req_3", "mm_openrouter", "z-ai/glm-5.3", RecordedAt);
        CostEstimate estimate = CostEstimator.Estimate(usage, Snapshot(), "mm_openrouter", "z-ai/glm-5.3", AsOf);

        Assert.Equal(CostEstimateStatus.Unavailable, estimate.Status);
        Assert.Null(estimate.TotalCost);
    }

    [Fact]
    public void Cached_and_reasoning_without_prices_are_partial_not_free()
    {
        UsageRecord usage = Usage(100, 50) with
        {
            CachedTokens = 10,
            ReasoningTokens = 5,
        };
        CostEstimate estimate = CostEstimator.Estimate(usage, Snapshot(), "mm_openrouter", "z-ai/glm-5.3", AsOf);

        Assert.Equal(CostEstimateStatus.PartialUsage, estimate.Status);
        Assert.Null(estimate.CachedCost);
        Assert.Null(estimate.ReasoningCost);
        Assert.NotNull(estimate.TotalCost);
    }

    [Fact]
    public void Stale_pricing_is_marked_stale_with_amounts_preserved()
    {
        DateTimeOffset staleAsOf = DateTimeOffset.Parse("2027-01-01T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal);
        UsageRecord usage = Usage(1000, 500);
        CostEstimate estimate = CostEstimator.Estimate(usage, Snapshot(), "mm_openrouter", "z-ai/glm-5.3", staleAsOf);

        Assert.Equal(CostEstimateStatus.StalePrice, estimate.Status);
        Assert.Equal(0.005m, estimate.InputCost);
        Assert.True(estimate.Estimated);
    }

    // Freshness boundary of the production rule (stale only when asOf is later
    // than EffectiveAt + DefaultStaleAfter). The instants are derived from the
    // fixture price's own EffectiveAt, never from the wall clock.
    [Theory]
    [InlineData(-TimeSpan.TicksPerDay, CostEstimateStatus.Complete)]
    [InlineData(-1L, CostEstimateStatus.Complete)]
    [InlineData(0L, CostEstimateStatus.Complete)]
    [InlineData(1L, CostEstimateStatus.StalePrice)]
    [InlineData(TimeSpan.TicksPerDay, CostEstimateStatus.StalePrice)]
    public void Price_freshness_boundary_is_exactly_the_default_stale_window(long offsetTicks, CostEstimateStatus expected)
    {
        PricingSnapshot snapshot = Snapshot();
        DateTimeOffset effective = snapshot.TryGet("mm_openrouter", "z-ai/glm-5.3")!.EffectiveAt!.Value;
        DateTimeOffset asOf = effective + CostEstimator.DefaultStaleAfter + TimeSpan.FromTicks(offsetTicks);

        CostEstimate estimate = CostEstimator.Estimate(Usage(1000, 500), snapshot, "mm_openrouter", "z-ai/glm-5.3", asOf);

        Assert.Equal(TimeSpan.FromDays(90), CostEstimator.DefaultStaleAfter);
        Assert.Equal(expected, estimate.Status);
        Assert.Equal(effective, estimate.EffectiveAt);
        Assert.Equal(0.005m, estimate.InputCost);
    }

    [Fact]
    public void Currency_mismatch_fails_closed()
    {
        string json = """
            {"version":3,"price_basis":"USD per 1M tokens","providers":[
              {"id":"openrouter","label":"OpenRouter","models":[{"id":"a","price_input":1,"price_output":2,"price_currency":"USD","price_source":"s","price_updated_at":"2026-08-01","status":"credit"}]},
              {"id":"mimo","label":"MiMo","models":[{"id":"a","price_input":1,"price_output":2,"price_currency":"EUR","price_source":"s","price_updated_at":"2026-08-01","status":"credit"}]}
            ]}
            """;
        CatalogProjectionResult projection = ModelCatalogProjector.Project(json);
        projection.Validate();

        PricingProjectionResult pricing = PricingProjector.Project(projection.Projection!, AsOf);

        Assert.False(pricing.IsSuccess);
        Assert.Equal(PricingProjector.ErrorCurrencyMismatch, pricing.ErrorCode);
    }

    [Fact]
    public void Deterministic_calculation_repeatable()
    {
        UsageRecord usage = Usage(123_456, 65_432);
        CostEstimate first = CostEstimator.Estimate(usage, Snapshot(), "mm_openrouter", "z-ai/glm-5.3", AsOf);
        CostEstimate second = CostEstimator.Estimate(usage, Snapshot(), "mm_openrouter", "z-ai/glm-5.3", AsOf);

        Assert.Equal(first, second);
        Assert.Equal(JsonSerializer.Serialize(first, JsonOptions), JsonSerializer.Serialize(second, JsonOptions));
    }

    [Fact]
    public void Cost_estimate_never_contains_prompt_or_secret_fields()
    {
        CostEstimate estimate = CostEstimator.Estimate(Usage(10, 10), Snapshot(), "mm_openrouter", "z-ai/glm-5.3", AsOf);
        string json = JsonSerializer.Serialize(estimate, JsonOptions);

        Assert.DoesNotContain("prompt", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("authorization", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("secret", json, StringComparison.OrdinalIgnoreCase);
    }

    private static UsageRecord Usage(int inputTokens, int outputTokens)
        => new()
        {
            RequestId = "req_usage",
            ProviderId = "mm_openrouter",
            ModelId = "z-ai/glm-5.3",
            InputTokens = inputTokens,
            OutputTokens = outputTokens,
            TotalTokens = inputTokens + outputTokens,
            Estimated = false,
            RecordedAt = RecordedAt,
        };
}
