namespace Router.CircuitBreaker;

/// <summary>
/// Deterministic thread-safe circuit breaker. Uses an injected clock callback
/// or explicit timestamps so tests never rely on real time. Client/shutdown
/// cancellation is never recorded as a provider failure, and rate limits do
/// not trip the breaker by default.
/// </summary>
public sealed class CircuitBreakerStateMachine
{
    private readonly object _sync = new();
    private readonly CircuitBreakerPolicy _policy;
    private readonly Dictionary<CircuitBreakerKey, Entry> _entries = new();

    public CircuitBreakerStateMachine(CircuitBreakerPolicy? policy = null)
    {
        _policy = policy ?? CircuitBreakerPolicy.Disabled;
    }

    public BreakerDecision CanAttempt(CircuitBreakerKey key, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(key);
        lock (_sync)
        {
            if (!_policy.Enabled)
            {
                return Admitted(CircuitBreakerState.Closed, "breaker_disabled");
            }

            Entry entry = Get(key);
            if (entry.State == CircuitBreakerState.Closed)
            {
                return Admitted(CircuitBreakerState.Closed, "breaker_closed");
            }

            if (entry.State == CircuitBreakerState.Open)
            {
                if (now < entry.OpenedAt!.Value + _policy.Cooldown)
                {
                    return new BreakerDecision
                    {
                        Admitted = false,
                        State = CircuitBreakerState.Open,
                        ReasonCode = "breaker_open",
                    };
                }

                entry.State = CircuitBreakerState.HalfOpen;
                entry.TrialsInFlight = 0;
            }

            if (entry.TrialsInFlight >= _policy.HalfOpenMaxTrials)
            {
                return new BreakerDecision
                {
                    Admitted = false,
                    State = CircuitBreakerState.HalfOpen,
                    ReasonCode = "breaker_half_open_full",
                };
            }

            entry.TrialsInFlight++;
            return new BreakerDecision
            {
                Admitted = true,
                State = CircuitBreakerState.HalfOpen,
                ReasonCode = "breaker_half_open_trial",
            };
        }
    }

    public void RecordFailure(CircuitBreakerKey key, DateTimeOffset now, string? errorCode = null)
    {
        ArgumentNullException.ThrowIfNull(key);
        lock (_sync)
        {
            if (!_policy.Enabled || string.Equals(errorCode, "cancelled", StringComparison.Ordinal) || string.Equals(errorCode, "rate_limited", StringComparison.Ordinal))
            {
                return;
            }

            Entry entry = Get(key);
            entry.FailureCount++;
            entry.TrialsInFlight = Math.Max(0, entry.TrialsInFlight - 1);
            if (entry.State == CircuitBreakerState.HalfOpen || entry.FailureCount >= _policy.FailureThreshold)
            {
                entry.State = CircuitBreakerState.Open;
                entry.OpenedAt = now;
            }
        }
    }

    public void RecordSuccess(CircuitBreakerKey key)
    {
        ArgumentNullException.ThrowIfNull(key);
        lock (_sync)
        {
            if (!_policy.Enabled)
            {
                return;
            }

            Entry entry = Get(key);
            entry.TrialsInFlight = Math.Max(0, entry.TrialsInFlight - 1);
            entry.FailureCount = 0;
            if (entry.State != CircuitBreakerState.Closed)
            {
                entry.State = CircuitBreakerState.Closed;
                entry.OpenedAt = null;
            }
        }
    }

    public BreakerSnapshot Snapshot(CircuitBreakerKey key, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(key);
        lock (_sync)
        {
            Entry entry = Get(key);
            string reason = entry.State switch
            {
                CircuitBreakerState.Open => "breaker_open",
                CircuitBreakerState.HalfOpen => "breaker_half_open",
                _ => "breaker_closed",
            };

            if (!_policy.Enabled)
            {
                reason = "breaker_disabled";
            }

            return new BreakerSnapshot
            {
                State = entry.State,
                FailureCount = entry.FailureCount,
                TrialsInFlight = entry.TrialsInFlight,
                OpenedAt = entry.OpenedAt,
                ReasonCode = reason,
            };
        }
    }

    private Entry Get(CircuitBreakerKey key)
    {
        if (!_entries.TryGetValue(key, out Entry? entry))
        {
            entry = new Entry();
            _entries.Add(key, entry);
        }

        return entry;
    }

    private static BreakerDecision Admitted(CircuitBreakerState state, string reason)
        => new() { Admitted = true, State = state, ReasonCode = reason };

    private sealed class Entry
    {
        public CircuitBreakerState State { get; set; } = CircuitBreakerState.Closed;

        public int FailureCount { get; set; }

        public int TrialsInFlight { get; set; }

        public DateTimeOffset? OpenedAt { get; set; }
    }
}
