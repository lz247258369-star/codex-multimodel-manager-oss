namespace Router.Secrets;

/// <summary>
/// Environment-variable source abstraction. Machine scope is intentionally not
/// representable; tests inject fakes so real user environment variables are
/// never read or modified.
/// </summary>
public interface IEnvironment
{
    /// <summary>Reads a variable from the given scope (Process or User only).</summary>
    string? GetVariable(string name, SecretScope scope);
}

/// <summary>Production environment source backed by the process environment.</summary>
public sealed class RealEnvironment : IEnvironment
{
    public string? GetVariable(string name, SecretScope scope) => scope switch
    {
        SecretScope.Process => Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Process),
        SecretScope.User => Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User),
        _ => throw new ArgumentOutOfRangeException(nameof(scope)),
    };
}
