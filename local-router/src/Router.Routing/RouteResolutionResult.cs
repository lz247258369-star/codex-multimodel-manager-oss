using Router.Core.Errors;

namespace Router.Routing;

/// <summary>Typed resolution outcome: exactly one of a resolved route or an error.</summary>
public sealed record RouteResolutionResult
{
    public ResolvedRoute? Route { get; init; }

    public RouterError? Error { get; init; }

    public bool IsResolved => Route is not null;

    public static RouteResolutionResult Resolved(ResolvedRoute route)
        => new() { Route = route };

    public static RouteResolutionResult Failed(RouterError error)
        => new() { Error = error };

    /// <summary>Validates the discriminated invariant.</summary>
    public void Validate()
    {
        if ((Route is null) == (Error is null))
        {
            throw new InvalidOperationException("A RouteResolutionResult must contain exactly one of route or error.");
        }
    }
}
