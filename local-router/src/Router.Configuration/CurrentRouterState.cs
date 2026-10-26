namespace Router.Configuration;

/// <summary>
/// Immutable, published Router runtime view consumed by live serving gates,
/// live policy resolution, and control-plane reads. One immutable snapshot per
/// successful mutation keeps feature state, policy state, and config
/// generation mutually consistent.
/// </summary>
public sealed record PublishedRouterState
{
    public required string ConfigGeneration { get; init; }

    public required bool LocalRouterEnabled { get; init; }

    /// <summary>
    /// HS-1B thread-selection capability state published with the same
    /// generation as the rest of the immutable snapshot.
    /// </summary>
    public bool ThreadSelectionEnabled { get; init; }

    public required IReadOnlyList<PolicyConfig> Policies { get; init; }

    public required IReadOnlyList<RouterRouteConfig> Routes { get; init; }

    public static PublishedRouterState From(RouterConfig config, string configGeneration)
    {
        ArgumentNullException.ThrowIfNull(config);
        ArgumentException.ThrowIfNullOrWhiteSpace(configGeneration);
        return new PublishedRouterState
        {
            ConfigGeneration = configGeneration,
            LocalRouterEnabled = config.LocalRouter.Enabled,
            ThreadSelectionEnabled = config.LocalRouter.ThreadSelection.Enabled,
            Policies = config.Policies,
            Routes = config.Routes,
        };
    }
}

/// <summary>
/// Thread-safe holder of the current published Router runtime view. Publish is
/// an atomic reference swap so readers always observe one complete immutable
/// generation and never a torn feature/policy combination.
/// </summary>
public sealed class CurrentRouterState : IRouterConfigPublicationSink
{
    private PublishedRouterState _current;

    public CurrentRouterState(PublishedRouterState initial)
    {
        _current = initial ?? throw new ArgumentNullException(nameof(initial));
    }

    public PublishedRouterState Snapshot => Volatile.Read(ref _current);

    public void Publish(PublishedRouterState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        _ = Interlocked.Exchange(ref _current, state);
    }
}
