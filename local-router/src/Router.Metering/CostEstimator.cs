namespace Router.Metering;

/// <summary>
/// Deterministic decimal cost estimator. Prices are per 1M tokens; no float or
/// double arithmetic is used. Unknown prices/missing usage never yield zero.
/// </summary>
public static class CostEstimator
{
    public const decimal PerMillion = 1_000_000m;

    public static TimeSpan DefaultStaleAfter { get; } = TimeSpan.FromDays(90);

    public static CostEstimate Estimate(
        UsageRecord usage,
        PricingSnapshot snapshot,
        string providerId,
        string modelId,
        DateTimeOffset asOf,
        TimeSpan? staleAfter = null)
    {
        ArgumentNullException.ThrowIfNull(usage);
        ArgumentNullException.ThrowIfNull(snapshot);
        ModelPricing? pricing = snapshot.TryGet(providerId, modelId);
        if (pricing is null)
        {
            return new CostEstimate
            {
                PricingSnapshotVersion = snapshot.SnapshotVersion,
                Status = CostEstimateStatus.Unavailable,
                Estimated = true,
            };
        }

        if (usage.InputTokens is null && usage.OutputTokens is null && usage.TotalTokens is null)
        {
            return new CostEstimate
            {
                PricingSnapshotVersion = snapshot.SnapshotVersion,
                PricingSource = pricing.PriceSource,
                EffectiveAt = pricing.EffectiveAt,
                Status = CostEstimateStatus.Unavailable,
                Estimated = true,
            };
        }

        decimal? inputCost = null;
        decimal? outputCost = null;
        decimal? cachedCost = null;
        decimal? reasoningCost = null;
        var missing = new List<string>();

        if (usage.InputTokens is > 0)
        {
            if (pricing.InputPrice is { } inputPrice)
            {
                inputCost = PerMillionCost(usage.InputTokens.Value, inputPrice);
            }
            else
            {
                missing.Add("input_price");
            }
        }

        if (usage.OutputTokens is > 0)
        {
            if (pricing.OutputPrice is { } outputPrice)
            {
                outputCost = PerMillionCost(usage.OutputTokens.Value, outputPrice);
            }
            else
            {
                missing.Add("output_price");
            }
        }

        // Cached/reasoning usage is preserved as metadata. Catalog v3 has no
        // price for either, so a non-null count means partial, never free.
        if (usage.CachedTokens is > 0)
        {
            cachedCost = null;
        }

        if (usage.ReasoningTokens is > 0)
        {
            reasoningCost = null;
        }

        if (missing.Count > 0)
        {
            return new CostEstimate
            {
                Currency = pricing.Currency,
                PricingSnapshotVersion = snapshot.SnapshotVersion,
                PricingSource = pricing.PriceSource,
                EffectiveAt = pricing.EffectiveAt,
                Status = CostEstimateStatus.UnknownPrice,
                Estimated = true,
            };
        }

        decimal? total = Sum(inputCost, outputCost);
        CostEstimateStatus status = inputCost is null && outputCost is null
            ? CostEstimateStatus.Unavailable
            : usage.CachedTokens is > 0 || usage.ReasoningTokens is > 0
                ? CostEstimateStatus.PartialUsage
                : CostEstimateStatus.Complete;

        bool stale = pricing.EffectiveAt is { } effective
            && asOf > effective + (staleAfter ?? DefaultStaleAfter);
        if (stale)
        {
            status = CostEstimateStatus.StalePrice;
        }

        return new CostEstimate
        {
            InputCost = inputCost,
            OutputCost = outputCost,
            CachedCost = cachedCost,
            ReasoningCost = reasoningCost,
            TotalCost = total,
            Currency = pricing.Currency,
            PricingSnapshotVersion = snapshot.SnapshotVersion,
            PricingSource = pricing.PriceSource,
            EffectiveAt = pricing.EffectiveAt,
            Status = status,
            Estimated = true,
        };
    }

    private static decimal PerMillionCost(long tokens, decimal rate)
        => tokens / PerMillion * rate;

    private static decimal? Sum(params decimal?[] values)
    {
        decimal? total = null;
        foreach (decimal? value in values)
        {
            if (value is not null)
            {
                total = (total ?? 0m) + value.Value;
            }
        }

        return total;
    }
}
