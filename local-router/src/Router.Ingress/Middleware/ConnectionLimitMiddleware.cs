using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Router.Core.Errors;

namespace Router.Ingress.Middleware;

/// <summary>
/// Bounded in-flight admission. At capacity the request is rejected with a
/// stable 429; the limiter never queues and releases on every exit path.
/// </summary>
public sealed class ConnectionLimitMiddleware
{
    private readonly RequestDelegate _next;

    public ConnectionLimitMiddleware(RequestDelegate next)
    {
        _next = next;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        ConnectionLimiter limiter = context.RequestServices.GetRequiredService<ConnectionLimiter>();
        if (!limiter.TryEnter())
        {
            RouterError error = RouterError.RateLimited(CurrentRequestId(context));
            await ErrorEnvelopeWriter
                .WriteAsync(context.Response, error, HttpStatusMapper.ToStatusCode(error), context.RequestAborted)
                .ConfigureAwait(false);
            return;
        }

        try
        {
            await _next(context).ConfigureAwait(false);
        }
        finally
        {
            limiter.Exit();
        }
    }

    private static string? CurrentRequestId(HttpContext context)
        => context.Items.TryGetValue(IngressContextKeys.RequestId, out object? value) && value is Router.Core.Ids.RequestId requestId
            ? requestId.Value
            : null;
}
