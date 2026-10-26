using System.Text.RegularExpressions;
using Router.Core.Errors;

namespace Router.Secrets;

/// <summary>
/// Shape validation for <see cref="SecretReference"/>. Rejects inline values,
/// interpolation syntax, paths, registry/expression shapes, and arbitrary names.
/// </summary>
public static class SecretReferenceValidator
{
    public const string EnvironmentResolver = "environment";
    public const int MaxNameLength = 128;
    public const int MaxProviderIdLength = 64;

    private static readonly Regex NamePattern =
        new("^[A-Z][A-Z0-9_]{2,127}$", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly Regex ProviderIdPattern =
        new("^[a-z][a-z0-9_]*$", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    /// <summary>Returns a normalized error when the reference shape is invalid; otherwise null.</summary>
    public static RouterError? Validate(SecretReference reference)
    {
        if (reference is null)
        {
            return SecretErrors.ReferenceInvalid();
        }

        if (!string.Equals(reference.Resolver, EnvironmentResolver, StringComparison.Ordinal))
        {
            return SecretErrors.ReferenceInvalid("resolver");
        }

        if (string.IsNullOrEmpty(reference.Name)
            || reference.Name.Length > MaxNameLength
            || !NamePattern.IsMatch(reference.Name))
        {
            return SecretErrors.ReferenceInvalid("name");
        }

        if (reference.AllowedProviderIds.Count == 0
            || reference.AllowedProviderIds.Any(static id =>
                string.IsNullOrEmpty(id) || id.Length > MaxProviderIdLength || !ProviderIdPattern.IsMatch(id)))
        {
            return SecretErrors.ReferenceInvalid("allowed_provider_ids");
        }

        if (reference.Version < 1)
        {
            return SecretErrors.ReferenceInvalid("version");
        }

        return null;
    }
}
