using Microsoft.AspNetCore.Http;
using Router.Core.Errors;

namespace Router.Ingress.Middleware;

/// <summary>
/// Strict browser/CSRF boundary. Any Origin-bearing request is denied unless
/// its exact value is in the explicit allowlist. A wildcard is never honored,
/// no CORS headers are emitted, and an Origin can never bypass authentication.
/// </summary>
public sealed class OriginPolicyMiddleware
{
    private readonly RequestDelegate _next;
    private readonly HashSet<string> _allowedOrigins;

    public OriginPolicyMiddleware(RequestDelegate next, IngressRuntimeOptions options)
    {
        _next = next;
        _allowedOrigins = options.AllowedOrigins
            .Where(static origin => !string.Equals(origin, "*", StringComparison.Ordinal))
            .ToHashSet(StringComparer.Ordinal);
    }

    public Task InvokeAsync(HttpContext context)
    {
        if (context.Request.Headers.TryGetValue("Origin", out Microsoft.Extensions.Primitives.StringValues originValues))
        {
            string origin = originValues.ToString();
            if (!_allowedOrigins.Contains(origin))
            {
                RouterError error = RouterError.OriginForbidden(CurrentRequestId(context));
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
