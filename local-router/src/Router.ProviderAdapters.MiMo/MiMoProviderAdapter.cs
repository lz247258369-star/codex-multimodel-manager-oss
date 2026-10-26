using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.Responses;
using Router.Registries;

namespace Router.ProviderAdapters.MiMo;

/// <summary>
/// LR-7B Xiaomi MiMo (<c>mm_mimo</c>) Responses-compatible provider adapter.
/// Identity is exact and reused from the existing Manager provider model; the
/// adapter never infers a provider, model, or adapter from names and never
/// performs automatic endpoint selection. All traffic goes through
/// <see cref="IUpstreamTransport"/>; no live MiMo request is ever made by this
/// adapter or its tests.
/// </summary>
public sealed class MiMoProviderAdapter : ResponsesCompatibleProviderAdapterBase
{
    public const string AdapterId = "adapter.provider.mm_mimo.responses.v1";
    public const string AdapterVersion = "1.0";
    public const string ProviderId = "mm_mimo";
    public const string ProtocolId = "protocol.openai.responses.v1";

    public MiMoProviderAdapter(string? requestPath = null)
        : base(requestPath ?? MiMoCapabilities.UpstreamPath)
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
        Description = "Xiaomi MiMo (mm_mimo) Responses-compatible provider adapter (LR-7B).",
    };

    /// <summary>
    /// Executes one attempt. Revalidates the explicit configured MiMo endpoint
    /// and fails closed when the request demands a capability the resolved
    /// route does not declare (streaming, reasoning, or tools).
    /// </summary>
    public override async Task<ProviderAdapterResult> InvokeAsync(
        ProviderAdapterInvocation invocation,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(invocation);

        if (invocation.Request.Stream && !invocation.Route.EffectiveCapabilities.Contains("streaming"))
        {
            return ProviderAdapterResult.Failed(RouterError.UnsupportedCapability());
        }

        if (invocation.Request.Reasoning is not null && !invocation.Route.EffectiveCapabilities.Contains("reasoning"))
        {
            return ProviderAdapterResult.Failed(RouterError.UnsupportedCapability());
        }

        if ((invocation.Request.Tools.Count > 0 || invocation.Request.ToolChoice is not null)
            && !invocation.Route.EffectiveCapabilities.Contains("tools"))
        {
            return ProviderAdapterResult.Failed(RouterError.UnsupportedCapability());
        }

        Result<UpstreamEndpoint, RouterError> validated = MiMoEndpointValidator.Validate(
            invocation.Endpoint.Uri,
            invocation.Endpoint.LoopbackTestOnly);
        if (validated.Error is { } endpointError)
        {
            return ProviderAdapterResult.Failed(endpointError);
        }

        return await base.InvokeAsync(invocation with { Endpoint = validated.Value! }, cancellationToken)
            .ConfigureAwait(false);
    }
}
