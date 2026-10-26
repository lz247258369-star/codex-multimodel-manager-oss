using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;

namespace Router.UpstreamHttp;

/// <summary>
/// Maps transport-level exceptions and status codes to the typed normalized
/// error contract. Messages never carry secrets, headers, prompts, or payloads.
/// </summary>
public static class TransportFailureMapper
{
    public static RouterError MapException(Exception exception, TimeoutStage stage, bool userCancelled, string? requestId = null)
    {
        if (exception is OperationCanceledException)
        {
            if (userCancelled)
            {
                return RouterError.Cancelled(requestId);
            }

            return stage switch
            {
                TimeoutStage.Connect => ProviderAdapterErrors.TimeoutConnect(requestId),
                TimeoutStage.FirstByte => ProviderAdapterErrors.TimeoutFirstByte(requestId),
                TimeoutStage.Idle => ProviderAdapterErrors.TimeoutIdle(requestId),
                _ => ProviderAdapterErrors.TimeoutTotal(requestId),
            };
        }

        return stage == TimeoutStage.Read
            ? ProviderAdapterErrors.StreamInterrupted(requestId)
            : ProviderAdapterErrors.ConnectionFailed(requestId);
    }

    public static RouterError MapStatus(int statusCode, string? requestId = null)
    {
        if (statusCode == 429)
        {
            return ProviderAdapterErrors.RateLimited(requestId);
        }

        if (statusCode is >= 400 and < 500)
        {
            return ProviderAdapterErrors.Provider4xx(statusCode, requestId);
        }

        if (statusCode >= 500)
        {
            return ProviderAdapterErrors.Provider5xx(statusCode, requestId);
        }

        return ProviderAdapterErrors.InvalidResponse(requestId);
    }
}

/// <summary>Phase of the upstream attempt where a failure occurred.</summary>
public enum TimeoutStage
{
    Connect,
    FirstByte,
    Idle,
    Read,
    Total,
}
