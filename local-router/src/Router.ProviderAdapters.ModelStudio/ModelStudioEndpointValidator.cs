using System.Text.RegularExpressions;
using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;

namespace Router.ProviderAdapters.ModelStudio;

/// <summary>
/// Strict workspace endpoint URL validator for Alibaba Model Studio
/// (<c>mm_modelstudio</c>) Responses-compatible endpoints. Only explicitly
/// configured endpoints are accepted; HTTPS is mandatory in production;
/// loopback HTTP is allowed only inside the explicit test boundary. Arbitrary
/// host interpolation, unresolved workspace templates, non-workspace hosts,
/// query/userinfo/fragment content, non-workspace paths, and non-default ports
/// fail closed. The secret never leaves the HTTP authorization boundary.
/// </summary>
public static partial class ModelStudioEndpointValidator
{
    /// <summary>Exact allowed base path of Responses-compatible Model Studio endpoints.</summary>
    public const string RequiredPath = "/compatible-mode/v1";

    private const string TokenPlanHost = "token-plan.cn-beijing.maas.aliyuncs.com";
    private const string DashScopeHost = "dashscope.aliyuncs.com";

    /// <summary>
    /// Workspace host shape: <c>{workspace}.{region}.maas.aliyuncs.com</c>
    /// where the workspace label is a validated project identifier
    /// (lowercase letters, digits, hyphens; DNS-label length).
    /// </summary>
    [GeneratedRegex(
        @"^(?<workspace>[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)\.(?<region>[a-z0-9-]+)\.maas\.aliyuncs\.com$",
        RegexOptions.CultureInvariant)]
    private static partial Regex WorkspaceHostPattern();

    /// <summary>
    /// Validates an explicit Model Studio endpoint URL and returns a transport
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
            // non-default port is not an approved workspace endpoint shape.
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
    /// True only for repository-approved Model Studio production hosts:
    /// workspace hosts, the Token Plan host, or the public DashScope host.
    /// </summary>
    public static bool IsAllowedProductionHost(string host)
    {
        if (string.IsNullOrWhiteSpace(host))
        {
            return false;
        }

        return WorkspaceHostPattern().IsMatch(host)
            || string.Equals(host, TokenPlanHost, StringComparison.OrdinalIgnoreCase)
            || string.Equals(host, DashScopeHost, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>True when the host is a validated workspace-scoped Model Studio host.</summary>
    public static bool IsWorkspaceHost(string host)
        => !string.IsNullOrWhiteSpace(host) && WorkspaceHostPattern().IsMatch(host);
}
