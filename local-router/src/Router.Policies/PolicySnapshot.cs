namespace Router.Policies;

/// <summary>
/// Immutable per-request policy snapshot. Configuration reloads never change a
/// request's already-selected generation.
/// </summary>
public sealed record PolicySnapshot
{
    public const int SchemaVersion = 1;

    public required string ConfigGeneration { get; init; }

    public required RetryPolicy Retry { get; init; }

    public required TimeoutPolicy Timeout { get; init; }

    public required FailoverPolicy Failover { get; init; }

    public static PolicySnapshot Create(
        string configGeneration,
        RetryPolicy retry,
        TimeoutPolicy timeout,
        FailoverPolicy failover)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(configGeneration);
        ArgumentNullException.ThrowIfNull(retry);
        ArgumentNullException.ThrowIfNull(timeout);
        ArgumentNullException.ThrowIfNull(failover);
        return new PolicySnapshot
        {
            ConfigGeneration = configGeneration,
            Retry = retry,
            Timeout = timeout,
            Failover = failover,
        };
    }
}
