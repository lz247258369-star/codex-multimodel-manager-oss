using System.Text.RegularExpressions;

namespace Router.Observability;

/// <summary>
/// Strict allowlist for a safe failure-diagnostic field path.
///
/// A diagnostic may name the capability field that failed closed, but it must
/// never carry request content. Only the exact shapes below are accepted:
/// <list type="bullet">
///   <item><c>background</c>, <c>store</c>, <c>modalities</c>, <c>previous_response_id</c>, <c>tool_choice.type</c></item>
///   <item><c>tools[&lt;n&gt;].type</c></item>
///   <item><c>input[&lt;n&gt;].type</c></item>
///   <item><c>input[&lt;n&gt;].content[&lt;m&gt;].type</c></item>
/// </list>
/// Everything else is rejected, so a value that ever leaked into the path
/// (for example <c>tools[0].type=web_search</c>, a URL, a tool name, or a
/// previous response id) can never reach the diagnostic log. Validation is
/// fail-closed and never throws.
/// </summary>
public static partial class SafeFailureDiagnosticPath
{
    /// <summary>Hard upper bound on an accepted path, well under any file cap.</summary>
    public const int MaxLength = 64;

    private static readonly HashSet<string> StaticPaths = new(StringComparer.Ordinal)
    {
        "background",
        "store",
        "modalities",
        "previous_response_id",
        "tool_choice.type",
    };

    [GeneratedRegex(@"^tools\[(?<index>[0-9]{1,6})\]\.type$", RegexOptions.CultureInvariant)]
    private static partial Regex ToolTypePath();

    [GeneratedRegex(@"^input\[(?<index>[0-9]{1,6})\]\.type$", RegexOptions.CultureInvariant)]
    private static partial Regex InputTypePath();

    [GeneratedRegex(@"^input\[(?<index>[0-9]{1,6})\]\.content\[(?<part>[0-9]{1,6})\]\.type$", RegexOptions.CultureInvariant)]
    private static partial Regex InputContentTypePath();

    /// <summary>True only for an exact, content-free capability field path.</summary>
    public static bool IsSafe(string? candidate)
    {
        if (string.IsNullOrEmpty(candidate) || candidate.Length > MaxLength)
        {
            return false;
        }

        // Reject whitespace, control characters, quotes, and any other byte that
        // is not part of the allowed grammar before pattern matching.
        foreach (char c in candidate)
        {
            if (c is not ((>= 'a' and <= 'z') or (>= '0' and <= '9') or '.' or '[' or ']' or '_'))
            {
                return false;
            }
        }

        if (StaticPaths.Contains(candidate))
        {
            return true;
        }

        return ToolTypePath().IsMatch(candidate)
            || InputTypePath().IsMatch(candidate)
            || InputContentTypePath().IsMatch(candidate);
    }

    /// <summary>
    /// True only for the tool-type shape <c>tools[&lt;n&gt;].type</c>, which is
    /// the single shape that may carry a classified tool-type label.
    /// </summary>
    public static bool IsToolTypePath(string? candidate)
        => !string.IsNullOrEmpty(candidate) && candidate.Length <= MaxLength && ToolTypePath().IsMatch(candidate);
}
