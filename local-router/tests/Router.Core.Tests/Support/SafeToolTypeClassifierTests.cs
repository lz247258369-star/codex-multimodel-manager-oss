using Router.Core.Support;
using Xunit;

namespace Router.Core.Tests.Support;

/// <summary>
/// DSR7-C-FIX3: the tool-type classifier is a closed mapping. Every known type
/// maps to its fixed label, and anything else - including secret-shaped or
/// overlong input - collapses to unknown_non_function without ever echoing the
/// raw value.
/// </summary>
public sealed class SafeToolTypeClassifierTests
{
    [Theory]
    [InlineData("shell", SafeToolTypeClassifier.Shell)]
    [InlineData("local_shell", SafeToolTypeClassifier.LocalShell)]
    [InlineData("apply_patch", SafeToolTypeClassifier.ApplyPatch)]
    [InlineData("custom", SafeToolTypeClassifier.Custom)]
    [InlineData("mcp", SafeToolTypeClassifier.Mcp)]
    [InlineData("web_search", SafeToolTypeClassifier.WebSearch)]
    [InlineData("web_search_preview", SafeToolTypeClassifier.WebSearchPreview)]
    [InlineData("file_search", SafeToolTypeClassifier.FileSearch)]
    [InlineData("computer", SafeToolTypeClassifier.Computer)]
    [InlineData("computer_use_preview", SafeToolTypeClassifier.ComputerUsePreview)]
    [InlineData("code_interpreter", SafeToolTypeClassifier.CodeInterpreter)]
    [InlineData("image_generation", SafeToolTypeClassifier.ImageGeneration)]
    // DSR7-C-FIX6-B1: the two extra non-function types the real Codex Desktop
    // taxonomy sends. They get an exact fixed label, so the local diagnostic can
    // name the category without ever storing the raw value.
    [InlineData("namespace", SafeToolTypeClassifier.Namespace)]
    [InlineData("tool_search", SafeToolTypeClassifier.ToolSearch)]
    public void Known_types_map_to_fixed_labels(string rawType, string expected)
    {
        Assert.Equal(expected, SafeToolTypeClassifier.Classify(rawType));
    }

    // DSR7-C-FIX6-B1: the new labels are exact and case-sensitive. A wrong case,
    // a hyphenated variant, a trailing space or a secret-shaped value must never
    // be normalised into a known category.
    [Theory]
    [InlineData("SUPER_SECRET_TOOL_TYPE")]
    [InlineData("sk-test-DO_NOT_LEAK")]
    [InlineData("https://secret.example/private")]
    [InlineData("Web_Search")]
    [InlineData("web-search")]
    [InlineData("shell ")]
    [InlineData("Namespace")]
    [InlineData("NAMESPACE")]
    [InlineData("namespace ")]
    [InlineData("namespaces")]
    [InlineData("Tool_Search")]
    [InlineData("TOOL_SEARCH")]
    [InlineData("tool-search")]
    [InlineData(" tool_search")]
    [InlineData("tool_search ")]
    [InlineData("sk-test-namespace-DO_NOT_LEAK")]
    [InlineData("")]
    [InlineData(null)]
    public void Unknown_types_collapse_to_the_fixed_fallback(string? rawType)
    {
        string label = SafeToolTypeClassifier.Classify(rawType);

        Assert.Equal(SafeToolTypeClassifier.UnknownNonFunction, label);
        if (!string.IsNullOrEmpty(rawType))
        {
            Assert.DoesNotContain(rawType, label, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void Overlong_type_collapses_to_the_fixed_fallback()
    {
        string rawType = "sk-test-" + new string('x', 5000);

        string label = SafeToolTypeClassifier.Classify(rawType);

        Assert.Equal(SafeToolTypeClassifier.UnknownNonFunction, label);
        Assert.True(label.Length < 32);
    }

    [Fact]
    public void Only_allowlisted_labels_are_ever_emitted()
    {
        foreach (string rawType in new[] { "local_shell", "nope", "SUPER_SECRET_TOOL_TYPE", "https://secret.example/private" })
        {
            Assert.True(SafeToolTypeClassifier.IsKnownLabel(SafeToolTypeClassifier.Classify(rawType)));
        }

        Assert.False(SafeToolTypeClassifier.IsKnownLabel("local_shell "));
        Assert.False(SafeToolTypeClassifier.IsKnownLabel("SUPER_SECRET_TOOL_TYPE"));
        Assert.False(SafeToolTypeClassifier.IsKnownLabel("Namespace"));
        Assert.False(SafeToolTypeClassifier.IsKnownLabel("TOOL_SEARCH"));
        Assert.False(SafeToolTypeClassifier.IsKnownLabel(null));
        Assert.Equal(15, SafeToolTypeClassifier.Labels.Count);
    }
}
