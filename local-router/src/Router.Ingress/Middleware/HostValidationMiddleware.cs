using System.Globalization;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Router.Core.Errors;

namespace Router.Ingress.Middleware;

/// <summary>
/// Rejects requests whose Host header does not match the loopback listener
/// contract (127.0.0.1 or 127.0.0.1:&lt;port&gt;). Alternate Host values,
/// localhost, hostnames, and forwarded identities are ignored or rejected.
/// </summary>
public sealed class HostValidationMiddleware
{
    private readonly RequestDelegate _next;

    public HostValidationMiddleware(RequestDelegate next)
    {
        _next = next;
    }

    public Task InvokeAsync(HttpContext context)
    {
        IngressRuntimeOptions options = context.RequestServices.GetRequiredService<IngressRuntimeOptions>();
        string? host = context.Request.Host.HasValue ? context.Request.Host.Value : null;
        int expectedPort = options.ActualPort > 0 ? options.ActualPort : options.Port;
        string hostWithPort = LoopbackBindPolicy.LoopbackHost + ":" + expectedPort.ToString(CultureInfo.InvariantCulture);

        bool valid = host is not null
            && (string.Equals(host, LoopbackBindPolicy.LoopbackHost, StringComparison.Ordinal)
                || string.Equals(host, hostWithPort, StringComparison.Ordinal));

        if (!valid)
        {
            RouterError error = RouterError.InvalidRequest("The Host header does not match the loopback listener.", "host", CurrentRequestId(context));
            return ErrorEnvelopeWriter.WriteAsync(context.Response, error, HttpStatusMapper.ToStatusCode(error), context.RequestAborted);
        }

        return _next(context);
    }

    private static string? CurrentRequestId(HttpContext context)
        => context.Items.TryGetValue(IngressContextKeys.RequestId, out object? value) && value is Router.Core.Ids.RequestId requestId
            ? requestId.Value
            : null;
}
