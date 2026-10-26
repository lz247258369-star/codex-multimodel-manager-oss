using Router.Configuration;

namespace Router.Ingress;

/// <summary>
/// Immutable options for one ingress instance. Host is fixed to the loopback
/// contract; limits inherit LR-2 configuration and are hard-capped in code.
/// </summary>
public sealed record IngressRuntimeOptions
{
    /// <summary>Must be <c>127.0.0.1</c>; anything else fails closed.</summary>
    public required string Host { get; init; }

    /// <summary>
    /// Port to bind. Production wiring always supplies a validated 1..65535
    /// port; tests may use 0 for an ephemeral loopback port.
    /// </summary>
    public required int Port { get; init; }

    public required LimitsConfig Limits { get; init; }

    public required string ConfigGeneration { get; init; }

    /// <summary>Environment-variable reference name for the local bearer token.</summary>
    public required string TokenReferenceName { get; init; }

    /// <summary>Enabled client definitions used to resolve auth scopes.</summary>
    public IReadOnlyList<ClientConfig> Clients { get; init; } = [];

    /// <summary>
    /// Exact browser-origin allowlist. Empty by default, which denies every
    /// Origin-bearing request. A wildcard is never honored.
    /// </summary>
    public IReadOnlyList<string> AllowedOrigins { get; init; } = [];

    /// <summary>
    /// Optional transport-level request deadline. Route timeout policy is a
    /// later slice; when null no ingress deadline is applied.
    /// </summary>
    public TimeSpan? RequestTimeout { get; init; }

    /// <summary>Actual bound port, set after startup (used for Host validation).</summary>
    public int ActualPort { get; internal set; }
}
