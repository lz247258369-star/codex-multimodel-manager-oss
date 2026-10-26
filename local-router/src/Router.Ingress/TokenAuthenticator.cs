using System.Security.Cryptography;
using System.Text;
using Router.Core.Errors;
using Router.Secrets;

namespace Router.Ingress;

/// <summary>
/// Bearer token authenticator backed by the LR-2 secret resolver. Comparison
/// uses a fixed-time algorithm; failures never reveal length, prefix, or
/// character details. The token value never enters logs, errors, or responses.
/// </summary>
public sealed class TokenAuthenticator
{
    private const int MaxTokenLength = 1024;

    private readonly ISecretResolver _resolver;
    private readonly SecretReference _reference;

    public TokenAuthenticator(ISecretResolver resolver, SecretReference reference)
    {
        _resolver = resolver ?? throw new ArgumentNullException(nameof(resolver));
        _reference = reference ?? throw new ArgumentNullException(nameof(reference));
    }

    public async Task<TokenAuthenticationResult> ValidateAsync(string? authorizationHeader, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(authorizationHeader))
        {
            return TokenAuthenticationResult.Required();
        }

        if (!authorizationHeader.StartsWith("Bearer ", StringComparison.Ordinal))
        {
            return TokenAuthenticationResult.Invalid();
        }

        string presented = authorizationHeader["Bearer ".Length..];
        if (string.IsNullOrEmpty(presented) || presented.Length > MaxTokenLength)
        {
            return TokenAuthenticationResult.Invalid();
        }

        SecretResolutionResult resolution = await _resolver.ResolveAsync(_reference, LocalRouterSecrets.ProviderId, cancellationToken).ConfigureAwait(false);
        if (!resolution.IsSuccess || resolution.Handle is null)
        {
            return TokenAuthenticationResult.Failed(resolution.Error ?? SecretErrors.Missing(_reference.Name));
        }

        using (resolution.Handle)
        {
            string expected = resolution.Handle.ReadValue();
            return TimingSafeEquals(expected, presented)
                ? TokenAuthenticationResult.Success()
                : TokenAuthenticationResult.Invalid();
        }
    }

    private static bool TimingSafeEquals(string expected, string provided)
    {
        byte[] expectedBytes = Encoding.UTF8.GetBytes(expected);
        byte[] providedBytes = Encoding.UTF8.GetBytes(provided);
        try
        {
            return providedBytes.Length == expectedBytes.Length
                && CryptographicOperations.FixedTimeEquals(expectedBytes, providedBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(expectedBytes);
            CryptographicOperations.ZeroMemory(providedBytes);
        }
    }
}

/// <summary>Outcome of a token authentication attempt.</summary>
public sealed record TokenAuthenticationResult
{
    public bool IsSuccess { get; init; }

    public RouterError? Error { get; init; }

    public static TokenAuthenticationResult Success()
        => new() { IsSuccess = true };

    public static TokenAuthenticationResult Required()
        => new() { IsSuccess = false, Error = RouterError.AuthenticationRequired() };

    public static TokenAuthenticationResult Invalid()
        => new() { IsSuccess = false, Error = RouterError.AuthenticationInvalid() };

    public static TokenAuthenticationResult Failed(RouterError error)
        => new() { IsSuccess = false, Error = error };
}
