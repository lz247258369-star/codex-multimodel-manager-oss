namespace Router.Core.Ids;

/// <summary>
/// Canonical per-trace correlation ID: <c>trc_&lt;uuidv7-lowercase&gt;</c>.
/// </summary>
public readonly record struct TraceId
{
    public const string Prefix = "trc_";

    private readonly string _value;

    private TraceId(string value)
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
    public static TraceId Create(UuidV7 uuid) => new(TypedId.Create(Prefix, uuid));

    /// <summary>Parses a canonical trace ID.</summary>
    public static TraceId Parse(string text)
    {
        if (!TryParse(text, out TraceId value))
        {
            throw new FormatException("The value is not a canonical TraceId.");
        }

        return value;
    }

    /// <summary>
    /// Attempts to parse a canonical trace ID. Accepts only ASCII, lowercase,
    /// version-7 IDs of at most 128 characters.
    /// </summary>
    public static bool TryParse(string? text, out TraceId value)
    {
        if (!TypedId.TryCreate(text, Prefix, out string canonical))
        {
            value = default;
            return false;
        }

        value = new TraceId(canonical);
        return true;
    }

    /// <inheritdoc />
    public override string ToString() => Value;
}
