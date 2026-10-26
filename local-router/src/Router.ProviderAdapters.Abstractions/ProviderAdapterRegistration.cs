using Router.Registries;

namespace Router.ProviderAdapters.Abstractions;

/// <summary>
/// Explicit registration of one adapter implementation. Identity is exact;
/// duplicate adapter_id+version and mismatched provider/protocol identities
/// fail closed. Placeholder registrations are never eligible.
/// </summary>
public sealed record ProviderAdapterRegistration
{
    public required ProviderAdapterDescriptor Descriptor { get; init; }

    public required IProviderAdapter Adapter { get; init; }

    public static ProviderAdapterRegistration Create(
        ProviderAdapterDescriptor descriptor,
        IProviderAdapter adapter)
    {
        ArgumentNullException.ThrowIfNull(descriptor);
        ArgumentNullException.ThrowIfNull(adapter);

        if (string.IsNullOrWhiteSpace(descriptor.AdapterId)
            || string.IsNullOrWhiteSpace(descriptor.AdapterVersion)
            || string.IsNullOrWhiteSpace(descriptor.ProviderId)
            || string.IsNullOrWhiteSpace(descriptor.ProtocolId))
        {
            throw new ArgumentException("Adapter identity fields must not be empty.");
        }

        return new ProviderAdapterRegistration { Descriptor = descriptor, Adapter = adapter };
    }
}
