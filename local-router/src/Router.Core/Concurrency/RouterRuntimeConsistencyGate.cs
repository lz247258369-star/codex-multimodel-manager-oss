namespace Router.Core.Concurrency;

/// <summary>
/// The single Router-process runtime consistency boundary.
///
/// Two runtime owners form one observable pair: the immutable
/// <c>PublishedRouterState</c> (config generation, Router feature, policies) and
/// the runtime effective state of the thread-selection capability. A new
/// published generation and the capability transition it implies are applied
/// inside ONE exclusive runtime consistency section, and every reader or
/// mutator of either side enters the same boundary. An observer can therefore
/// only ever complete while holding the OLD pair or the NEW pair - never a new
/// published config combined with an old capability state, and never the
/// reverse.
///
/// The boundary is process-wide: exactly one instance is composed by the
/// production Host and shared by the runtime publication sink, the
/// thread-selection store, and the control-plane combined projections. A
/// subsystem must never create its own private boundary for this pair.
///
/// Sections are synchronous by contract: a boundary must never be held across
/// an await, and an exclusive section must contain no I/O, provider call,
/// filesystem access, background queue, or task scheduling.
/// </summary>
public interface IRouterRuntimeConsistencyGate
{
    /// <summary>
    /// Enters a section that only observes the runtime pair. Shared sections
    /// exclude the exclusive publication section, and may nest on the same
    /// thread so a combined read can legitimately read several domains.
    /// </summary>
    IDisposable EnterShared();

    /// <summary>
    /// Enters the section that publishes a new runtime pair. Exclusive sections
    /// exclude every shared section and every other exclusive section.
    /// </summary>
    IDisposable EnterExclusive();
}

/// <summary>
/// Runtime effective feature state of a domain that participates in the Router
/// runtime consistency boundary.
/// </summary>
public interface IRouterRuntimeFeatureState
{
    /// <summary>Effective capability state currently applied at runtime.</summary>
    bool Enabled { get; }

    /// <summary>
    /// Applies a published effective state.
    ///
    /// The caller MUST already hold the runtime consistency boundary
    /// exclusively; implementations therefore never re-acquire it, and they
    /// perform no I/O, await, or provider work. Disabling clears every pending
    /// and active selection plus every capture; enabling grants the capability
    /// only and never creates state.
    /// </summary>
    void ApplyPublishedState(bool enabled, string disabledReason);
}

/// <summary>
/// Default runtime consistency boundary: one reentrant mutual-exclusion
/// section. Exclusive and shared sections serialize against each other, and
/// same-thread nesting is permitted so a combined read may call domain APIs
/// that take the boundary themselves.
/// </summary>
public sealed class RouterRuntimeConsistencyGate : IRouterRuntimeConsistencyGate
{
    private readonly object _sync = new();

    /// <inheritdoc />
    public IDisposable EnterShared() => Enter();

    /// <inheritdoc />
    public IDisposable EnterExclusive() => Enter();

    private Section Enter()
    {
        Monitor.Enter(_sync);
        return new Section(_sync);
    }

    private sealed class Section : IDisposable
    {
        private object? _sync;

        public Section(object sync)
        {
            _sync = sync;
        }

        public void Dispose()
        {
            object? sync = Interlocked.Exchange(ref _sync, null);
            if (sync is not null)
            {
                Monitor.Exit(sync);
            }
        }
    }
}
