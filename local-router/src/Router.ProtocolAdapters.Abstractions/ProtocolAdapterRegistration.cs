namespace Router.ProtocolAdapters.Abstractions;

/// <summary>
/// Explicit registration of one protocol adapter implementation. Duplicate
/// identities and incompatible protocol pairs fail closed; placeholders are
/// never eligible.
/// </summary>
public sealed record ProtocolAdapterRegistration
{
    public required ProtocolAdapterDescriptor Descriptor { get; init; }

    public required IResponsesProtocolAdapter Adapter { get; init; }

    public static ProtocolAdapterRegistration Create(
        ProtocolAdapterDescriptor descriptor,
        IResponsesProtocolAdapter adapter)
    {
        ArgumentNullException.ThrowIfNull(descriptor);
        ArgumentNullException.ThrowIfNull(adapter);

        if (string.IsNullOrWhiteSpace(descriptor.AdapterId)
            || string.IsNullOrWhiteSpace(descriptor.AdapterVersion)
            || string.IsNullOrWhiteSpace(descriptor.CanonicalProtocolId)
            || string.IsNullOrWhiteSpace(descriptor.UpstreamProtocolId))
        {
            throw new ArgumentException("Protocol adapter identity fields must not be empty.");
        }

        return new ProtocolAdapterRegistration { Descriptor = descriptor, Adapter = adapter };
    }
}
