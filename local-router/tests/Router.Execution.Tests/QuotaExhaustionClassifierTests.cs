using System.Text;
using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Xunit;

namespace Router.Execution.Tests;

/// <summary>
/// Draft PR #88 classifier tests, kept case for case. The effective error is
/// the classifier's explicit evidence when present, otherwise the provider
/// adapter's unchanged status mapping (exactly what the execution service does).
/// </summary>
public sealed class QuotaExhaustionClassifierTests
{
    [Theory]
    [InlineData("mm_openai_api", 429, "{\"error\":{\"type\":\"insufficient_quota\",\"code\":null}}", RouterErrorCode.QuotaExhausted)]
    [InlineData("mm_openai_api", 429, "{\"error\":{\"type\":\"rate_limit_error\",\"code\":\"rate_limit_exceeded\"}}", RouterErrorCode.RateLimited)]
    [InlineData("mm_openai_api", 429, "{\"error\":{\"code\":\"organization_spend_limit_exceeded\"}}", RouterErrorCode.QuotaExhausted)]
    [InlineData("mm_openai_api", 402, "{\"error\":{\"code\":\"credit_balance_exhausted\"}}", RouterErrorCode.CreditExhausted)]
    [InlineData("mm_mimo", 402, "{\"error\":{\"message\":\"balance exhausted\"}}", RouterErrorCode.CreditExhausted)]
    [InlineData("mm_mimo", 429, "{\"error\":{\"message\":\"token plan or frequency limit\"}}", RouterErrorCode.RateLimited)]
    [InlineData("mm_modelstudio", 403, "{\"code\":\"AllocationQuota.FreeTierOnly\"}", RouterErrorCode.QuotaExhausted)]
    [InlineData("mm_modelstudio", 429, "{\"code\":\"Throttling.AllocationQuota\"}", RouterErrorCode.RateLimited)]
    [InlineData("deepseek", 402, "{\"error\":{\"message\":\"Insufficient Balance\"}}", RouterErrorCode.CreditExhausted)]
    [InlineData("deepseek", 429, "{\"error\":{\"message\":\"Rate Limit Reached\"}}", RouterErrorCode.RateLimited)]
    [InlineData("mm_openrouter", 402, "{\"error\":{\"code\":402}}", RouterErrorCode.CreditExhausted)]
    [InlineData("mm_openrouter", 429, "{\"error\":{\"code\":429}}", RouterErrorCode.RateLimited)]
    public void Only_explicit_quota_evidence_triggers_quota_classification(
        string providerId,
        int statusCode,
        string json,
        string expectedCode)
    {
        RouterError error = Effective(providerId, statusCode, json);

        Assert.Equal(expectedCode, error.Code);
        Assert.DoesNotContain("balance exhausted", error.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("token plan", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Unknown_or_malformed_429_stays_rate_limited()
    {
        RouterError malformed = Effective("mm_openai_api", 429, "not-json");
        RouterError unknown = Effective(
            "mm_openai_api",
            429,
            "{\"error\":{\"type\":\"future_vendor_shape\",\"code\":\"new_code\"}}");

        Assert.Equal(RouterErrorCode.RateLimited, malformed.Code);
        Assert.Equal(RouterErrorCode.RateLimited, unknown.Code);
    }

    [Fact]
    public void Classifier_never_requires_the_full_provider_body()
    {
        string json = "{\"error\":{\"type\":\"insufficient_quota\"},\"ignored\":\"" + new string('x', 32_000) + "\"}";

        RouterError error = Effective("mm_openai_api", 429, json);

        // The bounded parser intentionally fails closed when the prefix is not
        // complete JSON. A large/raw body can never force quota failover.
        Assert.Equal(RouterErrorCode.RateLimited, error.Code);
    }

    [Theory]
    [InlineData("mm_openai_api", 500)]
    [InlineData("mm_openai_api", 400)]
    [InlineData("mm_mimo", 429)]
    [InlineData("mm_modelstudio", 429)]
    [InlineData("deepseek", 429)]
    [InlineData("mm_openrouter", 403)]
    public void Pairs_that_cannot_carry_quota_evidence_are_never_read(string providerId, int statusCode)
    {
        Assert.False(QuotaExhaustionClassifier.CanEstablishEvidence(providerId, statusCode));
        Assert.Null(QuotaExhaustionClassifier.Classify(
            providerId, statusCode, Encoding.UTF8.GetBytes("{\"error\":{\"type\":\"insufficient_quota\"}}")));
    }

    private static RouterError Effective(string providerId, int statusCode, string body)
    {
        // The transport reads at most MaxErrorBodyBytes of the error body.
        byte[] bytes = Encoding.UTF8.GetBytes(body);
        ReadOnlySpan<byte> prefix = bytes.AsSpan(0, Math.Min(bytes.Length, QuotaExhaustionClassifier.MaxErrorBodyBytes));
        return QuotaExhaustionClassifier.Classify(providerId, statusCode, prefix)
            ?? ProviderStatusMapper.MapStatus(statusCode);
    }
}
