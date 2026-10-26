using System.Collections.Concurrent;

namespace Router.Secrets;

/// <summary>
/// Test-support resolver. Returns configured values or errors and records every
/// call. Never touches a real environment.
/// </summary>
public sealed class FakeSecretResolver : ISecretResolver
{
    private readonly ConcurrentDictionary<(string ProviderId, string Name), (string? Value, Router.Core.Errors.RouterError? Error)> _results = new();
    private readonly ConcurrentQueue<(SecretReference Reference, string ProviderId)> _calls = new();

    /// <summary>Configures a successful (or missing) resolution for a provider/name pair.</summary>
    public void Configure(string providerId, string name, string? value)
        => _results[(providerId, name)] = (value, null);

    /// <summary>Configures an explicit error result.</summary>
    public void ConfigureError(string providerId, string name, Router.Core.Errors.RouterError error)
        => _results[(providerId, name)] = (null, error);

    /// <summary>All recorded resolution calls, in order.</summary>
    public IReadOnlyList<(SecretReference Reference, string ProviderId)> Calls => _calls.ToArray();

    /// <inheritdoc />
    public Task<SecretResolutionResult> ResolveAsync(SecretReference reference, string providerId, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _calls.Enqueue((reference, providerId));

        if (_results.TryGetValue((providerId, reference.Name), out (string? Value, Router.Core.Errors.RouterError? Error) configured))
        {
            // A fresh opaque handle per call so per-request consumption and
            // disposal (rotation-safe semantics) never reuse a disposed value.
            SecretResolutionResult result = configured.Value is null
                ? new SecretResolutionResult(null, configured.Error ?? SecretErrors.Missing(reference.Name))
                : new SecretResolutionResult(SecretHandle.FromValue(configured.Value), null);
            return Task.FromResult(result);
        }

        return Task.FromResult(new SecretResolutionResult(null, SecretErrors.Missing(reference.Name)));
    }
}
