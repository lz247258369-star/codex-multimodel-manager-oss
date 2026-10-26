using Router.Core.Errors;

namespace Router.Routing;

/// <summary>Stable, content-free route resolution errors.</summary>
public static class RoutingErrors
{
    public static RouterError RouteNotFound(string? requestId = null)
        => RouterError.RouteNotFound(requestId);

    public static RouterError UnknownClient(string? requestId = null)
        => RouterError.Create(RouterErrorCode.UnknownClient, "The client is not registered.", "client", requestId);

    public static RouterError ClientDisabled(string? requestId = null)
        => RouterError.Create(RouterErrorCode.RouteIneligible, "The client is disabled.", "client", requestId);

    public static RouterError UnknownModel(string? requestId = null)
        => RouterError.Create(RouterErrorCode.UnknownModel, "No provider-scoped mapping exists for the requested model.", "model", requestId);

    public static RouterError UnknownProvider(string? requestId = null)
        => RouterError.Create(RouterErrorCode.UnknownProvider, "The provider is not registered.", "provider", requestId);

    public static RouterError UnknownProtocol(string? requestId = null)
        => RouterError.Create(RouterErrorCode.UnknownProtocol, "The protocol is not registered.", "protocol", requestId);

    public static RouterError UnknownRoute(string? requestId = null)
        => RouterError.Create(RouterErrorCode.UnknownRoute, "The route is not registered.", "route", requestId);

    public static RouterError AmbiguousModel(string? requestId = null)
        => RouterError.Create(RouterErrorCode.AmbiguousModel, "The requested model mapping is ambiguous.", "model", requestId);

    public static RouterError ExplicitRoutePreferenceInvalid(string? requestId = null)
        => RouterError.Create(RouterErrorCode.ExplicitRoutePreferenceInvalid, "The explicit route preference is not allowed or not eligible.", "route", requestId);

    public static RouterError RouteDisabled(string? requestId = null)
        => RouterError.RouteDisabled(requestId);

    public static RouterError RouteNotAllowed(string? requestId = null)
        => RouterError.Create(RouterErrorCode.RouteNotAllowed, "The client is not authorized for the route.", "route", requestId);

    public static RouterError PlaceholderUnavailable(string? requestId = null)
        => RouterError.Create(RouterErrorCode.PlaceholderUnavailable, "A provider or protocol placeholder cannot serve this route.", null, requestId);

    public static RouterError UnsupportedCapability(string? capability = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.UnsupportedCapability, "The route cannot preserve the required semantics.", capability, requestId);

    public static RouterError RouteIneligible(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.RouteIneligible, "The route is not eligible.", param, requestId);

    public static RouterError InvalidEndpointReference(string? requestId = null)
        => RouterError.Create(RouterErrorCode.InvalidEndpointReference, "The provider route has no usable endpoint.", "endpoint", requestId);

    public static RouterError GenerationMismatch(string? requestId = null)
        => RouterError.Create(RouterErrorCode.InvalidRegistry, "The request context generation does not match the registry snapshot generation.", null, requestId);
}
