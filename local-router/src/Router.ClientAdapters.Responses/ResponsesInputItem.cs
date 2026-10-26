using System.Text.Json;

namespace Router.ClientAdapters.Responses;

/// <summary>Canonical input item base. Only supported item shapes are produced.</summary>
public abstract record ResponsesInputItem
{
    public required string Type { get; init; }
}

/// <summary>Message item with text content parts.</summary>
public sealed record MessageInputItem : ResponsesInputItem
{
    public required string Role { get; init; }

    public required IReadOnlyList<TextContentPart> Content { get; init; }
}

/// <summary>Function call produced by a model (preserved as data).</summary>
public sealed record FunctionCallInputItem : ResponsesInputItem
{
    public required string CallId { get; init; }

    public required string Name { get; init; }

    /// <summary>JSON arguments string, preserved verbatim.</summary>
    public required string Arguments { get; init; }
}

/// <summary>Function call result supplied by the client (preserved as data).</summary>
public sealed record FunctionCallOutputItem : ResponsesInputItem
{
    public required string CallId { get; init; }

    public required string Output { get; init; }
}

/// <summary>
/// DSR7-C-FIX5-A: a Codex freeform tool call replayed by the client after the
/// Router restored it. Only <c>apply_patch</c> is representable; the input is the
/// raw patch text (request content, never logged).
/// </summary>
public sealed record CustomToolCallInputItem : ResponsesInputItem
{
    public string? Id { get; init; }

    public required string CallId { get; init; }

    /// <summary>Always <see cref="ApplyPatchBridgeContract.ApplyPatchToolName"/>.</summary>
    public required string Name { get; init; }

    /// <summary>The raw patch text as supplied by the client.</summary>
    public required string Input { get; init; }
}

/// <summary>
/// DSR7-C-FIX5-A: the client's result for a restored freeform tool call. The
/// output is preserved as JSON data (it is not guaranteed to be a string) and is
/// never logged.
/// </summary>
public sealed record CustomToolCallOutputInputItem : ResponsesInputItem
{
    public required string CallId { get; init; }

    public required JsonElement Output { get; init; }
}

/// <summary>Reasoning summary input item (represented, never logged).</summary>
public sealed record ReasoningInputItem : ResponsesInputItem
{
    public string? Id { get; init; }

    public required IReadOnlyList<SummaryTextPart> Summary { get; init; }
}

/// <summary>Text content part inside a message item.</summary>
public sealed record TextContentPart
{
    /// <summary>Either <c>input_text</c> or <c>output_text</c>.</summary>
    public required string Type { get; init; }

    public required string Text { get; init; }
}

/// <summary>Summary text part inside a reasoning item.</summary>
public sealed record SummaryTextPart
{
    public required string Type { get; init; }

    public required string Text { get; init; }
}
