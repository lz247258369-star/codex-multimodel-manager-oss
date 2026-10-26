using Router.Configuration;

namespace Router.Ingress;

/// <summary>
/// Resolves the required auth scope to an enabled client identity. A request is
/// denied when no enabled client grants the required scope (fail closed).
/// </summary>
public sealed class ClientScopeRegistry
{
    private readonly IReadOnlyDictionary<string, string> _clientScopes;

    public ClientScopeRegistry(IEnumerable<ClientConfig> clients)
    {
        _clientScopes = clients
            .Where(static c => c.Enabled)
            .ToDictionary(static c => c.ClientId, static c => c.AuthScope, StringComparer.Ordinal);
    }

    public IReadOnlyCollection<string> AllowedScopes
        => _clientScopes.Values.Distinct(StringComparer.Ordinal).ToArray();

    public bool TryResolve(string requiredScope, out string clientId)
    {
        foreach (KeyValuePair<string, string> pair in _clientScopes)
        {
            if (string.Equals(pair.Value, requiredScope, StringComparison.Ordinal))
            {
                clientId = pair.Key;
                return true;
            }
        }

        clientId = string.Empty;
        return false;
    }
}
