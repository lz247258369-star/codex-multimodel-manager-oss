namespace Router.CircuitBreaker;

/// <summary>
/// Versioned breaker policy. The breaker is DISABLED by default and only
/// participates in admission when explicitly enabled.
/// </summary>
public sealed record CircuitBreakerPolicy
{
    public const int SchemaVersion = 1;

    public required bool Enabled { get; init; }

    public required int FailureThreshold { get; init; }

    public required TimeSpan Cooldown { get; init; }

    public required int HalfOpenMaxTrials { get; init; }

    public static CircuitBreakerPolicy Disabled { get; } = Create(
        enabled: false,
        failureThreshold: 5,
        cooldown: TimeSpan.FromSeconds(30),
        halfOpenMaxTrials: 1);

    public static CircuitBreakerPolicy Create(bool enabled, int failureThreshold, TimeSpan cooldown, int halfOpenMaxTrials)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(failureThreshold, 1, nameof(failureThreshold));
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(cooldown, TimeSpan.Zero, nameof(cooldown));
        ArgumentOutOfRangeException.ThrowIfLessThan(halfOpenMaxTrials, 1, nameof(halfOpenMaxTrials));
        return new CircuitBreakerPolicy
        {
            Enabled = enabled,
            FailureThreshold = failureThreshold,
            Cooldown = cooldown,
            HalfOpenMaxTrials = halfOpenMaxTrials,
        };
    }
}
