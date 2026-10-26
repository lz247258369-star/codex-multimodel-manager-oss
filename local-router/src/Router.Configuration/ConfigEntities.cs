using System.Text.Json.Serialization;
using Router.Secrets;

namespace Router.Configuration;

/// <summary>Schema-v1 client definition.</summary>
public sealed record ClientConfig
{
    public required string ClientId { get; init; }

    public required string AdapterId { get; init; }

    public required bool Enabled { get; init; }

    public required string AuthScope { get; init; }

    public IReadOnlyList<string> AllowedRouteIds { get; init; } = [];

    public IReadOnlyList<string> Capabilities { get; init; } = [];

    public required int Version { get; init; }
}

/// <summary>Schema-v1 protocol route definition.</summary>
public sealed record ProtocolRouteConfig
{
    public required string ProtocolRouteId { get; init; }

    public required string IngressProtocol { get; init; }

    public required string UpstreamProtocol { get; init; }

    public required string AdapterId { get; init; }

    public required string AdapterVersion { get; init; }

    public IReadOnlyList<string> Capabilities { get; init; } = [];

    public required string LossPolicy { get; init; }

    public required int Version { get; init; }
}

/// <summary>Schema-v1 provider route definition.</summary>
public sealed record ProviderRouteConfig
{
    public required string ProviderRouteId { get; init; }

    public required string ProviderId { get; init; }

    public required string AdapterId { get; init; }

    public required string AdapterVersion { get; init; }

    public IReadOnlyList<string> EndpointIds { get; init; } = [];

    public SecretReference? SecretRef { get; init; }

    public string? BaseUrlRef { get; init; }

    public required bool Enabled { get; init; }

    public IReadOnlyList<string> Capabilities { get; init; } = [];

    public required int Version { get; init; }
}

/// <summary>
/// Schema-v1 endpoint definition. Endpoints are referenced by
/// <see cref="ProviderRouteConfig.EndpointIds"/> and selected explicitly during
/// route resolution; they never interpolate environment data or request input.
/// </summary>
public sealed record EndpointConfig
{
    public required string EndpointId { get; init; }

    public required string BaseUrlRef { get; init; }

    public required bool Enabled { get; init; }

    public required string DataBoundary { get; init; }

    public required bool TlsRequired { get; init; }

    public required int Priority { get; init; }

    public required int Weight { get; init; }

    public required int Version { get; init; }
}

/// <summary>Schema-v1 model route definition.</summary>
public sealed record ModelRouteConfig
{
    public required string ModelRouteId { get; init; }

    public required string ProviderId { get; init; }

    public required string ClientModelId { get; init; }

    public required string ModelId { get; init; }

    public required string UpstreamModelId { get; init; }

    public IReadOnlyList<string> Aliases { get; init; } = [];

    public IReadOnlyList<string> Capabilities { get; init; } = [];

    public string? PricingRef { get; init; }

    public required string IdentityVerification { get; init; }

    public required bool Enabled { get; init; }

    public required int Version { get; init; }
}

/// <summary>Schema-v1 router route definition.</summary>
public sealed record RouterRouteConfig
{
    public required string RouteId { get; init; }

    public IReadOnlyList<string> ClientIds { get; init; } = [];

    public required string ProviderRouteId { get; init; }

    public required string ProtocolRouteId { get; init; }

    public required string ModelRouteId { get; init; }

    public required bool Enabled { get; init; }

    public required int Priority { get; init; }

    public required int Weight { get; init; }

    public required string HealthState { get; init; }

    public required string TimeoutPolicyId { get; init; }

    public required string RetryPolicyId { get; init; }

    public required string FailoverPolicyId { get; init; }

    public IReadOnlyList<string> FallbackRouteIds { get; init; } = [];

    public required DateTimeOffset CreatedAt { get; init; }

    public required DateTimeOffset UpdatedAt { get; init; }

    public required int Version { get; init; }
}

/// <summary>
/// Schema-v1 policy placeholder. Policy bodies are not defined by schema v1;
/// unknown fields fail closed so later policy slices can extend the schema
/// explicitly.
/// </summary>
public sealed record PolicyConfig
{
    public required string PolicyId { get; init; }

    public required int Version { get; init; }

    /// <summary>
    /// Optional versioned retry body (LR-14P additive evolution). Absent means
    /// "not configured"; execution falls back to safe defaults.
    /// </summary>
    [JsonPropertyName("retry")]
    public PolicyRetryBodyConfig? RetryBody { get; init; }

    /// <summary>Optional versioned timeout body. Absent means safe defaults.</summary>
    [JsonPropertyName("timeout")]
    public PolicyTimeoutBodyConfig? TimeoutBody { get; init; }

    /// <summary>
    /// Optional versioned failover body. Absent means failover OFF. The body
    /// deliberately has no cross-model field; cross-model fallback stays HARD
    /// OFF by construction.
    /// </summary>
    [JsonPropertyName("failover")]
    public PolicyFailoverBodyConfig? FailoverBody { get; init; }
}

/// <summary>
/// Versioned retry policy body persisted in the config document. Field names
/// mirror the LR-11 <c>RetryPolicy</c> surface; duration fields are integer
/// milliseconds so the config schema stays deterministic and bounded.
/// </summary>
public sealed record PolicyRetryBodyConfig
{
    public const int SchemaVersion = 1;

    public required int SchemaVersionValue { get; init; }

    public required int MaxAttempts { get; init; }

    public required long BaseDelayMs { get; init; }

    public required long MaxDelayMs { get; init; }

    public required decimal Jitter { get; init; }

    public required bool RespectRetryAfter { get; init; }

    public required long MaxRetryAfterMs { get; init; }
}

/// <summary>
/// Versioned timeout policy body persisted in the config document. Mirrors the
/// LR-11 <c>TimeoutPolicy</c> surface in integer milliseconds.
/// </summary>
public sealed record PolicyTimeoutBodyConfig
{
    public const int SchemaVersion = 1;

    public required int SchemaVersionValue { get; init; }

    public required long ConnectTimeoutMs { get; init; }

    public required long FirstByteTimeoutMs { get; init; }

    public required long IdleTimeoutMs { get; init; }

    public required long AttemptTimeoutMs { get; init; }

    public required long TotalTimeoutMs { get; init; }
}

/// <summary>
/// Versioned failover policy body persisted in the config document. Cross-model
/// fallback is not a field and cannot be enabled through any config path.
/// </summary>
public sealed record PolicyFailoverBodyConfig
{
    public const int SchemaVersion = 1;

    public required int SchemaVersionValue { get; init; }

    public required bool AllowSameModelAlternateEndpoint { get; init; }

    public required bool AllowSameModelAlternateProvider { get; init; }
}

/// <summary>Hard ceilings applied to persisted policy bodies.</summary>
public static class PolicyBodyLimits
{
    public const int MaxRetryAttempts = 10;

    public const long MinDurationMs = 1;

    /// <summary>24 hours; policy durations beyond this are rejected.</summary>
    public const long MaxDurationMs = 86_400_000;
}
