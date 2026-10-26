namespace Router.ProviderAdapters.Abstractions;

/// <summary>
/// Transient upstream HTTP request. The body is buffered before the attempt
/// begins; the Authorization value is supplied by the adapter from an opaque
/// <c>SecretHandle</c> immediately before sending and never enters records.
/// </summary>
public sealed record UpstreamRequest
{
    public required string Method { get; init; }

    public required UpstreamEndpoint Endpoint { get; init; }

    public required string PathAndQuery { get; init; }

    /// <summary>Explicit request headers; only safe names are allowed here.</summary>
    public IReadOnlyDictionary<string, string> Headers { get; init; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    public byte[]? Body { get; init; }

    public string? ContentType { get; init; }

    public static UpstreamRequest Create(
        string method,
        UpstreamEndpoint endpoint,
        string pathAndQuery,
        IReadOnlyDictionary<string, string>? headers = null,
        byte[]? body = null,
        string? contentType = null)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        if (string.IsNullOrWhiteSpace(method))
        {
            throw new ArgumentException("Method must not be empty.");
        }

        return new UpstreamRequest
        {
            Method = method,
            Endpoint = endpoint,
            PathAndQuery = pathAndQuery,
            Headers = headers ?? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase),
            Body = body,
            ContentType = contentType,
        };
    }

    public Uri FullUri => new(Endpoint.Uri, PathAndQuery);
}

/// <summary>
/// Upstream HTTP response. Headers are the allowlisted safe subset only; the
/// body is a forward-only stream owned by the transport until consumed.
/// </summary>
public sealed record UpstreamResponse
{
    public required int StatusCode { get; init; }

    public required IReadOnlyDictionary<string, string> SafeHeaders { get; init; }

    public required Stream Body { get; init; }

    public bool IsSuccessStatusCode => StatusCode is >= 200 and < 300;
}
