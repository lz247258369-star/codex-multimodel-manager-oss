using CanonicalUsage = Router.ClientAdapters.Responses.UsageRecord;

namespace Router.Metering;

/// <summary>
/// Pure normalizer from provider-normalized canonical usage to the typed
/// metering <see cref="UsageRecord"/>. It never re-parses raw bodies, never
/// calls providers, and never estimates tokens. Missing usage stays null.
/// </summary>
public static class UsageNormalizer
{
    public static UsageRecord Normalize(
        CanonicalUsage? usage,
        string requestId,
        string providerId,
        string modelId,
        DateTimeOffset recordedAt)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(requestId);
        ArgumentException.ThrowIfNullOrWhiteSpace(providerId);
        ArgumentException.ThrowIfNullOrWhiteSpace(modelId);

        if (usage is null)
        {
            return new UsageRecord
            {
                RequestId = requestId,
                ProviderId = providerId,
                ModelId = modelId,
                Estimated = false,
                RecordedAt = recordedAt,
            };
        }

        return new UsageRecord
        {
            RequestId = requestId,
            ProviderId = providerId,
            ModelId = modelId,
            InputTokens = usage.InputTokens,
            OutputTokens = usage.OutputTokens,
            TotalTokens = usage.TotalTokens,
            CachedTokens = usage.CachedTokens,
            ReasoningTokens = usage.ReasoningTokens,
            Estimated = false,
            RecordedAt = recordedAt,
        };
    }
}
