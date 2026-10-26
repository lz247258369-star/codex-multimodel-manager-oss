namespace Router.Observability;

/// <summary>Versioned typed trace-event kinds; no user content is ever carried.</summary>
public enum TraceEventKind
{
    RequestAccepted,
    RouteResolved,
    ProtocolSelected,
    ProviderSelected,
    AttemptStarted,
    FirstByte,
    AttemptOutcome,
    ResponseCompleted,
    RequestCancelled,
    RequestFailed,
}

/// <summary>One immutable safe trace event.</summary>
public sealed record SafeTraceEvent
{
    public required int Sequence { get; init; }

    public required TraceEventKind Kind { get; init; }

    public required DateTimeOffset OccurredAt { get; init; }

    public string? AttemptId { get; init; }

    public string? ErrorCode { get; init; }
}

/// <summary>Immutable bounded trace for one request.</summary>
public sealed record TraceRecord
{
    public const int SchemaVersion = 1;

    public required string RequestId { get; init; }

    public required string TraceId { get; init; }

    public required DateTimeOffset StartedAt { get; init; }

    public DateTimeOffset? CompletedAt { get; init; }

    public required IReadOnlyList<SafeTraceEvent> Events { get; init; }

    public required bool Truncated { get; init; }
}

/// <summary>
/// Bounded per-request trace builder. When the event limit is reached the
/// builder stops recording and marks the trace truncated; it never grows
/// without bound.
/// </summary>
public sealed class TraceBuilder
{
    private readonly int _maxEvents;
    private readonly string _requestId;
    private readonly string _traceId;
    private readonly DateTimeOffset _startedAt;
    private readonly object _sync = new();
    private readonly List<SafeTraceEvent> _events = [];
    private bool _truncated;

    public TraceBuilder(string requestId, string traceId, DateTimeOffset startedAt, int maxEvents = 64)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(requestId);
        ArgumentException.ThrowIfNullOrWhiteSpace(traceId);
        ArgumentOutOfRangeException.ThrowIfLessThan(maxEvents, 1, nameof(maxEvents));
        _requestId = requestId;
        _traceId = traceId;
        _startedAt = startedAt;
        _maxEvents = maxEvents;
    }

    public void Add(TraceEventKind kind, DateTimeOffset occurredAt, string? attemptId = null, string? errorCode = null)
    {
        lock (_sync)
        {
            if (_events.Count >= _maxEvents)
            {
                _truncated = true;
                return;
            }

            _events.Add(new SafeTraceEvent
            {
                Sequence = _events.Count + 1,
                Kind = kind,
                OccurredAt = occurredAt,
                AttemptId = attemptId,
                ErrorCode = errorCode,
            });
        }
    }

    public TraceRecord Build(DateTimeOffset? completedAt = null)
    {
        lock (_sync)
        {
            return new TraceRecord
            {
                RequestId = _requestId,
                TraceId = _traceId,
                StartedAt = _startedAt,
                CompletedAt = completedAt,
                Events = _events.ToArray(),
                Truncated = _truncated,
            };
        }
    }
}
