using Router.CircuitBreaker;
using Xunit;

namespace Router.Policies.Tests;

public sealed class CircuitBreakerTests
{
    private static readonly DateTimeOffset T0 = DateTimeOffset.Parse("2026-09-03T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal);
    private static readonly CircuitBreakerKey Key = CircuitBreakerKey.Create("provider-route.a", "endpoint.a", "model-route.a");

    [Fact]
    public void Breaker_defaults_to_disabled_and_admits()
    {
        var breaker = new CircuitBreakerStateMachine();

        BreakerDecision decision = breaker.CanAttempt(Key, T0);

        Assert.True(decision.Admitted);
        Assert.Equal("breaker_disabled", decision.ReasonCode);
    }

    [Fact]
    public void Failures_open_breaker_after_threshold()
    {
        var breaker = new CircuitBreakerStateMachine(CircuitBreakerPolicy.Create(true, 2, TimeSpan.FromSeconds(30), 1));
        breaker.RecordFailure(Key, T0, "provider_5xx");
        breaker.RecordFailure(Key, T0.AddSeconds(1), "connection_failed");

        BreakerDecision decision = breaker.CanAttempt(Key, T0.AddSeconds(2));

        Assert.False(decision.Admitted);
        Assert.Equal("breaker_open", decision.ReasonCode);
    }

    [Fact]
    public void Cooldown_moves_open_to_half_open_trial()
    {
        var breaker = new CircuitBreakerStateMachine(CircuitBreakerPolicy.Create(true, 1, TimeSpan.FromSeconds(30), 1));
        breaker.RecordFailure(Key, T0, "provider_5xx");
        Assert.False(breaker.CanAttempt(Key, T0.AddSeconds(1)).Admitted);

        BreakerDecision trial = breaker.CanAttempt(Key, T0.AddSeconds(31));

        Assert.True(trial.Admitted);
        Assert.Equal(CircuitBreakerState.HalfOpen, trial.State);
    }

    [Fact]
    public void Half_open_success_closes_breaker()
    {
        var breaker = new CircuitBreakerStateMachine(CircuitBreakerPolicy.Create(true, 1, TimeSpan.FromSeconds(30), 1));
        breaker.RecordFailure(Key, T0, "provider_5xx");
        Assert.True(breaker.CanAttempt(Key, T0.AddSeconds(31)).Admitted);
        breaker.RecordSuccess(Key);

        Assert.Equal(CircuitBreakerState.Closed, breaker.Snapshot(Key, T0.AddSeconds(32)).State);
    }

    [Fact]
    public void Half_open_failure_reopens_breaker()
    {
        var breaker = new CircuitBreakerStateMachine(CircuitBreakerPolicy.Create(true, 1, TimeSpan.FromSeconds(30), 1));
        breaker.RecordFailure(Key, T0, "provider_5xx");
        Assert.True(breaker.CanAttempt(Key, T0.AddSeconds(31)).Admitted);

        breaker.RecordFailure(Key, T0.AddSeconds(31), "provider_5xx");

        Assert.Equal(CircuitBreakerState.Open, breaker.Snapshot(Key, T0.AddSeconds(31)).State);
    }

    [Fact]
    public void Cancellation_and_rate_limits_never_trip_breaker()
    {
        var breaker = new CircuitBreakerStateMachine(CircuitBreakerPolicy.Create(true, 1, TimeSpan.FromSeconds(30), 1));
        breaker.RecordFailure(Key, T0, "cancelled");
        breaker.RecordFailure(Key, T0.AddSeconds(1), "rate_limited");

        Assert.True(breaker.CanAttempt(Key, T0.AddSeconds(2)).Admitted);
        Assert.Equal(CircuitBreakerState.Closed, breaker.Snapshot(Key, T0.AddSeconds(2)).State);
    }

    [Fact]
    public void Half_open_concurrency_is_bounded()
    {
        var breaker = new CircuitBreakerStateMachine(CircuitBreakerPolicy.Create(true, 1, TimeSpan.FromSeconds(30), 1));
        breaker.RecordFailure(Key, T0, "provider_5xx");

        BreakerDecision first = breaker.CanAttempt(Key, T0.AddSeconds(31));
        BreakerDecision second = breaker.CanAttempt(Key, T0.AddSeconds(31));

        Assert.True(first.Admitted);
        Assert.False(second.Admitted);
        Assert.Equal("breaker_half_open_full", second.ReasonCode);
    }
}
