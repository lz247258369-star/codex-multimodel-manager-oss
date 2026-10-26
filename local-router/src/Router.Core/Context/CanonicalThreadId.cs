namespace Router.Core.Context;

/// <summary>
/// Canonical Codex thread identity extracted from router-local control
/// metadata (<c>thread-id</c> or <c>x-codex-turn-metadata.thread_id</c>).
///
/// The value is opaque: it is never parsed as a GUID, never interpreted as
/// text, never used in a filesystem path, and never exposed outside the
/// process. External surfaces use <see cref="ThreadRef"/> instead.
/// </summary>
public sealed record CanonicalThreadId
{
    /// <summary>Minimum accepted length of a raw thread identity.</summary>
    public const int MinLength = 8;

    /// <summary>Maximum accepted length of a raw thread identity.</summary>
    public const int MaxLength = 64;

    private CanonicalThreadId(string canonical)
    {
        Value = canonical;
    }

    /// <summary>Canonical (ASCII-lowercase) opaque identity value.</summary>
    public string Value { get; }

    /// <summary>
    /// Validates and canonicalizes a raw identity value. Accepted values use
    /// the allowlist charset <c>[0-9a-fA-F-]</c> and must contain at least one
    /// hexadecimal digit.
    /// </summary>
    public static bool TryParse(string? raw, out CanonicalThreadId? identity)
    {
        identity = null;
        if (raw is null)
        {
            return false;
        }

        string trimmed = raw.Trim();
        if (trimmed.Length is < MinLength or > MaxLength)
        {
            return false;
        }

        bool hasHexDigit = false;
        foreach (char c in trimmed)
        {
            bool isHex = c is >= '0' and <= '9' or >= 'a' and <= 'f' or >= 'A' and <= 'F';
            if (isHex)
            {
                hasHexDigit = true;
                continue;
            }

            if (c != '-')
            {
                return false;
            }
        }

        if (!hasHexDigit)
        {
            return false;
        }

        identity = new CanonicalThreadId(trimmed.ToLowerInvariant());
        return true;
    }
}
