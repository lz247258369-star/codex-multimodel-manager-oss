namespace Router.Core.Ids;

/// <summary>
/// Shared validation for typed correlation IDs:
/// <c>prefix + canonical lowercase UUIDv7</c>, ASCII, at most 128 characters.
/// </summary>
internal static class TypedId
{
    public const int MaxLength = 128;

    public static bool TryCreate(string? text, string prefix, out string value)
    {
        value = string.Empty;
        if (string.IsNullOrEmpty(text)
            || text.Length > MaxLength
            || !text.StartsWith(prefix, StringComparison.Ordinal))
        {
            return false;
        }

        string uuidPart = text[prefix.Length..];
        if (!UuidV7.TryParse(uuidPart, out _))
        {
            return false;
        }

        value = text;
        return true;
    }

    public static string Create(string prefix, UuidV7 uuid) => prefix + uuid.Value;
}
