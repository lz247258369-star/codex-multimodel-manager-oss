namespace Router.Core.Support;

/// <summary>
/// DSR7-C-FIX4: maps the direct <c>name</c> of a REJECTED <c>custom</c> tool onto
/// a FIXED identity label.
///
/// The custom tool name is request content, so it is never stored. The mapping is
/// deliberately minimal and exact:
/// <list type="bullet">
///   <item><c>apply_patch</c> (ordinal, exact) -> <see cref="ApplyPatch"/></item>
///   <item>everything else -> <see cref="UnknownCustom"/></item>
/// </list>
/// There is no case folding, no trimming, no substring matching, no regex
/// capture, no fuzzy matching and no hashing: a near-miss cannot be promoted,
/// and the raw name can never escape.
/// </summary>
public static class SafeCustomToolIdentityClassifier
{
    /// <summary>The only explicitly recognized custom tool identity.</summary>
    public const string ApplyPatch = "apply_patch";

    /// <summary>Fixed fallback for every other custom tool name.</summary>
    public const string UnknownCustom = "unknown_custom";

    private static readonly HashSet<string> KnownIdentities = new(StringComparer.Ordinal)
    {
        ApplyPatch,
        UnknownCustom,
    };

    /// <summary>All identities this classifier can ever emit.</summary>
    public static IReadOnlyCollection<string> Identities => KnownIdentities;

    /// <summary>
    /// Classifies a rejected custom tool name. The result is always one of
    /// <see cref="Identities"/>; the raw name is never echoed.
    /// </summary>
    public static string Classify(string? rawName)
        => string.Equals(rawName, ApplyPatch, StringComparison.Ordinal) ? ApplyPatch : UnknownCustom;

    /// <summary>True only for an identity this classifier is allowed to emit.</summary>
    public static bool IsKnownIdentity(string? candidate)
        => candidate is not null && KnownIdentities.Contains(candidate);
}
