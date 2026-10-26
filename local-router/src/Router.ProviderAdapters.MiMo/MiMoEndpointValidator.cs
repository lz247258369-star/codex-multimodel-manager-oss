using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;

namespace Router.ProviderAdapters.MiMo;

/// <summary>
/// Strict endpoint URL validator for Xiaomi MiMo (<c>mm_mimo</c>)
/// Responses-compatible endpoints. Only explicitly configured endpoints are
/// accepted; HTTPS is mandatory in production; loopback HTTP is allowed only
/// inside the explicit test boundary. Approved production hosts come from the
/// existing Direct MiMo endpoint references (<c>api.xiaomimimo.com</c> and
/// <c>token-plan-cn.xiaomimimo.com</c>); arbitrary host interpolation,
/// automatic endpoint/region selection, query/userinfo/fragment content,
/// non-<c>/v1</c> paths, and non-default ports fail closed. The secret never
/// leaves the HTTP authorization boundary.
/// </summary>
public static class MiMoEndpointValidator
{
    /// <summary>Exact allowed base path of Responses-compatible MiMo endpoints.</summary>
    public const string RequiredPath = "/v1";

    private const string PayAsYouGoHost = "api.xiaomimimo.com";
    private const string TokenPlanHost = "token-plan-cn.xiaomimimo.com";

    /// <summary>
    /// Validates an explicit MiMo endpoint URL and returns a transport
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
            // non-default port is not an approved MiMo endpoint shape.
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
    /// True only for the repository-approved MiMo production hosts that the
    /// existing Direct MiMo flow can configure.
    /// </summary>
    public static bool IsAllowedProductionHost(string host)
        => string.Equals(host, PayAsYouGoHost, StringComparison.OrdinalIgnoreCase)
            || string.Equals(host, TokenPlanHost, StringComparison.OrdinalIgnoreCase);
}
