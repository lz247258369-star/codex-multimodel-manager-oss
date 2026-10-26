using Microsoft.AspNetCore.Http;
using Router.Core.Context;
using Router.Core.Ids;
using Router.Core.Lifecycle;

namespace Router.Ingress.Handlers;

/// <summary>Shared helpers for ingress handlers.</summary>
internal static class RequestPipeline
{
    public static RequestId RequestId(HttpContext context)
        => (RequestId)context.Items[IngressContextKeys.RequestId]!;

    public static TraceId TraceId(HttpContext context)
        => (TraceId)context.Items[IngressContextKeys.TraceId]!;

    public static string RequestIdValue(HttpContext context) => RequestId(context).Value;

    public static string TraceIdValue(HttpContext context) => TraceId(context).Value;

    /// <summary>
    /// Reads the two optional router-local identity headers from the live
    /// request and interprets them with the single shared
    /// <see cref="ThreadIdentityParser"/>.
    ///
    /// The result is control metadata, never Responses protocol input: a
    /// malformed, oversized, or contradictory presentation simply means this
    /// request owns no thread state (<c>null</c>) and continues with the Codex
    /// requested model. Identity material can never fail the HTTP request.
    /// </summary>
    public static ThreadIdentity? ResolveThreadIdentity(HttpContext context)
    {
        string? threadIdHeader = context.Request.Headers[ThreadIdentityParser.ThreadIdHeaderName];
        string? metadataHeader = context.Request.Headers[ThreadIdentityParser.TurnMetadataHeaderName];
        ThreadIdentityParseResult parsed = ThreadIdentityParser.Parse(threadIdHeader, metadataHeader);
        return parsed.IsAccepted ? parsed.Identity : null;
    }

    public static RequestContext CreateContext(
        HttpContext context,
        IngressServices services,
        string clientId,
        string scope,
        string? idempotencyKeyHash,
        DateTimeOffset receivedAt,
        CancellationToken cancellationToken)
        => RequestContext.Create(
            RequestId(context),
            TraceId(context),
            clientId,
            receivedAt,
            scope,
            deadlineAt: services.Options.RequestTimeout is { } timeout ? receivedAt + timeout : null,
            configGeneration: services.Options.ConfigGeneration,
            idempotencyKeyHash: idempotencyKeyHash,
            thread: ResolveThreadIdentity(context),
            cancellationToken: cancellationToken);

    public static void Record(IngressServices services, RequestExecutionResult result)
        => services.Observer?.OnCompleted(result);

    public static RequestExecutionResult Result(
        HttpContext context,
        IngressServices services,
        string clientId,
        string scope,
        RequestState state,
        int httpStatus,
        string? errorCode,
        string? idempotencyKeyHash,
        TimeSpan? ttft,
        DateTimeOffset receivedAt,
        bool stream,
        string? errorParam = null,
        string? errorDiagnosticClass = null,
        string? errorDiagnosticIdentity = null)
        => new()
        {
            RequestId = RequestId(context).Value,
            TraceId = TraceId(context).Value,
            ClientId = clientId,
            Scope = scope,
            State = state,
            HttpStatus = httpStatus,
            ErrorCode = errorCode,
            ErrorParam = errorParam,
            ErrorDiagnosticClass = errorDiagnosticClass,
            ErrorDiagnosticIdentity = errorDiagnosticIdentity,
            IdempotencyKeyHash = idempotencyKeyHash,
            Ttft = ttft,
            LatencyMs = (long?)Math.Round((services.Clock.UtcNow - receivedAt).TotalMilliseconds, MidpointRounding.AwayFromZero),
            Stream = stream,
        };
}
