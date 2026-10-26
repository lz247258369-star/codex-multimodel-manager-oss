using System.Text.RegularExpressions;

namespace Router.Core.Ids;

/// <summary>
/// An RFC 9562 version 7 (time-ordered) UUID in canonical lowercase form.
/// </summary>
public readonly record struct UuidV7
{
    private const int CanonicalLength = 36;

    private static readonly Regex CanonicalPattern = new(
        "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private readonly string _value;

    private UuidV7(string value)
    {
        _value = value;
    }

    /// <summary>Canonical lowercase string form, or an empty string for the default value.</summary>
    public string Value => _value ?? string.Empty;

    /// <summary>True when this is the default instance (no UUID assigned).</summary>
    public bool IsDefault => string.IsNullOrEmpty(_value);

    /// <summary>The same UUID as a <see cref="Guid"/>.</summary>
    public Guid AsGuid => Guid.ParseExact(Value, "D");

    /// <summary>The embedded Unix timestamp in milliseconds (the first 48 bits).</summary>
    public long UnixTimeMilliseconds
    {
        get
        {
            if (IsDefault)
            {
                throw new InvalidOperationException("The default UuidV7 has no timestamp.");
            }

            long timestamp = 0;
            ReadOnlySpan<char> text = Value;
            for (int i = 0; i < 8; i++)
            {
                timestamp = (timestamp << 4) | (uint)HexValue(text[i]);
            }

            for (int i = 9; i < 13; i++)
            {
                timestamp = (timestamp << 4) | (uint)HexValue(text[i]);
            }

            return timestamp;
        }
    }

    /// <summary>Parses a canonical lowercase UUIDv7 string.</summary>
    public static UuidV7 Parse(string text)
    {
        if (!TryParse(text, out UuidV7 value))
        {
            throw new FormatException("The value is not a canonical lowercase UUIDv7 string.");
        }

        return value;
    }

    /// <summary>
    /// Attempts to parse a canonical lowercase UUIDv7 string. Accepts only ASCII,
    /// lowercase, version-7, variant-10 UUIDs.
    /// </summary>
    public static bool TryParse(string? text, out UuidV7 value)
    {
        if (text is null || text.Length != CanonicalLength || !CanonicalPattern.IsMatch(text))
        {
            value = default;
            return false;
        }

        value = new UuidV7(text);
        return true;
    }

    /// <inheritdoc />
    public override string ToString() => Value;

    internal static UuidV7 FromUnixTimeMilliseconds(
        long unixTimeMilliseconds,
        ushort subMillisecondCounter,
        ReadOnlySpan<byte> randomBytes)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(unixTimeMilliseconds);

        if (randomBytes.Length != 8)
        {
            throw new ArgumentException("Exactly 8 random bytes are required.", nameof(randomBytes));
        }

        byte[] bytes = new byte[16];
        ulong timestamp = (ulong)unixTimeMilliseconds;
        bytes[0] = (byte)(timestamp >> 40);
        bytes[1] = (byte)(timestamp >> 32);
        bytes[2] = (byte)(timestamp >> 24);
        bytes[3] = (byte)(timestamp >> 16);
        bytes[4] = (byte)(timestamp >> 8);
        bytes[5] = (byte)timestamp;
        bytes[6] = (byte)(0x70 | ((subMillisecondCounter >> 8) & 0x0F));
        bytes[7] = (byte)(subMillisecondCounter & 0xFF);
        bytes[8] = (byte)(0x80 | (randomBytes[0] & 0x3F));
        randomBytes[1..].CopyTo(bytes.AsSpan(9));

        return new UuidV7(Format(bytes));
    }

    private static string Format(byte[] bytes)
    {
        string hex = Convert.ToHexString(bytes).ToLowerInvariant();
        return string.Create(CanonicalLength, hex, static (span, source) =>
        {
            source.AsSpan(0, 8).CopyTo(span);
            span[8] = '-';
            source.AsSpan(8, 4).CopyTo(span.Slice(9, 4));
            span[13] = '-';
            source.AsSpan(12, 4).CopyTo(span.Slice(14, 4));
            span[18] = '-';
            source.AsSpan(16, 4).CopyTo(span.Slice(19, 4));
            span[23] = '-';
            source.AsSpan(20, 12).CopyTo(span.Slice(24, 12));
        });
    }

    private static int HexValue(char c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'a' and <= 'f' => c - 'a' + 10,
        _ => -1,
    };
}
