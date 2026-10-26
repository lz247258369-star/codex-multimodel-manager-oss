namespace Router.Ingress;

/// <summary>First-output checkpoint states for the retry boundary.</summary>
public enum OutputCheckpointState
{
    NoOutputEmitted = 0,
    OutputStarted = 1,
}

/// <summary>
/// One-way first-output checkpoint. The transition NO_OUTPUT_EMITTED ->
/// OUTPUT_STARTED is atomic and cannot be reset; later retry/failover slices
/// use it to prove no replay after observable output.
/// </summary>
public sealed class OutputCheckpoint
{
    private int _state;

    public OutputCheckpointState State => (OutputCheckpointState)Volatile.Read(ref _state);

    /// <summary>Atomically marks the first downstream output; false when already started.</summary>
    public bool TryMarkOutputStarted()
        => Interlocked.CompareExchange(ref _state, (int)OutputCheckpointState.OutputStarted, (int)OutputCheckpointState.NoOutputEmitted)
            == (int)OutputCheckpointState.NoOutputEmitted;
}
