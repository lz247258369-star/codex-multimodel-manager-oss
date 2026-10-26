using Router.Registries;

namespace Router.Health;

/// <summary>
/// Immutable typed health snapshot. Contains only safe route/endpoint state
/// and reason codes; never requests, secrets, prompts, or paths.
/// </summary>
public sealed record HealthSnapshot
{
    public const int SchemaVersion = 1;

    public required int Version { get; init; }

    public required DateTimeOffset GeneratedAt { get; init; }

    public IReadOnlyList<RouteHealthSnapshotEntry> Routes { get; init; } = [];
}

/// <summary>One immutable route/endpoint/model health entry.</summary>
public sealed record RouteHealthSnapshotEntry
{
    public required HealthKey Key { get; init; }

    public required RouteHealthState State { get; init; }

    public required string ReasonCode { get; init; }

    public required int FailureCount { get; init; }

    public required int SuccessCount { get; init; }

    public DateTimeOffset? LastObservedAt { get; init; }

    public DateTimeOffset? LastChangedAt { get; init; }
}

/// <summary>Immutable safe summary for the authenticated status endpoint.</summary>
public sealed record HealthStatusSummary
{
    public required int HealthyCount { get; init; }

    public required int DegradedCount { get; init; }

    public required int UnhealthyCount { get; init; }

    public required int UnknownCount { get; init; }

    public required IReadOnlyList<RouteHealthSnapshotEntry> Routes { get; init; }

    public static HealthStatusSummary From(HealthSnapshot snapshot)
    {
        int healthy = 0;
        int degraded = 0;
        int unhealthy = 0;
        int unknown = 0;
        foreach (RouteHealthSnapshotEntry entry in snapshot.Routes)
        {
            switch (entry.State)
            {
                case RouteHealthState.Healthy:
                    healthy++;
                    break;
                case RouteHealthState.Degraded:
                    degraded++;
                    break;
                case RouteHealthState.Unhealthy:
                    unhealthy++;
                    break;
                default:
                    unknown++;
                    break;
            }
        }

        return new HealthStatusSummary
        {
            HealthyCount = healthy,
            DegradedCount = degraded,
            UnhealthyCount = unhealthy,
            UnknownCount = unknown,
            Routes = snapshot.Routes,
        };
    }
}
