using Router.Configuration;
using Router.Core.Concurrency;

namespace Router.Host;

/// <summary>
/// The one live runtime publication boundary of a running Router process.
///
/// It is invoked by <see cref="LocalRouterConfigOperator"/> INSIDE the config
/// mutation gate immediately after a successful durable commit, and it is the
/// only place where published config becomes live runtime state. One call
/// closes BOTH owners of that state synchronously and in order:
///
/// 1. the immutable <see cref="PublishedRouterState"/> every live reader uses
///    (feature gate, policy resolution, control-plane reads), and
/// 2. the runtime effective thread-selection capability of the single
///    <see cref="ThreadSelectionStore"/> this process owns.
///
/// Both updates happen inside ONE exclusive section of the shared
/// <see cref="IRouterRuntimeConsistencyGate"/>, and every thread-selection
/// operation plus every combined control-plane projection enters that same
/// boundary. An observer can therefore only complete on the OLD pair or the NEW
/// pair - never on a new published config combined with an old capability state
/// (or the reverse). The linearization point of a runtime publication is the
/// moment this exclusive section is released.
///
/// The effective capability is the conjunction of the overall Router feature
/// and the thread-selection feature: disabling the Router disables thread
/// selection too, which clears every pending/active selection and cancels every
/// capture. Re-enabling never resurrects a cleared selection.
///
/// This method is deliberately free of I/O, awaits, provider work, and
/// expected exceptions: it runs after the durable commit point, where nothing
/// may fail. Both underlying operations are in-memory atomic field updates.
/// </summary>
public sealed class RouterRuntimePublicationSink : IRouterConfigPublicationSink
{
    /// <summary>Cleared-reason recorded when the overall Router feature is disabled.</summary>
    public const string RouterDisabledReason = "router_disabled";

    /// <summary>Cleared-reason recorded when only thread selection is disabled.</summary>
    public const string ThreadSelectionDisabledReason = "thread_selection_disabled";

    private readonly CurrentRouterState _currentState;
    private readonly IRouterRuntimeFeatureState _threadSelection;
    private readonly IRouterRuntimeConsistencyGate _consistencyGate;

    public RouterRuntimePublicationSink(
        CurrentRouterState currentState,
        IRouterRuntimeFeatureState threadSelection,
        IRouterRuntimeConsistencyGate consistencyGate)
    {
        _currentState = currentState ?? throw new ArgumentNullException(nameof(currentState));
        _threadSelection = threadSelection ?? throw new ArgumentNullException(nameof(threadSelection));
        _consistencyGate = consistencyGate ?? throw new ArgumentNullException(nameof(consistencyGate));
    }

    /// <summary>The published-state owner this sink keeps current.</summary>
    public CurrentRouterState CurrentState => _currentState;

    /// <summary>The thread-selection runtime feature state this sink keeps current.</summary>
    public IRouterRuntimeFeatureState ThreadSelection => _threadSelection;

    /// <summary>The process-wide runtime consistency boundary this sink publishes under.</summary>
    public IRouterRuntimeConsistencyGate ConsistencyGate => _consistencyGate;

    /// <inheritdoc />
    public void Publish(PublishedRouterState state)
    {
        ArgumentNullException.ThrowIfNull(state);

        bool effective = state.LocalRouterEnabled && state.ThreadSelectionEnabled;
        string disabledReason = effective
            ? string.Empty
            : state.LocalRouterEnabled ? ThreadSelectionDisabledReason : RouterDisabledReason;

        // Runtime publication linearization point: the whole update below is one
        // exclusive section. No I/O, no await, no provider call, no queue.
        using (_consistencyGate.EnterExclusive())
        {
            // 1. Publish the immutable runtime view first so every live reader
            //    and control-plane read observes the same generation as the store.
            _currentState.Publish(state);

            // 2. Close the capability owner inside the same exclusive section.
            //    The call is boundary-free by contract; the section is already held.
            _threadSelection.ApplyPublishedState(effective, disabledReason);
        }
    }
}
