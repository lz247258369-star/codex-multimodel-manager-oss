namespace Router.Metering;

/// <summary>
/// Typed, versioned, safe operational metering record for one logical request.
/// This is informational observability, never billing truth. Missing usage and
/// unknown prices stay null; a cost estimate is always marked estimated.
/// </summary>
public sealed record RequestMeteringRecord
{
    public const int SchemaVersion = 1;

    public required int SchemaVersionValue { get; init; }

    public required string RequestId { get; init; }

    public required string TraceId { get; init; }

    public string? ClientId { get; init; }

    public string? ConfigGeneration { get; init; }

    public string? ProviderId { get; init; }

    public string? RouteId { get; init; }

    public string? ModelRouteId { get; init; }

    public string? ModelId { get; init; }

    public string? UpstreamModelId { get; init; }

    public UsageRecord? Usage { get; init; }

    public CostEstimate? CostEstimate { get; init; }

    public required RequestMeteringStatus Status { get; init; }

    public required bool Stream { get; init; }

    public required DateTimeOffset CompletedAt { get; init; }

    public required long DurationMs { get; init; }

    public static RequestMeteringRecord Create(
        string requestId,
        string traceId,
        string clientId,
        string? configGeneration,
        string? providerId,
        string? routeId,
        string? modelRouteId,
        string? modelId,
        string? upstreamModelId,
        UsageRecord? usage,
        CostEstimate? costEstimate,
        RequestMeteringStatus status,
        bool stream,
        DateTimeOffset completedAt,
        long durationMs)
        => new()
        {
            SchemaVersionValue = SchemaVersion,
            RequestId = requestId,
            TraceId = traceId,
            ClientId = clientId,
            ConfigGeneration = configGeneration,
            ProviderId = providerId,
            RouteId = routeId,
            ModelRouteId = modelRouteId,
            ModelId = modelId,
            UpstreamModelId = upstreamModelId,
            Usage = usage,
            CostEstimate = costEstimate,
            Status = status,
            Stream = stream,
            CompletedAt = completedAt,
            DurationMs = durationMs,
        };
}
