namespace Router.ProviderAdapters.Abstractions;

/// <summary>
/// First-output checkpoint state machine. The system can determine "can we
/// still safely retry?" from this state alone: retry is allowed only before
/// the first output byte/event has been emitted to the client.
/// </summary>
public enum RetryCheckpointState
{
    NotStarted,
    RequestSent,
    WaitingFirstByte,
    FirstByteReceived,
    FirstOutputEmitted,
    Terminal,
}

/// <summary>Immutable checkpoint view carried by an attempt.</summary>
public sealed record RetryCheckpoint
{
    public required RetryCheckpointState State { get; init; }

    public bool OutputObserved => State is RetryCheckpointState.FirstOutputEmitted or RetryCheckpointState.Terminal;

    public static RetryCheckpoint NotStarted { get; } = new() { State = RetryCheckpointState.NotStarted };

    public static RetryCheckpoint Advance(RetryCheckpointState next)
        => new() { State = next };
}

/// <summary>
/// LR-5 mechanical retry guard. It only answers whether a same-route retry is
/// still safe before output; LR-11 owns whether to retry, how many times, and
/// failover/breaker decisions.
/// </summary>
public static class PreOutputRetryGuard
{
    public static bool CanRetry(RetryCheckpoint checkpoint)
        => checkpoint is not null && !checkpoint.OutputObserved;

    public static bool CanRetry(RetryCheckpointState state)
        => state is not (RetryCheckpointState.FirstOutputEmitted or RetryCheckpointState.Terminal);
}
