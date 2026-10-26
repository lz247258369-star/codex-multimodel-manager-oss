using System.Text.Json.Serialization;

namespace Router.ClientAdapters.Responses;

/// <summary>
/// Canonical non-stream Responses response. Field names serialize to the
/// OpenAI Responses snake_case shape; values are synthetic or normalized.
/// </summary>
public sealed record CanonicalResponsesResponse
{
    public required string Id { get; init; }

    [JsonPropertyName("object")]
    public required string ObjectType { get; init; }

    /// <summary>Unix seconds when the response was created.</summary>
    public required long CreatedAt { get; init; }

    /// <summary><c>completed</c> or <c>failed</c>.</summary>
    public required string Status { get; init; }

    public required string Model { get; init; }

    public IReadOnlyList<ResponseOutputItem> Output { get; init; } = [];

    public UsageRecord? Usage { get; init; }

    /// <summary>Safe normalized error code for failed responses; never raw text.</summary>
    public string? ErrorCode { get; init; }

    /// <summary>Safe content-free message for failed responses.</summary>
    public string? ErrorMessage { get; init; }
}

/// <summary>Canonical response output item base.</summary>
public abstract record ResponseOutputItem
{
    public required string Type { get; init; }

    public string? Id { get; init; }
}

/// <summary>Assistant message output with text parts.</summary>
public sealed record MessageOutputItem : ResponseOutputItem
{
    public required string Role { get; init; }

    public required IReadOnlyList<OutputTextPart> Content { get; init; }
}

/// <summary>Reasoning summary output item (represented, never logged).</summary>
public sealed record ReasoningOutputItem : ResponseOutputItem
{
    public required IReadOnlyList<SummaryTextPart> Summary { get; init; }
}

/// <summary>Function call output item (response side).</summary>
public sealed record FunctionCallResponseItem : ResponseOutputItem
{
    public required string CallId { get; init; }

    public required string Name { get; init; }

    public required string Arguments { get; init; }
}

/// <summary>
/// DSR7-C-FIX5-A: restored Codex freeform tool call. A provider compatibility
/// bridge emits this instead of the Router-owned synthetic function call, so the
/// client never sees the synthetic identity. Only <c>apply_patch</c> is
/// representable; <see cref="Input"/> is the raw patch text (request content,
/// never logged).
/// </summary>
public sealed record CustomToolCallResponseItem : ResponseOutputItem
{
    public required string CallId { get; init; }

    /// <summary>Always <see cref="ApplyPatchBridgeContract.ApplyPatchToolName"/>.</summary>
    public required string Name { get; init; }

    /// <summary>The raw patch text handed back to Codex for execution.</summary>
    public required string Input { get; init; }
}

/// <summary>Output text part.</summary>
public sealed record OutputTextPart
{
    public required string Type { get; init; }

    public required string Text { get; init; }

    public IReadOnlyList<string> Annotations { get; init; } = [];
}

/// <summary>Canonical usage summary. Unknown values remain null, never zero.</summary>
public sealed record UsageRecord
{
    public int? InputTokens { get; init; }

    public int? OutputTokens { get; init; }

    public int? TotalTokens { get; init; }

    public int? CachedTokens { get; init; }

    public int? ReasoningTokens { get; init; }
}
