using CanonicalUsage = Router.ClientAdapters.Responses.UsageRecord;

namespace Router.Metering;

/// <summary>
/// Safe per-request metering input produced by the production completion path.
/// Carries canonical usage plus correlation/identity metadata only; never
/// prompt, output, tool, header, secret, or path content.
/// </summary>
public sealed record RequestMeteringInput
{
    public required string RequestId { get; init; }

    public required string TraceId { get; init; }

    public required string ClientId { get; init; }

    public string? ConfigGeneration { get; init; }

    /// <summary>Client-visible model id from the canonical request.</summary>
    public required string ModelId { get; init; }

    public string? ProviderId { get; init; }

    public string? RouteId { get; init; }

    public string? ModelRouteId { get; init; }

    /// <summary>Catalog canonical model id used for pricing lookups.</summary>
    public string? CatalogModelId { get; init; }

    public string? UpstreamModelId { get; init; }

    public CanonicalUsage? Usage { get; init; }

    public required bool Stream { get; init; }

    public required DateTimeOffset CompletedAt { get; init; }

    public required long DurationMs { get; init; }
}
