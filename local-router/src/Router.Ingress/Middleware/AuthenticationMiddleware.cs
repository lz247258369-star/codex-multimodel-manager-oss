using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;

namespace Router.Ingress.Middleware;

/// <summary>
/// Bearer authentication for protected endpoints. /health stays anonymous.
/// Scope enforcement is endpoint-specific and occurs in the handlers.
/// </summary>
public sealed class AuthenticationMiddleware
{
    private readonly RequestDelegate _next;

    public AuthenticationMiddleware(RequestDelegate next)
    {
        _next = next;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        TokenAuthenticator authenticator = context.RequestServices.GetRequiredService<TokenAuthenticator>();
        TokenAuthenticationResult result = await authenticator
            .ValidateAsync(context.Request.Headers.Authorization, context.RequestAborted)
            .ConfigureAwait(false);

        if (!result.IsSuccess || result.Error is not null)
        {
            Router.Core.Errors.RouterError error = result.Error! with { RequestId = CurrentRequestId(context) };
            await ErrorEnvelopeWriter
                .WriteAsync(context.Response, error, HttpStatusMapper.ToStatusCode(error), context.RequestAborted)
                .ConfigureAwait(false);
            return;
        }

        await _next(context).ConfigureAwait(false);
    }

    private static string? CurrentRequestId(HttpContext context)
        => context.Items.TryGetValue(IngressContextKeys.RequestId, out object? value) && value is Router.Core.Ids.RequestId requestId
            ? requestId.Value
            : null;
}
