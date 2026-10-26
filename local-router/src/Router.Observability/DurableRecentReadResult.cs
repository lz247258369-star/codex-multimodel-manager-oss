namespace Router.Observability;

/// <summary>
/// Bounded outcome of a safe recent durable-log read. Valid safe records are
/// returned together with explicit degradation counters; a bad record never
/// fails the whole read and never surfaces raw exception text.
/// </summary>
public sealed record DurableRecentReadResult
{
    public const int SchemaVersion = 1;

    public required int SchemaVersionValue { get; init; }

    public required IReadOnlyList<RedactedRequestRecord> Records { get; init; }

    public required bool Degraded { get; init; }

    public required int SkippedCorrupt { get; init; }

    public required int SkippedOversized { get; init; }

    public required int SkippedUnreadable { get; init; }

    public required bool ScanLimited { get; init; }

    public required IReadOnlyList<string> Codes { get; init; }

    public static DurableRecentReadResult Unavailable()
        => new()
        {
            SchemaVersionValue = SchemaVersion,
            Records = [],
            Degraded = true,
            SkippedCorrupt = 0,
            SkippedOversized = 0,
            SkippedUnreadable = 0,
            ScanLimited = true,
            Codes = ["recent_log_unavailable"],
        };
}
