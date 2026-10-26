namespace Router.Core.Support;

/// <summary>
/// DSR7-C-FIX3: maps a raw, rejected non-function Responses tool type onto a
/// FIXED taxonomy label.
///
/// The raw value is request content and must never be stored, so this is a
/// closed mapping with no pass-through path: there is no "return the input",
/// no lower-casing of the input, no truncation, no hashing and no prefixing.
/// Anything that is not an exact known label becomes
/// <see cref="UnknownNonFunction"/>.
///
/// The same fixed label set is what the local diagnostic record validates
/// against, so a value can only reach disk if it is one of these literals.
/// </summary>
public static class SafeToolTypeClassifier
{
    public const string Shell = "shell";
    public const string LocalShell = "local_shell";
    public const string ApplyPatch = "apply_patch";
    public const string Custom = "custom";
    public const string Mcp = "mcp";
    public const string WebSearch = "web_search";
    public const string WebSearchPreview = "web_search_preview";
    public const string FileSearch = "file_search";
    public const string Computer = "computer";
    public const string ComputerUsePreview = "computer_use_preview";
    public const string CodeInterpreter = "code_interpreter";
    public const string ImageGeneration = "image_generation";
    // DSR7-C-FIX6-B1: the two extra non-function types observed in the real
    // Codex Desktop taxonomy. They are recognised as fixed labels only - they
    // stay rejected, are never mapped to a function and are never forwarded.
    public const string Namespace = "namespace";
    public const string ToolSearch = "tool_search";

    /// <summary>Fixed fallback for any non-function type outside the taxonomy.</summary>
    public const string UnknownNonFunction = "unknown_non_function";

    private static readonly Dictionary<string, string> FixedMap = new(StringComparer.Ordinal)
    {
        [Shell] = Shell,
        [LocalShell] = LocalShell,
        [ApplyPatch] = ApplyPatch,
        [Custom] = Custom,
        [Mcp] = Mcp,
        [WebSearch] = WebSearch,
        [WebSearchPreview] = WebSearchPreview,
        [FileSearch] = FileSearch,
        [Computer] = Computer,
        [ComputerUsePreview] = ComputerUsePreview,
        [CodeInterpreter] = CodeInterpreter,
        [ImageGeneration] = ImageGeneration,
        [Namespace] = Namespace,
        [ToolSearch] = ToolSearch,
    };

    private static readonly HashSet<string> KnownLabels = new(FixedMap.Values, StringComparer.Ordinal)
    {
        UnknownNonFunction,
    };

    /// <summary>All labels this classifier can ever emit.</summary>
    public static IReadOnlyCollection<string> Labels => KnownLabels;

    /// <summary>
    /// Classifies a rejected non-function tool type. The returned value is always
    /// one of <see cref="Labels"/>; the raw input is never echoed.
    /// </summary>
    public static string Classify(string? rawToolType)
        => rawToolType is not null && FixedMap.TryGetValue(rawToolType, out string? label)
            ? label
            : UnknownNonFunction;

    /// <summary>True only for a label this classifier is allowed to emit.</summary>
    public static bool IsKnownLabel(string? candidate)
        => candidate is not null && KnownLabels.Contains(candidate);
}
