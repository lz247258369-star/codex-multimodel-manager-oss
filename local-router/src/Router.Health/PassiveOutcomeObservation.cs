using Router.ProviderAdapters.Abstractions;

namespace Router.Health;

/// <summary>
/// One passive health observation derived from a real request attempt. It
/// contains typed identity and outcome only; never prompt, headers, secrets,
/// or raw bodies.
/// </summary>
public sealed record PassiveOutcomeObservation
{
    public required HealthKey Key { get; init; }

    public required RouteHealthKey Route { get; init; }

    public required AttemptOutcome Outcome { get; init; }

    public string? ErrorCode { get; init; }

    public required DateTimeOffset ObservedAt { get; init; }
}

/// <summary>Typed classification of one passive outcome for health purposes.</summary>
public enum HealthSignalKind
{
    Positive,
    Transient,
    ProviderFailure,
    TimeoutOrConnectionFailure,
    ClientCancelled,
}

/// <summary>Safe reason codes exposed by health/status (never raw exception text).</summary>
public static class HealthReasonCode
{
    public const string NotProbed = "not_probed";
    public const string Healthy = "healthy";
    public const string DegradedAfterFailure = "degraded_after_failure";
    public const string UnhealthyThreshold = "unhealthy_threshold_exceeded";
    public const string RecoveryInCooldown = "recovery_in_cooldown";
    public const string Stale = "stale";

    public static string FromErrorCode(string? errorCode)
        => errorCode switch
        {
            "authentication_invalid" or "authentication_required" or "secret_missing" or "secret_scope_violation" => "provider_auth_failed",
            "rate_limited" => "provider_rate_limited",
            "provider_5xx" => "provider_5xx",
            "timeout_connect" or "timeout_first_byte" or "timeout_idle" or "timeout_total" or "provider_timeout" => "timeout",
            "connection_failed" => "connection_failed",
            "semantic_loss" => "semantic_loss",
            "cancelled" => "cancelled",
            _ => "route_unavailable",
        };
}

/// <summary>
/// Deterministic outcome classifier. Client cancellation is never counted as a
/// provider failure.
/// </summary>
public static class HealthSignalClassifier
{
    public static HealthSignalKind Classify(AttemptOutcome outcome, string? errorCode)
    {
        if (outcome == AttemptOutcome.Cancelled
            || string.Equals(errorCode, "cancelled", StringComparison.Ordinal))
        {
            return HealthSignalKind.ClientCancelled;
        }

        if (outcome == AttemptOutcome.Succeeded)
        {
            return HealthSignalKind.Positive;
        }

        return errorCode switch
        {
            "rate_limited" => HealthSignalKind.Transient,
            "timeout_connect" or "timeout_first_byte" or "timeout_idle" or "timeout_total" or "provider_timeout" => HealthSignalKind.TimeoutOrConnectionFailure,
            "connection_failed" => HealthSignalKind.TimeoutOrConnectionFailure,
            _ => HealthSignalKind.ProviderFailure,
        };
    }
}
