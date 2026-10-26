namespace Router.Core.Lifecycle;

/// <summary>
/// Router process lifecycle states (contract names: STOPPED, STARTING, READY,
/// DEGRADED, STOPPING, FAILED).
/// </summary>
public enum LifecycleState
{
    Stopped = 0,
    Starting = 1,
    Ready = 2,
    Degraded = 3,
    Stopping = 4,
    Failed = 5,
}

/// <summary>Mapping between <see cref="LifecycleState"/> and contract wire names.</summary>
public static class LifecycleStateExtensions
{
    /// <summary>Returns the uppercase contract name for a lifecycle state.</summary>
    public static string ToWireName(this LifecycleState state) => state switch
    {
        LifecycleState.Stopped => "STOPPED",
        LifecycleState.Starting => "STARTING",
        LifecycleState.Ready => "READY",
        LifecycleState.Degraded => "DEGRADED",
        LifecycleState.Stopping => "STOPPING",
        LifecycleState.Failed => "FAILED",
        _ => throw new ArgumentOutOfRangeException(nameof(state)),
    };

    /// <summary>Parses a contract wire name into a lifecycle state.</summary>
    public static bool TryFromWireName(string? name, out LifecycleState state)
    {
        switch (name)
        {
            case "STOPPED":
                state = LifecycleState.Stopped;
                return true;
            case "STARTING":
                state = LifecycleState.Starting;
                return true;
            case "READY":
                state = LifecycleState.Ready;
                return true;
            case "DEGRADED":
                state = LifecycleState.Degraded;
                return true;
            case "STOPPING":
                state = LifecycleState.Stopping;
                return true;
            case "FAILED":
                state = LifecycleState.Failed;
                return true;
            default:
                state = default;
                return false;
        }
    }
}
