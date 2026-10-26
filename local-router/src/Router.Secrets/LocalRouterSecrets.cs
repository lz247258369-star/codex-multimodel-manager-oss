namespace Router.Secrets;

/// <summary>
/// Secret-reference helpers for the local client bearer token. The token value
/// never appears in config, state, logs, errors, or fixtures; only the
/// reference name is used.
/// </summary>
public static class LocalRouterSecrets
{
    /// <summary>Provider identity used when resolving the local router token.</summary>
    public const string ProviderId = EnvironmentSecretAllowlist.LocalRouterProviderId;

    /// <summary>Creates the schema-v1 environment reference for the local token.</summary>
    public static SecretReference CreateTokenReference(string tokenReferenceName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(tokenReferenceName);
        return new SecretReference
        {
            Resolver = SecretReferenceValidator.EnvironmentResolver,
            Name = tokenReferenceName,
            Scope = SecretScope.UserOrProcess,
            AllowedProviderIds = [ProviderId],
            Version = 1,
        };
    }
}
