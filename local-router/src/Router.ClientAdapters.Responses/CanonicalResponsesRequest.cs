using System.Text.Json.Serialization;

namespace Router.ClientAdapters.Responses;

/// <summary>
/// Immutable canonical Responses request produced by the client adapter. It
/// contains semantic data only: no Authorization header, no raw secret, no
/// HttpContext, no socket, and no logger.
/// </summary>
public sealed record CanonicalResponsesRequest
{
    public required string Model { get; init; }

    public required IReadOnlyList<ResponsesInputItem> Input { get; init; }

    public bool Stream { get; init; }

    public string? Instructions { get; init; }

    public ReasoningRequest? Reasoning { get; init; }

    public IReadOnlyList<FunctionToolDefinition> Tools { get; init; } = [];

    /// <summary>
    /// DSR7-C-FIX5-A: the accepted Codex freeform <c>apply_patch</c> tool, when
    /// the client declared it. It is kept separate from <see cref="Tools"/> so its
    /// origin is never lost, and it is JSON-ignored on the canonical wire: until a
    /// provider bridge exists (FIX5-B) nothing may forward a custom definition
    /// upstream.
    /// </summary>
    [JsonIgnore]
    public ApplyPatchCustomToolDefinition? ApplyPatchTool { get; init; }

    public ToolChoice? ToolChoice { get; init; }

    /// <summary>
    /// Optional explicit upstream output-token budget (Responses
    /// <c>max_output_tokens</c>). Null means the client did not send a budget, and
    /// the Router must never invent a default or rewrite the value per provider.
    /// </summary>
    [JsonPropertyName("max_output_tokens")]
    public int? MaxOutputTokens { get; init; }

    public IReadOnlyDictionary<string, string> Metadata { get; init; } = new Dictionary<string, string>(StringComparer.Ordinal);
}
