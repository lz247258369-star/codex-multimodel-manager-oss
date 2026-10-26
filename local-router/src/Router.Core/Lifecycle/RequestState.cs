namespace Router.Core.Lifecycle;

/// <summary>
/// Request execution states (contract names: RECEIVED, ROUTED, UPSTREAM_PENDING,
/// STREAMING, COMPLETED, FAILED, CANCELLED).
/// </summary>
public enum RequestState
{
    Received = 0,
    Routed = 1,
    UpstreamPending = 2,
    Streaming = 3,
    Completed = 4,
    Failed = 5,
    Cancelled = 6,
}

/// <summary>Mapping between <see cref="RequestState"/> and contract wire names.</summary>
public static class RequestStateExtensions
{
    /// <summary>Returns the uppercase contract name for a request state.</summary>
    public static string ToWireName(this RequestState state) => state switch
    {
        RequestState.Received => "RECEIVED",
        RequestState.Routed => "ROUTED",
        RequestState.UpstreamPending => "UPSTREAM_PENDING",
        RequestState.Streaming => "STREAMING",
        RequestState.Completed => "COMPLETED",
        RequestState.Failed => "FAILED",
        RequestState.Cancelled => "CANCELLED",
        _ => throw new ArgumentOutOfRangeException(nameof(state)),
    };

    /// <summary>Parses a contract wire name into a request state.</summary>
    public static bool TryFromWireName(string? name, out RequestState state)
    {
        switch (name)
        {
            case "RECEIVED":
                state = RequestState.Received;
                return true;
            case "ROUTED":
                state = RequestState.Routed;
                return true;
            case "UPSTREAM_PENDING":
                state = RequestState.UpstreamPending;
                return true;
            case "STREAMING":
                state = RequestState.Streaming;
                return true;
            case "COMPLETED":
                state = RequestState.Completed;
                return true;
            case "FAILED":
                state = RequestState.Failed;
                return true;
            case "CANCELLED":
                state = RequestState.Cancelled;
                return true;
            default:
                state = default;
                return false;
        }
    }
}
