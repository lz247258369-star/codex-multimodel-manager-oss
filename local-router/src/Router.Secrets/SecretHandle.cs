using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;

namespace Router.Secrets;

/// <summary>
/// Opaque handle to a resolved secret. The value is not exposed by ToString,
/// debugger views, or JSON serialization; it is readable only through the
/// explicit consumption boundary (<see cref="ReadValue"/>).
/// </summary>
[DebuggerDisplay("[secret-redacted]")]
public sealed class SecretHandle : IDisposable
{
    private byte[] _utf8;
    private bool _disposed;

    private SecretHandle(byte[] utf8)
    {
        _utf8 = utf8;
    }

    /// <summary>Creates an opaque handle from a secret value.</summary>
    public static SecretHandle FromValue(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return new SecretHandle(Encoding.UTF8.GetBytes(value));
    }

    /// <summary>
    /// Explicit consumption boundary: returns the value as UTF-8 text. Only a
    /// provider adapter may call this, once, immediately before sending.
    /// </summary>
    public string ReadValue()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return Encoding.UTF8.GetString(_utf8);
    }

    /// <inheritdoc />
    public override string ToString() => "[secret-redacted]";

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        CryptographicOperations.ZeroMemory(_utf8);
        _disposed = true;
        GC.SuppressFinalize(this);
    }
}
