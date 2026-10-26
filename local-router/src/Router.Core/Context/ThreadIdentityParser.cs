using System.Text;
using System.Text.Json;

namespace Router.Core.Context;

/// <summary>
/// Interprets the two identity-bearing Codex request sources —
/// <c>thread-id</c> (SOURCE A) and <c>x-codex-turn-metadata.thread_id</c>
/// (SOURCE B) — with a fail-closed truth table.
///
/// Rules that are deliberately impossible here: no fallback to
/// <c>session-id</c>, <c>x-codex-window-id</c>, or <c>x-client-request-id</c>;
/// no "most recent thread" inference; and no masking of a malformed presented
/// source by the other source.
/// </summary>
public static class ThreadIdentityParser
{
    /// <summary>Wire header carrying SOURCE A, the canonical Codex thread id.</summary>
    public const string ThreadIdHeaderName = "thread-id";

    /// <summary>Wire header carrying SOURCE B, the Codex turn metadata document.</summary>
    public const string TurnMetadataHeaderName = "x-codex-turn-metadata";

    /// <summary>Hard bound for the metadata header that may be parsed.</summary>
    public const int MaxMetadataBytes = 4096;

    private const int MaxRequestKindLength = 32;
    private const int MaxWindowNumber = 65_535;

    /// <summary>
    /// Parses the presented identity sources. A request that is not
    /// <see cref="ThreadIdentityOutcome.Accepted"/> can still be served with
    /// the Codex requested model; it simply owns no thread state.
    /// </summary>
    public static ThreadIdentityParseResult Parse(string? threadIdHeader, string? metadataHeader)
    {
        bool sourceAPresented = !string.IsNullOrWhiteSpace(threadIdHeader);
        bool sourceAValid = CanonicalThreadId.TryParse(threadIdHeader, out CanonicalThreadId? sourceA);

        bool metadataPresented = !string.IsNullOrWhiteSpace(metadataHeader);
        bool metadataOversized = metadataPresented
            && Encoding.UTF8.GetByteCount(metadataHeader!) > MaxMetadataBytes;

        CanonicalThreadId? sourceB = null;
        bool sourceBPresented = false;
        bool sourceBValid = false;
        string? requestKind = null;
        int? windowNumber = null;
        bool metadataReadable = false;

        if (metadataPresented && !metadataOversized)
        {
            metadataReadable = TryReadMetadata(
                metadataHeader!,
                out string? rawThreadId,
                out requestKind,
                out windowNumber);

            sourceBPresented = metadataReadable && !string.IsNullOrWhiteSpace(rawThreadId);
            sourceBValid = sourceBPresented && CanonicalThreadId.TryParse(rawThreadId, out sourceB);
        }

        // A presented metadata header that cannot be read, is oversized, or
        // carries an invalid thread_id is a defective identity source. It is
        // never silently ignored while the other source is accepted.
        bool sourceBDefective = metadataPresented && (metadataOversized || !metadataReadable || (sourceBPresented && !sourceBValid));

        if (sourceAValid)
        {
            if (sourceBValid)
            {
                return string.Equals(sourceA!.Value, sourceB!.Value, StringComparison.Ordinal)
                    ? Accepted(sourceA, requestKind, windowNumber)
                    : FailedClosed();
            }

            return sourceBDefective
                ? FailedClosed()
                : Accepted(sourceA!, requestKind, windowNumber);
        }

        if (sourceAPresented)
        {
            // Malformed SOURCE A may never be ignored in favour of SOURCE B.
            return sourceBValid ? FailedClosed() : NoIdentity();
        }

        return sourceBValid
            ? Accepted(sourceB!, requestKind, windowNumber)
            : NoIdentity();
    }

    private static ThreadIdentityParseResult Accepted(CanonicalThreadId identity, string? requestKind, int? windowNumber)
        => new()
        {
            Outcome = ThreadIdentityOutcome.Accepted,
            Identity = new ThreadIdentity
            {
                ThreadId = identity,
                Ref = ThreadRef.From(identity),
                RequestKind = requestKind,
                WindowNumber = windowNumber,
            },
        };

    private static ThreadIdentityParseResult FailedClosed()
        => new()
        {
            Outcome = ThreadIdentityOutcome.FailedClosed,
            FailureCode = ThreadIdentityParseResult.MismatchCode,
        };

    private static ThreadIdentityParseResult NoIdentity()
        => new() { Outcome = ThreadIdentityOutcome.NoIdentity };

    private static bool TryReadMetadata(
        string metadata,
        out string? rawThreadId,
        out string? requestKind,
        out int? windowNumber)
    {
        rawThreadId = null;
        requestKind = null;
        windowNumber = null;
        try
        {
            using JsonDocument document = JsonDocument.Parse(metadata, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                MaxDepth = 8,
            });

            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return false;
            }

            if (document.RootElement.TryGetProperty("thread_id", out JsonElement threadId)
                && threadId.ValueKind == JsonValueKind.String)
            {
                rawThreadId = threadId.GetString();
            }

            if (document.RootElement.TryGetProperty("request_kind", out JsonElement kind)
                && kind.ValueKind == JsonValueKind.String)
            {
                requestKind = SanitizeToken(kind.GetString());
            }

            if (document.RootElement.TryGetProperty("window_number", out JsonElement window)
                && window.ValueKind == JsonValueKind.Number
                && window.TryGetInt32(out int parsed)
                && parsed is >= 0 and <= MaxWindowNumber)
            {
                windowNumber = parsed;
            }

            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    /// <summary>
    /// Accepts only a short lowercase token; anything else becomes <c>null</c>
    /// so an unknown or malformed kind can never be treated as an eligible
    /// turn.
    /// </summary>
    private static string? SanitizeToken(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > MaxRequestKindLength)
        {
            return null;
        }

        foreach (char c in value)
        {
            if (c is not ((>= 'a' and <= 'z') or (>= '0' and <= '9') or '_' or '-'))
            {
                return null;
            }
        }

        return value;
    }
}
