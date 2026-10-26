using Router.Core.Support;
using Xunit;

namespace Router.Core.Tests.Support;

/// <summary>
/// DSR7-C-FIX4: custom tool identity is a closed, exact mapping. Only the
/// literal <c>apply_patch</c> is recognized; nothing else - case variants,
/// separators, secret-shaped strings, URLs or overlong input - can be promoted,
/// and the raw name is never echoed.
/// </summary>
public sealed class SafeCustomToolIdentityClassifierTests
{
    [Fact]
    public void Apply_patch_is_the_only_recognized_identity()
    {
        Assert.Equal("apply_patch", SafeCustomToolIdentityClassifier.Classify("apply_patch"));
        Assert.Equal(2, SafeCustomToolIdentityClassifier.Identities.Count);
    }

    [Theory]
    [InlineData("Apply_Patch")]
    [InlineData("APPLY_PATCH")]
    [InlineData("apply-patch")]
    [InlineData("apply patch")]
    [InlineData("apply_patch ")]
    [InlineData(" apply_patch")]
    [InlineData("patch")]
    [InlineData("shell")]
    [InlineData("SUPER_SECRET_TOOL_NAME")]
    [InlineData("sk-test-DO_NOT_LEAK")]
    [InlineData("https://secret.example/private")]
    [InlineData("resp_secret_123")]
    [InlineData("")]
    [InlineData(null)]
    public void Everything_else_collapses_to_unknown_custom(string? rawName)
    {
        string identity = SafeCustomToolIdentityClassifier.Classify(rawName);

        Assert.Equal("unknown_custom", identity);
        if (!string.IsNullOrEmpty(rawName))
        {
            Assert.DoesNotContain(rawName, identity, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void Overlong_name_collapses_to_the_fixed_fallback()
    {
        string rawName = new string('a', 10_000);

        string identity = SafeCustomToolIdentityClassifier.Classify(rawName);

        Assert.Equal("unknown_custom", identity);
        Assert.True(identity.Length < 32);
    }

    [Fact]
    public void Only_allowlisted_identities_are_ever_emitted()
    {
        foreach (string rawName in new[] { "apply_patch", "nope", "SUPER_SECRET_TOOL_NAME", "https://secret.example/private" })
        {
            Assert.True(SafeCustomToolIdentityClassifier.IsKnownIdentity(SafeCustomToolIdentityClassifier.Classify(rawName)));
        }

        Assert.False(SafeCustomToolIdentityClassifier.IsKnownIdentity("apply_patch "));
        Assert.False(SafeCustomToolIdentityClassifier.IsKnownIdentity("Apply_Patch"));
        Assert.False(SafeCustomToolIdentityClassifier.IsKnownIdentity("SUPER_SECRET_TOOL_NAME"));
        Assert.False(SafeCustomToolIdentityClassifier.IsKnownIdentity(null));
    }
}
