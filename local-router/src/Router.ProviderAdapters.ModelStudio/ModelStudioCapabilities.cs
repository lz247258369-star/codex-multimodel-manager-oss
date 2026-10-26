using Router.Registries;

namespace Router.ProviderAdapters.ModelStudio;

/// <summary>
/// Alibaba Model Studio (<c>mm_modelstudio</c>) capability truth table for the
/// Responses-compatible V1 adapter. Canonical Responses semantics only; no
/// Chat Completions or Coding Plan conversion exists. Any capability not
/// listed here fails closed and is never silently dropped. Model identity
/// (Qwen, DeepSeek, GLM, ...) is never used to infer the provider.
/// </summary>
public static class ModelStudioCapabilities
{
    /// <summary>Canonical upstream path for Responses-compatible Model Studio endpoints.</summary>
    public const string UpstreamPath = "/compatible-mode/v1/responses";

    /// <summary>Repository-approved base-url reference name (never a value).</summary>
    public const string BaseUrlReference = "provider-config:mm_modelstudio.base_url";

    /// <summary>
    /// Supported request semantics: model (from the resolved route's
    /// upstream_model_id only), text input, instructions, stream, reasoning
    /// (only when the route declares it), function tools and tool choice.
    /// Unknown fields are rejected by the canonical request model before the
    /// adapter is reached.
    /// </summary>
    public static CapabilitySet SupportedRequestSemantics { get; } = CapabilitySet.From(
    [
        "model", "text", "instructions", "stream", "reasoning", "tools", "tool_choice",
    ]);

    /// <summary>
    /// Supported response/event semantics: non-stream and SSE, text deltas,
    /// reasoning deltas, tool call deltas, usage, completed events, and
    /// normalized error events.
    /// </summary>
    public static CapabilitySet SupportedResponseSemantics { get; } = CapabilitySet.From(
    [
        "non_stream", "sse", "text_delta", "reasoning_delta", "tool_call_delta",
        "usage", "completed", "error_event",
    ]);

    /// <summary>Headers the adapter sends upstream (no blind client pass-through).</summary>
    public static IReadOnlyList<string> RequestHeaderAllowlist { get; } =
    [
        "Authorization", "Content-Type", "Accept",
    ];
}
