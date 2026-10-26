using Router.Core.Lifecycle;

namespace Router.Ingress;

/// <summary>
/// Safe per-request execution result. Contains correlation IDs, the terminal
/// state, status, error code, TTFT, and latency only; never request content,
/// headers, or secrets.
/// </summary>
public sealed record RequestExecutionResult
{
    public required string RequestId { get; init; }

    public required string TraceId { get; init; }

    public required string ClientId { get; init; }

    public required string Scope { get; init; }

    public required RequestState State { get; init; }

    public required int HttpStatus { get; init; }

    public string? ErrorCode { get; init; }

    /// <summary>
    /// DSR7-C-FIX2: the SAFE field path of a rejected capability, when the
    /// failing gate can name one (for example <c>tools[0].type</c>). It exists
    /// only so the in-process production observer can write the local safe
    /// failure diagnostic; it never carries request content and it is NOT part
    /// of the metering record or of the redacted durable request log schema.
    /// </summary>
    public string? ErrorParam { get; init; }

    /// <summary>
    /// DSR7-C-FIX3: the FIXED taxonomy label of a rejected capability value,
    /// when the failing gate can classify it (for example <c>local_shell</c>).
    /// It is internal-only, never serialized into the HTTP envelope, the
    /// metering record, or the redacted durable request log.
    /// </summary>
    public string? ErrorDiagnosticClass { get; init; }

    /// <summary>
    /// DSR7-C-FIX4: the FIXED identity label of a rejected custom tool
    /// (<c>apply_patch</c> or <c>unknown_custom</c>). Internal-only, exactly like
    /// the diagnostic class.
    /// </summary>
    public string? ErrorDiagnosticIdentity { get; init; }

    public string? IdempotencyKeyHash { get; init; }

    public TimeSpan? Ttft { get; init; }

    public long? LatencyMs { get; init; }

    public bool Stream { get; init; }
}

/// <summary>
/// Test/security sink for request execution results. The production default is
/// a no-op; LR-9 observability storage is a later slice.
/// </summary>
public abstract class IngressRequestObserver
{
    public virtual void OnCompleted(RequestExecutionResult result)
    {
        _ = result;
    }

    /// <summary>
    /// Called at most once per logically completed request when canonical usage
    /// is known (usage may still be absent by provider contract). The default
    /// is a no-op so existing observers remain backward compatible.
    /// </summary>
    public virtual Task OnUsageCompletedAsync(
        RequestUsageCompletion completion,
        CancellationToken cancellationToken = default)
    {
        _ = completion;
        _ = cancellationToken;
        return Task.CompletedTask;
    }
}

/// <summary>Context item keys shared between middleware and handlers.</summary>
public static class IngressContextKeys
{
    public const string RequestId = "router.request_id";
    public const string TraceId = "router.trace_id";
}
