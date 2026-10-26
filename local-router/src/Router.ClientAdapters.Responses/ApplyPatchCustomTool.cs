namespace Router.ClientAdapters.Responses;

/// <summary>
/// DSR7-C-FIX5-A: the client-side contract for Codex's freeform
/// <c>apply_patch</c> custom tool.
///
/// The Router never executes a patch. This contract only represents the tool
/// definition, the canonical tool call, and the Router-owned synthetic function
/// identity that a provider compatibility bridge may use later (FIX5-B). The
/// grammar definition and description are request content: they may be sent
/// upstream by a bridge, but they are never logged, metered, diagnosed or
/// printed.
/// </summary>
public static class ApplyPatchBridgeContract
{
    /// <summary>Client wire type of the tool definition.</summary>
    public const string ClientToolType = "custom";

    /// <summary>The only accepted custom tool name for this bridge.</summary>
    public const string ApplyPatchToolName = "apply_patch";

    /// <summary>Client wire type of the restored tool call.</summary>
    public const string ClientToolCallType = "custom_tool_call";

    /// <summary>Client wire type of the tool call output.</summary>
    public const string ClientToolCallOutputType = "custom_tool_call_output";

    /// <summary>
    /// Router-owned synthetic upstream function name. A client may never use it.
    /// </summary>
    public const string SyntheticFunctionName = "mm_apply_patch_bridge_v1";

    /// <summary>Explicit capability name a provider must declare to be bridged.</summary>
    public const string CompatBridgeCapability = "apply_patch_compat_bridge";

    /// <summary>Required <c>format.type</c> value of the freeform tool.</summary>
    public const string RequiredFormatType = "grammar";

    /// <summary>Required <c>format.syntax</c> value.</summary>
    public const string RequiredFormatSyntax = "lark";

    /// <summary>Bounded description length accepted from the client.</summary>
    public const int MaxDescriptionLength = 4096;

    /// <summary>Bounded grammar definition length accepted from the client.</summary>
    public const int MaxFormatDefinitionLength = 65_536;

    /// <summary>True only for the reserved synthetic function name.</summary>
    public static bool IsReservedSyntheticName(string? name)
        => string.Equals(name, SyntheticFunctionName, StringComparison.Ordinal);
}

/// <summary>
/// Canonical representation of the accepted <c>custom</c>/<c>apply_patch</c>
/// tool definition. It is deliberately a distinct canonical type - never a
/// renamed <see cref="FunctionToolDefinition"/> - so the origin of the tool is
/// preserved in memory and can never be inferred back from a description.
///
/// The type is not serialized on the canonical wire: no bridge exists yet, and
/// a custom definition must never be forwarded upstream by accident.
/// </summary>
public sealed record ApplyPatchCustomToolDefinition
{
    /// <summary>Always <see cref="ApplyPatchBridgeContract.ApplyPatchToolName"/>.</summary>
    public required string Name { get; init; }

    public string? Description { get; init; }

    /// <summary>Always <c>grammar</c>.</summary>
    public required string FormatType { get; init; }

    /// <summary>Always <c>lark</c>.</summary>
    public required string FormatSyntax { get; init; }

    /// <summary>The freeform grammar body (request content; never logged).</summary>
    public required string FormatDefinition { get; init; }
}
