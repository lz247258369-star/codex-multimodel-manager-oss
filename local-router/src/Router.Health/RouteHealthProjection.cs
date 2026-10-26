using Router.Registries;

namespace Router.Health;

/// <summary>
/// Immutable route-level health projection consumed by the route-resolver
/// bridge. States and counts are produced by the exact same passive-health
/// policy and transition rules as <see cref="HealthSnapshot"/> entries; this
/// type only re-keys observations by the configured route id so the resolver
/// can consume current dynamic health. It never redefines healthy, degraded,
/// or unhealthy semantics and never duplicates the transition algorithm.
/// </summary>
public sealed record RouteHealthProjection
{
    public const int SchemaVersion = 1;

    public required DateTimeOffset GeneratedAt { get; init; }

    public required IReadOnlyList<RouteHealthProjectionEntry> Routes { get; init; }
}

/// <summary>One route-level health entry keyed by configured route id.</summary>
public sealed record RouteHealthProjectionEntry
{
    public required string RouteId { get; init; }

    public required RouteHealthState State { get; init; }

    public required string ReasonCode { get; init; }

    public required int FailureCount { get; init; }

    public required int SuccessCount { get; init; }

    public DateTimeOffset? LastObservedAt { get; init; }

    public DateTimeOffset? LastChangedAt { get; init; }
}
