namespace Router.Registries;

/// <summary>
/// Immutable, ordered capability set. Effective capabilities are always an
/// explicit intersection; a required capability missing from the intersection
/// fails closed and is never silently downgraded.
/// </summary>
public sealed class CapabilitySet : IEquatable<CapabilitySet>
{
    private readonly string[] _ordered;
    private readonly HashSet<string> _set;

    private CapabilitySet(IEnumerable<string> capabilities)
    {
        _ordered = capabilities.Distinct(StringComparer.Ordinal).OrderBy(static value => value, StringComparer.Ordinal).ToArray();
        _set = new HashSet<string>(_ordered, StringComparer.Ordinal);
    }

    public static CapabilitySet Empty { get; } = new([]);

    public IReadOnlyList<string> Values => _ordered;

    public int Count => _ordered.Length;

    public bool Contains(string capability) => _set.Contains(capability);

    public static CapabilitySet From(IEnumerable<string> capabilities)
    {
        ArgumentNullException.ThrowIfNull(capabilities);
        return new CapabilitySet(capabilities.Where(static value => !string.IsNullOrWhiteSpace(value)));
    }

    /// <summary>Returns the explicit intersection of two capability sets.</summary>
    public CapabilitySet Intersect(CapabilitySet other)
    {
        ArgumentNullException.ThrowIfNull(other);
        return From(_ordered.Where(other.Contains));
    }

    /// <summary>True when every required capability is present in this set.</summary>
    public bool ContainsAll(CapabilitySet required)
    {
        ArgumentNullException.ThrowIfNull(required);
        return required._ordered.All(Contains);
    }

    public bool Equals(CapabilitySet? other)
        => other is not null && _ordered.SequenceEqual(other._ordered, StringComparer.Ordinal);

    public override bool Equals(object? obj) => Equals(obj as CapabilitySet);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (string value in _ordered)
        {
            hash.Add(value, StringComparer.Ordinal);
        }

        return hash.ToHashCode();
    }
}

/// <summary>
/// Fixed canonical ingress capability line for V1 (Responses semantics). The
/// resolver intersects this with client, protocol, provider, and model sets.
/// </summary>
public static class CanonicalIngressCapabilities
{
    public static CapabilitySet V1 { get; } = CapabilitySet.From(
    [
        "text", "streaming", "reasoning", "tools", "usage", "cancellation",
    ]);
}
