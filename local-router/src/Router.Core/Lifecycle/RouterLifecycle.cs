namespace Router.Core.Lifecycle;

/// <summary>
/// Thread-safe router lifecycle state machine. All transitions are compare-and-set
/// and enforce the legal transition table from the lifecycle contract. FAILED is
/// terminal except for the single explicit recovery transition FAILED -> STOPPED.
/// STARTING -> STOPPING is legal because the loopback listener can already be
/// bound while the Host has not yet committed durable READY: an operator or
/// process signal in that window must still be able to stop the process through
/// the normal STOPPING -> STOPPED path. STARTING -> STOPPED stays forbidden, so
/// the STOPPING checkpoint can never be skipped.
/// </summary>
public sealed class RouterLifecycle
{
    private int _state = (int)LifecycleState.Stopped;

    /// <summary>Gets the current lifecycle state.</summary>
    public LifecycleState State => (LifecycleState)Volatile.Read(ref _state);

    /// <summary>True when the machine is in the terminal FAILED state.</summary>
    public bool IsFailed => State == LifecycleState.Failed;

    /// <summary>
    /// Attempts the transition <paramref name="expected"/> -> <paramref name="next"/>.
    /// Returns false when the transition is illegal or when another thread changed
    /// the state first (compare-and-set).
    /// </summary>
    public bool TryTransition(LifecycleState expected, LifecycleState next)
    {
        if (!IsLegal(expected, next))
        {
            return false;
        }

        return Interlocked.CompareExchange(ref _state, (int)next, (int)expected) == (int)expected;
    }

    /// <summary>
    /// Attempts to move from the current state to <paramref name="next"/> when legal.
    /// Returns false on illegal transitions or when a concurrent transition won.
    /// </summary>
    public bool TryTransitionTo(LifecycleState next)
    {
        LifecycleState current = State;
        if (!IsLegal(current, next))
        {
            return false;
        }

        return Interlocked.CompareExchange(ref _state, (int)next, (int)current) == (int)current;
    }

    /// <summary>Evaluates the lifecycle transition table from the contracts document.</summary>
    public static bool IsLegal(LifecycleState from, LifecycleState to) => from switch
    {
        LifecycleState.Stopped => to == LifecycleState.Starting,
        LifecycleState.Starting => to is LifecycleState.Ready or LifecycleState.Degraded or LifecycleState.Stopping or LifecycleState.Failed,
        LifecycleState.Ready => to is LifecycleState.Degraded or LifecycleState.Stopping or LifecycleState.Failed,
        LifecycleState.Degraded => to is LifecycleState.Ready or LifecycleState.Stopping or LifecycleState.Failed,
        LifecycleState.Stopping => to is LifecycleState.Stopped or LifecycleState.Failed,
        LifecycleState.Failed => to == LifecycleState.Stopped,
        _ => false,
    };
}
