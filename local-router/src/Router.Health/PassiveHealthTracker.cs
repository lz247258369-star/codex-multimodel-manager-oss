using Router.Registries;

namespace Router.Health;

/// <summary>
/// Thread-safe passive health tracker. It consumes real request outcomes only,
/// never active probes, and exposes immutable snapshots. Deterministic
/// transitions use the supplied observation timestamps; no wall-clock or
/// network behavior is required.
/// </summary>
public sealed class PassiveHealthTracker
{
    private readonly object _sync = new();
    private readonly PassiveHealthPolicy _policy;
    private readonly Dictionary<HealthKey, RouteHealthEntry> _routes = new();
    private readonly Dictionary<string, RouteHealthEntry> _routesByRoute = new();

    public PassiveHealthTracker(PassiveHealthPolicy? policy = null)
    {
        _policy = policy ?? PassiveHealthPolicy.Default;
    }

    public void Record(PassiveOutcomeObservation observation)
    {
        ArgumentNullException.ThrowIfNull(observation);
        lock (_sync)
        {
            if (!_routes.TryGetValue(observation.Key, out RouteHealthEntry? entry))
            {
                entry = new RouteHealthEntry();
                _routes.Add(observation.Key, entry);
            }

            Apply(entry, observation);

            // Route-level bridge entry: the same observation is applied with
            // the same policy rules under the route id so the resolver can
            // consume a current route-level snapshot without a second health
            // algorithm. A route id is always present on recorded outcomes.
            if (!_routesByRoute.TryGetValue(observation.Route.RouteId, out RouteHealthEntry? routeEntry))
            {
                routeEntry = new RouteHealthEntry();
                _routesByRoute.Add(observation.Route.RouteId, routeEntry);
            }

            Apply(routeEntry, observation);
        }
    }

    public HealthSnapshot Snapshot(DateTimeOffset generatedAt)
    {
        lock (_sync)
        {
            var entries = new List<RouteHealthSnapshotEntry>();
            foreach (KeyValuePair<HealthKey, RouteHealthEntry> pair in _routes)
            {
                RouteHealthEntry entry = pair.Value;
                RouteHealthState state = entry.State;
                string reason = entry.ReasonCode;

                if (entry.LastObservedAt is { } lastObserved
                    && generatedAt - lastObserved > _policy.Staleness)
                {
                    state = RouteHealthState.Unknown;
                    reason = HealthReasonCode.Stale;
                }

                entries.Add(new RouteHealthSnapshotEntry
                {
                    Key = pair.Key,
                    State = state,
                    ReasonCode = reason,
                    FailureCount = entry.Failures,
                    SuccessCount = entry.Successes,
                    LastObservedAt = entry.LastObservedAt,
                    LastChangedAt = entry.LastChangedAt,
                });
            }

            return new HealthSnapshot
            {
                Version = HealthSnapshot.SchemaVersion,
                GeneratedAt = generatedAt,
                Routes = entries.OrderBy(static e => e.Key.ProviderRouteId, StringComparer.Ordinal)
                    .ThenBy(static e => e.Key.EndpointId, StringComparer.Ordinal)
                    .ThenBy(static e => e.Key.ModelRouteId, StringComparer.Ordinal)
                    .ToArray(),
            };
        }
    }

    /// <summary>
    /// Immutable route-level projection of the same tracked outcomes. Only
    /// routes that have produced at least one outcome appear; routes without
    /// outcomes keep their configured health state at the resolver.
    /// </summary>
    public RouteHealthProjection ProjectRoutes(DateTimeOffset generatedAt)
    {
        lock (_sync)
        {
            var entries = new List<RouteHealthProjectionEntry>();
            foreach (KeyValuePair<string, RouteHealthEntry> pair in _routesByRoute)
            {
                RouteHealthEntry entry = pair.Value;
                RouteHealthState state = entry.State;
                string reason = entry.ReasonCode;

                if (entry.LastObservedAt is { } lastObserved
                    && generatedAt - lastObserved > _policy.Staleness)
                {
                    state = RouteHealthState.Unknown;
                    reason = HealthReasonCode.Stale;
                }

                entries.Add(new RouteHealthProjectionEntry
                {
                    RouteId = pair.Key,
                    State = state,
                    ReasonCode = reason,
                    FailureCount = entry.Failures,
                    SuccessCount = entry.Successes,
                    LastObservedAt = entry.LastObservedAt,
                    LastChangedAt = entry.LastChangedAt,
                });
            }

            return new RouteHealthProjection
            {
                GeneratedAt = generatedAt,
                Routes = entries
                    .OrderBy(static entry => entry.RouteId, StringComparer.Ordinal)
                    .ToArray(),
            };
        }
    }

    private void Apply(RouteHealthEntry entry, PassiveOutcomeObservation observation)
    {
        HealthSignalKind kind = HealthSignalClassifier.Classify(observation.Outcome, observation.ErrorCode);

        if (entry.LastObservedAt is { } previous && observation.ObservedAt < previous)
        {
            return; // out-of-order/stale observation cannot roll history back.
        }

        entry.LastObservedAt = observation.ObservedAt;
        if (kind == HealthSignalKind.ClientCancelled)
        {
            return; // client cancellation is never a provider failure signal.
        }

        if (kind == HealthSignalKind.Positive)
        {
            bool inCooldown = entry.State == RouteHealthState.Unhealthy
                && entry.LastChangedAt is { } lastChanged
                && observation.ObservedAt < lastChanged + _policy.Cooldown;
            if (inCooldown)
            {
                entry.ReasonCode = HealthReasonCode.RecoveryInCooldown;
                return;
            }

            entry.Successes++;
            if (entry.State is RouteHealthState.Healthy)
            {
                return;
            }

            if (entry.State == RouteHealthState.Unhealthy)
            {
                if (entry.Successes >= _policy.SuccessRecoveryThreshold)
                {
                    entry.State = RouteHealthState.Healthy;
                    entry.ReasonCode = HealthReasonCode.Healthy;
                    entry.LastChangedAt = observation.ObservedAt;
                }
                else
                {
                    entry.State = RouteHealthState.Degraded;
                    entry.ReasonCode = HealthReasonCode.DegradedAfterFailure;
                    entry.LastChangedAt = observation.ObservedAt;
                }

                return;
            }

            if (entry.State == RouteHealthState.Degraded)
            {
                if (entry.Successes >= _policy.SuccessRecoveryThreshold)
                {
                    entry.State = RouteHealthState.Healthy;
                    entry.ReasonCode = HealthReasonCode.Healthy;
                    entry.LastChangedAt = observation.ObservedAt;
                }

                return;
            }

            entry.State = RouteHealthState.Healthy;
            entry.ReasonCode = HealthReasonCode.Healthy;
            entry.LastChangedAt = observation.ObservedAt;
            return;
        }

        // Any provider/endpoint failure is a negative signal.
        entry.Failures++;
        entry.Successes = 0;
        if (entry.State == RouteHealthState.Healthy || entry.State == RouteHealthState.Unknown)
        {
            entry.State = RouteHealthState.Degraded;
            entry.ReasonCode = HealthReasonCode.DegradedAfterFailure;
            entry.LastChangedAt = observation.ObservedAt;
        }

        if (entry.Failures >= _policy.FailureThreshold)
        {
            entry.State = RouteHealthState.Unhealthy;
            entry.ReasonCode = HealthReasonCode.UnhealthyThreshold;
            entry.LastChangedAt = observation.ObservedAt;
        }
    }

    private sealed class RouteHealthEntry
    {
        public RouteHealthState State { get; set; } = RouteHealthState.Unknown;

        public string ReasonCode { get; set; } = HealthReasonCode.NotProbed;

        public int Failures { get; set; }

        public int Successes { get; set; }

        public DateTimeOffset? LastObservedAt { get; set; }

        public DateTimeOffset? LastChangedAt { get; set; }
    }
}
