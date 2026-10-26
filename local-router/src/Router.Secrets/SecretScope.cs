namespace Router.Secrets;

/// <summary>
/// Secret reference scope. Machine scope is never represented: the contract
/// authorizes only process and user scopes (and their explicit combination).
/// </summary>
public enum SecretScope
{
    Process = 0,
    User = 1,
    UserOrProcess = 2,
}

/// <summary>Mapping between <see cref="SecretScope"/> and contract wire names.</summary>
public static class SecretScopeExtensions
{
    public static string ToWireName(this SecretScope scope) => scope switch
    {
        SecretScope.Process => "process",
        SecretScope.User => "user",
        SecretScope.UserOrProcess => "user_or_process",
        _ => throw new ArgumentOutOfRangeException(nameof(scope)),
    };

    public static bool TryFromWireName(string? name, out SecretScope scope)
    {
        switch (name)
        {
            case "process":
                scope = SecretScope.Process;
                return true;
            case "user":
                scope = SecretScope.User;
                return true;
            case "user_or_process":
                scope = SecretScope.UserOrProcess;
                return true;
            default:
                scope = default;
                return false;
        }
    }
}
