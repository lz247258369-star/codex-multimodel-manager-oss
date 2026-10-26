using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Router.ProviderAdapters.MiMo;
using Router.ProviderAdapters.ModelStudio;
using Router.ProviderAdapters.OpenAI;
using Router.ProviderAdapters.OpenRouter;
using Router.Registries;
using Xunit;

namespace Router.Execution.Tests;

/// <summary>
/// Exact production final-URI contract for the existing providers. Every
/// case composes the repository-approved base URL with the concrete provider
/// adapter request path and asserts the exact <see cref="UpstreamRequest.FullUri"/>.
/// These tests are pure URI construction: no transport, no outbound call, and
/// no network of any kind.
/// </summary>
public sealed class RouterExecutionEndpointContractTests
{
    public static TheoryData<string, string, string, string> ProductionEndpointCases
    {
        get
        {
            var cases = new TheoryData<string, string, string, string>
            {
                { "mm_openai_api", RouterExecutionEndpoints.OpenAiBaseUrlReference, OpenAICapabilities.UpstreamPath, "https://api.openai.com/v1/responses" },
                { "mm_modelstudio", RouterExecutionEndpoints.ModelStudioBaseUrlReference, ModelStudioCapabilities.UpstreamPath, "https://dashscope.aliyuncs.com/compatible-mode/v1/responses" },
                { "mm_openrouter", RouterExecutionEndpoints.OpenRouterBaseUrlReference, OpenRouterCapabilities.UpstreamPath, "https://openrouter.ai/api/v1/responses" },
                { "mm_mimo", RouterExecutionEndpoints.MiMoBaseUrlReference, MiMoCapabilities.UpstreamPath, "https://api.xiaomimimo.com/v1/responses" },
                { "deepseek", RouterExecutionEndpoints.DeepSeekBaseUrlReference, DeepSeekCapabilities.UpstreamPath, "https://api.deepseek.com/responses" },
            };
            return cases;
        }
    }

    [Theory]
    [MemberData(nameof(ProductionEndpointCases))]
    public void Production_base_url_plus_adapter_request_path_composes_exact_responses_uri(
        string providerId,
        string baseUrlRef,
        string adapterRequestPath,
        string expectedUri)
    {
        // Endpoint registry entry -> approved production endpoint source (no
        // test override) -> concrete adapter request path -> UpstreamRequest.
        var source = new RouterExecutionEndpointSource();
        var endpointEntry = new EndpointRegistryEntry
        {
            EndpointId = "endpoint." + providerId + ".production-contract",
            BaseUrlRef = baseUrlRef,
            Enabled = true,
            DataBoundary = "provider-default",
            TlsRequired = true,
            Priority = 100,
            Weight = 100,
            Version = 1,
        };

        Result<UpstreamEndpoint, RouterError> resolved = source.Resolve(endpointEntry);
        Assert.True(resolved.IsSuccess, providerId + ": " + resolved.Error?.Code + " / " + resolved.Error?.Message);
        Assert.False(resolved.Value!.LoopbackTestOnly);

        UpstreamRequest request = UpstreamRequest.Create("POST", resolved.Value, adapterRequestPath);
        Assert.Equal(expectedUri, request.FullUri.AbsoluteUri);
    }
}
