namespace Router.Policies;

/// <summary>Typed policy decision kind; never contains request content.</summary>
public enum PolicyDecisionKind
{
    Retry,
    NoRetry,
    Failover,
    NoFailover,
}

/// <summary>
/// Safe typed policy decision with an explainable reason code. It never
/// carries prompts, secrets, headers, or raw responses.
/// </summary>
public sealed record PolicyDecision
{
    public required PolicyDecisionKind Kind { get; init; }

    public required string ReasonCode { get; init; }

    public string? RouteId { get; init; }

    public int? AttemptNumber { get; init; }

    public TimeSpan? Delay { get; init; }
}
