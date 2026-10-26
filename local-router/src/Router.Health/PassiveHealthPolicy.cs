namespace Router.Health;

/// <summary>
/// Versioned, configurable passive-health policy. Thresholds have explicit
/// defaults and boundary validation; deterministic behavior never depends on
/// wall-clock randomness.
/// </summary>
public sealed record PassiveHealthPolicy
{
    public const int SchemaVersion = 1;

    public required int FailureThreshold { get; init; }

    public required int SuccessRecoveryThreshold { get; init; }

    public required TimeSpan Cooldown { get; init; }

    public required TimeSpan Staleness { get; init; }

    public static PassiveHealthPolicy Default { get; } = Create(
        failureThreshold: 3,
        successRecoveryThreshold: 2,
        cooldown: TimeSpan.FromSeconds(30),
        staleness: TimeSpan.FromMinutes(5));

    public static PassiveHealthPolicy Create(
        int failureThreshold,
        int successRecoveryThreshold,
        TimeSpan cooldown,
        TimeSpan staleness)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(failureThreshold, 1, nameof(failureThreshold));
        ArgumentOutOfRangeException.ThrowIfLessThan(successRecoveryThreshold, 1, nameof(successRecoveryThreshold));
        ArgumentOutOfRangeException.ThrowIfLessThan(cooldown, TimeSpan.Zero, nameof(cooldown));
        ArgumentOutOfRangeException.ThrowIfLessThan(staleness, TimeSpan.Zero, nameof(staleness));

        return new PassiveHealthPolicy
        {
            FailureThreshold = failureThreshold,
            SuccessRecoveryThreshold = successRecoveryThreshold,
            Cooldown = cooldown,
            Staleness = staleness,
        };
    }
}
