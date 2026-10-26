namespace Router.CircuitBreaker;

/// <summary>Typed breaker admission result.</summary>
public sealed record BreakerDecision
{
    public required bool Admitted { get; init; }

    public required CircuitBreakerState State { get; init; }

    public required string ReasonCode { get; init; }
}

/// <summary>Breaker state machine states from the contracts document.</summary>
public enum CircuitBreakerState
{
    Closed,
    Open,
    HalfOpen,
}

/// <summary>Immutable safe breaker snapshot.</summary>
public sealed record BreakerSnapshot
{
    public required CircuitBreakerState State { get; init; }

    public required int FailureCount { get; init; }

    public required int TrialsInFlight { get; init; }

    public DateTimeOffset? OpenedAt { get; init; }

    public required string ReasonCode { get; init; }
}
