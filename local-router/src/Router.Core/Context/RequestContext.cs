using Router.Core.Ids;

namespace Router.Core.Context;

/// <summary>
/// Immutable per-request context. Contains only correlation IDs, client identity,
/// timing, config generation, cancellation, and auth scope. Never contains a raw
/// bearer token, secret, or request content.
/// </summary>
public sealed record RequestContext
{
    /// <summary>Canonical per-request correlation ID.</summary>
    public required RequestId RequestId { get; init; }

    /// <summary>Canonical per-trace correlation ID.</summary>
    public required TraceId TraceId { get; init; }

    /// <summary>Canonical client registry key, for example <c>client.codex_cli</c>.</summary>
    public required string ClientId { get; init; }

    /// <summary>UTC instant the request was received.</summary>
    public required DateTimeOffset ReceivedAt { get; init; }

    /// <summary>Optional absolute deadline; must not precede <see cref="ReceivedAt"/>.</summary>
    public DateTimeOffset? DeadlineAt { get; init; }

    /// <summary>Immutable effective-config generation, when known.</summary>
    public string? ConfigGeneration { get; init; }

    /// <summary>
    /// SHA-256 hash of the optional client Idempotency-Key. The raw key never
    /// enters the context, logs, state, or errors.
    /// </summary>
    public string? IdempotencyKeyHash { get; init; }

    /// <summary>Cancellation token propagated through the whole request.</summary>
    public required CancellationToken CancellationToken { get; init; }

    /// <summary>Authorized local scope, for example <c>responses:invoke</c>.</summary>
    public required string AuthScope { get; init; }

    /// <summary>
    /// Router-local Codex thread identity, when the request presented
    /// consistent identity metadata. <c>null</c> means the request owns no
    /// thread state (absent, malformed, or contradictory identity sources).
    /// </summary>
    public ThreadIdentity? Thread { get; init; }

    /// <summary>Always false in LR-1; content capture is out of scope.</summary>
    public bool ContentLogging { get; init; }

    /// <summary>Creates a validated immutable request context.</summary>
    public static RequestContext Create(
        RequestId requestId,
        TraceId traceId,
        string clientId,
        DateTimeOffset receivedAt,
        string authScope,
        DateTimeOffset? deadlineAt = null,
        string? configGeneration = null,
        string? idempotencyKeyHash = null,
        ThreadIdentity? thread = null,
        bool contentLogging = false,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(clientId))
        {
            throw new ArgumentException("ClientId must not be empty.", nameof(clientId));
        }

        if (string.IsNullOrWhiteSpace(authScope))
        {
            throw new ArgumentException("AuthScope must not be empty.", nameof(authScope));
        }

        if (idempotencyKeyHash is not null
            && (idempotencyKeyHash.Length != 64
                || !idempotencyKeyHash.All(static c => c is >= '0' and <= '9' or >= 'a' and <= 'f')))
        {
            throw new ArgumentException("IdempotencyKeyHash must be a lowercase SHA-256 hex string.", nameof(idempotencyKeyHash));
        }

        if (deadlineAt is { } deadline && deadline < receivedAt)
        {
            throw new ArgumentException("DeadlineAt must not precede ReceivedAt.", nameof(deadlineAt));
        }

        return new RequestContext
        {
            RequestId = requestId,
            TraceId = traceId,
            ClientId = clientId,
            ReceivedAt = receivedAt,
            DeadlineAt = deadlineAt,
            ConfigGeneration = configGeneration,
            IdempotencyKeyHash = idempotencyKeyHash,
            Thread = thread,
            CancellationToken = cancellationToken,
            AuthScope = authScope,
            ContentLogging = contentLogging,
        };
    }
}
