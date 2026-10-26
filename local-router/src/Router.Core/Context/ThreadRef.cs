using Router.Core.Support;

namespace Router.Core.Context;

/// <summary>
/// External, content-free reference for a canonical thread identity.
///
/// <c>ThreadRef = lowercase hex(SHA-256(canonicalThreadId))[:16]</c>. Only this
/// reference may appear in control-plane payloads, durable request records,
/// traces, logs, or the V4 UI; the raw canonical id never leaves process
/// memory.
/// </summary>
public static class ThreadRef
{
    /// <summary>Number of leading SHA-256 hex characters exposed externally.</summary>
    public const int Length = 16;

    /// <summary>Derives the external reference for a canonical thread identity.</summary>
    public static string From(CanonicalThreadId identity)
    {
        ArgumentNullException.ThrowIfNull(identity);
        return SafeHasher.Sha256Hex(identity.Value)[..Length];
    }

    /// <summary>
    /// True only for a well-formed external reference: exactly
    /// <see cref="Length"/> lowercase hexadecimal characters. A raw canonical
    /// thread id is never a valid reference.
    /// </summary>
    public static bool IsValid(string? candidate)
    {
        if (candidate is null || candidate.Length != Length)
        {
            return false;
        }

        foreach (char c in candidate)
        {
            if (c is not (>= '0' and <= '9' or >= 'a' and <= 'f'))
            {
                return false;
            }
        }

        return true;
    }
}
