using Router.Core.Errors;

namespace Router.Secrets;

/// <summary>
/// Environment secret resolver. No caching: every call reads the current
/// environment, so rotation is observed immediately. For <c>user_or_process</c>
/// the precedence is process first, then user (the existing Manager convention).
/// Machine scope is never read.
/// </summary>
public sealed class EnvironmentSecretResolver : ISecretResolver
{
    private readonly IEnvironment _environment;

    public EnvironmentSecretResolver(IEnvironment environment)
    {
        _environment = environment ?? throw new ArgumentNullException(nameof(environment));
    }

    public Task<SecretResolutionResult> ResolveAsync(SecretReference reference, string providerId, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        RouterError? shapeError = SecretReferenceValidator.Validate(reference);
        if (shapeError is not null)
        {
            return Task.FromResult(new SecretResolutionResult(null, shapeError));
        }

        bool allowed = EnvironmentSecretAllowlist.IsProviderSecretAllowed(providerId, reference.Name)
            || (string.Equals(providerId, EnvironmentSecretAllowlist.LocalRouterProviderId, StringComparison.Ordinal)
                && EnvironmentSecretAllowlist.IsLocalRouterTokenReferenceAllowed(reference.Name));
        if (!allowed)
        {
            return Task.FromResult(new SecretResolutionResult(null, SecretErrors.ScopeViolation(reference.Name)));
        }

        string? value = reference.Scope switch
        {
            SecretScope.Process => _environment.GetVariable(reference.Name, SecretScope.Process),
            SecretScope.User => _environment.GetVariable(reference.Name, SecretScope.User),
            SecretScope.UserOrProcess => _environment.GetVariable(reference.Name, SecretScope.Process)
                ?? _environment.GetVariable(reference.Name, SecretScope.User),
            _ => throw new ArgumentOutOfRangeException(nameof(reference)),
        };

        if (string.IsNullOrEmpty(value))
        {
            return Task.FromResult(new SecretResolutionResult(null, SecretErrors.Missing(reference.Name)));
        }

        return Task.FromResult(new SecretResolutionResult(SecretHandle.FromValue(value), null));
    }
}
