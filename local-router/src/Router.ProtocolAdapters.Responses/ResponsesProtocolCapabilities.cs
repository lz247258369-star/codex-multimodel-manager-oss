using Router.Registries;

namespace Router.ProtocolAdapters.Responses;

/// <summary>
/// Frozen LR-8 capability matrix for the Responses-to-Responses protocol
/// adapter. Text, streaming, reasoning, tools, usage, and cancellation are
/// supported; multimodal and background semantics are unsupported and fail
/// closed. No provider-specific capability is listed here.
/// </summary>
public static class ResponsesProtocolCapabilities
{
    public const string CanonicalProtocolId = "protocol.openai.responses.v1";
    public const string UpstreamProtocolId = "protocol.openai.responses.v1";
    public const string AdapterId = "adapter.protocol.responses-compatible.v1";
    public const string AdapterVersion = "1.0";

    public static CapabilitySet V1 { get; } = CapabilitySet.From(
    [
        "responses", "text", "streaming", "reasoning", "tools", "usage", "cancellation",
    ]);

    /// <summary>Supported input content-part types (text only; no image fallback).</summary>
    public static IReadOnlyList<string> SupportedInputPartTypes { get; } =
    [
        "input_text", "output_text",
    ];

    /// <summary>Explicitly unsupported semantics; presence always fails closed.</summary>
    public static IReadOnlyList<string> UnsupportedSemantics { get; } =
    [
        "multimodal", "background",
    ];
}
