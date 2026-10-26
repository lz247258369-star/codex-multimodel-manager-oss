namespace Router.ProviderAdapters.Abstractions;

/// <summary>
/// Explicit response-header allowlist and redaction policy. Secrets,
/// credentials, cookies, and vendor secret headers never cross into
/// observability; only explicitly safe fields may be extracted.
/// </summary>
public static class UpstreamHeaderPolicy
{
    private static readonly HashSet<string> SafeResponseHeaders = new(StringComparer.OrdinalIgnoreCase)
    {
        "content-type",
        "content-length",
        "retry-after",
        "x-request-id",
        "x-correlation-id",
    };

    private static readonly HashSet<string> ForbiddenHeaderNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-auth-token",
        "api-key",
        "x-goog-api-key",
        "x-openai-api-key",
    };

    public static bool IsSafeResponseHeader(string headerName)
        => !string.IsNullOrWhiteSpace(headerName) && SafeResponseHeaders.Contains(headerName);

    public static bool IsForbiddenHeader(string headerName)
        => !string.IsNullOrWhiteSpace(headerName) && ForbiddenHeaderNames.Contains(headerName);

    /// <summary>
    /// Extracts only allowlisted response headers. Header names are
    /// case-preserved as received; values are never logged by callers.
    /// </summary>
    public static IReadOnlyDictionary<string, string> ExtractSafeHeaders(IEnumerable<KeyValuePair<string, IEnumerable<string>>> headers)
    {
        ArgumentNullException.ThrowIfNull(headers);

        var safe = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (KeyValuePair<string, IEnumerable<string>> header in headers)
        {
            if (IsSafeResponseHeader(header.Key))
            {
                safe[header.Key] = string.Join(",", header.Value);
            }
        }

        return safe;
    }
}
