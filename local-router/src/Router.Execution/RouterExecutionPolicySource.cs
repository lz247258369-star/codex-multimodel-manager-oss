using Router.Configuration;
using Router.Policies;
using Router.Routing;

namespace Router.Execution;

/// <summary>
/// Composition seam that resolves the LR-11 policy bodies actually consumed by
/// production execution for one resolved route. Absent policy bodies fall back
/// to the existing safe defaults; cross-model fallback is structurally absent
/// from every configurable body and therefore always HARD OFF.
/// </summary>
public interface IRouterExecutionPolicySource
{
    RouterExecutionPolicySet Resolve(ResolvedRoute route);
}

/// <summary>Source bound to one immutable policy set (legacy behavior).</summary>
public sealed class FixedRouterExecutionPolicySource : IRouterExecutionPolicySource
{
    private readonly RouterExecutionPolicySet _policies;

    public FixedRouterExecutionPolicySource(RouterExecutionPolicySet policies)
    {
        _policies = policies ?? throw new ArgumentNullException(nameof(policies));
    }

    public RouterExecutionPolicySet Resolve(ResolvedRoute route)
    {
        _ = route;
        return _policies;
    }
}

/// <summary>
/// Projection from versioned config policy bodies onto the existing LR-11
/// policy types. Mapping is the only responsibility: the retry, timeout,
/// failover, and breaker algorithms themselves are never modified.
/// </summary>
public sealed class ConfigRouterExecutionPolicySource : IRouterExecutionPolicySource
{
    private readonly Dictionary<string, PolicyConfig> _policiesById;

    public ConfigRouterExecutionPolicySource(IEnumerable<PolicyConfig> policies)
    {
        ArgumentNullException.ThrowIfNull(policies);
        _policiesById = policies.ToDictionary(
            static policy => policy.PolicyId,
            StringComparer.Ordinal);
    }

    public RouterExecutionPolicySet Resolve(ResolvedRoute route)
        => Resolve(route.RetryPolicyId, route.TimeoutPolicyId, route.FailoverPolicyId);

    /// <summary>Resolves by the three route policy references.</summary>
    public RouterExecutionPolicySet Resolve(
        string retryPolicyId,
        string timeoutPolicyId,
        string failoverPolicyId)
        => new()
        {
            Retry = ResolveRetry(retryPolicyId),
            Timeout = ResolveTimeout(timeoutPolicyId),
            Failover = ResolveFailover(failoverPolicyId),
        };

    private RetryPolicy ResolveRetry(string policyId)
    {
        if (_policiesById.TryGetValue(policyId, out PolicyConfig? policy)
            && policy.RetryBody is { } body)
        {
            return RetryPolicy.Create(
                body.MaxAttempts,
                TimeSpan.FromMilliseconds(body.BaseDelayMs),
                TimeSpan.FromMilliseconds(body.MaxDelayMs),
                body.Jitter,
                body.RespectRetryAfter,
                TimeSpan.FromMilliseconds(body.MaxRetryAfterMs));
        }

        return RetryPolicy.Default;
    }

    private TimeoutPolicy ResolveTimeout(string policyId)
    {
        if (_policiesById.TryGetValue(policyId, out PolicyConfig? policy)
            && policy.TimeoutBody is { } body)
        {
            return TimeoutPolicy.Create(
                TimeSpan.FromMilliseconds(body.ConnectTimeoutMs),
                TimeSpan.FromMilliseconds(body.FirstByteTimeoutMs),
                TimeSpan.FromMilliseconds(body.IdleTimeoutMs),
                TimeSpan.FromMilliseconds(body.AttemptTimeoutMs),
                TimeSpan.FromMilliseconds(body.TotalTimeoutMs));
        }

        return TimeoutPolicy.Default;
    }

    private FailoverPolicy ResolveFailover(string policyId)
    {
        if (_policiesById.TryGetValue(policyId, out PolicyConfig? policy)
            && policy.FailoverBody is { } body)
        {
            return FailoverPolicy.Create(
                body.AllowSameModelAlternateEndpoint,
                body.AllowSameModelAlternateProvider,
                allowCrossModelFallback: false);
        }

        return FailoverPolicy.Off;
    }
}

/// <summary>Convenience factory for the config-backed projection.</summary>
public static class RouterExecutionPolicyProjection
{
    public static IRouterExecutionPolicySource FromPolicies(IReadOnlyList<PolicyConfig> policies)
        => new ConfigRouterExecutionPolicySource(policies);
}
