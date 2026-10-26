using System.Text.Json.Serialization;

namespace Router.Configuration;

/// <summary>
/// Schema-v1 effective router configuration. Immutable after loading; contains
/// secret references only, never secret values.
/// </summary>
public sealed record RouterConfig
{
    public const int CurrentSchemaVersion = 1;

    public required int SchemaVersion { get; init; }

    public required int Version { get; init; }

    [JsonConverter(typeof(RouterModeJsonConverter))]
    public required RouterMode Mode { get; init; }

    public required LocalRouterConfig LocalRouter { get; init; }

    public IReadOnlyList<ClientConfig> Clients { get; init; } = [];

    public IReadOnlyList<ProtocolRouteConfig> ProtocolRoutes { get; init; } = [];

    public IReadOnlyList<ProviderRouteConfig> ProviderRoutes { get; init; } = [];

    public IReadOnlyList<EndpointConfig> Endpoints { get; init; } = [];

    public IReadOnlyList<ModelRouteConfig> ModelRoutes { get; init; } = [];

    public IReadOnlyList<RouterRouteConfig> Routes { get; init; } = [];

    public IReadOnlyList<PolicyConfig> Policies { get; init; } = [];

    public DateTimeOffset? UpdatedAt { get; init; }
}

/// <summary>Loopback-only local router settings.</summary>
public sealed record LocalRouterConfig
{
    public required bool Enabled { get; init; }

    public required string Host { get; init; }

    public required int Port { get; init; }

    public required ClientAuthConfig ClientAuth { get; init; }

    public required LimitsConfig Limits { get; init; }

    /// <summary>
    /// HS-1B thread-scoped model selection capability. Absent configuration
    /// means the capability is disabled, which keeps routing byte-for-byte
    /// equivalent to a Router without HS-1B.
    /// </summary>
    public ThreadSelectionConfig ThreadSelection { get; init; } = new();
}

/// <summary>
/// Thread-scoped model selection settings. Every duration is validated against
/// the hard floors/ceilings in
/// <c>Router.ThreadSelection.ThreadSelectionOptions</c>.
/// </summary>
public sealed record ThreadSelectionConfig
{
    /// <summary>Default pending selection TTL in milliseconds (5 minutes).</summary>
    public const long DefaultPendingTtlMs = 300_000;

    /// <summary>Default active selection idle TTL in milliseconds (24 hours).</summary>
    public const long DefaultActiveIdleTtlMs = 86_400_000;

    /// <summary>Whether the capability is enabled. Defaults to disabled.</summary>
    public bool Enabled { get; init; }

    /// <summary>TTL applied to a pending selection.</summary>
    public long PendingTtlMs { get; init; } = DefaultPendingTtlMs;

    /// <summary>Idle TTL applied to an active selection.</summary>
    public long ActiveIdleTtlMs { get; init; } = DefaultActiveIdleTtlMs;

    /// <summary>
    /// HS-1C quota-exhaustion sticky failover. Defaults OFF so LR-11 ordinary
    /// cross-model fallback remains hard-disabled unless this explicit path is enabled.
    /// </summary>
    public bool QuotaFailoverEnabled { get; init; }
}

/// <summary>Local client authentication configuration (reference only).</summary>
public sealed record ClientAuthConfig
{
    public required string Mode { get; init; }

    public required string TokenRef { get; init; }
}

/// <summary>Local router security limits.</summary>
public sealed record LimitsConfig
{
    public required int MaxRequestBytes { get; init; }

    public required int MaxHeaderBytes { get; init; }

    public required int MaxConnections { get; init; }

    public required int ShutdownGraceMs { get; init; }
}
