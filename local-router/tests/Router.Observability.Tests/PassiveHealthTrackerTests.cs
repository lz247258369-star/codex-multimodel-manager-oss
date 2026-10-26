using Router.Core.Lifecycle;
using Router.Health;
using Router.ProviderAdapters.Abstractions;
using Router.Registries;
using Xunit;

namespace Router.Observability.Tests;

public sealed class PassiveHealthTrackerTests
{
    private static readonly DateTimeOffset T0 = DateTimeOffset.Parse("2026-09-03T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal);

    [Fact]
    public void Success_sequence_moves_route_to_healthy()
    {
        var tracker = new PassiveHealthTracker();

        Record(tracker, T0, AttemptOutcome.Succeeded, null);

        HealthSnapshot snapshot = tracker.Snapshot(T0.AddSeconds(1));
        RouteHealthSnapshotEntry entry = Assert.Single(snapshot.Routes);
        Assert.Equal(RouteHealthState.Healthy, entry.State);
    }

    [Fact]
    public void Single_failure_moves_route_to_degraded()
    {
        var tracker = new PassiveHealthTracker();

        Record(tracker, T0, AttemptOutcome.Failed, "provider_5xx");

        HealthSnapshot snapshot = tracker.Snapshot(T0.AddSeconds(1));
        Assert.Equal(RouteHealthState.Degraded, Assert.Single(snapshot.Routes).State);
    }

    [Fact]
    public void Threshold_crossing_moves_route_to_unhealthy()
    {
        var tracker = new PassiveHealthTracker(PassiveHealthPolicy.Create(2, 1, TimeSpan.Zero, TimeSpan.FromMinutes(5)));

        Record(tracker, T0, AttemptOutcome.Failed, "connection_failed");
        Record(tracker, T0.AddSeconds(1), AttemptOutcome.Failed, "connection_failed");

        HealthSnapshot snapshot = tracker.Snapshot(T0.AddSeconds(2));
        Assert.Equal(RouteHealthState.Unhealthy, Assert.Single(snapshot.Routes).State);
    }

    [Fact]
    public void Cooldown_blocks_immediate_recovery()
    {
        var tracker = new PassiveHealthTracker(PassiveHealthPolicy.Create(1, 1, TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(30)));
        Record(tracker, T0, AttemptOutcome.Failed, "provider_5xx");
        Record(tracker, T0.AddSeconds(1), AttemptOutcome.Succeeded, null);

        HealthSnapshot snapshot = tracker.Snapshot(T0.AddSeconds(2));
        Assert.Equal(RouteHealthState.Unhealthy, Assert.Single(snapshot.Routes).State);
        Assert.Equal(HealthReasonCode.RecoveryInCooldown, Assert.Single(snapshot.Routes).ReasonCode);
    }

    [Fact]
    public void Recovery_after_cooldown_moves_route_back_to_healthy()
    {
        var tracker = new PassiveHealthTracker(PassiveHealthPolicy.Create(1, 1, TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(30)));
        Record(tracker, T0, AttemptOutcome.Failed, "provider_5xx");
        Record(tracker, T0.AddMinutes(6), AttemptOutcome.Succeeded, null);

        HealthSnapshot snapshot = tracker.Snapshot(T0.AddMinutes(7));
        Assert.Equal(RouteHealthState.Healthy, Assert.Single(snapshot.Routes).State);
    }

    [Fact]
    public void Stale_observation_expires_to_unknown()
    {
        var tracker = new PassiveHealthTracker(PassiveHealthPolicy.Create(1, 1, TimeSpan.Zero, TimeSpan.FromMinutes(5)));
        Record(tracker, T0, AttemptOutcome.Succeeded, null);

        HealthSnapshot snapshot = tracker.Snapshot(T0.AddMinutes(6));
        RouteHealthSnapshotEntry entry = Assert.Single(snapshot.Routes);
        Assert.Equal(RouteHealthState.Unknown, entry.State);
        Assert.Equal(HealthReasonCode.Stale, entry.ReasonCode);
    }

    [Fact]
    public void Client_cancellation_is_never_counted_as_provider_failure()
    {
        var tracker = new PassiveHealthTracker();
        Record(tracker, T0, AttemptOutcome.Cancelled, "cancelled");

        HealthSnapshot snapshot = tracker.Snapshot(T0.AddSeconds(1));
        RouteHealthSnapshotEntry entry = Assert.Single(snapshot.Routes);
        Assert.Equal(RouteHealthState.Unknown, entry.State);
        Assert.Equal(0, entry.FailureCount);
        Assert.Equal(0, entry.SuccessCount);
    }

    [Fact]
    public void Classifier_maps_all_passive_outcomes_deterministically()
    {
        Assert.Equal(HealthSignalKind.Positive, HealthSignalClassifier.Classify(AttemptOutcome.Succeeded, null));
        Assert.Equal(HealthSignalKind.Transient, HealthSignalClassifier.Classify(AttemptOutcome.Failed, "rate_limited"));
        Assert.Equal(HealthSignalKind.ProviderFailure, HealthSignalClassifier.Classify(AttemptOutcome.Failed, "provider_5xx"));
        Assert.Equal(HealthSignalKind.TimeoutOrConnectionFailure, HealthSignalClassifier.Classify(AttemptOutcome.Failed, "timeout_first_byte"));
        Assert.Equal(HealthSignalKind.TimeoutOrConnectionFailure, HealthSignalClassifier.Classify(AttemptOutcome.Failed, "connection_failed"));
        Assert.Equal(HealthSignalKind.ClientCancelled, HealthSignalClassifier.Classify(AttemptOutcome.Cancelled, "cancelled"));
        Assert.Equal(HealthSignalKind.ClientCancelled, HealthSignalClassifier.Classify(AttemptOutcome.Failed, "cancelled"));
    }

    [Fact]
    public void Health_reason_codes_are_safe_and_typed()
    {
        Assert.Equal("provider_auth_failed", HealthReasonCode.FromErrorCode("authentication_invalid"));
        Assert.Equal("provider_rate_limited", HealthReasonCode.FromErrorCode("rate_limited"));
        Assert.Equal("provider_5xx", HealthReasonCode.FromErrorCode("provider_5xx"));
        Assert.Equal("timeout", HealthReasonCode.FromErrorCode("timeout_total"));
        Assert.Equal("connection_failed", HealthReasonCode.FromErrorCode("connection_failed"));
        Assert.Equal("semantic_loss", HealthReasonCode.FromErrorCode("semantic_loss"));
        Assert.Equal("route_unavailable", HealthReasonCode.FromErrorCode(null));
    }

    [Fact]
    public void Snapshot_and_summary_are_immutable_and_typed()
    {
        var tracker = new PassiveHealthTracker(PassiveHealthPolicy.Create(2, 1, TimeSpan.Zero, TimeSpan.FromMinutes(5)));
        Record(tracker, T0, AttemptOutcome.Failed, "provider_5xx");
        Record(tracker, T0.AddSeconds(1), AttemptOutcome.Succeeded, null);

        HealthSnapshot snapshot = tracker.Snapshot(T0.AddSeconds(2));
        HealthStatusSummary summary = HealthStatusSummary.From(snapshot);

        Assert.Equal(RouteHealthState.Healthy, Assert.Single(snapshot.Routes).State);
        Assert.Equal(1, summary.HealthyCount);
        Assert.Equal(0, summary.UnhealthyCount);
    }

    [Fact]
    public void Route_projection_tracks_route_level_state_without_a_second_policy()
    {
        var tracker = new PassiveHealthTracker(PassiveHealthPolicy.Create(2, 1, TimeSpan.Zero, TimeSpan.FromMinutes(5)));

        Record(tracker, T0, AttemptOutcome.Failed, "provider_5xx");
        Record(tracker, T0.AddSeconds(1), AttemptOutcome.Failed, "provider_5xx");

        RouteHealthProjection projection = tracker.ProjectRoutes(T0.AddSeconds(2));
        RouteHealthProjectionEntry entry = Assert.Single(projection.Routes);
        Assert.Equal("route.test", entry.RouteId);
        Assert.Equal(RouteHealthState.Unhealthy, entry.State);
        Assert.Equal(2, entry.FailureCount);
        Assert.Equal(0, entry.SuccessCount);
        Assert.Equal(HealthReasonCode.UnhealthyThreshold, entry.ReasonCode);
    }

    [Fact]
    public void Route_projection_ignores_client_cancellation_like_health_snapshot()
    {
        var tracker = new PassiveHealthTracker();
        Record(tracker, T0, AttemptOutcome.Cancelled, "cancelled");

        RouteHealthProjection projection = tracker.ProjectRoutes(T0.AddSeconds(1));
        RouteHealthProjectionEntry entry = Assert.Single(projection.Routes);
        Assert.Equal(RouteHealthState.Unknown, entry.State);
        Assert.Equal(0, entry.FailureCount);
        Assert.Equal(0, entry.SuccessCount);
    }

    private static void Record(PassiveHealthTracker tracker, DateTimeOffset at, AttemptOutcome outcome, string? errorCode)
    {
        tracker.Record(new PassiveOutcomeObservation
        {
            Key = HealthKey.Create("provider-route.test", "endpoint.test", "model-route.test"),
            Route = RouteHealthKey.Create("route.test"),
            Outcome = outcome,
            ErrorCode = errorCode,
            ObservedAt = at,
        });
    }
}
