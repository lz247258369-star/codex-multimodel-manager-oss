using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.Responses;
using Router.Registries;

namespace Router.ProviderAdapters.OpenRouter;

/// <summary>
/// LR-6 OpenRouter (<c>mm_openrouter</c>) Responses-compatible provider
/// adapter. Identity is exact and reused from the existing Manager provider
/// model; the adapter never infers a provider, model, or adapter from names.
/// All traffic goes through <see cref="IUpstreamTransport"/>; no live
/// OpenRouter request is ever made by this adapter or its tests.
/// </summary>
public sealed class OpenRouterProviderAdapter : ResponsesCompatibleProviderAdapterBase
{
    public const string AdapterId = "adapter.provider.mm_openrouter.responses.v1";
    public const string AdapterVersion = "1.0";
    public const string ProviderId = "mm_openrouter";
    public const string ProtocolId = "protocol.openai.responses.v1";

    public OpenRouterProviderAdapter(string? requestPath = null)
        : base(requestPath ?? OpenRouterCapabilities.UpstreamPath)
    {
    }

    public override ProviderAdapterDescriptor Descriptor { get; } = new()
    {
        AdapterId = AdapterId,
        AdapterVersion = AdapterVersion,
        ProviderId = ProviderId,
        ProtocolId = ProtocolId,
        Capabilities = CapabilitySet.From(
        [
            "responses", "text", "streaming", "reasoning", "tools", "usage", "cancellation",
        ]),
        RequestSemantics = RequestSemantics.Both,
        ResponseSemantics = ResponseSemantics.Both,
        EndpointRequirement = EndpointRequirement.HttpsWithTestLoopback,
        SecretRequirement = SecretRequirement.RequiresProviderSecret,
        CancellationSupport = CancellationSupport.Full,
        UsageSupport = UsageSupport.Canonical,
        Eligible = true,
        Description = "OpenRouter (mm_openrouter) Responses-compatible provider adapter (LR-6).",
    };
}
