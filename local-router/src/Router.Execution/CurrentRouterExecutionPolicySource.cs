using Router.Configuration;
using Router.Routing;

namespace Router.Execution;

/// <summary>
/// Live policy source backed by the published current Router state. Each new
/// logical request reads one immutable current snapshot at its request
/// boundary; a successful control-plane mutation atomically publishes a new
/// snapshot that the very next request observes without any service restart.
/// Policy algorithms are never modified.
/// </summary>
public sealed class CurrentRouterExecutionPolicySource : IRouterExecutionPolicySource
{
    private readonly CurrentRouterState _state;

    public CurrentRouterExecutionPolicySource(CurrentRouterState state)
    {
        _state = state ?? throw new ArgumentNullException(nameof(state));
    }

    public RouterExecutionPolicySet Resolve(ResolvedRoute route)
    {
        PublishedRouterState snapshot = _state.Snapshot;
        return new ConfigRouterExecutionPolicySource(snapshot.Policies).Resolve(route);
    }
}
