using System.Text.Json;
using Router.Core.Errors;

namespace Router.Execution;

/// <summary>HS-1C content-free quota error factories.</summary>
public static class QuotaErrors
{
    public static RouterError QuotaExhausted(string? requestId = null)
        => RouterError.Create(RouterErrorCode.QuotaExhausted, "The provider quota is exhausted.", "quota", requestId);

    public static RouterError CreditExhausted(string? requestId = null)
        => RouterError.Create(RouterErrorCode.CreditExhausted, "The provider credit balance is exhausted.", "credit", requestId);

    /// <summary>G-6: the model quota is exhausted and no approved fallback model could serve the request.</summary>
    public static RouterError QuotaFallbacksExhausted(string? requestId = null)
        => RouterError.Create(RouterErrorCode.QuotaFallbacksExhausted, "The model quota is exhausted and no approved fallback model is available.", "fallback", requestId);
}

/// <summary>
/// HS-1C bounded, content-free classifier for provider quota failures (the
/// Draft PR #88 classifier, relocated so no provider adapter changes). It
/// extracts only allowlisted machine error identifiers from a bounded error-body
/// prefix and never returns or stores raw provider text. Ambiguous 429
/// responses are never quota evidence.
/// </summary>
public static class QuotaExhaustionClassifier
{
    /// <summary>Maximum error-body prefix ever read for classification.</summary>
    public const int MaxErrorBodyBytes = 16 * 1024;

    private static readonly HashSet<string> OpenAIQuotaCodes = new(StringComparer.Ordinal)
    {
        "organization_usage_limit_exceeded",
        "organization_spend_limit_exceeded",
        "project_spend_limit_exceeded",
    };

    /// <summary>
    /// True only for status/provider pairs that can establish quota evidence.
    /// Every other failure keeps its fast status-only path: HS-1C adds no
    /// body-reading latency to ordinary 4xx, 5xx, timeout or unavailability.
    /// </summary>
    public static bool CanEstablishEvidence(string providerId, int statusCode)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(providerId);
        return statusCode == 402 || NeedsBody(providerId, statusCode);
    }

    /// <summary>True when the decision needs the bounded error-body prefix.</summary>
    public static bool NeedsBody(string providerId, int statusCode)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(providerId);
        return (statusCode == 429 && string.Equals(providerId, "mm_openai_api", StringComparison.Ordinal))
            || (statusCode == 403 && string.Equals(providerId, "mm_modelstudio", StringComparison.Ordinal));
    }

    /// <summary>
    /// Returns the quota/credit exhaustion error when the evidence is explicit,
    /// otherwise null (the adapter's existing status mapping stays authoritative).
    /// </summary>
    public static RouterError? Classify(string providerId, int statusCode, ReadOnlySpan<byte> bodyPrefix)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(providerId);

        // HTTP 402 is an explicit billing boundary for the Router providers that
        // use it (MiMo, DeepSeek insufficient balance, OpenRouter insufficient
        // credits). It is never an ordinary transient rate limit, and the body is
        // not needed for the decision.
        if (statusCode == 402)
        {
            return QuotaErrors.CreditExhausted();
        }

        if (!NeedsBody(providerId, statusCode))
        {
            return null;
        }

        (string? code, string? type) = ReadMachineIdentifiers(bodyPrefix);

        if (statusCode == 429)
        {
            if (string.Equals(code, "credit_balance_exhausted", StringComparison.Ordinal))
            {
                return QuotaErrors.CreditExhausted();
            }

            if (OpenAIQuotaCodes.Contains(code ?? string.Empty)
                || string.Equals(type, "insufficient_quota", StringComparison.Ordinal))
            {
                return QuotaErrors.QuotaExhausted();
            }
        }

        if (statusCode == 403
            && string.Equals(code, "AllocationQuota.FreeTierOnly", StringComparison.Ordinal))
        {
            return QuotaErrors.QuotaExhausted();
        }

        // MiMo 429 is documented as ambiguous between request-frequency
        // throttling and Token Plan exhaustion, so it deliberately stays with the
        // status mapping unless a future provider-specific stable code exists.
        return null;
    }

    private static (string? Code, string? Type) ReadMachineIdentifiers(ReadOnlySpan<byte> body)
    {
        if (body.IsEmpty)
        {
            return (null, null);
        }

        try
        {
            var reader = new Utf8JsonReader(body);
            using JsonDocument document = JsonDocument.ParseValue(ref reader);
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return (null, null);
            }

            JsonElement source = root;
            if (root.TryGetProperty("error", out JsonElement error)
                && error.ValueKind == JsonValueKind.Object)
            {
                source = error;
            }

            return (ReadString(source, "code"), ReadString(source, "type"));
        }
        catch (JsonException)
        {
            return (null, null);
        }
    }

    private static string? ReadString(JsonElement source, string propertyName)
        => source.TryGetProperty(propertyName, out JsonElement value)
            && value.ValueKind == JsonValueKind.String
                ? value.GetString()
                : null;
}
