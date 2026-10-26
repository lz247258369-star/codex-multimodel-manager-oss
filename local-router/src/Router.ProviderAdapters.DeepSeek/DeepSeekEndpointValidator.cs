using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;

namespace Router.ProviderAdapters.DeepSeek;

/// <summary>
/// Strict endpoint URL validator for the DeepSeek official (<c>deepseek</c>)
/// Responses API. Only the repository-approved production host is accepted;
/// HTTPS is mandatory in production; loopback HTTP is allowed only inside the
/// explicit test boundary. The approved base URL is the provider root
/// (<c>https://api.deepseek.com</c>) because the adapter itself composes the
/// official <c>/responses</c> path; a base URL that already carries a path would
/// produce a doubled route, so any non-root path fails closed. Arbitrary host
/// interpolation, sub-domain or suffix look-alikes, IP literals, userinfo,
/// query/fragment content, and non-default ports fail closed. The secret never
/// leaves the HTTP authorization boundary.
/// </summary>
public static class DeepSeekEndpointValidator
{
    /// <summary>
    /// Exact allowed base path of the DeepSeek official endpoint: the provider
    /// root, with or without the standard trailing slash.
    /// </summary>
    public const string RequiredPath = "/";

    private const string ProductionHost = "api.deepseek.com";

    /// <summary>
    /// Validates an explicit DeepSeek endpoint URL and returns a transport
    /// endpoint. HTTPS is required for production; HTTP is accepted only for
    /// loopback hosts with <paramref name="loopbackTestOnly"/> set.
    /// </summary>
    public static Result<UpstreamEndpoint, RouterError> Validate(Uri uri, bool loopbackTestOnly = false)
    {
        ArgumentNullException.ThrowIfNull(uri);

        if (!uri.IsAbsoluteUri
            || !string.IsNullOrEmpty(uri.UserInfo)
            || !string.IsNullOrEmpty(uri.Query)
            || !string.IsNullOrEmpty(uri.Fragment))
        {
            return new Result<UpstreamEndpoint, RouterError>
            {
                Error = ProviderAdapterErrors.InvalidEndpoint("endpoint"),
            };
        }

        bool isHttps = string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase);
        bool isHttp = string.Equals(uri.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase);
        if (!isHttps && !isHttp)
        {
            return new Result<UpstreamEndpoint, RouterError>
            {
                Error = ProviderAdapterErrors.TlsRequired("endpoint"),
            };
        }

        if (isHttp && (!loopbackTestOnly || !UpstreamEndpoint.IsLoopbackHost(uri.Host)))
        {
            return new Result<UpstreamEndpoint, RouterError>
            {
                Error = ProviderAdapterErrors.TlsRequired("endpoint"),
            };
        }

        if (!string.Equals(uri.AbsolutePath, RequiredPath, StringComparison.Ordinal))
        {
            return new Result<UpstreamEndpoint, RouterError>
            {
                Error = ProviderAdapterErrors.InvalidEndpoint("endpoint"),
            };
        }

        if (!isHttp)
        {
            if (!IsAllowedProductionHost(uri.Host))
            {
                return new Result<UpstreamEndpoint, RouterError>
                {
                    Error = ProviderAdapterErrors.InvalidEndpoint("endpoint"),
                };
            }

            // Production endpoints must use the default HTTPS port; an explicit
            // non-default port is not an approved DeepSeek endpoint shape.
            if (uri.Port != -1 && uri.Port != 443)
            {
                return new Result<UpstreamEndpoint, RouterError>
                {
                    Error = ProviderAdapterErrors.InvalidEndpoint("endpoint"),
                };
            }
        }

        return new Result<UpstreamEndpoint, RouterError>
        {
            Value = new UpstreamEndpoint
            {
                Uri = uri,
                TlsRequired = isHttps,
                LoopbackTestOnly = loopbackTestOnly,
                RedirectPolicy = RedirectPolicy.SameOriginOnly,
            },
        };
    }

    /// <summary>
    /// True only for the repository-approved DeepSeek official production host.
    /// </summary>
    public static bool IsAllowedProductionHost(string host)
        => string.Equals(host, ProductionHost, StringComparison.OrdinalIgnoreCase);
}
