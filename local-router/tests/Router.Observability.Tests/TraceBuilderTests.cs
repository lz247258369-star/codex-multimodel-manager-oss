using Router.Observability;
using Xunit;

namespace Router.Observability.Tests;

public sealed class TraceBuilderTests
{
    private static readonly DateTimeOffset T0 = DateTimeOffset.Parse("2026-09-03T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal);

    [Fact]
    public void Trace_is_bounded_and_preserves_order()
    {
        var builder = new TraceBuilder("req_1", "trc_1", T0, maxEvents: 2);

        builder.Add(TraceEventKind.RequestAccepted, T0);
        builder.Add(TraceEventKind.RouteResolved, T0.AddSeconds(1));
        builder.Add(TraceEventKind.ResponseCompleted, T0.AddSeconds(2));

        TraceRecord trace = builder.Build(T0.AddSeconds(3));

        Assert.Equal(2, trace.Events.Count);
        Assert.True(trace.Truncated);
        Assert.Equal(TraceEventKind.RequestAccepted, trace.Events[0].Kind);
        Assert.Equal(TraceEventKind.RouteResolved, trace.Events[1].Kind);
        Assert.Equal(1, trace.Events[0].Sequence);
    }

    [Fact]
    public void Trace_carries_safe_correlation_ids_only()
    {
        var builder = new TraceBuilder("req_2", "trc_2", T0);
        builder.Add(TraceEventKind.AttemptStarted, T0, attemptId: "att_1");
        builder.Add(TraceEventKind.AttemptOutcome, T0.AddSeconds(1), attemptId: "att_1", errorCode: "provider_5xx");

        TraceRecord trace = builder.Build();

        Assert.Equal("req_2", trace.RequestId);
        Assert.Equal("trc_2", trace.TraceId);
        Assert.Equal("att_1", trace.Events[0].AttemptId);
        Assert.Equal("provider_5xx", trace.Events[1].ErrorCode);
    }
}
