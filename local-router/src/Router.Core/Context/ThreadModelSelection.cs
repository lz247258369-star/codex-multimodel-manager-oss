namespace Router.Core.Context;

/// <summary>Per-request input for thread model selection resolution.</summary>
public sealed record ThreadModelSelectionRequest
{
    /// <summary>Router-local identity; <c>null</c> when the request owns no thread state.</summary>
    public ThreadIdentity? Thread { get; init; }

    /// <summary>Authenticated canonical client identity.</summary>
    public required string ClientId { get; init; }

    /// <summary>The model the Codex client asked for (request truth).</summary>
    public required string RequestedModel { get; init; }

    /// <summary>UTC instant the request entered the Router.</summary>
    public required DateTimeOffset ObservedAt { get; init; }
}

/// <summary>
/// Immutable selection decision. <see cref="RequestedModel"/> is always the
/// Codex truth and is never rewritten; <see cref="SelectedModel"/> is what the
/// Router actually resolved.
/// </summary>
public sealed record ThreadModelSelectionDecision
{
    /// <summary>Selection source value used when no thread selection applied.</summary>
    public const string SourceNone = "none";

    /// <summary>Selection source value for the first eligible turn of a pending selection.</summary>
    public const string SourceThreadPending = "thread_pending";

    /// <summary>Selection source value for a thread with an active selection.</summary>
    public const string SourceThreadActive = "thread_active";

    /// <summary>Codex requested model (request truth).</summary>
    public required string RequestedModel { get; init; }

    /// <summary>Model the Router will resolve for this request.</summary>
    public required string SelectedModel { get; init; }

    /// <summary>One of <c>none</c>, <c>thread_pending</c>, <c>thread_active</c>.</summary>
    public required string SelectionSource { get; init; }

    /// <summary>Thread selection generation when a selection applied.</summary>
    public ulong? OverrideGeneration { get; init; }

    /// <summary>
    /// Generation observed for this thread at request start, even when no
    /// override was active. HS-1C uses it as a CAS guard so a later manual
    /// model choice always wins over an automatic quota failover.
    /// </summary>
    public ulong? ThreadGeneration { get; init; }

    /// <summary>External thread reference when a thread selection applied.</summary>
    public string? ThreadRef { get; init; }

    /// <summary>Wire request kind as parsed from metadata, when available.</summary>
    public string? RequestKind { get; init; }

    /// <summary>Creates the no-selection decision (requested model only).</summary>
    public static ThreadModelSelectionDecision None(ThreadModelSelectionRequest request, ThreadIdentity? thread, ulong? threadGeneration = null)
    {
        ArgumentNullException.ThrowIfNull(request);
        return new ThreadModelSelectionDecision
        {
            RequestedModel = request.RequestedModel,
            SelectedModel = request.RequestedModel,
            SelectionSource = SourceNone,
            ThreadGeneration = threadGeneration,
            ThreadRef = thread?.Ref,
            RequestKind = thread?.RequestKind,
        };
    }
}

/// <summary>
/// Thread model selection seam consumed by the production execution boundary.
/// Implementations must never change the incoming requested model inside the
/// decision record and must never consult provider state.
/// </summary>
public interface IThreadModelSelectionSource
{
    /// <summary>Resolves (and records) the selection for one request.</summary>
    ThreadModelSelectionDecision Resolve(ThreadModelSelectionRequest request);
}

/// <summary>
/// Optional companion of <see cref="IThreadModelSelectionSource"/>: a domain
/// that can also record a fail-closed capability error for one thread.
/// Implementations store only a fixed error code plus an instant; the recorded
/// value never carries request content, and recording never changes, clears,
/// or replaces the selection itself.
/// </summary>
public interface IThreadSelectionFailureSink
{
    /// <summary>Records a fail-closed selection error for one thread reference.</summary>
    void RecordSelectionFailure(string? threadRef, string failureCode, DateTimeOffset observedAt);
}


/// <summary>
/// HS-1C companion seam used only after a confirmed quota/credit exhaustion
/// event and a successful explicitly configured fallback route. Implementations
/// must compare the request-start generation before replacing sticky state, so
/// concurrent manual selection always has higher authority.
/// </summary>
public interface IThreadAutomaticSelectionSink
{
    /// <summary>
    /// Attempts to make <paramref name="selectedModel"/> the active sticky model
    /// for the thread. Returns false when the thread changed since request start
    /// or the capability is unavailable.
    /// </summary>
    bool TryApplyAutomaticSelection(
        string? threadRef,
        string expectedCurrentModel,
        ulong? expectedThreadGeneration,
        string selectedModel,
        DateTimeOffset observedAt);
}

/// <summary>
/// Static approved-model check reused by the thread-selection control plane.
/// Implementations must reuse the existing model registry/route eligibility
/// primitives and must never contact a provider.
/// </summary>
public interface IApprovedModelValidator
{
    /// <summary>
    /// True when <paramref name="clientModelId"/> is an approved and eligible
    /// Router model for the given client.
    /// </summary>
    bool IsApprovedForClient(string clientId, string clientModelId);
}
