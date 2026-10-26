using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.ProtocolAdapters.Abstractions;
using Router.Registries;

namespace Router.ProtocolAdapters.Responses;

/// <summary>
/// LR-8 Responses-to-Responses protocol adapter. Canonical semantics and
/// upstream Responses semantics are the same protocol family, so the mapping
/// is an exact, lossless pass-through/normalization: no text/reasoning/tool
/// conversion, no silent downgrade, no vendor branching. The protocol adapter
/// never touches secrets, HTTP, endpoints, providers, retry, failover, or
/// health.
/// </summary>
public sealed class ResponsesProtocolAdapter : IResponsesProtocolAdapter
{
    public ProtocolAdapterDescriptor Descriptor { get; } = new()
    {
        AdapterId = ResponsesProtocolCapabilities.AdapterId,
        AdapterVersion = ResponsesProtocolCapabilities.AdapterVersion,
        CanonicalProtocolId = ResponsesProtocolCapabilities.CanonicalProtocolId,
        UpstreamProtocolId = ResponsesProtocolCapabilities.UpstreamProtocolId,
        Capabilities = ResponsesProtocolCapabilities.V1,
        LossPolicy = ProtocolLossPolicy.LosslessOnly,
        Eligible = true,
        Description = "Lossless Responses-to-Responses protocol adapter (LR-8).",
    };

    public Result<CanonicalResponsesRequest, RouterError> MapRequest(CanonicalResponsesRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        SemanticLoss? loss = SemanticLossDetector.Detect(request, Descriptor.Capabilities);
        if (loss is not null)
        {
            return new Result<CanonicalResponsesRequest, RouterError>
            {
                Error = ProtocolAdapterErrors.SemanticLoss(loss.Capability),
            };
        }

        // Canonical and upstream semantics are identical; exact pass-through.
        return new Result<CanonicalResponsesRequest, RouterError> { Value = request };
    }

    public Result<CanonicalResponsesResponse, RouterError> MapResponse(CanonicalResponsesResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);

        if (response.Status is not ("completed" or "failed"))
        {
            return new Result<CanonicalResponsesResponse, RouterError>
            {
                Error = ProtocolAdapterErrors.SemanticLoss("status"),
            };
        }

        return new Result<CanonicalResponsesResponse, RouterError> { Value = response };
    }

    public Result<CanonicalEvent, RouterError> MapEvent(CanonicalEvent canonicalEvent)
    {
        ArgumentNullException.ThrowIfNull(canonicalEvent);

        SemanticLoss? loss = SemanticLossDetector.DetectEvent(canonicalEvent);
        if (loss is not null)
        {
            return new Result<CanonicalEvent, RouterError>
            {
                Error = ProtocolAdapterErrors.SemanticLoss(loss.Capability),
            };
        }

        return new Result<CanonicalEvent, RouterError> { Value = canonicalEvent };
    }
}
