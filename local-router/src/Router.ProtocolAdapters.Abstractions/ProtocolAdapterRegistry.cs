using Router.Core.Errors;

namespace Router.ProtocolAdapters.Abstractions;

/// <summary>Registry resolution outcome: an adapter or a typed error.</summary>
public sealed record ProtocolAdapterResolveResult
{
    public IResponsesProtocolAdapter? Adapter { get; init; }

    public ProtocolAdapterDescriptor? Descriptor { get; init; }

    public RouterError? Error { get; init; }

    public bool IsResolved => Adapter is not null;

    public static ProtocolAdapterResolveResult Resolved(IResponsesProtocolAdapter adapter, ProtocolAdapterDescriptor descriptor)
        => new() { Adapter = adapter, Descriptor = descriptor };

    public static ProtocolAdapterResolveResult Failed(RouterError error)
        => new() { Error = error };
}

/// <summary>
/// Immutable protocol adapter registry. Resolution is exact on the canonical
/// protocol pair plus adapter version; duplicate identities fail closed and a
/// placeholder is never eligible. No protocol is inferred from providers,
/// models, or endpoints.
/// </summary>
public sealed class ProtocolAdapterRegistry
{
    private readonly IReadOnlyDictionary<string, IResponsesProtocolAdapter> _byExactKey;
    private readonly IReadOnlyDictionary<string, ProtocolAdapterDescriptor> _descriptors;

    private ProtocolAdapterRegistry(
        IReadOnlyDictionary<string, IResponsesProtocolAdapter> byExactKey,
        IReadOnlyDictionary<string, ProtocolAdapterDescriptor> descriptors)
    {
        _byExactKey = byExactKey;
        _descriptors = descriptors;
    }

    /// <summary>Stable exact key: canonical protocol + upstream protocol + adapter version.</summary>
    public static string ExactKey(string canonicalProtocolId, string upstreamProtocolId, string adapterVersion)
        => canonicalProtocolId + "\u001f" + upstreamProtocolId + "\u001f" + adapterVersion;

    /// <summary>Builds the immutable registry; duplicate identities fail closed.</summary>
    public static Result<ProtocolAdapterRegistry, RouterError> Create(
        IEnumerable<ProtocolAdapterRegistration> registrations)
    {
        ArgumentNullException.ThrowIfNull(registrations);

        var byExactKey = new Dictionary<string, IResponsesProtocolAdapter>(StringComparer.Ordinal);
        var descriptors = new Dictionary<string, ProtocolAdapterDescriptor>(StringComparer.Ordinal);
        var seenPairs = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);

        foreach (ProtocolAdapterRegistration registration in registrations)
        {
            ProtocolAdapterDescriptor descriptor = registration.Descriptor;
            string key = ExactKey(
                descriptor.CanonicalProtocolId,
                descriptor.UpstreamProtocolId,
                descriptor.AdapterVersion);

            if (!byExactKey.TryAdd(key, registration.Adapter))
            {
                return new Result<ProtocolAdapterRegistry, RouterError>
                {
                    Error = ProtocolAdapterErrors.RegistrationInvalid("duplicate protocol adapter identity"),
                };
            }

            descriptors[key] = descriptor;

            string pair = descriptor.CanonicalProtocolId + "\u001f" + descriptor.UpstreamProtocolId;
            if (!seenPairs.TryGetValue(pair, out HashSet<string>? versions))
            {
                versions = [];
                seenPairs.Add(pair, versions);
            }

            if (!versions.Add(descriptor.AdapterVersion))
            {
                return new Result<ProtocolAdapterRegistry, RouterError>
                {
                    Error = ProtocolAdapterErrors.RegistrationInvalid("protocol adapter version collision"),
                };
            }
        }

        return new Result<ProtocolAdapterRegistry, RouterError>
        {
            Value = new ProtocolAdapterRegistry(byExactKey, descriptors),
        };
    }

    /// <summary>
    /// Resolves one adapter by exact canonical/upstream protocol pair and
    /// version. A placeholder registration is never eligible; an unsupported
    /// pair fails closed.
    /// </summary>
    public ProtocolAdapterResolveResult Resolve(
        string canonicalProtocolId,
        string upstreamProtocolId,
        string adapterVersion)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(canonicalProtocolId);
        ArgumentException.ThrowIfNullOrWhiteSpace(upstreamProtocolId);
        ArgumentException.ThrowIfNullOrWhiteSpace(adapterVersion);

        string key = ExactKey(canonicalProtocolId, upstreamProtocolId, adapterVersion);
        if (_byExactKey.TryGetValue(key, out IResponsesProtocolAdapter? adapter))
        {
            ProtocolAdapterDescriptor descriptor = _descriptors[key];
            if (!descriptor.Eligible)
            {
                return ProtocolAdapterResolveResult.Failed(ProtocolAdapterErrors.PlaceholderUnavailable());
            }

            return ProtocolAdapterResolveResult.Resolved(adapter, descriptor);
        }

        bool knownPairWithDifferentVersion = _descriptors.Values.Any(descriptor =>
            string.Equals(descriptor.CanonicalProtocolId, canonicalProtocolId, StringComparison.Ordinal)
            && string.Equals(descriptor.UpstreamProtocolId, upstreamProtocolId, StringComparison.Ordinal));

        return ProtocolAdapterResolveResult.Failed(
            knownPairWithDifferentVersion
                ? ProtocolAdapterErrors.VersionMismatch()
                : ProtocolAdapterErrors.NotFound());
    }
}
