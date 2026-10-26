namespace Router.ProtocolAdapters.Abstractions;

/// <summary>
/// Stable reason codes for a semantic-loss detection. Reasons are typed and
/// content-free; they never include prompts, tool payloads, or raw bodies.
/// </summary>
public static class SemanticLossReason
{
    public const string UnsupportedCapability = "unsupported_capability";
    public const string UnsupportedParameter = "unsupported_parameter";
    public const string MultimodalUnsupported = "multimodal_unsupported";
    public const string ReasoningUnsupported = "reasoning_unsupported";
    public const string ToolUnsupported = "tool_unsupported";
    public const string StreamingUnsupported = "streaming_unsupported";
    public const string UnknownEvent = "unknown_event";
    public const string BackgroundUnsupported = "background_unsupported";
}

/// <summary>
/// One detected semantic loss. LR-8 always fails closed when a loss is
/// reported; there is no best-effort or lossy path.
/// </summary>
public sealed record SemanticLoss
{
    public required string Capability { get; init; }

    public required string Reason { get; init; }

    public static SemanticLoss Create(string capability, string reason)
        => new() { Capability = capability, Reason = reason };
}
