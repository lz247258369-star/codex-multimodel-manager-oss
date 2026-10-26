using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.Responses;
using Router.Registries;

namespace Router.ProviderAdapters.DeepSeek;

/// <summary>
/// Direct DeepSeek official (<c>deepseek</c>) Responses-compatible provider
/// adapter. Identity is exact and reused from the existing Manager provider
/// identity; the adapter never infers a provider, model, or adapter from names
/// and never performs automatic endpoint or region selection. All traffic goes
/// through <see cref="IUpstreamTransport"/>; no live DeepSeek request is ever
/// made by this adapter or its tests.
/// </summary>
public sealed class DeepSeekProviderAdapter : ResponsesCompatibleProviderAdapterBase
{
    public const string AdapterId = "adapter.provider.deepseek.responses.v1";
    public const string AdapterVersion = "1.0";
    public const string ProviderId = "deepseek";
    public const string ProtocolId = "protocol.openai.responses.v1";

    public DeepSeekProviderAdapter(string? requestPath = null)
        : base(requestPath ?? DeepSeekCapabilities.UpstreamPath)
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
        Description = "Direct DeepSeek official (deepseek) Responses-compatible provider adapter.",
    };

    /// <summary>
    /// Executes one attempt. Revalidates the explicit configured DeepSeek
    /// endpoint and fails closed when the request demands a capability the
    /// resolved route does not declare (streaming, reasoning, or tools).
    ///
    /// DSR7-C-FIX5-B1b-1: this is the only adapter that can bridge Codex's
    /// freeform <c>apply_patch</c> tool. The bridge requires the provider's
    /// declared compatibility bridge capability, a DeepSeek provider route, a
    /// route that declares <c>tools</c>, and a non-streaming request; everything
    /// else fails closed before the transport is touched, and the canonical
    /// request is never modified in place.
    ///
    /// DSR7-C-FIX5-B1b-2: the return half of the same bridge. A non-stream
    /// response that carries the Router-owned synthetic function call is restored
    /// to the freeform <c>custom_tool_call</c> the client expects - but only when
    /// this attempt really enabled the bridge. Without an active bridge the
    /// reserved identity is a synthetic injection and the response fails closed.
    ///
    /// DSR7-C-FIX5-B2: the same return half for a streamed attempt. The synthetic
    /// call is buffered and validated inside the DeepSeek compatibility layer and
    /// released as one fully restored item; the frozen client event vocabulary is
    /// never extended and ordinary events keep their order and their instances.
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

        bool bridgeIsActive = false;
        ProviderAdapterInvocation effectiveInvocation = invocation;
        if (invocation.Request.ApplyPatchTool is not null)
        {
            if (!ApplyPatchRequestBridge.IsEligible(invocation, DeepSeekCapabilities.SupportedCompatibilityBridges))
            {
                return ProviderAdapterResult.Failed(RouterError.UnsupportedCapability());
            }

            Result<CanonicalResponsesRequest, RouterError> bridged =
                ApplyPatchRequestBridge.CreateProviderLocalRequest(invocation.Request);
            if (bridged.Error is { } bridgeError)
            {
                return ProviderAdapterResult.Failed(bridgeError);
            }

            bridgeIsActive = true;
            effectiveInvocation = invocation with { Request = bridged.Value! };
        }

        Result<UpstreamEndpoint, RouterError> validated = DeepSeekEndpointValidator.Validate(
            invocation.Endpoint.Uri,
            invocation.Endpoint.LoopbackTestOnly);
        if (validated.Error is { } endpointError)
        {
            return ProviderAdapterResult.Failed(endpointError);
        }

        ProviderAdapterResult result = await base
            .InvokeAsync(effectiveInvocation with { Endpoint = validated.Value! }, cancellationToken)
            .ConfigureAwait(false);

        if (result.EventStream is { } providerEvents)
        {
            return ProviderAdapterResult.Stream(
                ApplyPatchStreamBridge.Apply(providerEvents, bridgeIsActive, cancellationToken));
        }

        // Every adapter error is returned untouched; only a decoded non-stream
        // response can carry a restorable synthetic call.
        return ApplyPatchResponseBridge.Apply(result, bridgeIsActive);
    }
}
