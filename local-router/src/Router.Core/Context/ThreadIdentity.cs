namespace Router.Core.Context;

/// <summary>
/// Router-local control metadata that identifies the Codex thread a request
/// belongs to. It is derived only from explicitly presented identity sources
/// (see <see cref="ThreadIdentityParser"/>) and never from session ids, window
/// ids, or traffic recency.
/// </summary>
public sealed record ThreadIdentity
{
    /// <summary>The only request kind eligible for a thread model selection.</summary>
    public const string TurnRequestKind = "turn";

    /// <summary>Canonical thread identity.</summary>
    public required CanonicalThreadId ThreadId { get; init; }

    /// <summary>Opaque external reference derived from <see cref="ThreadId"/>.</summary>
    public required string Ref { get; init; }

    /// <summary>
    /// Wire <c>request_kind</c> when the metadata header carried it; otherwise
    /// <c>null</c>.
    /// </summary>
    public string? RequestKind { get; init; }

    /// <summary>Wire <c>window_number</c> when the metadata carried a valid value.</summary>
    public int? WindowNumber { get; init; }

    /// <summary>
    /// True only for an exact <c>request_kind == "turn"</c> match. Auxiliary,
    /// missing, and unknown kinds are never eligible.
    /// </summary>
    public bool IsEligibleTurn
        => string.Equals(RequestKind, TurnRequestKind, StringComparison.Ordinal);
}

/// <summary>Outcome of interpreting the two identity-bearing request sources.</summary>
public enum ThreadIdentityOutcome
{
    /// <summary>A consistent identity was accepted.</summary>
    Accepted,

    /// <summary>No identity-bearing source was presented, so no identity exists.</summary>
    NoIdentity,

    /// <summary>
    /// Identity material was presented but is malformed, oversized, or
    /// contradictory. The request is served with the Codex requested model, but
    /// it can neither observe a thread nor consume a selection.
    /// </summary>
    FailedClosed,
}

/// <summary>Typed outcome of parsing router-local thread identity.</summary>
public sealed record ThreadIdentityParseResult
{
    /// <summary>Fixed, content-free failure code used for the fail-closed case.</summary>
    public const string MismatchCode = "control_thread_identity_mismatch";

    /// <summary>Overall outcome.</summary>
    public required ThreadIdentityOutcome Outcome { get; init; }

    /// <summary>Accepted identity, when <see cref="Outcome"/> is Accepted.</summary>
    public ThreadIdentity? Identity { get; init; }

    /// <summary>Fixed failure code, when <see cref="Outcome"/> is FailedClosed.</summary>
    public string? FailureCode { get; init; }

    /// <summary>True when the request may observe/consume thread state.</summary>
    public bool IsAccepted => Outcome == ThreadIdentityOutcome.Accepted && Identity is not null;
}
