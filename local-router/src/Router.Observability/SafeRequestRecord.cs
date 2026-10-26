using Router.Core.Lifecycle;

namespace Router.Observability;

/// <summary>
/// Typed, safe request record. The type has no prompt, instruction, tool,
/// image, body, header, or secret fields by construction; redaction is never a
/// post-capture regex pass.
/// </summary>
public sealed record SafeRequestRecord
{
    public const int SchemaVersion = 1;

    public required string RequestId { get; init; }

    public required string TraceId { get; init; }

    public string? ClientId { get; init; }

    public string? RouteId { get; init; }

    public string? ProviderId { get; init; }

    public string? ProtocolId { get; init; }

    public string? ModelRouteId { get; init; }

    public required DateTimeOffset StartedAt { get; init; }

    public required DateTimeOffset CompletedAt { get; init; }

    public required long DurationMs { get; init; }

    public required string TerminalState { get; init; }

    public int? HttpStatus { get; init; }

    public string? ErrorCode { get; init; }

    public int AttemptCount { get; init; }

    public bool UsagePresent { get; init; }

    public bool Stream { get; init; }

    public int RetryCount { get; init; }

    public int FallbackCount { get; init; }

    public static SafeRequestRecord Create(
        string requestId,
        string traceId,
        DateTimeOffset startedAt,
        DateTimeOffset completedAt,
        RequestState terminalState,
        string? errorCode = null,
        string? clientId = null,
        string? routeId = null,
        string? providerId = null,
        string? protocolId = null,
        string? modelRouteId = null,
        int? httpStatus = null,
        int attemptCount = 0,
        bool usagePresent = false,
        bool stream = false,
        int retryCount = 0,
        int fallbackCount = 0)
        => new()
        {
            RequestId = requestId,
            TraceId = traceId,
            ClientId = clientId,
            RouteId = routeId,
            ProviderId = providerId,
            ProtocolId = protocolId,
            ModelRouteId = modelRouteId,
            StartedAt = startedAt,
            CompletedAt = completedAt,
            DurationMs = Math.Max(0, (long)Math.Round((completedAt - startedAt).TotalMilliseconds, MidpointRounding.AwayFromZero)),
            TerminalState = terminalState.ToWireName(),
            HttpStatus = httpStatus,
            ErrorCode = errorCode,
            AttemptCount = attemptCount,
            UsagePresent = usagePresent,
            Stream = stream,
            RetryCount = retryCount,
            FallbackCount = fallbackCount,
        };
}

/// <summary>
/// Redacted-by-construction wrapper accepted by durable sinks. Only a
/// validated <see cref="SafeRequestRecord"/> can ever become this type.
/// </summary>
public sealed record RedactedRequestRecord
{
    public required int SchemaVersion { get; init; }

    public required string RequestId { get; init; }

    public required string TraceId { get; init; }

    public string? ClientId { get; init; }

    public string? RouteId { get; init; }

    public string? ProviderId { get; init; }

    public string? ProtocolId { get; init; }

    public string? ModelRouteId { get; init; }

    public required string StartedAt { get; init; }

    public required string CompletedAt { get; init; }

    public required long DurationMs { get; init; }

    public required string TerminalState { get; init; }

    public int? HttpStatus { get; init; }

    public string? ErrorCode { get; init; }

    public int AttemptCount { get; init; }

    public bool UsagePresent { get; init; }

    public bool Stream { get; init; }

    public int RetryCount { get; init; }

    public int FallbackCount { get; init; }

    public static RedactedRequestRecord From(SafeRequestRecord record)
        => new()
        {
            SchemaVersion = SafeRequestRecord.SchemaVersion,
            RequestId = record.RequestId,
            TraceId = record.TraceId,
            ClientId = record.ClientId,
            RouteId = record.RouteId,
            ProviderId = record.ProviderId,
            ProtocolId = record.ProtocolId,
            ModelRouteId = record.ModelRouteId,
            StartedAt = record.StartedAt.ToString("O"),
            CompletedAt = record.CompletedAt.ToString("O"),
            DurationMs = record.DurationMs,
            TerminalState = record.TerminalState,
            HttpStatus = record.HttpStatus,
            ErrorCode = record.ErrorCode,
            AttemptCount = record.AttemptCount,
            UsagePresent = record.UsagePresent,
            Stream = record.Stream,
            RetryCount = record.RetryCount,
            FallbackCount = record.FallbackCount,
        };
}
