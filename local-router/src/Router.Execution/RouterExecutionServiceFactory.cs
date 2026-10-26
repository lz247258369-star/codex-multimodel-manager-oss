using Router.CircuitBreaker;
using Router.Configuration;
using Router.Core.Abstractions;
using Router.Core.Context;
using Router.Core.Errors;
using Router.Health;
using Router.ProviderAdapters.Abstractions;
using Router.ProtocolAdapters.Abstractions;
using Router.Registries;
using Router.Routing;
using Router.Secrets;
using Router.UpstreamHttp;

namespace Router.Execution;

/// <summary>
/// Composition factory that turns one immutable effective config snapshot into
/// a production execution service. Registry, adapter, transport, endpoint, and
/// policy wiring is explicit; any invariant violation fails closed before the
/// service is returned. The optional thread model selection source (HS-1B) is
/// injected by the caller: when it is omitted the resulting service keeps the
/// legacy behavior of resolving exactly the Codex requested model.
/// </summary>
public static class RouterExecutionServiceFactory
{
    /// <summary>Creates the production service, or a typed startup error.</summary>
    public static RouterExecutionServiceFactoryResult Create(
        EffectiveRouterConfigSnapshot effectiveConfig,
        ISecretResolver secretResolver,
        HttpMessageHandler? transportHandler = null,
        RouterExecutionPolicySet? policies = null,
        IReadOnlyDictionary<string, string>? endpointOverrides = null,
        IClock? clock = null,
        CircuitBreakerPolicy? circuitBreakerPolicy = null,
        PassiveHealthPolicy? passiveHealthPolicy = null,
        IExecutionOutcomeSink? outcomeSink = null,
        IRouterExecutionPolicySource? policySource = null,
        IThreadModelSelectionSource? threadModelSelectionSource = null)
    {
        ArgumentNullException.ThrowIfNull(effectiveConfig);
        ArgumentNullException.ThrowIfNull(secretResolver);

        RegistrySnapshotBuildResult registryResult = RegistrySnapshotBuilder.Build(
            effectiveConfig,
            catalogProjection: null,
            RouterExecutionDefaults.RegistryRegistrations);
        if (!registryResult.IsSnapshot() || registryResult.Snapshot is null)
        {
            return RouterExecutionServiceFactoryResult.Fail(
                registryResult.Error ?? RegistryErrors.Invalid());
        }

        ProviderAdapterRegistry providerAdapters;
        ProtocolAdapterRegistry protocolAdapters;
        HttpUpstreamTransport transport;
        try
        {
            providerAdapters = RouterExecutionDefaults.CreateProviderAdapterRegistry();
            protocolAdapters = RouterExecutionDefaults.CreateProtocolAdapterRegistry();
            transport = transportHandler is null
                ? new HttpUpstreamTransport()
                : new HttpUpstreamTransport(transportHandler);
        }
        catch (Exception)
        {
            return RouterExecutionServiceFactoryResult.Fail(
                ProviderAdapterErrors.AdapterRegistrationInvalid());
        }

        try
        {
            var endpointSource = new RouterExecutionEndpointSource(loopbackOverrides: endpointOverrides);
            CircuitBreakerStateMachine breaker = circuitBreakerPolicy is null
                ? new CircuitBreakerStateMachine(CircuitBreakerPolicy.Disabled)
                : new CircuitBreakerStateMachine(circuitBreakerPolicy);
            PassiveHealthTracker? health = passiveHealthPolicy is null
                ? null
                : new PassiveHealthTracker(passiveHealthPolicy);

            RouterExecutionResponsesService service = new(
                registryResult.Snapshot,
                new RouteResolver(),
                providerAdapters,
                protocolAdapters,
                secretResolver,
                transport,
                endpointSource,
                policies,
                clock,
                circuitBreaker: breaker,
                passiveHealth: health,
                outcomeSink: outcomeSink,
                policySource: policySource,
                threadModelSelectionSource: threadModelSelectionSource,
                quotaFailoverEnabled: effectiveConfig.Config.LocalRouter.ThreadSelection.QuotaFailoverEnabled);
            return RouterExecutionServiceFactoryResult.Ok(service);
        }
        catch (Exception)
        {
            transport.Dispose();
            return RouterExecutionServiceFactoryResult.Fail(RegistryErrors.Invalid());
        }
    }
}

/// <summary>Typed factory outcome: exactly one of a service or an error.</summary>
public sealed record RouterExecutionServiceFactoryResult
{
    public RouterExecutionResponsesService? Service { get; init; }

    public RouterError? Error { get; init; }

    public bool IsSuccess => Service is not null && Error is null;

    public static RouterExecutionServiceFactoryResult Ok(RouterExecutionResponsesService service)
        => new() { Service = service };

    public static RouterExecutionServiceFactoryResult Fail(RouterError error)
        => new() { Error = error };

    /// <summary>Validates the discriminated invariant.</summary>
    public void Validate()
    {
        if ((Service is null) == (Error is null))
        {
            throw new InvalidOperationException("A factory result must contain exactly one of service or error.");
        }
    }
}

/// <summary>Snapshot-build discriminated-state helper.</summary>
internal static class RegistrySnapshotBuildResultExtensions
{
    public static bool IsSnapshot(this RegistrySnapshotBuildResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        return result.Snapshot is not null && result.Error is null;
    }
}
