namespace Router.ClientAdapters.Responses;

/// <summary>
/// Versioned authoritative execution metadata carried by a production
/// <see cref="ResponsesServiceResult"/>. Identity comes exclusively from the
/// resolved route and the provider attempt; it is never guessed from model
/// names, configuration order, or provider brands. No secret, request content,
/// or raw upstream text ever appears here.
///
/// The metadata is deliberately two-phase. The instant a route is resolved and
/// a provider attempt starts, every identity field plus
/// <see cref="ExecutionStartedAt"/> is authoritative and is attached to the
/// result returned to the caller - including streamed results, before any
/// event is enumerated. <see cref="CompletedAt"/> stays <c>null</c> for an
/// in-flight streamed execution because terminal time is unknown until the
/// stream actually reaches its terminal boundary; it is never filled with a
/// synthetic "stream returned" time. The terminal-aware stream finalizer then
/// emits the same identity with the real terminal <see cref="CompletedAt"/>.
/// </summary>
public sealed record ResponsesExecutionMetadata
{
    public const int SchemaVersion = 1;

    /// <summary>Immutable effective-config generation the execution is bound to.</summary>
    public required string ConfigGeneration { get; init; }

    /// <summary>Canonical client identity that requested the execution.</summary>
    public required string ClientId { get; init; }

    /// <summary>Exact resolved router route identity.</summary>
    public required string RouteId { get; init; }

    /// <summary>Exact provider identity selected by the route resolver.</summary>
    public required string ProviderId { get; init; }

    /// <summary>Exact provider route identity selected by the route resolver.</summary>
    public required string ProviderRouteId { get; init; }

    /// <summary>Exact model route identity selected by the route resolver.</summary>
    public required string ModelRouteId { get; init; }

    /// <summary>Client-facing model identity carried by the model route.</summary>
    public required string ClientModelId { get; init; }

    /// <summary>
    /// Provider-scoped catalog model identity, when the model route carries
    /// catalog metadata; otherwise the model route's explicit model identity.
    /// </summary>
    public required string CatalogModelId { get; init; }

    /// <summary>Exact upstream model identity sent to the provider.</summary>
    public required string UpstreamModelId { get; init; }

    /// <summary>Exact endpoint identity selected for the attempt.</summary>
    public required string EndpointId { get; init; }

    /// <summary>Number of provider attempts executed for this request.</summary>
    public int AttemptCount { get; init; } = 1;

    /// <summary>
    /// UTC instant the first upstream attempt of this execution started.
    /// Identity selection and execution timing are explicit fields; a caller
    /// never has to infer them from configuration order or stream return time.
    /// </summary>
    public required DateTimeOffset ExecutionStartedAt { get; init; }

    /// <summary>
    /// UTC instant the execution reached its terminal boundary, or <c>null</c>
    /// while a streamed execution is still in flight.
    /// </summary>
    /// <remarks>
    /// Non-stream terminal results (success and failure) always carry a
    /// non-null value equal to the instant the result was finalized. A streamed
    /// result returned to the caller carries the full authoritative identity
    /// with <c>CompletedAt == null</c>; the terminal-aware stream boundary
    /// finalizes a later outcome carrying the same identity and the real
    /// terminal timestamp exactly once when the stream completes, fails, or is
    /// cancelled. This field never means "the stream was returned".
    /// </remarks>
    public required DateTimeOffset? CompletedAt { get; init; }
}
