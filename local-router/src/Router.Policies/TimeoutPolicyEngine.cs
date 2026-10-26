using Router.ProviderAdapters.Abstractions;

namespace Router.Policies;

/// <summary>
/// Produces typed timeout boundaries for one attempt while never exceeding the
/// remaining total deadline.
/// </summary>
public static class TimeoutPolicyEngine
{
    public static TimeoutBoundaries Boundaries(TimeoutPolicy policy, TimeSpan remainingDeadline)
    {
        ArgumentNullException.ThrowIfNull(policy);
        TimeSpan remaining = remainingDeadline > TimeSpan.Zero ? remainingDeadline : TimeSpan.Zero;
        TimeSpan total = remaining < policy.TotalTimeout ? remaining : policy.TotalTimeout;
        TimeSpan attempt = total < policy.AttemptTimeout ? total : policy.AttemptTimeout;
        TimeSpan firstByte = attempt < policy.FirstByteTimeout ? attempt : policy.FirstByteTimeout;
        TimeSpan connect = firstByte < policy.ConnectTimeout ? firstByte : policy.ConnectTimeout;

        return TimeoutBoundaries.Create(connect, firstByte, policy.IdleTimeout, total);
    }
}
