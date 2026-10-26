namespace Router.Core.Ids;

/// <summary>
/// Canonical per-upstream-attempt ID: <c>att_&lt;uuidv7-lowercase&gt;</c>.
/// </summary>
public readonly record struct AttemptId
{
    public const string Prefix = "att_";

    private readonly string _value;

    private AttemptId(string value)
    {
        _value = value;
    }

    /// <summary>Canonical string value, or an empty string for the default instance.</summary>
    public string Value => _value ?? string.Empty;

    /// <summary>True when this is the default instance (no ID assigned).</summary>
    public bool IsDefault => string.IsNullOrEmpty(_value);

    /// <summary>The embedded UUIDv7 component.</summary>
    public UuidV7 Uuid => IsDefault ? default : UuidV7.Parse(Value[Prefix.Length..]);

    /// <summary>Creates an ID from a UUIDv7.</summary>
    public static AttemptId Create(UuidV7 uuid) => new(TypedId.Create(Prefix, uuid));

    /// <summary>Parses a canonical attempt ID.</summary>
    public static AttemptId Parse(string text)
    {
        if (!TryParse(text, out AttemptId value))
        {
            throw new FormatException("The value is not a canonical AttemptId.");
        }

        return value;
    }

    /// <summary>
    /// Attempts to parse a canonical attempt ID. Accepts only ASCII, lowercase,
    /// version-7 IDs of at most 128 characters.
    /// </summary>
    public static bool TryParse(string? text, out AttemptId value)
    {
        if (!TypedId.TryCreate(text, Prefix, out string canonical))
        {
            value = default;
            return false;
        }

        value = new AttemptId(canonical);
        return true;
    }

    /// <inheritdoc />
    public override string ToString() => Value;
}
