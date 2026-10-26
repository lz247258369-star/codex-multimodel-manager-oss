using Router.ProviderAdapters.Abstractions;

namespace Router.Policies;

/// <summary>
/// Deterministic retry decision engine. Retry is allowed only before output,
/// bounded by attempts and total deadline, and never loops.
/// </summary>
public static class RetryPolicyEngine
{
    private static readonly HashSet<string> RetryableCodes = new(StringComparer.Ordinal)
    {
        "connection_failed",
        "timeout_connect",
        "timeout_first_byte",
        "timeout_idle",
        "timeout_total",
        "provider_5xx",
        "rate_limited",
    };

    public static PolicyDecision Decide(
        RetryPolicy policy,
        int attemptNumber,
        bool outputObserved,
        TimeSpan remainingDeadline,
        string? errorCode,
        int? statusCode = null,
        TimeSpan? retryAfter = null,
        IDeterministicRandom? random = null)
    {
        ArgumentNullException.ThrowIfNull(policy);

        if (outputObserved)
        {
            return NoRetry("post_output_retry_forbidden", attemptNumber);
        }

        if (attemptNumber >= policy.MaxAttempts)
        {
            return NoRetry("max_attempts_reached", attemptNumber);
        }

        if (remainingDeadline <= TimeSpan.Zero)
        {
            return NoRetry("deadline_exhausted", attemptNumber);
        }

        if (string.Equals(errorCode, "cancelled", StringComparison.Ordinal))
        {
            return NoRetry("client_cancelled", attemptNumber);
        }

        if (!IsRetryable(errorCode, statusCode))
        {
            return NoRetry("not_retryable", attemptNumber);
        }

        TimeSpan delay = Backoff(policy, attemptNumber, random ?? new DeterministicRandom("retry-" + attemptNumber));
        if (policy.RespectRetryAfter && retryAfter is { } serverDelay)
        {
            delay = serverDelay > policy.MaxRetryAfter ? policy.MaxRetryAfter : serverDelay;
        }

        if (delay > remainingDeadline)
        {
            return NoRetry("retry_after_exceeds_deadline", attemptNumber);
        }

        return new PolicyDecision
        {
            Kind = PolicyDecisionKind.Retry,
            ReasonCode = "retry_allowed",
            AttemptNumber = attemptNumber + 1,
            Delay = delay,
        };
    }

    public static bool IsRetryable(string? errorCode, int? statusCode)
    {
        if (statusCode is 408 or 429 or >= 500)
        {
            return true;
        }

        if (statusCode is >= 400 and < 500)
        {
            return false;
        }

        return errorCode is not null && RetryableCodes.Contains(errorCode);
    }

    private static PolicyDecision NoRetry(string reason, int attemptNumber)
        => new()
        {
            Kind = PolicyDecisionKind.NoRetry,
            ReasonCode = reason,
            AttemptNumber = attemptNumber,
        };

    private static TimeSpan Backoff(RetryPolicy policy, int attemptNumber, IDeterministicRandom random)
    {
        decimal factor = Math.Min(policy.MaxDelay.Ticks, policy.BaseDelay.Ticks * (decimal)Math.Pow(2, Math.Max(0, attemptNumber - 1)));
        double jitter = (double)policy.Jitter * (random.NextDouble() * 2d - 1d);
        double ticks = (double)factor * (1d + jitter);
        return TimeSpan.FromTicks((long)Math.Clamp(ticks, 0d, (double)policy.MaxDelay.Ticks));
    }
}
