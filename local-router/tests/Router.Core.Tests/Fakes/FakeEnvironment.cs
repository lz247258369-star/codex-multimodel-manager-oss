using Router.Secrets;

namespace Router.Core.Tests.Fakes;

/// <summary>In-memory environment fake; never touches a real environment.</summary>
public sealed class FakeEnvironment : IEnvironment
{
    private readonly Dictionary<(string Name, SecretScope Scope), string?> _values = new();
    private readonly List<(string Name, SecretScope Scope)> _reads = [];

    public void Set(string name, SecretScope scope, string? value)
        => _values[(name, scope)] = value;

    public string? GetVariable(string name, SecretScope scope)
    {
        _reads.Add((name, scope));
        return _values.TryGetValue((name, scope), out string? value) ? value : null;
    }

    public IReadOnlyList<(string Name, SecretScope Scope)> Reads => _reads;
}
