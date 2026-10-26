using Router.ProtocolAdapters.Abstractions;

namespace Router.ProtocolAdapters.Responses;

/// <summary>
/// Reserved future protocol placeholders. Placeholders have no capabilities,
/// are never eligible, and can never resolve, route, execute, or convert.
/// Anthropic Messages is a placeholder only; no conversion implementation
/// exists in LR-8.
/// </summary>
public static class FutureProtocolPlaceholders
{
    public static ProtocolAdapterDescriptor AnthropicMessagesV1 { get; } = new()
    {
        AdapterId = "adapter.protocol.anthropic.messages.v1",
        AdapterVersion = "0.0",
        CanonicalProtocolId = ResponsesProtocolCapabilities.CanonicalProtocolId,
        UpstreamProtocolId = "protocol.anthropic.messages.v1",
        Capabilities = Router.Registries.CapabilitySet.Empty,
        LossPolicy = ProtocolLossPolicy.LosslessOnly,
        Eligible = false,
        Description = "Reserved Anthropic Messages protocol placeholder (not implemented).",
    };
}
