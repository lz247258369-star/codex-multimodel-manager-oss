using Router.Core.Errors;

namespace Router.Registries;

/// <summary>Stable, content-free registry construction errors.</summary>
public static class RegistryErrors
{
    public static RouterError Invalid(string? param = null)
        => RouterError.Create(RouterErrorCode.InvalidRegistry, "The router registry is invalid.", param);

    public static RouterError Duplicate(string? param = null)
        => RouterError.Create(RouterErrorCode.DuplicateRegistryKey, "A duplicate registry key was detected.", param);

    public static RouterError UnknownClient(string? param = null)
        => RouterError.Create(RouterErrorCode.UnknownClient, "The client is not registered.", param);

    public static RouterError UnknownProvider(string? param = null)
        => RouterError.Create(RouterErrorCode.UnknownProvider, "The provider is not registered.", param);

    public static RouterError UnknownProtocol(string? param = null)
        => RouterError.Create(RouterErrorCode.UnknownProtocol, "The protocol is not registered.", param);

    public static RouterError UnknownModel(string? param = null)
        => RouterError.Create(RouterErrorCode.UnknownModel, "The model mapping is not registered.", param);

    public static RouterError UnknownRoute(string? param = null)
        => RouterError.Create(RouterErrorCode.UnknownRoute, "The route is not registered.", param);

    public static RouterError UnknownEndpoint(string? param = null)
        => RouterError.Create(RouterErrorCode.UnknownEndpoint, "The endpoint is not registered.", param);

    public static RouterError UnknownPolicy(string? param = null)
        => RouterError.Create(RouterErrorCode.InvalidRegistry, "The policy reference is not registered.", param);

    public static RouterError AmbiguousModel(string? param = null)
        => RouterError.Create(RouterErrorCode.AmbiguousModel, "The requested model mapping is ambiguous within its provider scope.", param);

    public static RouterError InvalidProviderModelRelation(string? param = null)
        => RouterError.Create(RouterErrorCode.InvalidProviderModelRelation, "The route links a provider route and a model route of different providers.", param);

    public static RouterError InvalidEndpointReference(string? param = null)
        => RouterError.Create(RouterErrorCode.InvalidEndpointReference, "The provider route has no usable endpoint.", param);
}
