using Router.Configuration;
using Router.Core.Concurrency;
using Router.Core.Context;
using Router.Health;
using Router.Metering;
using Router.Observability;
using Router.ThreadSelection;

namespace Router.Ingress;

/// <summary>
/// Production runtime services composed into one ingress for the LR-14P
/// control-plane surface. The metering service and durable log are the exact
/// instances written by the production completion observer; the config
/// operator is host-independent and never depends on the HTTP server being
/// alive.
/// </summary>
public sealed record ControlPlaneRuntimeServices
{
    public RequestMeteringService? Metering { get; init; }

    public DurableRequestLog? RequestLog { get; init; }

    public LocalRouterConfigOperator? ConfigOperator { get; init; }

    /// <summary>
    /// Published current Router state shared with production execution. When
    /// non-null, live feature gating and live policy resolution read the same
    /// immutable snapshot that control-plane status/policy reads expose.
    /// </summary>
    public CurrentRouterState? CurrentState { get; init; }

    /// <summary>Read-only view of the production passive-health tracker.</summary>
    public IRouterHealthSnapshotSource? Health { get; init; }

    /// <summary>
    /// The live runtime publication sink this process actually publishes
    /// through, when the Host composes one. Mutation availability is proven by
    /// reference identity against the operator's own publication sink, so an
    /// offline operator can never claim a mutation took effect.
    /// </summary>
    public IRouterConfigPublicationSink? RuntimePublicationSink { get; init; }

    /// <summary>
    /// The process-wide runtime consistency boundary shared by the runtime
    /// publication sink and the single thread-selection store. Combined
    /// control-plane projections (status, thread-selection feature) read the
    /// published config and the capability summary inside one shared section so
    /// they can never combine a new published generation with an old capability
    /// state, or the reverse.
    /// </summary>
    public IRouterRuntimeConsistencyGate? RuntimeConsistencyGate { get; init; }

    /// <summary>
    /// The one router-process thread-selection store also consumed by
    /// production execution, when HS-1B is composed. The control plane shares
    /// this exact instance; a second store must never be created.
    /// </summary>
    public ThreadSelectionStore? ThreadSelection { get; init; }

    /// <summary>
    /// Static approved-model validator bound to the production registry
    /// snapshot. Null when no production execution service is composed, in
    /// which case selecting a model is unavailable rather than unvalidated.
    /// </summary>
    public IApprovedModelValidator? ApprovedModelValidator { get; init; }
}
