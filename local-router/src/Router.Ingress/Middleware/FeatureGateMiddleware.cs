using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Router.Configuration;
using Router.Core.Errors;

namespace Router.Ingress.Middleware;

/// <summary>
/// Live Local Router feature gate for new Responses invocations. It reads the
/// same published current state that control-plane status exposes, so after a
/// successful live disable, requests that have not yet started fail closed
/// with a normalized error before any provider call. Already in-flight
/// requests follow existing Router semantics and are never force-killed.
/// </summary>
public sealed class FeatureGateMiddleware
{
    private readonly RequestDelegate _next;

    public FeatureGateMiddleware(RequestDelegate next)
    {
        _next = next;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        CurrentRouterState? currentState = services.ControlPlane?.CurrentState;
        if (currentState is null || currentState.Snapshot.LocalRouterEnabled)
        {
            await _next(context).ConfigureAwait(false);
            return;
        }

        RouterError error = RouterError.RouterDisabled(
            Router.Ingress.Handlers.RequestPipeline.RequestIdValue(context));
        await ErrorEnvelopeWriter.WriteAsync(
                context.Response,
                error,
                HttpStatusMapper.ToStatusCode(error),
                context.RequestAborted)
            .ConfigureAwait(false);
    }
}
