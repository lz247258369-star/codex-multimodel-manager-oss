using System.Security.Cryptography;
using System.Text;

namespace Router.Core.Support;

/// <summary>Deterministic lowercase SHA-256 helpers for content hashing.</summary>
public static class SafeHasher
{
    public static string Sha256Hex(ReadOnlySpan<byte> data)
        => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    public static string Sha256Hex(string text)
        => Sha256Hex(Encoding.UTF8.GetBytes(text));
}
