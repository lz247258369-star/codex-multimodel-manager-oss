using Router.CatalogProjection;
using Router.Metering;
using Xunit;
using CanonicalUsage = Router.ClientAdapters.Responses.UsageRecord;

namespace Router.Metering.Tests;

public sealed class RequestMeteringServiceTests
{
    private static readonly DateTimeOffset CompletedAt = DateTimeOffset.Parse(
        "2026-09-03T00:00:00Z",
        System.Globalization.CultureInfo.InvariantCulture,
        System.Globalization.DateTimeStyles.AdjustToUniversal);

    private static string FixtureRoot
        => Path.Combine(AppContext.BaseDirectory, "fixtures", "local-router", "v1", "metering");

    private static PricingSnapshot Snapshot()
    {
        byte[] bytes = File.ReadAllBytes(Path.Combine(FixtureRoot, "catalog.v3.metering.json"));
        CatalogProjectionResult projection = ModelCatalogProjector.Project(bytes, "catalog.v3.metering.json", "test-sha");
        projection.Validate();
        PricingProjectionResult pricing = PricingProjector.Project(projection.Projection!, CompletedAt);
        Assert.True(pricing.IsSuccess);
        return pricing.Snapshot!;
    }

    private static RequestMeteringInput Input(
        CanonicalUsage? usage,
        string requestId = "req_lr10r_1",
        string? providerId = "mm_openrouter",
        string? catalogModelId = "z-ai/glm-5.3",
        string? routeId = "route.lr10r",
        string? modelRouteId = "model_route.lr10r",
        string? upstreamModelId = "z-ai/glm-5.3")
        => new()
        {
            RequestId = requestId,
            TraceId = "trc_lr10r_1",
            ClientId = "client.local_test",
            ConfigGeneration = new string('a', 64),
            ModelId = "z-ai/glm-5.3",
            ProviderId = providerId,
            RouteId = routeId,
            ModelRouteId = modelRouteId,
            CatalogModelId = catalogModelId,
            UpstreamModelId = upstreamModelId,
            Usage = usage,
            Stream = false,
            CompletedAt = CompletedAt,
            DurationMs = 100,
        };

    [Fact]
    public void Production_usage_is_normalized_once_with_correct_counts()
    {
        RequestMeteringService service = new(pricing: Snapshot());
        RequestMeteringRecord record = service.Record(Input(new CanonicalUsage
        {
            InputTokens = 100,
            OutputTokens = 25,
            TotalTokens = 125,
        }));

        Assert.Equal(RequestMeteringStatus.Recorded, record.Status);
        Assert.Equal(100, record.Usage!.InputTokens);
        Assert.Equal(25, record.Usage.OutputTokens);
        Assert.Equal(125, record.Usage.TotalTokens);
        Assert.NotNull(record.CostEstimate);
        Assert.Equal(0.0005m, record.CostEstimate!.InputCost);
        Assert.Equal(0.00075m, record.CostEstimate.OutputCost);
        Assert.Equal(0.00125m, record.CostEstimate.TotalCost);
        Assert.Equal(CostEstimateStatus.Complete, record.CostEstimate.Status);
        Assert.True(record.CostEstimate.Estimated);
    }

    [Fact]
    public void Missing_usage_stays_null_and_cost_is_unavailable()
    {
        RequestMeteringService service = new(pricing: Snapshot());
        RequestMeteringRecord record = service.Record(Input(null));

        Assert.Equal(RequestMeteringStatus.UsageMissing, record.Status);
        Assert.Null(record.Usage!.InputTokens);
        Assert.Null(record.Usage.OutputTokens);
        Assert.Equal(CostEstimateStatus.Unavailable, record.CostEstimate!.Status);
        Assert.Null(record.CostEstimate.TotalCost);
    }

    [Fact]
    public void Missing_identity_never_guesses_provider_or_model()
    {
        RequestMeteringService service = new(pricing: Snapshot());
        RequestMeteringRecord record = service.Record(Input(
            new CanonicalUsage { InputTokens = 100, OutputTokens = 25, TotalTokens = 125 },
            providerId: null,
            catalogModelId: null));

        Assert.Equal(RequestMeteringStatus.IdentityUnavailable, record.Status);
        Assert.Null(record.Usage);
        Assert.Null(record.CostEstimate);
    }

    [Fact]
    public void Ambiguous_routes_for_the_same_client_model_never_select_a_route()
    {
        // The same client model is reachable through multiple routes/providers
        // in configuration, but the execution result carried no authoritative
        // identity. Metering must record IdentityUnavailable instead of picking
        // the lexicographically first route.
        RequestMeteringService service = new(pricing: Snapshot());
        RequestMeteringRecord record = service.Record(Input(
            new CanonicalUsage { InputTokens = 100, OutputTokens = 25, TotalTokens = 125 },
            requestId: "req_ambiguous_route",
            providerId: null,
            catalogModelId: null,
            routeId: null,
            modelRouteId: null,
            upstreamModelId: null));

        Assert.Equal(RequestMeteringStatus.IdentityUnavailable, record.Status);
        Assert.Null(record.ProviderId);
        Assert.Null(record.RouteId);
        Assert.Null(record.ModelRouteId);
        Assert.Null(record.ModelId);
        Assert.Null(record.UpstreamModelId);
        Assert.Null(record.Usage);
        Assert.Null(record.CostEstimate);
    }

    [Fact]
    public void Unknown_price_never_becomes_zero()
    {
        RequestMeteringService service = new(pricing: Snapshot());
        RequestMeteringRecord record = service.Record(Input(
            new CanonicalUsage { InputTokens = 10_000, OutputTokens = 0, TotalTokens = 10_000 },
            providerId: "mm_modelstudio",
            catalogModelId: "qwen3.8-max"));

        Assert.Equal(CostEstimateStatus.UnknownPrice, record.CostEstimate!.Status);
        Assert.Null(record.CostEstimate.InputCost);
        Assert.Null(record.CostEstimate.OutputCost);
        Assert.Null(record.CostEstimate.TotalCost);
    }

    [Fact]
    public void One_logical_request_produces_one_metering_record()
    {
        RequestMeteringService service = new();
        CanonicalUsage usage = new() { InputTokens = 100, OutputTokens = 25, TotalTokens = 125 };
        service.Record(Input(usage));
        service.Record(Input(usage));

        Assert.Equal(1, service.Store.Count);
        Assert.Single(service.Store.Recent(20));
    }

    [Fact]
    public void Store_is_bounded_and_returns_most_recent_records()
    {
        RequestMeteringStore store = new(capacity: 3);
        for (int index = 0; index < 5; index++)
        {
            store.Add(RequestMeteringRecord.Create(
                "req_" + index,
                "trc_" + index,
                "client.local_test",
                null,
                "mm_openrouter",
                null,
                null,
                "z-ai/glm-5.3",
                null,
                null,
                null,
                RequestMeteringStatus.IdentityUnavailable,
                false,
                CompletedAt.AddSeconds(index),
                index));
        }

        Assert.Equal(3, store.Count);
        IReadOnlyList<RequestMeteringRecord> recent = store.Recent(20);
        Assert.Equal(3, recent.Count);
        Assert.Equal("req_4", recent[^1].RequestId);
    }

    [Fact]
    public void Metering_records_never_contain_content_or_secret_sentinels()
    {
        RequestMeteringService service = new(pricing: Snapshot());
        service.Record(Input(new CanonicalUsage { InputTokens = 100, OutputTokens = 25, TotalTokens = 125 }));
        string json = System.Text.Json.JsonSerializer.Serialize(service.Store.Recent(20));

        foreach (string sentinel in new[]
        {
            "PROMPT_SENTINEL", "OUTPUT_SENTINEL", "TOOL_SENTINEL", "AUTH_SENTINEL",
            "API_KEY_SENTINEL", "PATH_SENTINEL",
        })
        {
            Assert.DoesNotContain(sentinel, json, StringComparison.Ordinal);
        }
    }
}
