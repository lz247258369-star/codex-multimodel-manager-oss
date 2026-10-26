using Router.Core.Errors;

namespace Router.ProviderAdapters.Abstractions;

/// <summary>
/// Validated upstream endpoint. Production endpoints require HTTPS; HTTP is
/// allowed only for loopback test fixtures (127.0.0.1 / localhost / [::1])
/// created inside the test boundary.
/// </summary>
public sealed record UpstreamEndpoint
{
    public required Uri Uri { get; init; }

    public required bool TlsRequired { get; init; }

    public required bool LoopbackTestOnly { get; init; }

    public RedirectPolicy RedirectPolicy { get; init; } = RedirectPolicy.SameOriginOnly;

    public static bool IsLoopbackHost(string host)
        => string.Equals(host, "127.0.0.1", StringComparison.Ordinal)
            || string.Equals(host, "localhost", StringComparison.OrdinalIgnoreCase)
            || string.Equals(host, "[::1]", StringComparison.Ordinal)
            || string.Equals(host, "::1", StringComparison.Ordinal);

    /// <summary>
    /// Creates a validated endpoint. HTTPS is always allowed; HTTP is allowed
    /// only when the host is loopback and the endpoint is explicitly marked
    /// <c>loopbackTestOnly</c>. Scheme downgrade and non-loopback HTTP fail
    /// closed with <c>tls_required</c>.
    /// </summary>
    public static Result<UpstreamEndpoint, RouterError> Create(
        Uri uri,
        bool tlsRequired = true,
        bool loopbackTestOnly = false,
        RedirectPolicy redirectPolicy = RedirectPolicy.SameOriginOnly)
    {
        ArgumentNullException.ThrowIfNull(uri);

        if (!uri.IsAbsoluteUri)
        {
            return new Result<UpstreamEndpoint, RouterError> { Error = ProviderAdapterErrors.TlsRequired("endpoint") };
        }

        bool isHttps = string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase);
        bool isHttp = string.Equals(uri.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase);
        if (!isHttps && !isHttp)
        {
            return new Result<UpstreamEndpoint, RouterError> { Error = ProviderAdapterErrors.TlsRequired("endpoint") };
        }

        if (isHttp)
        {
            if (tlsRequired || !loopbackTestOnly || string.IsNullOrEmpty(uri.Host) || !IsLoopbackHost(uri.Host))
            {
                return new Result<UpstreamEndpoint, RouterError> { Error = ProviderAdapterErrors.TlsRequired("endpoint") };
            }
        }

        if (uri.Query.Length > 0 || !string.IsNullOrEmpty(uri.Fragment))
        {
            return new Result<UpstreamEndpoint, RouterError> { Error = ProviderAdapterErrors.InvalidEndpoint("endpoint") };
        }

        return new Result<UpstreamEndpoint, RouterError>
        {
            Value = new UpstreamEndpoint
            {
                Uri = uri,
                TlsRequired = tlsRequired,
                LoopbackTestOnly = loopbackTestOnly,
                RedirectPolicy = redirectPolicy,
            },
        };
    }

    /// <summary>True when a redirect to <paramref name="target"/> is allowed by the redirect policy.</summary>
    public bool AllowsRedirect(Uri target)
    {
        ArgumentNullException.ThrowIfNull(target);

        if (RedirectPolicy == RedirectPolicy.None)
        {
            return false;
        }

        // Same-origin only: scheme (no downgrade), host, and port must match.
        return string.Equals(Uri.Scheme, target.Scheme, StringComparison.OrdinalIgnoreCase)
            && string.Equals(Uri.Host, target.Host, StringComparison.OrdinalIgnoreCase)
            && Uri.Port == target.Port
            && !(Uri.Scheme == Uri.UriSchemeHttps && target.Scheme == Uri.UriSchemeHttp);
    }
}

/// <summary>Redirect handling policy for one endpoint.</summary>
public enum RedirectPolicy
{
    /// <summary>Any 3xx redirect is rejected with <c>redirect_rejected</c>.</summary>
    None,

    /// <summary>Same-origin, same-scheme redirects may be followed; everything else is rejected.</summary>
    SameOriginOnly,
}

/// <summary>Minimal discriminated result used by pure validators.</summary>
public sealed record Result<TValue, TError>
{
    public TValue? Value { get; init; }

    public TError? Error { get; init; }

    public bool IsSuccess => Value is not null;

}
