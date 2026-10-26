using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.Core.Lifecycle;

namespace Router.Ingress.Handlers;

/// <summary>
/// Authenticated redacted status endpoint. Requires the router:status scope and
/// returns lifecycle, config generation, in-flight count, feature flag,
/// supported contracts, and an empty route list. Never returns secrets, raw
/// secret refs, base URLs, request content, or paths.
/// </summary>
public static class StatusHandler
{
    public const string RequiredScope = "router:status";

    public static async Task HandleAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        DateTimeOffset receivedAt = services.Clock.UtcNow;
        string requestId = RequestPipeline.RequestIdValue(context);

        if (!services.ScopeRegistry.TryResolve(RequiredScope, out string clientId))
        {
            RouterError error = RouterError.ScopeDenied(requestId);
            await ErrorEnvelopeWriter
                .WriteAsync(context.Response, error, HttpStatusMapper.ToStatusCode(error), context.RequestAborted)
                .ConfigureAwait(false);
            RequestPipeline.Record(services, RequestPipeline.Result(context, services, clientId, RequiredScope, RequestState.Failed, HttpStatusMapper.ToStatusCode(error), error.Code, null, null, receivedAt, stream: false));
            return;
        }

        LifecycleState state = services.Lifecycle.State;
        RouterStatusPayload payload = new()
        {
            SchemaVersion = 1,
            Lifecycle = state.ToWireName(),
            Ready = state == LifecycleState.Ready,
            ConfigGeneration = services.Options.ConfigGeneration,
            InFlightCount = services.Limiter.InFlightCount,
            LocalRouterEnabled = true,
            SupportedContracts = ["responses/v1"],
            Routes = [],
        };

        context.Response.StatusCode = StatusCodes.Status200OK;
        context.Response.ContentType = "application/json";
        await context.Response
            .WriteAsync(JsonSerializer.Serialize(payload, ResponsesJson.Options), context.RequestAborted)
            .ConfigureAwait(false);

        RequestPipeline.Record(services, RequestPipeline.Result(context, services, clientId, RequiredScope, RequestState.Completed, StatusCodes.Status200OK, null, null, null, receivedAt, stream: false));
    }
}

/// <summary>Redacted status payload.</summary>
public sealed record RouterStatusPayload
{
    public required int SchemaVersion { get; init; }

    public required string Lifecycle { get; init; }

    public required bool Ready { get; init; }

    public required string ConfigGeneration { get; init; }

    public required int InFlightCount { get; init; }

    public required bool LocalRouterEnabled { get; init; }

    public required IReadOnlyList<string> SupportedContracts { get; init; }

    public required IReadOnlyList<object> Routes { get; init; }
}
