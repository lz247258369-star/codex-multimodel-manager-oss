using Router.Registries;

namespace Router.ProviderAdapters.OpenAI;

/// <summary>
/// OpenAI API (<c>mm_openai_api</c>) capability truth table for the
/// Responses-compatible V1 adapter. Canonical Responses semantics only; no
/// Chat Completions or account-protocol conversion exists. Any capability not
/// listed here fails closed and is never silently dropped. Account-mode
/// authentication is never used as an upstream secret.
/// </summary>
public static class OpenAICapabilities
{
    /// <summary>Canonical upstream path used by the adapter.</summary>
    public const string UpstreamPath = "/v1/responses";

    /// <summary>Repository-approved base-url reference name (never a value).</summary>
    public const string BaseUrlReference = "provider-config:mm_openai_api.base_url";

    /// <summary>
    /// Supported request semantics: model (from the resolved route's
    /// upstream_model_id only), text input, instructions, stream, reasoning
    /// (where the upstream declares equivalent semantics), function tools and
    /// tool choice, and safe metadata. Unknown fields are rejected by the
    /// canonical request model before the adapter is reached.
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
