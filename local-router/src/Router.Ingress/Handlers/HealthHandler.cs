using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Router.ClientAdapters.Responses;
using Router.Core.Lifecycle;

namespace Router.Ingress.Handlers;

/// <summary>
/// Public minimal health endpoint: schema version, lifecycle, and readiness
/// only. Never exposes routes, providers, models, paths, errors, or secrets.
/// </summary>
public static class HealthHandler
{
    public static Task HandleAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        LifecycleState state = services.Lifecycle.State;
        bool ready = state == LifecycleState.Ready;

        HealthPayload payload = new()
        {
            SchemaVersion = 1,
            Lifecycle = state.ToWireName(),
            Ready = ready,
        };

        context.Response.StatusCode = ready ? StatusCodes.Status200OK : StatusCodes.Status503ServiceUnavailable;
        context.Response.ContentType = "application/json";
        return context.Response.WriteAsync(JsonSerializer.Serialize(payload, ResponsesJson.Options), context.RequestAborted);
    }
}

/// <summary>Health payload: fixed allowed fields only.</summary>
public sealed record HealthPayload
{
    public required int SchemaVersion { get; init; }

    public required string Lifecycle { get; init; }

    public required bool Ready { get; init; }
}
