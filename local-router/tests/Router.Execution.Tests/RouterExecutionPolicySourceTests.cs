using Router.Configuration;
using Router.Execution;
using Router.Policies;
using Xunit;

namespace Router.Execution.Tests;

/// <summary>
/// LR-14P policy projection tests: configured vs effective are distinct, absent
/// bodies fall back to safe defaults, and cross-model fallback cannot be
/// expressed through any configurable body.
/// </summary>
public sealed class RouterExecutionPolicySourceTests
{
    [Fact]
    public void Absent_bodies_fall_back_to_safe_defaults()
    {
        PolicyConfig policy = Policy("policy.safe");
        ConfigRouterExecutionPolicySource source = new([policy]);

        RouterExecutionPolicySet resolved = source.Resolve(
            retryPolicyId: policy.PolicyId,
            timeoutPolicyId: policy.PolicyId,
            failoverPolicyId: policy.PolicyId);

        Assert.Equal(RetryPolicy.Default, resolved.Retry);
        Assert.Equal(TimeoutPolicy.Default, resolved.Timeout);
        Assert.Equal(FailoverPolicy.Off, resolved.Failover);
    }

    [Fact]
    public void Configured_retry_body_maps_onto_the_real_retry_policy()
    {
        PolicyConfig policy = Policy("policy.retry") with
        {
            RetryBody = new PolicyRetryBodyConfig
            {
                SchemaVersionValue = PolicyRetryBodyConfig.SchemaVersion,
                MaxAttempts = 4,
                BaseDelayMs = 500,
                MaxDelayMs = 4000,
                Jitter = 0.1m,
                RespectRetryAfter = true,
                MaxRetryAfterMs = 20000,
            },
        };
        ConfigRouterExecutionPolicySource source = new([policy]);

        RouterExecutionPolicySet resolved = source.Resolve(
            retryPolicyId: policy.PolicyId,
            timeoutPolicyId: policy.PolicyId,
            failoverPolicyId: policy.PolicyId);

        Assert.Equal(4, resolved.Retry.MaxAttempts);
        Assert.Equal(TimeSpan.FromMilliseconds(500), resolved.Retry.BaseDelay);
        Assert.Equal(TimeSpan.FromMilliseconds(4000), resolved.Retry.MaxDelay);
        Assert.Equal(0.1m, resolved.Retry.Jitter);
        Assert.True(resolved.Retry.RespectRetryAfter);
        Assert.Equal(TimeSpan.FromSeconds(20), resolved.Retry.MaxRetryAfter);
        Assert.Equal(TimeoutPolicy.Default, resolved.Timeout);
        Assert.Equal(FailoverPolicy.Off, resolved.Failover);
    }

    [Fact]
    public void Configured_timeout_body_maps_onto_the_real_timeout_policy()
    {
        PolicyConfig policy = Policy("policy.timeout") with
        {
            TimeoutBody = new PolicyTimeoutBodyConfig
            {
                SchemaVersionValue = PolicyTimeoutBodyConfig.SchemaVersion,
                ConnectTimeoutMs = 5000,
                FirstByteTimeoutMs = 10000,
                IdleTimeoutMs = 30000,
                AttemptTimeoutMs = 60000,
                TotalTimeoutMs = 120000,
            },
        };
        ConfigRouterExecutionPolicySource source = new([policy]);

        RouterExecutionPolicySet resolved = source.Resolve(
            retryPolicyId: policy.PolicyId,
            timeoutPolicyId: policy.PolicyId,
            failoverPolicyId: policy.PolicyId);

        Assert.Equal(TimeSpan.FromSeconds(5), resolved.Timeout.ConnectTimeout);
        Assert.Equal(TimeSpan.FromSeconds(10), resolved.Timeout.FirstByteTimeout);
        Assert.Equal(TimeSpan.FromSeconds(30), resolved.Timeout.IdleTimeout);
        Assert.Equal(TimeSpan.FromMinutes(1), resolved.Timeout.AttemptTimeout);
        Assert.Equal(TimeSpan.FromMinutes(2), resolved.Timeout.TotalTimeout);
    }

    [Fact]
    public void Failover_body_can_never_express_cross_model_fallback()
    {
        PolicyConfig policy = Policy("policy.failover") with
        {
            FailoverBody = new PolicyFailoverBodyConfig
            {
                SchemaVersionValue = PolicyFailoverBodyConfig.SchemaVersion,
                AllowSameModelAlternateEndpoint = true,
                AllowSameModelAlternateProvider = false,
            },
        };
        ConfigRouterExecutionPolicySource source = new([policy]);

        RouterExecutionPolicySet resolved = source.Resolve(
            retryPolicyId: policy.PolicyId,
            timeoutPolicyId: policy.PolicyId,
            failoverPolicyId: policy.PolicyId);

        Assert.True(resolved.Failover.Enabled);
        Assert.True(resolved.Failover.AllowSameModelAlternateEndpoint);
        Assert.False(resolved.Failover.AllowSameModelAlternateProvider);
        Assert.False(resolved.Failover.AllowCrossModelFallback);
    }

    [Fact]
    public void Unknown_policy_references_use_safe_defaults()
    {
        ConfigRouterExecutionPolicySource source = new([]);
        RouterExecutionPolicySet resolved = source.Resolve("policy.missing", "policy.missing", "policy.missing");
        Assert.Equal(RouterExecutionPolicySet.SafeDefaults.Retry, resolved.Retry);
        Assert.Equal(RouterExecutionPolicySet.SafeDefaults.Timeout, resolved.Timeout);
        Assert.Equal(RouterExecutionPolicySet.SafeDefaults.Failover, resolved.Failover);
    }

    private static PolicyConfig Policy(string policyId)
        => new() { PolicyId = policyId, Version = 1 };
}
