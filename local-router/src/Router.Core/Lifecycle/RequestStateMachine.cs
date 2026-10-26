namespace Router.Core.Lifecycle;

/// <summary>
/// Thread-safe per-request state machine. Terminal states (COMPLETED, FAILED,
/// CANCELLED) are immutable and reached by compare-and-set so that exactly one
/// terminal outcome wins a race.
/// </summary>
public sealed class RequestStateMachine
{
    private int _state = (int)RequestState.Received;

    /// <summary>Gets the current request state.</summary>
    public RequestState State => (RequestState)Volatile.Read(ref _state);

    /// <summary>True when the request reached a terminal state.</summary>
    public bool IsTerminal => IsTerminalState(State);

    /// <summary>
    /// Attempts the advance <paramref name="expected"/> -> <paramref name="next"/>.
    /// Returns false when the advance is illegal or when a concurrent change won.
    /// </summary>
    public bool TryAdvance(RequestState expected, RequestState next)
    {
        if (!IsLegal(expected, next))
        {
            return false;
        }

        return Interlocked.CompareExchange(ref _state, (int)next, (int)expected) == (int)expected;
    }

    /// <summary>Atomically terminalizes as COMPLETED when no terminal outcome won yet.</summary>
    public bool TryComplete() => TryTerminalize(RequestState.Completed);

    /// <summary>Atomically terminalizes as FAILED when no terminal outcome won yet.</summary>
    public bool TryFail() => TryTerminalize(RequestState.Failed);

    /// <summary>Atomically terminalizes as CANCELLED when no terminal outcome won yet.</summary>
    public bool TryCancel() => TryTerminalize(RequestState.Cancelled);

    /// <summary>Evaluates the request transition graph from the contracts document.</summary>
    public static bool IsLegal(RequestState from, RequestState to) => from switch
    {
        RequestState.Received => to is RequestState.Routed
            or RequestState.Completed or RequestState.Failed or RequestState.Cancelled,
        RequestState.Routed => to is RequestState.UpstreamPending
            or RequestState.Completed or RequestState.Failed or RequestState.Cancelled,
        RequestState.UpstreamPending => to is RequestState.Streaming
            or RequestState.Completed or RequestState.Failed or RequestState.Cancelled,
        RequestState.Streaming => to is RequestState.Completed or RequestState.Failed or RequestState.Cancelled,
        _ => false,
    };

    private static bool IsTerminalState(RequestState state) => state is RequestState.Completed
        or RequestState.Failed or RequestState.Cancelled;

    private bool TryTerminalize(RequestState terminal)
    {
        while (true)
        {
            RequestState current = State;
            if (IsTerminalState(current))
            {
                return false;
            }

            if (Interlocked.CompareExchange(ref _state, (int)terminal, (int)current) == (int)current)
            {
                return true;
            }
        }
    }
}
