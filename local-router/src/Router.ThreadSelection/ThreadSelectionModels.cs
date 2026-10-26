namespace Router.ThreadSelection;

/// <summary>Thread model selection state machine.</summary>
public enum ThreadSelectionState
{
    /// <summary>No selection exists for this thread.</summary>
    None,

    /// <summary>The user selected a model; no eligible turn has used it yet.</summary>
    Pending,

    /// <summary>The selection is sticky for every future eligible turn.</summary>
    Active,

    /// <summary>The selection was replaced by a newer selection.</summary>
    Superseded,

    /// <summary>The user restored the Codex requested model.</summary>
    Cleared,

    /// <summary>A pending or active selection reached its TTL.</summary>
    Expired,
}

/// <summary>Capture lifecycle states (identity discovery only).</summary>
public enum ThreadCaptureStatus
{
    /// <summary>Waiting for the first eligible turn.</summary>
    Open,

    /// <summary>An eligible turn was bound to a thread reference.</summary>
    Captured,

    /// <summary>The window elapsed before a claim.</summary>
    Expired,

    /// <summary>The owner cancelled the window.</summary>
    Cancelled,
}

/// <summary>Outcome of opening a capture window.</summary>
public enum ThreadCaptureOpenStatus
{
    /// <summary>A new OPEN window was created.</summary>
    Opened,

    /// <summary>The thread-selection capability is disabled.</summary>
    Disabled,

    /// <summary>An OPEN window already exists for this Router process.</summary>
    Busy,
}

/// <summary>
/// Typed result of opening a capture window. <see cref="ThreadCaptureOpenStatus.Busy"/>
/// deliberately carries no capture projection: the caller must never learn
/// whether an existing window belongs to it or to another owner.
/// </summary>
public sealed record ThreadCaptureOpenResult
{
    /// <summary>Operation outcome.</summary>
    public required ThreadCaptureOpenStatus Status { get; init; }

    /// <summary>Newly opened window, only when <see cref="ThreadCaptureOpenStatus.Opened"/>.</summary>
    public ThreadCaptureSnapshot? Capture { get; init; }

    /// <summary>Creates the opened result.</summary>
    public static ThreadCaptureOpenResult Opened(ThreadCaptureSnapshot capture)
    {
        ArgumentNullException.ThrowIfNull(capture);
        return new ThreadCaptureOpenResult { Status = ThreadCaptureOpenStatus.Opened, Capture = capture };
    }

    /// <summary>Creates the disabled result.</summary>
    public static ThreadCaptureOpenResult Disabled()
        => new() { Status = ThreadCaptureOpenStatus.Disabled };

    /// <summary>Creates the busy result.</summary>
    public static ThreadCaptureOpenResult Busy()
        => new() { Status = ThreadCaptureOpenStatus.Busy };
}

/// <summary>Safe, content-free read projection for one observed thread.</summary>
public sealed record ThreadSelectionSnapshot
{
    /// <summary>External thread reference (never the raw identity).</summary>
    public required string ThreadRef { get; init; }

    /// <summary>Authenticated client that most recently used this thread.</summary>
    public required string ClientId { get; init; }

    /// <summary>First observation instant.</summary>
    public required DateTimeOffset FirstSeen { get; init; }

    /// <summary>Most recent observation instant.</summary>
    public required DateTimeOffset LastSeen { get; init; }

    /// <summary>Most recent wire request kind, when present.</summary>
    public string? LastRequestKind { get; init; }

    /// <summary>Model the Codex client most recently requested.</summary>
    public string? LastRequestedModel { get; init; }

    /// <summary>Model the Router most recently resolved for this thread.</summary>
    public string? LastSelectedModel { get; init; }

    /// <summary>Advisory Codex window number, when the metadata carried it.</summary>
    public int? WindowNumber { get; init; }

    /// <summary>Current selection state.</summary>
    public required ThreadSelectionState SelectionState { get; init; }

    /// <summary>Selected Router model, when a selection exists.</summary>
    public string? SelectionModel { get; init; }

    /// <summary>Per-thread selection generation.</summary>
    public required ulong SelectionGeneration { get; init; }

    /// <summary>Instant the current selection was issued.</summary>
    public DateTimeOffset? SelectionIssuedAt { get; init; }

    /// <summary>Instant the current pending/active selection expires.</summary>
    public DateTimeOffset? SelectionExpiresAt { get; init; }

    /// <summary>Instant the selection last became active.</summary>
    public DateTimeOffset? LastActivatedAt { get; init; }

    /// <summary>Most recent fail-closed capability error code, when any.</summary>
    public string? LastFailureCode { get; init; }

    /// <summary>Instant of the most recent fail-closed capability error.</summary>
    public DateTimeOffset? LastFailureAt { get; init; }

    /// <summary>Reason the thread's selection was last cleared, when known.</summary>
    public string? LastClearedReason { get; init; }
}

/// <summary>Safe capture projection; never contains a model selection.</summary>
public sealed record ThreadCaptureSnapshot
{
    /// <summary>Opaque capture token.</summary>
    public required string Token { get; init; }

    /// <summary>Authenticated control-plane client that opened the window.</summary>
    public required string OwnerClientId { get; init; }

    /// <summary>Current capture status.</summary>
    public required ThreadCaptureStatus Status { get; init; }

    /// <summary>Window creation instant.</summary>
    public required DateTimeOffset CreatedAt { get; init; }

    /// <summary>Windows expiry instant.</summary>
    public required DateTimeOffset ExpiresAt { get; init; }

    /// <summary>Instant the first eligible turn was bound.</summary>
    public DateTimeOffset? CapturedAt { get; init; }

    /// <summary>Discovered thread reference, when captured.</summary>
    public string? ThreadRef { get; init; }
}

/// <summary>Safe aggregate status projection for the thread-selection capability.</summary>
public sealed record ThreadSelectionStatusSnapshot
{
    /// <summary>Runtime enabled state.</summary>
    public required bool Enabled { get; init; }

    /// <summary>Number of observed threads currently retained.</summary>
    public required int ObservedThreadCount { get; init; }

    /// <summary>Number of threads with an active selection.</summary>
    public required int ActiveSelectionCount { get; init; }

    /// <summary>Number of threads with a pending selection.</summary>
    public required int PendingSelectionCount { get; init; }

    /// <summary>True when a capture window is open.</summary>
    public required bool CaptureOpen { get; init; }

    /// <summary>Number of entries dropped by expiry/eviction since start.</summary>
    public required long EvictedCount { get; init; }

    /// <summary>Projection instant.</summary>
    public required DateTimeOffset SnapshotAt { get; init; }
}

/// <summary>Outcome of a thread-selection control-plane operation.</summary>
public enum ThreadSelectionOperationStatus
{
    /// <summary>The operation was applied.</summary>
    Applied,

    /// <summary>The expected generation was stale.</summary>
    Conflict,

    /// <summary>The thread reference is unknown or evicted.</summary>
    NotFound,

    /// <summary>The capability is disabled.</summary>
    Disabled,
}

/// <summary>Typed result of a thread-selection control-plane operation.</summary>
public sealed record ThreadSelectionOperationResult
{
    /// <summary>Operation outcome.</summary>
    public required ThreadSelectionOperationStatus Status { get; init; }

    /// <summary>Current generation after the operation, when known.</summary>
    public ulong? Generation { get; init; }

    /// <summary>Thread projection after the operation, when applicable.</summary>
    public ThreadSelectionSnapshot? Snapshot { get; init; }

    /// <summary>Number of selections cleared by a clear-all operation.</summary>
    public int ClearedCount { get; init; }

    /// <summary>Number of captures cancelled by a clear-all operation.</summary>
    public int CancelledCaptureCount { get; init; }
}
