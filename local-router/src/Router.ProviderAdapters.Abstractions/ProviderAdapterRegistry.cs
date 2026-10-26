using Router.Core.Errors;

namespace Router.ProviderAdapters.Abstractions;

/// <summary>Registry resolution outcome: an adapter or a typed error.</summary>
public sealed record AdapterResolveResult
{
    public IProviderAdapter? Adapter { get; init; }

    public ProviderAdapterDescriptor? Descriptor { get; init; }

    public RouterError? Error { get; init; }

    public bool IsResolved => Adapter is not null;

    public static AdapterResolveResult Resolved(IProviderAdapter adapter, ProviderAdapterDescriptor descriptor)
        => new() { Adapter = adapter, Descriptor = descriptor };

    public static AdapterResolveResult Failed(RouterError error)
        => new() { Error = error };
}

/// <summary>
/// Immutable provider adapter registry. It answers only "which concrete
/// adapter implementation may execute this route"; model/provider/route
/// identity remains owned by LR-4 registries. Lookup is exact and never
/// silently upgrades a pinned adapter version.
/// </summary>
public sealed class ProviderAdapterRegistry
{
    private readonly IReadOnlyDictionary<string, IProviderAdapter> _byExactKey;
    private readonly IReadOnlyDictionary<string, ProviderAdapterDescriptor> _descriptors;

    private ProviderAdapterRegistry(
        IReadOnlyDictionary<string, IProviderAdapter> byExactKey,
        IReadOnlyDictionary<string, ProviderAdapterDescriptor> descriptors)
    {
        _byExactKey = byExactKey;
        _descriptors = descriptors;
    }

    /// <summary>Stable exact key: adapter_id + version + provider_id + protocol_id.</summary>
    public static string ExactKey(string adapterId, string version, string providerId, string protocolId)
        => adapterId + "\u001f" + version + "\u001f" + providerId + "\u001f" + protocolId;

    /// <summary>Builds the immutable registry; duplicate identities fail closed.</summary>
    public static Result<ProviderAdapterRegistry, RouterError> Create(IEnumerable<ProviderAdapterRegistration> registrations)
    {
        ArgumentNullException.ThrowIfNull(registrations);

        var byExactKey = new Dictionary<string, IProviderAdapter>(StringComparer.Ordinal);
        var descriptors = new Dictionary<string, ProviderAdapterDescriptor>(StringComparer.Ordinal);
        var versionsByAdapter = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);

        foreach (ProviderAdapterRegistration registration in registrations)
        {
            ProviderAdapterDescriptor descriptor = registration.Descriptor;
            string key = ExactKey(descriptor.AdapterId, descriptor.AdapterVersion, descriptor.ProviderId, descriptor.ProtocolId);
            if (!byExactKey.TryAdd(key, registration.Adapter))
            {
                return new Result<ProviderAdapterRegistry, RouterError>
                {
                    Error = ProviderAdapterErrors.AdapterRegistrationInvalid("duplicate adapter identity"),
                };
            }

            descriptors[key] = descriptor;

            if (!versionsByAdapter.TryGetValue(descriptor.AdapterId, out HashSet<string>? versions))
            {
                versions = [];
                versionsByAdapter.Add(descriptor.AdapterId, versions);
            }

            if (!versions.Add(descriptor.AdapterVersion))
            {
                return new Result<ProviderAdapterRegistry, RouterError>
                {
                    Error = ProviderAdapterErrors.AdapterRegistrationInvalid("adapter version collision"),
                };
            }
        }

        return new Result<ProviderAdapterRegistry, RouterError>
        {
            Value = new ProviderAdapterRegistry(byExactKey, descriptors),
        };
    }

    /// <summary>
    /// Resolves an adapter by exact identity. Unknown adapter returns
    /// <c>adapter_not_found</c>; a known adapter with a different version
    /// returns <c>adapter_version_mismatch</c>; a placeholder is never
    /// eligible.
    /// </summary>
    public AdapterResolveResult Resolve(string adapterId, string adapterVersion, string providerId, string protocolId)
    {
        string key = ExactKey(adapterId, adapterVersion, providerId, protocolId);
        if (_byExactKey.TryGetValue(key, out IProviderAdapter? adapter))
        {
            ProviderAdapterDescriptor descriptor = _descriptors[key];
            if (!descriptor.Eligible)
            {
                return AdapterResolveResult.Failed(ProviderAdapterErrors.PlaceholderUnavailable());
            }

            return AdapterResolveResult.Resolved(adapter, descriptor);
        }

        if (_descriptors.Values.Any(descriptor =>
                string.Equals(descriptor.AdapterId, adapterId, StringComparison.Ordinal)
                && string.Equals(descriptor.ProviderId, providerId, StringComparison.Ordinal)
                && string.Equals(descriptor.ProtocolId, protocolId, StringComparison.Ordinal)))
        {
            return AdapterResolveResult.Failed(ProviderAdapterErrors.AdapterVersionMismatch());
        }

        return AdapterResolveResult.Failed(ProviderAdapterErrors.AdapterNotFound());
    }
}
