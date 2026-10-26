using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.Registries;

namespace Router.Execution;

/// <summary>
/// Resolves an endpoint registry reference to a validated transport endpoint.
/// Only explicitly approved base URLs (or explicit loopback test overrides) are
/// ever accepted; no URL is ever constructed from model names or request data.
/// </summary>
public interface IRouterExecutionEndpointSource
{
    Result<UpstreamEndpoint, RouterError> Resolve(EndpointRegistryEntry endpoint);
}

/// <summary>
/// Immutable execution endpoint source. Repository-approved production base
/// URLs are used by default; explicit loopback overrides are permitted only at
/// composition time (test seams). An unknown reference fails closed.
/// </summary>
public sealed class RouterExecutionEndpointSource : IRouterExecutionEndpointSource
{
    private readonly Dictionary<string, string> _baseUrls;
    private readonly Dictionary<string, string> _loopbackOverrides;

    public RouterExecutionEndpointSource(
        IReadOnlyDictionary<string, string>? baseUrls = null,
        IReadOnlyDictionary<string, string>? loopbackOverrides = null)
    {
        var approved = new Dictionary<string, string>(RouterExecutionEndpoints.ApprovedProductionBaseUrls, StringComparer.Ordinal);
        if (baseUrls is not null)
        {
            foreach (KeyValuePair<string, string> pair in baseUrls)
            {
                approved[pair.Key] = pair.Value;
            }
        }

        _baseUrls = approved;
        _loopbackOverrides = loopbackOverrides is null
            ? new Dictionary<string, string>(StringComparer.Ordinal)
            : new Dictionary<string, string>(loopbackOverrides, StringComparer.Ordinal);
    }

    public Result<UpstreamEndpoint, RouterError> Resolve(EndpointRegistryEntry endpoint)
    {
        ArgumentNullException.ThrowIfNull(endpoint);

        if (_loopbackOverrides.TryGetValue(endpoint.BaseUrlRef, out string? overrideUrl))
        {
            return CreateEndpoint(overrideUrl, tlsRequired: false, loopbackTestOnly: true);
        }

        if (_baseUrls.TryGetValue(endpoint.BaseUrlRef, out string? approvedUrl))
        {
            return CreateEndpoint(approvedUrl, tlsRequired: endpoint.TlsRequired, loopbackTestOnly: false);
        }

        return new Result<UpstreamEndpoint, RouterError>
        {
            Error = ProviderAdapterErrors.InvalidEndpoint("endpoint"),
        };
    }

    private static Result<UpstreamEndpoint, RouterError> CreateEndpoint(
        string url,
        bool tlsRequired,
        bool loopbackTestOnly)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out Uri? uri))
        {
            return new Result<UpstreamEndpoint, RouterError>
            {
                Error = ProviderAdapterErrors.InvalidEndpoint("endpoint"),
            };
        }

        return UpstreamEndpoint.Create(uri, tlsRequired, loopbackTestOnly, RedirectPolicy.SameOriginOnly);
    }
}

/// <summary>
/// Repository-approved endpoint base URL references and values. Every value is
/// the canonical Manager provider base URL; each provider adapter composes its
/// provider-specific request path (including any gateway prefix) against this
/// value. An unknown reference always fails closed.
/// </summary>
public static class RouterExecutionEndpoints
{
    public const string OpenAiBaseUrlReference = "provider-config:mm_openai_api.base_url";
    public const string ModelStudioBaseUrlReference = "provider-config:mm_modelstudio.base_url";
    public const string OpenRouterBaseUrlReference = "provider-config:mm_openrouter.base_url";
    public const string MiMoBaseUrlReference = "provider-config:mm_mimo.base_url";
    public const string DeepSeekBaseUrlReference = "provider-config:deepseek.base_url";

    public static IReadOnlyDictionary<string, string> ApprovedProductionBaseUrls { get; } =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [OpenAiBaseUrlReference] = "https://api.openai.com/v1",
            [ModelStudioBaseUrlReference] = "https://dashscope.aliyuncs.com/compatible-mode/v1",
            [OpenRouterBaseUrlReference] = "https://openrouter.ai/api/v1",
            [MiMoBaseUrlReference] = "https://api.xiaomimimo.com/v1",
            [DeepSeekBaseUrlReference] = "https://api.deepseek.com",
        };
}
