using Router.Policies;
using Router.ProviderAdapters.Abstractions;
using Xunit;

namespace Router.Policies.Tests;

public sealed class RetryPolicyTests
{
    private static readonly RetryPolicy Policy = RetryPolicy.Default;

    [Fact]
    public void Pre_output_provider_5xx_is_retryable_once()
    {
        PolicyDecision decision = RetryPolicyEngine.Decide(
            Policy,
            attemptNumber: 1,
            outputObserved: false,
            remainingDeadline: TimeSpan.FromSeconds(60),
            errorCode: "provider_5xx");

        Assert.Equal(PolicyDecisionKind.Retry, decision.Kind);
        Assert.True(decision.Delay > TimeSpan.Zero);
        Assert.Equal(2, decision.AttemptNumber);
    }

    [Fact]
    public void Post_output_retry_is_forbidden()
    {
        PolicyDecision decision = RetryPolicyEngine.Decide(
            Policy, 1, outputObserved: true, TimeSpan.FromMinutes(5), "provider_5xx");

        Assert.Equal(PolicyDecisionKind.NoRetry, decision.Kind);
        Assert.Equal("post_output_retry_forbidden", decision.ReasonCode);
    }

    [Fact]
    public void Max_attempts_are_bounded()
    {
        PolicyDecision decision = RetryPolicyEngine.Decide(
            Policy, attemptNumber: 2, outputObserved: false, TimeSpan.FromMinutes(5), "provider_5xx");

        Assert.Equal(PolicyDecisionKind.NoRetry, decision.Kind);
        Assert.Equal("max_attempts_reached", decision.ReasonCode);
    }

    [Fact]
    public void Deadline_exhaustion_forbids_retry()
    {
        PolicyDecision decision = RetryPolicyEngine.Decide(
            Policy, 1, false, TimeSpan.Zero, "provider_5xx");

        Assert.Equal(PolicyDecisionKind.NoRetry, decision.Kind);
        Assert.Equal("deadline_exhausted", decision.ReasonCode);
    }

    [Fact]
    public void Authentication_and_invalid_requests_are_not_retried()
    {
        Assert.Equal(PolicyDecisionKind.NoRetry, RetryPolicyEngine.Decide(Policy, 1, false, TimeSpan.FromMinutes(5), "authentication_invalid").Kind);
        Assert.Equal(PolicyDecisionKind.NoRetry, RetryPolicyEngine.Decide(Policy, 1, false, TimeSpan.FromMinutes(5), "invalid_request").Kind);
        Assert.False(RetryPolicyEngine.IsRetryable("provider_4xx", 401));
        Assert.False(RetryPolicyEngine.IsRetryable("provider_4xx", 409));
    }

    [Fact]
    public void Status_codes_408_429_and_5xx_are_retryable()
    {
        Assert.True(RetryPolicyEngine.IsRetryable("provider_4xx", 408));
        Assert.True(RetryPolicyEngine.IsRetryable("rate_limited", 429));
        Assert.True(RetryPolicyEngine.IsRetryable("provider_5xx", 503));
    }

    [Fact]
    public void Retry_after_is_bounded_by_policy_and_deadline()
    {
        PolicyDecision bounded = RetryPolicyEngine.Decide(
            Policy, 1, false, TimeSpan.FromMinutes(5), "rate_limited", 429, retryAfter: TimeSpan.FromHours(1));
        Assert.Equal(PolicyDecisionKind.Retry, bounded.Kind);
        Assert.Equal(TimeSpan.FromSeconds(30), bounded.Delay);

        PolicyDecision tooLate = RetryPolicyEngine.Decide(
            Policy, 1, false, TimeSpan.FromSeconds(10), "rate_limited", 429, retryAfter: TimeSpan.FromSeconds(30));
        Assert.Equal(PolicyDecisionKind.NoRetry, tooLate.Kind);
        Assert.Equal("retry_after_exceeds_deadline", tooLate.ReasonCode);
    }

    [Fact]
    public void Same_seed_produces_same_delay()
    {
        TimeSpan? first = RetryPolicyEngine.Decide(Policy, 1, false, TimeSpan.FromMinutes(5), "provider_5xx", random: new DeterministicRandom("seed-1")).Delay;
        TimeSpan? second = RetryPolicyEngine.Decide(Policy, 1, false, TimeSpan.FromMinutes(5), "provider_5xx", random: new DeterministicRandom("seed-1")).Delay;

        Assert.Equal(first, second);
    }

    [Fact]
    public void Pre_output_retry_guard_still_enforced()
    {
        Assert.True(PreOutputRetryGuard.CanRetry(RetryCheckpoint.NotStarted));
        Assert.False(PreOutputRetryGuard.CanRetry(new RetryCheckpoint { State = RetryCheckpointState.FirstOutputEmitted }));
    }
}
