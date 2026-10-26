using Router.ClientAdapters.Responses;
using Router.Core.Abstractions;
using Router.Core.Lifecycle;
using Router.Secrets;

namespace Router.Ingress;

/// <summary>Aggregate of services consumed by ingress handlers.</summary>
public sealed record IngressServices
{
    public required IngressRuntimeOptions Options { get; init; }

    public required IResponsesService Service { get; init; }

    public required IClock Clock { get; init; }

    public required IIdGenerator IdGenerator { get; init; }

    public required ConnectionLimiter Limiter { get; init; }

    public required ClientScopeRegistry ScopeRegistry { get; init; }

    public required RouterLifecycle Lifecycle { get; init; }

    public required IngressRequestObserver? Observer { get; init; }

    public required CancellationTokenSource ShutdownCts { get; init; }

    /// <summary>LR-14P control-plane runtime services, when composed.</summary>
    public ControlPlaneRuntimeServices? ControlPlane { get; init; }
}
