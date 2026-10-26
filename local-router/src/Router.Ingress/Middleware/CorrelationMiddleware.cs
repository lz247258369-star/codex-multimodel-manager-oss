using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Router.Core.Abstractions;
using Router.Core.Ids;

namespace Router.Ingress.Middleware;

/// <summary>
/// Assigns canonical request/trace IDs. Optional headers are accepted only when
/// they match the existing ID contract; unsafe values are replaced with freshly
/// generated IDs and never echoed.
/// </summary>
public sealed class CorrelationMiddleware
{
    private readonly RequestDelegate _next;

    public CorrelationMiddleware(RequestDelegate next)
    {
        _next = next;
    }

    public Task InvokeAsync(HttpContext context)
    {
        IIdGenerator idGenerator = context.RequestServices.GetRequiredService<IIdGenerator>();

        string? requested = context.Request.Headers["X-Request-Id"];
        string? trace = context.Request.Headers["traceparent"];

        RequestId requestId = RequestId.TryParse(requested, out RequestId parsedRequest) ? parsedRequest : idGenerator.NewRequestId();
        TraceId traceId = TraceId.TryParse(trace, out TraceId parsedTrace) ? parsedTrace : idGenerator.NewTraceId();

        context.Items[IngressContextKeys.RequestId] = requestId;
        context.Items[IngressContextKeys.TraceId] = traceId;

        context.Response.Headers["X-Request-Id"] = requestId.Value;
        context.Response.Headers["X-Trace-Id"] = traceId.Value;

        return _next(context);
    }
}
