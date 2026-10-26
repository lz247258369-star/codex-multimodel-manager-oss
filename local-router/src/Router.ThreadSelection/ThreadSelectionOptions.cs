namespace Router.ThreadSelection;

/// <summary>
/// Bounded options for the thread-selection domain. Defaults follow the
/// approved HS-1B design; every value is clamped to a hard ceiling so a
/// hostile config can never grow unbounded state.
/// </summary>
public sealed record ThreadSelectionOptions
{
    /// <summary>Default maximum number of observed threads.</summary>
    public const int DefaultMaxObservedThreads = 128;

    /// <summary>Hard ceiling for observed threads.</summary>
    public const int MaxObservedThreadsCeiling = 256;

    /// <summary>Default observed-entry idle TTL (24 hours).</summary>
    public static readonly TimeSpan DefaultEntryIdleTtl = TimeSpan.FromHours(24);

    /// <summary>Hard ceiling for the observed-entry idle TTL (7 days).</summary>
    public static readonly TimeSpan MaxEntryIdleTtl = TimeSpan.FromDays(7);

    /// <summary>Default pending selection TTL (5 minutes).</summary>
    public static readonly TimeSpan DefaultPendingTtl = TimeSpan.FromMinutes(5);

    /// <summary>Floor for the pending selection TTL (30 seconds).</summary>
    public static readonly TimeSpan MinPendingTtl = TimeSpan.FromSeconds(30);

    /// <summary>Ceiling for the pending selection TTL (30 minutes).</summary>
    public static readonly TimeSpan MaxPendingTtl = TimeSpan.FromMinutes(30);

    /// <summary>Default active selection idle TTL (24 hours).</summary>
    public static readonly TimeSpan DefaultActiveIdleTtl = TimeSpan.FromHours(24);

    /// <summary>Floor for the active selection idle TTL (1 hour).</summary>
    public static readonly TimeSpan MinActiveIdleTtl = TimeSpan.FromHours(1);

    /// <summary>Ceiling for the active selection idle TTL (7 days).</summary>
    public static readonly TimeSpan MaxActiveIdleTtl = TimeSpan.FromDays(7);

    /// <summary>Default capture window (2 minutes).</summary>
    public static readonly TimeSpan DefaultCaptureTtl = TimeSpan.FromMinutes(2);

    /// <summary>Floor for the capture window (30 seconds).</summary>
    public static readonly TimeSpan MinCaptureTtl = TimeSpan.FromSeconds(30);

    /// <summary>Ceiling for the capture window (10 minutes).</summary>
    public static readonly TimeSpan MaxCaptureTtl = TimeSpan.FromMinutes(10);

    /// <summary>How long a captured identity stays readable by the control plane.</summary>
    public static readonly TimeSpan CapturedRetentionTtl = TimeSpan.FromMinutes(5);

    /// <summary>Maximum number of observed threads retained.</summary>
    public int MaxObservedThreads { get; init; } = DefaultMaxObservedThreads;

    /// <summary>
    /// Hard ceiling for retained capture entries (at most one OPEN window plus
    /// CAPTURED results). It is deliberately derived from the observed-thread
    /// registry cap instead of adding a new user-facing setting: under pressure
    /// the oldest CAPTURED result is evicted, the OPEN window never is.
    /// </summary>
    public int MaxRetainedCaptures => Math.Clamp(MaxObservedThreads, 1, MaxObservedThreadsCeiling);

    /// <summary>Idle TTL for observed thread metadata.</summary>
    public TimeSpan EntryIdleTtl { get; init; } = DefaultEntryIdleTtl;

    /// <summary>TTL for a pending (not yet activated) selection.</summary>
    public TimeSpan PendingTtl { get; init; } = DefaultPendingTtl;

    /// <summary>Idle TTL for an active selection.</summary>
    public TimeSpan ActiveIdleTtl { get; init; } = DefaultActiveIdleTtl;

    /// <summary>Capture window length.</summary>
    public TimeSpan CaptureTtl { get; init; } = DefaultCaptureTtl;

    /// <summary>Creates an options instance with every value clamped to its bounds.</summary>
    public static ThreadSelectionOptions Create(
        int maxObservedThreads,
        TimeSpan entryIdleTtl,
        TimeSpan pendingTtl,
        TimeSpan activeIdleTtl)
        => new()
        {
            MaxObservedThreads = Math.Clamp(maxObservedThreads, 1, MaxObservedThreadsCeiling),
            EntryIdleTtl = Clamp(entryIdleTtl, TimeSpan.FromMinutes(1), MaxEntryIdleTtl),
            PendingTtl = Clamp(pendingTtl, MinPendingTtl, MaxPendingTtl),
            ActiveIdleTtl = Clamp(activeIdleTtl, MinActiveIdleTtl, MaxActiveIdleTtl),
        };

    private static TimeSpan Clamp(TimeSpan value, TimeSpan min, TimeSpan max)
        => value < min ? min : value > max ? max : value;
}
