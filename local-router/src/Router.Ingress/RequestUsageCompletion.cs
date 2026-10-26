using Router.ClientAdapters.Responses;

namespace Router.Ingress;

/// <summary>
/// Safe resolved request identity for metering annotations. All fields are
/// optional because route/provider resolution is a composition concern; when
/// absent the metering recorder must never guess an identity.
/// </summary>
public sealed record RequestUsageIdentity
{
    public string? ProviderId { get; init; }

    public string? RouteId { get; init; }

    public string? ModelRouteId { get; init; }

    /// <summary>Catalog canonical model identity used for pricing lookups.</summary>
    public string? CatalogModelId { get; init; }

    /// <summary>Provider-specific upstream model identity when declared.</summary>
    public string? UpstreamModelId { get; init; }
}

/// <summary>
/// Typed, safe per-request usage completion delivered to the optional ingress
/// observer. Identity is a pure projection of the authoritative execution
/// result (<c>ResponsesServiceResult.Execution</c>); ingress never looks up
/// configuration, model names, or provider brands. Contains canonical usage
/// plus correlation/identity metadata only; never prompt, output, tool,
/// header, secret, or path content.
/// </summary>
public sealed record RequestUsageCompletion
{
    public const int SchemaVersion = 1;

    public required string RequestId { get; init; }

    public required string TraceId { get; init; }

    public required string ClientId { get; init; }

    public string? ConfigGeneration { get; init; }

    /// <summary>Client-visible model id from the canonical request.</summary>
    public required string ModelId { get; init; }

    public RequestUsageIdentity? Identity { get; init; }

    public UsageRecord? Usage { get; init; }

    public required bool Stream { get; init; }

    public required DateTimeOffset CompletedAt { get; init; }

    public required long DurationMs { get; init; }
}
