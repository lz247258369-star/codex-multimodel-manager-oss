using System.Text.RegularExpressions;
using Router.Core.Ids;
using Router.Core.Tests.Fakes;
using Xunit;

namespace Router.Core.Tests.Ids;

public sealed class IdTests
{
    private static readonly Regex RequestIdPattern =
        new("^req_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", RegexOptions.CultureInvariant);

    private static readonly Regex TraceIdPattern =
        new("^trc_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", RegexOptions.CultureInvariant);

    private static readonly Regex AttemptIdPattern =
        new("^att_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", RegexOptions.CultureInvariant);

    private readonly UuidV7IdGenerator _generator = new(new FakeClock(1_752_000_000_000));

    [Fact]
    public void Generated_ids_match_the_contract_format()
    {
        Assert.Matches(RequestIdPattern, _generator.NewRequestId().Value);
        Assert.Matches(TraceIdPattern, _generator.NewTraceId().Value);
        Assert.Matches(AttemptIdPattern, _generator.NewAttemptId().Value);
    }

    [Fact]
    public void Generated_ids_round_trip_through_parse()
    {
        RequestId requestId = _generator.NewRequestId();
        TraceId traceId = _generator.NewTraceId();
        AttemptId attemptId = _generator.NewAttemptId();

        Assert.True(RequestId.TryParse(requestId.Value, out RequestId parsedRequest));
        Assert.True(TraceId.TryParse(traceId.Value, out TraceId parsedTrace));
        Assert.True(AttemptId.TryParse(attemptId.Value, out AttemptId parsedAttempt));
        Assert.Equal(requestId, parsedRequest);
        Assert.Equal(traceId, parsedTrace);
        Assert.Equal(attemptId, parsedAttempt);
    }

    [Fact]
    public void Generated_ids_are_unique()
    {
        const int count = 10_000;

        HashSet<RequestId> requests = new();
        HashSet<TraceId> traces = new();
        HashSet<AttemptId> attempts = new();

        for (int i = 0; i < count; i++)
        {
            Assert.True(requests.Add(_generator.NewRequestId()));
            Assert.True(traces.Add(_generator.NewTraceId()));
            Assert.True(attempts.Add(_generator.NewAttemptId()));
        }

        Assert.Equal(count, requests.Count);
        Assert.Equal(count, traces.Count);
        Assert.Equal(count, attempts.Count);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("req_")]
    [InlineData("trc_")]
    [InlineData("att_")]
    [InlineData("req_00000000-0000-0000-0000-000000000000")]
    [InlineData("REQ_00000000-0000-7000-8000-000000000000")]
    [InlineData("req_00000000-0000-7000-8000-00000000000A")]
    [InlineData("req_00000000-0000-6000-8000-000000000000")]
    [InlineData("foo_00000000-0000-7000-8000-000000000000")]
    [InlineData("00000000-0000-7000-8000-000000000000")]
    [InlineData("req_00000000-0000-7000-8000-00000000000g")]
    [InlineData("req_00000000-0000-7000-8000-00000000000")]
    [InlineData("req_00000000-0000-7000-8000-0000000000000")]
    [InlineData("req_ 00000000-0000-7000-8000-000000000000")]
    public void Invalid_request_ids_are_rejected(string? text)
    {
        Assert.False(RequestId.TryParse(text, out _));
    }

    [Fact]
    public void Oversized_ids_are_rejected()
    {
        string oversized = "req_" + new string('a', TypedIdMaxLength);

        Assert.False(RequestId.TryParse(oversized, out _));
        Assert.False(TraceId.TryParse("trc_" + new string('a', TypedIdMaxLength), out _));
        Assert.False(AttemptId.TryParse("att_" + new string('a', TypedIdMaxLength), out _));
    }

    [Fact]
    public void Generated_ids_respect_the_length_limit()
    {
        Assert.True(_generator.NewRequestId().Value.Length <= 128);
        Assert.True(_generator.NewTraceId().Value.Length <= 128);
        Assert.True(_generator.NewAttemptId().Value.Length <= 128);
    }

    [Fact]
    public void Prefixes_are_stable()
    {
        Assert.Equal("req_", RequestId.Prefix);
        Assert.Equal("trc_", TraceId.Prefix);
        Assert.Equal("att_", AttemptId.Prefix);
    }

    private const int TypedIdMaxLength = 128;
}
