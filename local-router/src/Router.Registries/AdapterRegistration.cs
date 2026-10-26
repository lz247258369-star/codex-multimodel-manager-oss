namespace Router.Registries;

/// <summary>Adapter kind used to match provider and protocol adapters.</summary>
public enum AdapterKind
{
    Provider,
    Protocol,
}

/// <summary>
/// Explicit adapter registration input (LR-5+ will register real adapters).
/// A registration is immutable for one snapshot and must be eligible to serve
/// routes; a placeholder registration never becomes eligible.
/// </summary>
public sealed record AdapterRegistration
{
    public required string AdapterId { get; init; }

    public required string Version { get; init; }

    public required AdapterKind Kind { get; init; }

    public string? ProviderId { get; init; }

    public string? ProtocolId { get; init; }

    public required bool Eligible { get; init; }

    public IReadOnlyList<string> Capabilities { get; init; } = [];

    public static AdapterRegistration Provider(string adapterId, string providerId, IReadOnlyList<string> capabilities)
        => new()
        {
            AdapterId = adapterId,
            Version = "1.0",
            Kind = AdapterKind.Provider,
            ProviderId = providerId,
            Eligible = true,
            Capabilities = capabilities,
        };

    public static AdapterRegistration Protocol(string adapterId, string protocolId, IReadOnlyList<string> capabilities)
        => new()
        {
            AdapterId = adapterId,
            Version = "1.0",
            Kind = AdapterKind.Protocol,
            ProtocolId = protocolId,
            Eligible = true,
            Capabilities = capabilities,
        };
}
