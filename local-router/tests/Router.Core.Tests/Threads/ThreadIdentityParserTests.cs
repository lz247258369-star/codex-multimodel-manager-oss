using Router.Core.Context;
using Xunit;

namespace Router.Core.Tests.Threads;

/// <summary>
/// HS-1B identity truth-table coverage: the two identity-bearing sources must
/// never mask each other, and no fallback identity is ever inferred.
/// </summary>
public sealed class ThreadIdentityParserTests
{
    private const string ThreadA = "01a09dae-3db7-7820-8912-0d86815051a6";
    private const string ThreadB = "01a09dae-3e22-7072-b928-701a84420b82";

    [Fact]
    public void ValidHeaderWithoutMetadata_IsAccepted()
    {
        ThreadIdentityParseResult result = ThreadIdentityParser.Parse(ThreadA, null);

        Assert.Equal(ThreadIdentityOutcome.Accepted, result.Outcome);
        Assert.Equal(ThreadA, result.Identity!.ThreadId.Value);
        Assert.Equal(ThreadRef.From(result.Identity.ThreadId), result.Identity.Ref);
        Assert.False(result.Identity.IsEligibleTurn);
    }

    [Fact]
    public void MissingHeaderWithValidMetadata_IsAccepted()
    {
        ThreadIdentityParseResult result = ThreadIdentityParser.Parse(
            null,
            """{"thread_id":"01a09dae-3db7-7820-8912-0d86815051a6","request_kind":"turn","window_number":2}""");

        Assert.Equal(ThreadIdentityOutcome.Accepted, result.Outcome);
        Assert.Equal(ThreadA, result.Identity!.ThreadId.Value);
        Assert.True(result.Identity.IsEligibleTurn);
        Assert.Equal(2, result.Identity.WindowNumber);
    }

    [Fact]
    public void EqualSources_AreAccepted()
    {
        ThreadIdentityParseResult result = ThreadIdentityParser.Parse(
            ThreadA.ToUpperInvariant(),
            $$"""{"thread_id":"{{ThreadA}}","request_kind":"turn"}""");

        Assert.Equal(ThreadIdentityOutcome.Accepted, result.Outcome);
        Assert.Equal(ThreadA, result.Identity!.ThreadId.Value);
    }

    [Fact]
    public void DifferentSources_FailClosed()
    {
        ThreadIdentityParseResult result = ThreadIdentityParser.Parse(
            ThreadA,
            $$"""{"thread_id":"{{ThreadB}}","request_kind":"turn"}""");

        Assert.Equal(ThreadIdentityOutcome.FailedClosed, result.Outcome);
        Assert.Equal(ThreadIdentityParseResult.MismatchCode, result.FailureCode);
        Assert.Null(result.Identity);
    }

    [Fact]
    public void ValidHeaderWithMalformedMetadata_FailsClosed()
    {
        ThreadIdentityParseResult result = ThreadIdentityParser.Parse(ThreadA, "{not-json");

        Assert.Equal(ThreadIdentityOutcome.FailedClosed, result.Outcome);
    }

    [Fact]
    public void ValidHeaderWithOversizedMetadata_FailsClosed()
    {
        string oversized = "{\"thread_id\":\"" + ThreadA + "\",\"padding\":\"" + new string('x', 5000) + "\"}";

        ThreadIdentityParseResult result = ThreadIdentityParser.Parse(ThreadA, oversized);

        Assert.Equal(ThreadIdentityOutcome.FailedClosed, result.Outcome);
    }

    [Fact]
    public void ValidHeaderWithInvalidMetadataThreadId_FailsClosed()
    {
        ThreadIdentityParseResult result = ThreadIdentityParser.Parse(
            ThreadA,
            """{"thread_id":"!!not-an-id!!"}""");

        Assert.Equal(ThreadIdentityOutcome.FailedClosed, result.Outcome);
    }

    [Fact]
    public void MalformedHeaderWithValidMetadata_FailsClosed()
    {
        ThreadIdentityParseResult result = ThreadIdentityParser.Parse(
            "short",
            $$"""{"thread_id":"{{ThreadB}}"}""");

        Assert.Equal(ThreadIdentityOutcome.FailedClosed, result.Outcome);
    }

    [Fact]
    public void MalformedHeaderWithoutMetadata_HasNoIdentity()
    {
        ThreadIdentityParseResult result = ThreadIdentityParser.Parse("short", null);

        Assert.Equal(ThreadIdentityOutcome.NoIdentity, result.Outcome);
        Assert.Null(result.Identity);
    }

    [Fact]
    public void MissingSources_HaveNoIdentity()
    {
        Assert.Equal(ThreadIdentityOutcome.NoIdentity, ThreadIdentityParser.Parse(null, null).Outcome);
        Assert.Equal(ThreadIdentityOutcome.NoIdentity, ThreadIdentityParser.Parse(string.Empty, "   ").Outcome);
    }

    [Fact]
    public void SessionIdLikeValuesAreNeverUsedAsFallbackIdentity()
    {
        // The parser only accepts the two identity-bearing sources; nothing in
        // the request can be interpreted as a substitute identity.
        ThreadIdentityParseResult result = ThreadIdentityParser.Parse(
            null,
            """{"session_id":"01a09dae-3db7-7820-8912-0d86815051a6","window_id":"x:0"}""");

        Assert.Equal(ThreadIdentityOutcome.NoIdentity, result.Outcome);
    }

    [Fact]
    public void NonTurnRequestKindsAreNeverEligible()
    {
        ThreadIdentityParseResult result = ThreadIdentityParser.Parse(
            ThreadA,
            """{"thread_id":"01a09dae-3db7-7820-8912-0d86815051a6","request_kind":"title"}""");

        Assert.Equal(ThreadIdentityOutcome.Accepted, result.Outcome);
        Assert.False(result.Identity!.IsEligibleTurn);
    }

    [Fact]
    public void CanonicalizationIsCaseInsensitive()
    {
        Assert.True(CanonicalThreadId.TryParse(ThreadA.ToUpperInvariant(), out CanonicalThreadId? upper));
        Assert.True(CanonicalThreadId.TryParse(ThreadA, out CanonicalThreadId? lower));

        Assert.Equal(lower!.Value, upper!.Value);
        Assert.Equal(ThreadRef.From(lower), ThreadRef.From(upper));
    }
}
