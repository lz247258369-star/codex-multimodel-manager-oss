using Router.Core.Errors;
using Router.Core.Ids;

namespace Router.ProviderAdapters.Abstractions;

/// <summary>Terminal outcome of one upstream attempt.</summary>
public enum AttemptOutcome
{
    Succeeded,
    Failed,
    Cancelled,
}

/// <summary>Reason for cancellation, when the attempt ended cancelled.</summary>
public enum CancellationReason
{
    None,
    ClientDisconnect,
    RequestDeadline,
    TimeoutTotal,
    RouterShutdown,
    Internal,
}

/// <summary>
/// Immutable, safe attempt record. Contains correlation IDs, route/adapter
/// identity, outcome, normalized error, retry checkpoint, cancellation reason,
/// and safe timing/usage metadata only. Prompt content, tool payloads, images,
/// raw bodies, headers, and secrets are never present.
/// </summary>
public sealed record AttemptRecord
{
    public required AttemptId AttemptId { get; init; }

    public required string RequestId { get; init; }

    public required string TraceId { get; init; }

    public required string RouteId { get; init; }

    public required string AdapterId { get; init; }

    public required string AdapterVersion { get; init; }

    public required string ProviderId { get; init; }

    public required string EndpointId { get; init; }

    public required int AttemptNumber { get; init; }

    public required DateTimeOffset StartedAt { get; init; }

    public DateTimeOffset? FirstByteAt { get; init; }

    public required DateTimeOffset CompletedAt { get; init; }

    public required AttemptOutcome Outcome { get; init; }

    public RouterError? NormalizedError { get; init; }

    public required RetryCheckpointState FinalCheckpoint { get; init; }

    public required CancellationReason CancellationReason { get; init; }

    public int? InputTokens { get; init; }

    public int? OutputTokens { get; init; }

    public int? CachedTokens { get; init; }
}
