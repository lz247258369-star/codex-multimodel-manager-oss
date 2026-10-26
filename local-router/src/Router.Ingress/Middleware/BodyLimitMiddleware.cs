using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Router.Core.Errors;

namespace Router.Ingress.Middleware;

/// <summary>
/// Pre-parse body guards: compressed request bodies are rejected fail-closed
/// and explicit Content-Length over the configured limit is rejected with 413.
/// Actual byte enforcement happens while reading (see ResponsesHandler).
/// </summary>
public sealed class BodyLimitMiddleware
{
    private readonly RequestDelegate _next;

    public BodyLimitMiddleware(RequestDelegate next)
    {
        _next = next;
    }

    public Task InvokeAsync(HttpContext context)
    {
        if (HttpMethods.IsPost(context.Request.Method))
        {
            string? contentEncoding = context.Request.Headers.ContentEncoding;
            if (!string.IsNullOrEmpty(contentEncoding)
                && !string.Equals(contentEncoding, "identity", StringComparison.OrdinalIgnoreCase))
            {
                RouterError error = RouterError.UnsupportedParameter("content_encoding", CurrentRequestId(context));
                return ErrorEnvelopeWriter.WriteAsync(context.Response, error, HttpStatusMapper.ToStatusCode(error), context.RequestAborted);
            }

            IngressRuntimeOptions options = context.RequestServices.GetRequiredService<IngressRuntimeOptions>();
            long maxBytes = Math.Min(options.Limits.MaxRequestBytes, Router.Configuration.ConfigLimitCeilings.MaxRequestBytesCeiling);
            if (context.Request.ContentLength is { } contentLength && contentLength > maxBytes)
            {
                RouterError error = RouterError.RequestTooLarge(CurrentRequestId(context));
                return ErrorEnvelopeWriter.WriteAsync(context.Response, error, HttpStatusMapper.ToStatusCode(error), context.RequestAborted);
            }
        }

        return _next(context);
    }

    private static string? CurrentRequestId(HttpContext context)
        => context.Items.TryGetValue(IngressContextKeys.RequestId, out object? value) && value is Router.Core.Ids.RequestId requestId
            ? requestId.Value
            : null;
}
