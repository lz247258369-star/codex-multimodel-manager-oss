namespace Router.Observability;

/// <summary>
/// Safe authenticated-status snapshot. It exposes bounded typed aggregates and
/// never request content, paths, secrets, or raw errors.
/// </summary>
public sealed record RouterStatusObservabilitySnapshot
{
    public const int SchemaVersion = 1;

    public required LogStateSnapshot Logs { get; init; }

    public required int BoundedTraceEventsPerRequest { get; init; }

    public required bool ObservabilityDegraded { get; init; }
}

/// <summary>Bounded log state summary; the directory path is never returned.</summary>
public sealed record LogStateSnapshot
{
    public required int FileCount { get; init; }

    public required long TotalBytes { get; init; }

    public required bool Degraded { get; init; }

    public string? LastErrorCode { get; init; }
}

/// <summary>Safe health record accepted by observability sinks (counts/reasons only).</summary>
public sealed record SafeHealthRecord
{
    public required int HealthyCount { get; init; }

    public required int DegradedCount { get; init; }

    public required int UnhealthyCount { get; init; }

    public required int UnknownCount { get; init; }

    public required string GeneratedAt { get; init; }
}
