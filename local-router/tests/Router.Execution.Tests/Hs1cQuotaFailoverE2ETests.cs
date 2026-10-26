using ProviderContractKit;
using Router.ClientAdapters.Responses;
using Router.Configuration;
using Router.Core.Abstractions;
using Router.Core.Context;
using Router.Core.Errors;
using Router.Core.Ids;
using Router.FakeProvider;
using Router.Health;
using Router.Secrets;
using Router.ThreadSelection;
using Xunit;

namespace Router.Execution.Tests;

public sealed class Hs1cQuotaFailoverE2ETests
{
    private const string ThreadId = "01a09dae-3db7-7820-8912-0d86815051a6";

    [Fact]
    public async Task Exhaustion_chain_sticks_manual_recovery_and_rearms_automatic_failover()
    {
        ProviderExecutionSpec primarySpec = ExecutionTestConfigFactory.OpenAiApi;
        ProviderExecutionSpec firstFallbackSpec = ExecutionTestConfigFactory.MiMo;
        ProviderExecutionSpec secondFallbackSpec = ExecutionTestConfigFactory.ModelStudio;

        await using var primaryServer = new FakeProviderServer();
        await using var firstFallbackServer = new FakeProviderServer();
        await using var secondFallbackServer = new FakeProviderServer();
        await primaryServer.StartAsync();
        await firstFallbackServer.StartAsync();
        await secondFallbackServer.StartAsync();

        primaryServer.SetScenario(FakeProviderScenario.Json(
            429,
            "{\"error\":{\"type\":\"insufficient_quota\",\"code\":null}}"));
        firstFallbackServer.SetScenario(FakeProviderScenario.Json(
            402,
            "{\"error\":{\"message\":\"credit exhausted\"}}"));
        secondFallbackServer.SetScenario(FakeProviderScenario.Json(
            200,
            SseFixtureBuilder.NonStreamJson("fallback-ok")));

        RouterRouteConfig firstFallback = ExecutionTestConfigFactory.Route(
            firstFallbackSpec.ProviderId,
            firstFallbackSpec.RouteId);
        RouterRouteConfig secondFallback = ExecutionTestConfigFactory.Route(
            secondFallbackSpec.ProviderId,
            secondFallbackSpec.RouteId);
        RouterRouteConfig primary = ExecutionTestConfigFactory.Route(
            primarySpec.ProviderId,
            primarySpec.RouteId) with
        {
            FallbackRouteIds = [firstFallback.RouteId, secondFallback.RouteId],
        };

        EffectiveRouterConfigSnapshot baseSnapshot = ExecutionTestConfigFactory.Snapshot(
            [primary, firstFallback, secondFallback],
            "hs1c-quota-failover-e2e");
        EffectiveRouterConfigSnapshot snapshot = baseSnapshot with
        {
            Config = baseSnapshot.Config with
            {
                Mode = RouterMode.Router,
                LocalRouter = baseSnapshot.Config.LocalRouter with
                {
                    Enabled = true,
                    ThreadSelection = new ThreadSelectionConfig
                    {
                        Enabled = true,
                        QuotaFailoverEnabled = true,
                    },
                },
            },
        };

        var secretResolver = new FakeSecretResolver();
        secretResolver.Configure(primarySpec.ProviderId, primarySpec.SecretEnvironmentName, "primary-secret");
        secretResolver.Configure(firstFallbackSpec.ProviderId, firstFallbackSpec.SecretEnvironmentName, "fallback-one-secret");
        secretResolver.Configure(secondFallbackSpec.ProviderId, secondFallbackSpec.SecretEnvironmentName, "fallback-two-secret");

        var endpointOverrides = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [primarySpec.EndpointBaseUrlReference] = new Uri(primaryServer.BaseUri, primarySpec.FakeBasePath).ToString(),
            [firstFallbackSpec.EndpointBaseUrlReference] = new Uri(firstFallbackServer.BaseUri, firstFallbackSpec.FakeBasePath).ToString(),
            [secondFallbackSpec.EndpointBaseUrlReference] = new Uri(secondFallbackServer.BaseUri, secondFallbackSpec.FakeBasePath).ToString(),
        };

        IClock clock = new SystemClock();
        var store = new ThreadSelectionStore(
            ThreadSelectionOptions.Create(
                ThreadSelectionOptions.DefaultMaxObservedThreads,
                ThreadSelectionOptions.DefaultEntryIdleTtl,
                ThreadSelectionOptions.DefaultPendingTtl,
                ThreadSelectionOptions.DefaultActiveIdleTtl),
            clock,
            enabled: true);

        RouterExecutionServiceFactoryResult created = RouterExecutionServiceFactory.Create(
            snapshot,
            secretResolver,
            transportHandler: new LoopbackOnlyHandler(),
            endpointOverrides: endpointOverrides,
            passiveHealthPolicy: PassiveHealthPolicy.Default,
            threadModelSelectionSource: store);
        Assert.True(
            created.IsSuccess,
            created.Error?.Code + ": " + created.Error?.Message + " (" + created.Error?.Param + ")");

        using RouterExecutionResponsesService service = created.Service!;

        CanonicalResponsesRequest request = new()
        {
            Model = primarySpec.ClientModelId,
            Input = [],
            Stream = false,
        };

        // Primary is exhausted; first explicit fallback is exhausted too;
        // second explicit fallback succeeds and becomes sticky.
        ResponsesServiceResult first = await service.InvokeAsync(
            request,
            CreateContext(snapshot, clock),
            CancellationToken.None);

        Assert.Null(first.Error);
        Assert.NotNull(first.Response);
        Assert.Equal(secondFallbackSpec.ProviderId, first.Execution!.ProviderId);
        Assert.Equal(3, first.Execution.AttemptCount);

        string threadRef = RefOfThread();
        ThreadSelectionSnapshot afterFailover = store.TryGet(threadRef)!;
        Assert.Equal(ThreadSelectionState.Active, afterFailover.SelectionState);
        Assert.Equal(secondFallbackSpec.ClientModelId, afterFailover.SelectionModel);
        Assert.Equal(QuotaAvailabilityState.Exhausted, service.QuotaAvailability.Get(primary.RouteId).State);
        Assert.Equal(QuotaAvailabilityState.Exhausted, service.QuotaAvailability.Get(firstFallback.RouteId).State);
        Assert.Equal(QuotaAvailabilityState.Available, service.QuotaAvailability.Get(secondFallback.RouteId).State);

        // The original quota recovers. Automation does NOT jump back by itself:
        // the next turn stays on the sticky fallback.
        primaryServer.SetScenario(FakeProviderScenario.Json(
            200,
            SseFixtureBuilder.NonStreamJson("primary-recovered")));
        ResponsesServiceResult sticky = await service.InvokeAsync(
            request,
            CreateContext(snapshot, clock),
            CancellationToken.None);
        Assert.Null(sticky.Error);
        Assert.Equal(secondFallbackSpec.ProviderId, sticky.Execution!.ProviderId);

        // User manually selects the recovered primary. Manual choice is
        // authoritative and a successful real request clears last-known
        // exhaustion for that route.
        ThreadSelectionSnapshot beforeManual = store.TryGet(threadRef)!;
        ThreadSelectionOperationResult manual = store.SetSelection(
            threadRef,
            primarySpec.ClientModelId,
            beforeManual.SelectionGeneration);
        Assert.Equal(ThreadSelectionOperationStatus.Applied, manual.Status);

        ResponsesServiceResult recovered = await service.InvokeAsync(
            request,
            CreateContext(snapshot, clock),
            CancellationToken.None);
        Assert.Null(recovered.Error);
        Assert.Equal(primarySpec.ProviderId, recovered.Execution!.ProviderId);
        Assert.Equal(QuotaAvailabilityState.Available, service.QuotaAvailability.Get(primary.RouteId).State);
        Assert.Equal(primarySpec.ClientModelId, store.TryGet(threadRef)!.SelectionModel);

        // Exhaust it again. Automatic failover is re-armed after the manual
        // switch; the known-exhausted first fallback is skipped and the known
        // available second fallback takes over again.
        primaryServer.SetScenario(FakeProviderScenario.Json(
            429,
            "{\"error\":{\"type\":\"insufficient_quota\"}}"));

        ResponsesServiceResult rearmed = await service.InvokeAsync(
            request,
            CreateContext(snapshot, clock),
            CancellationToken.None);

        Assert.Null(rearmed.Error);
        Assert.Equal(secondFallbackSpec.ProviderId, rearmed.Execution!.ProviderId);
        Assert.Equal(secondFallbackSpec.ClientModelId, store.TryGet(threadRef)!.SelectionModel);
        Assert.Equal(QuotaAvailabilityState.Exhausted, service.QuotaAvailability.Get(primary.RouteId).State);
    }

    [Fact]
    public async Task Ordinary_429_never_activates_cross_model_quota_failover()
    {
        ProviderExecutionSpec spec = ExecutionTestConfigFactory.OpenAiApi;
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(
            429,
            "{\"error\":{\"type\":\"rate_limit_error\",\"code\":\"rate_limit_exceeded\"}}"));

        RouterRouteConfig route = ExecutionTestConfigFactory.Route(spec.ProviderId, spec.RouteId);
        EffectiveRouterConfigSnapshot baseSnapshot = ExecutionTestConfigFactory.Snapshot(
            [route],
            "hs1c-rate-limit-no-switch");
        EffectiveRouterConfigSnapshot snapshot = baseSnapshot with
        {
            Config = baseSnapshot.Config with
            {
                Mode = RouterMode.Router,
                LocalRouter = baseSnapshot.Config.LocalRouter with
                {
                    Enabled = true,
                    ThreadSelection = new ThreadSelectionConfig
                    {
                        Enabled = true,
                        QuotaFailoverEnabled = true,
                    },
                },
            },
        };

        var secrets = new FakeSecretResolver();
        secrets.Configure(spec.ProviderId, spec.SecretEnvironmentName, "primary-secret");
        IClock clock = new SystemClock();
        var store = new ThreadSelectionStore(
            ThreadSelectionOptions.Create(
                ThreadSelectionOptions.DefaultMaxObservedThreads,
                ThreadSelectionOptions.DefaultEntryIdleTtl,
                ThreadSelectionOptions.DefaultPendingTtl,
                ThreadSelectionOptions.DefaultActiveIdleTtl),
            clock,
            enabled: true);

        RouterExecutionServiceFactoryResult created = RouterExecutionServiceFactory.Create(
            snapshot,
            secrets,
            transportHandler: new LoopbackOnlyHandler(),
            endpointOverrides: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                [spec.EndpointBaseUrlReference] = new Uri(server.BaseUri, spec.FakeBasePath).ToString(),
            },
            passiveHealthPolicy: PassiveHealthPolicy.Default,
            threadModelSelectionSource: store);
        Assert.True(created.IsSuccess, created.Error?.Code);

        using RouterExecutionResponsesService service = created.Service!;
        ResponsesServiceResult result = await service.InvokeAsync(
            new CanonicalResponsesRequest { Model = spec.ClientModelId, Input = [], Stream = false },
            CreateContext(snapshot, clock),
            CancellationToken.None);

        Assert.NotNull(result.Error);
        Assert.Equal(RouterErrorCode.RateLimited, result.Error!.Code);
        Assert.NotEqual(QuotaAvailabilityState.Exhausted, service.QuotaAvailability.Get(route.RouteId).State);
        Assert.Equal(ThreadSelectionState.None, store.TryGet(RefOfThread())!.SelectionState);
    }

    private static RequestContext CreateContext(EffectiveRouterConfigSnapshot snapshot, IClock clock)
    {
        Assert.True(CanonicalThreadId.TryParse(ThreadId, out CanonicalThreadId? canonical));
        var ids = new UuidV7IdGenerator(clock);
        return RequestContext.Create(
            ids.NewRequestId(),
            ids.NewTraceId(),
            ExecutionTestConfigFactory.ClientId,
            clock.UtcNow,
            "responses:invoke",
            configGeneration: snapshot.ConfigGeneration,
            thread: new ThreadIdentity
            {
                ThreadId = canonical!,
                Ref = ThreadRef.From(canonical!),
                RequestKind = ThreadIdentity.TurnRequestKind,
            });
    }

    private static string RefOfThread()
    {
        Assert.True(CanonicalThreadId.TryParse(ThreadId, out CanonicalThreadId? canonical));
        return ThreadRef.From(canonical!);
    }
}
