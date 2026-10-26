namespace Router.Health;

/// <summary>
/// Read-only source of the current passive-health projection. The control
/// plane consumes the exact <see cref="PassiveHealthTracker"/> instance used by
/// production execution; it never creates a second tracker.
/// </summary>
public interface IRouterHealthSnapshotSource
{
    RouteHealthProjection Snapshot();
}

/// <summary>Adapter over the production passive-health tracker.</summary>
public sealed class PassiveHealthSnapshotSource : IRouterHealthSnapshotSource
{
    private readonly PassiveHealthTracker _tracker;
    private readonly Func<DateTimeOffset> _clock;

    public PassiveHealthSnapshotSource(PassiveHealthTracker tracker, Func<DateTimeOffset>? clock = null)
    {
        _tracker = tracker ?? throw new ArgumentNullException(nameof(tracker));
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public RouteHealthProjection Snapshot()
        => _tracker.ProjectRoutes(_clock());
}
