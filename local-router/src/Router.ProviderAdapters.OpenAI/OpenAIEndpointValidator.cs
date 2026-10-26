using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;

namespace Router.ProviderAdapters.OpenAI;

/// <summary>
/// Strict endpoint URL validator for the OpenAI API (<c>mm_openai_api</c>)
/// Responses endpoint. Only the repository-approved <c>api.openai.com</c>
/// production host with the <c>/v1</c> base path is accepted; HTTPS is
/// mandatory in production; loopback HTTP is allowed only inside the explicit
/// test boundary. Arbitrary host interpolation, query/userinfo/fragment
/// content, non-<c>/v1</c> paths, and non-default ports fail closed. The
/// secret never leaves the HTTP authorization boundary.
/// </summary>
public static class OpenAIEndpointValidator
{
    /// <summary>Exact allowed base path of OpenAI API Responses endpoints.</summary>
    public const string RequiredPath = "/v1";

    private const string ApprovedProductionHost = "api.openai.com";

    /// <summary>
    /// Validates an explicit OpenAI API endpoint URL and returns a transport
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
            // non-default port is not an approved endpoint shape.
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
    /// True only for the repository-approved OpenAI API production host.
    /// </summary>
    public static bool IsAllowedProductionHost(string host)
        => string.Equals(host, ApprovedProductionHost, StringComparison.OrdinalIgnoreCase);
}
