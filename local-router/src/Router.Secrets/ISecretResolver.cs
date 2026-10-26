using Router.Core.Errors;

namespace Router.Secrets;

/// <summary>Result of a secret resolution attempt.</summary>
public sealed record SecretResolutionResult(SecretHandle? Handle, RouterError? Error)
{
    public bool IsSuccess => Handle is not null && Error is null;
}

/// <summary>
/// Resolves a validated secret reference into an opaque handle. Implementations
/// must never write the value to config, state, logs, traces, or errors.
/// </summary>
public interface ISecretResolver
{
    Task<SecretResolutionResult> ResolveAsync(SecretReference reference, string providerId, CancellationToken cancellationToken);
}
