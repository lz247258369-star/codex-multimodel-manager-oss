using Router.Policies;

namespace Router.Execution;

/// <summary>
/// Immutable deterministic policy bodies consumed by the production execution
/// service. Schema-v1 route entries declare policy identifiers only; until a
/// policy-body configuration contract exists, every configured route executes
/// with this single safe policy set. Cross-model fallback stays hard-OFF.
/// </summary>
public sealed record RouterExecutionPolicySet
{
    public RetryPolicy Retry { get; init; } = RetryPolicy.Default;

    public TimeoutPolicy Timeout { get; init; } = TimeoutPolicy.Default;

    public FailoverPolicy Failover { get; init; } = FailoverPolicy.Off;

    public static RouterExecutionPolicySet SafeDefaults { get; } = new();
}
