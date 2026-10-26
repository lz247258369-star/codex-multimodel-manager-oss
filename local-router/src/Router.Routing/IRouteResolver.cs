using Router.Core.Context;
using Router.Registries;

namespace Router.Routing;

/// <summary>
/// Selects exactly one eligible route from an immutable registry snapshot.
/// Resolution is pure and deterministic; health is an input, not mutable here.
/// </summary>
public interface IRouteResolver
{
    RouteResolutionResult Resolve(
        RouteRequest request,
        RouterRegistrySnapshot snapshot,
        RouteHealthSnapshot? health = null,
        RequestContext? context = null);
}
