using Router.Registries;

namespace Router.ProviderAdapters.DeepSeek;

/// <summary>
/// DeepSeek official (<c>deepseek</c>) capability truth table for the
/// Responses-compatible V1 adapter. The upstream path is the provider's
/// official <c>/responses</c> route composed against
/// <c>https://api.deepseek.com</c>; the legacy <c>/v1</c> Chat Completions
/// surface is never used and no protocol conversion exists. Any capability not
/// listed here fails closed and is never silently dropped. The model identity
/// (<c>deepseek-flash</c>, <c>deepseek-v4-pro</c>, or any configured upstream
/// model) is never used to infer the provider or rewrite a route, and this
/// adapter never performs client-slug to upstream-ID aliasing: that mapping
/// belongs to the routing/model-route layer.
/// </summary>
public static class DeepSeekCapabilities
{
    /// <summary>Canonical upstream path for the DeepSeek official Responses API.</summary>
    public const string UpstreamPath = "/responses";

    /// <summary>Repository-approved base-url reference name (never a value).</summary>
    public const string BaseUrlReference = "provider-config:deepseek.base_url";

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

    /// <summary>
    /// DSR7-C-FIX5-A: the explicit compatibility bridge this provider declares.
    ///
    /// This is deliberately NOT a broadening of <c>tools</c>: <c>tools</c> means
    /// ordinary function tools, and a custom tool is only representable when the
    /// provider declares this exact bridge capability. The namespace is
    /// Router-owned and mirrors the canonical client adapter contract.
    /// </summary>
    public const string ApplyPatchCompatBridge = "apply_patch_compat_bridge";

    /// <summary>
    /// Compatibility bridges this provider declares. No other provider declares
    /// one, so a canonical apply_patch tool fails closed everywhere else.
    /// </summary>
    public static CapabilitySet SupportedCompatibilityBridges { get; } = CapabilitySet.From(
    [
        ApplyPatchCompatBridge,
    ]);
}
