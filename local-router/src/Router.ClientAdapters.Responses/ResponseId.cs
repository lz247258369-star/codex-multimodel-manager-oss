using System.Text.RegularExpressions;

namespace Router.ClientAdapters.Responses;

/// <summary>
/// Canonical response ID: <c>resp_&lt;uuidv7-lowercase&gt;</c>. LR-3 fake
/// responses always carry a freshly generated canonical ID; safe upstream IDs
/// are a later provider-adapter concern.
/// </summary>
public readonly record struct ResponseId
{
    public const string Prefix = "resp_";

    private static readonly Regex Pattern = new(
        "^resp_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private readonly string _value;

    private ResponseId(string value)
    {
        _value = value;
    }

    /// <summary>Canonical string value, or an empty string for the default instance.</summary>
    public string Value => _value ?? string.Empty;

    /// <summary>True when this is the default instance (no ID assigned).</summary>
    public bool IsDefault => string.IsNullOrEmpty(_value);

    /// <summary>Creates an ID from a canonical UUIDv7 string (without the prefix).</summary>
    public static ResponseId FromUuid(string uuidValue)
    {
        string value = Prefix + uuidValue;
        if (!Pattern.IsMatch(value))
        {
            throw new FormatException("The value is not a canonical ResponseId.");
        }

        return new ResponseId(value);
    }

    /// <summary>Attempts to parse a canonical response ID.</summary>
    public static bool TryParse(string? text, out ResponseId value)
    {
        if (text is null || text.Length > 128 || !Pattern.IsMatch(text))
        {
            value = default;
            return false;
        }

        value = new ResponseId(text);
        return true;
    }

    /// <inheritdoc />
    public override string ToString() => Value;
}
