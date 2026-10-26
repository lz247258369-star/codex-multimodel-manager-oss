using System.Collections.Concurrent;
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

/// <summary>
/// HS-1C acceptance matrix on the current main baseline: offline loopback fake
/// providers only, no real provider, no paid inference.
/// </summary>
public sealed class Hs1cQuotaFailoverAcceptanceTests
{
    private const string ThreadId = "01a09dae-3db7-7820-8912-0d86815051b7";
    private const string OpenAiQuota429 = "{\"error\":{\"type\":\"insufficient_quota\",\"code\":null}}";
    private const string OpenAiRateLimit429 = "{\"error\":{\"type\":\"rate_limit_error\",\"code\":\"rate_limit_exceeded\"}}";

    private static readonly ProviderExecutionSpec PrimarySpec = ExecutionTestConfigFactory.OpenAiApi;
    private static readonly ProviderExecutionSpec FirstFallbackSpec = ExecutionTestConfigFactory.MiMo;
    private static readonly ProviderExecutionSpec SecondFallbackSpec = ExecutionTestConfigFactory.ModelStudio;

    [Fact]
    public async Task Single_fallback_success_becomes_sticky()
    {
        await using Hs1cFixture fx = await Hs1cFixture.StartAsync();
        fx.Primary.SetScenario(FakeProviderScenario.Json(429, OpenAiQuota429));
        fx.FirstFallback.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson("fallback-one")));

        ResponsesServiceResult result = await fx.InvokeAsync();

        Assert.Null(result.Error);
        Assert.Equal(FirstFallbackSpec.ProviderId, result.Execution!.ProviderId);
        Assert.Equal(2, result.Execution.AttemptCount);
        Assert.Equal(0, fx.Requests(fx.SecondFallback));
        ThreadSelectionSnapshot selection = fx.Selection();
        Assert.Equal(ThreadSelectionState.Active, selection.SelectionState);
        Assert.Equal(FirstFallbackSpec.ClientModelId, selection.SelectionModel);
    }

    [Theory]
    [InlineData(500)]
    [InlineData(502)]
    [InlineData(503)]
    public async Task Provider_5xx_never_switches_model(int statusCode)
    {
        await using Hs1cFixture fx = await Hs1cFixture.StartAsync();
        fx.Primary.SetScenario(FakeProviderScenario.Json(statusCode, "{\"error\":{\"type\":\"insufficient_quota\"}}"));
        fx.FirstFallback.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson("must-not-run")));

        ResponsesServiceResult result = await fx.InvokeAsync();

        Assert.NotNull(result.Error);
        Assert.Equal(RouterErrorCode.Provider5xx, result.Error!.Code);
        AssertNoSwitch(fx);
    }

    [Fact]
    public async Task Ordinary_429_never_switches_model()
    {
        await using Hs1cFixture fx = await Hs1cFixture.StartAsync();
        fx.Primary.SetScenario(FakeProviderScenario.Json(429, OpenAiRateLimit429));
        fx.FirstFallback.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson("must-not-run")));

        ResponsesServiceResult result = await fx.InvokeAsync();

        Assert.Equal(RouterErrorCode.RateLimited, result.Error!.Code);
        AssertNoSwitch(fx);
    }

    [Fact]
    public async Task Timeout_never_switches_model()
    {
        await using Hs1cFixture fx = await Hs1cFixture.StartAsync();
        fx.Primary.SetScenario(new FakeProviderScenario
        {
            StatusCode = 200,
            Body = System.Text.Encoding.UTF8.GetBytes(SseFixtureBuilder.NonStreamJson("too-late")),
            ContentType = "application/json",
            DelayBeforeFirstByte = TimeSpan.FromSeconds(3),
        });
        fx.FirstFallback.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson("must-not-run")));

        ResponsesServiceResult result = await fx.InvokeAsync(deadline: TimeSpan.FromMilliseconds(400));

        Assert.NotNull(result.Error);
        Assert.DoesNotContain(result.Error!.Code, QuotaCodes);
        AssertNoSwitch(fx);
    }

    [Fact]
    public async Task All_fallbacks_exhausted_stops_with_explicit_bounded_failure()
    {
        await using Hs1cFixture fx = await Hs1cFixture.StartAsync();
        fx.Primary.SetScenario(FakeProviderScenario.Json(429, OpenAiQuota429));
        fx.FirstFallback.SetScenario(FakeProviderScenario.Json(402, "{\"error\":{\"message\":\"credit exhausted\"}}"));
        fx.SecondFallback.SetScenario(FakeProviderScenario.Json(403, "{\"code\":\"AllocationQuota.FreeTierOnly\"}"));

        ResponsesServiceResult first = await fx.InvokeAsync();

        Assert.Equal(RouterErrorCode.QuotaFallbacksExhausted, first.Error!.Code);
        Assert.Equal(3, first.Execution!.AttemptCount);
        Assert.Equal(1, fx.Requests(fx.FirstFallback));
        Assert.Equal(1, fx.Requests(fx.SecondFallback));
        Assert.Equal(ThreadSelectionState.None, fx.Selection().SelectionState);

        // A later turn does not loop over known-exhausted fallbacks: only the
        // current model is attempted, then the same explicit failure returns.
        ResponsesServiceResult second = await fx.InvokeAsync();

        Assert.Equal(RouterErrorCode.QuotaFallbacksExhausted, second.Error!.Code);
        Assert.Equal(1, second.Execution!.AttemptCount);
        Assert.Equal(1, fx.Requests(fx.FirstFallback));
        Assert.Equal(1, fx.Requests(fx.SecondFallback));
    }

    [Fact]
    public async Task Unapproved_routes_never_become_candidates()
    {
        // The client may use the primary and the SECOND fallback only; the first
        // fallback is configured in fallback_route_ids but not approved for it.
        await using Hs1cFixture fx = await Hs1cFixture.StartAsync(
            clientAllowedRouteIds: [PrimarySpec.RouteId, SecondFallbackSpec.RouteId]);
        fx.Primary.SetScenario(FakeProviderScenario.Json(429, OpenAiQuota429));
        fx.FirstFallback.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson("unapproved")));
        fx.SecondFallback.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson("approved")));

        ResponsesServiceResult result = await fx.InvokeAsync();

        Assert.Null(result.Error);
        Assert.Equal(SecondFallbackSpec.ProviderId, result.Execution!.ProviderId);
        Assert.Equal(0, fx.Requests(fx.FirstFallback));
    }

    [Fact]
    public async Task Disabled_fallback_route_never_becomes_a_candidate()
    {
        await using Hs1cFixture fx = await Hs1cFixture.StartAsync(firstFallbackEnabled: false);
        fx.Primary.SetScenario(FakeProviderScenario.Json(429, OpenAiQuota429));
        fx.FirstFallback.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson("disabled")));
        fx.SecondFallback.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson("enabled")));

        ResponsesServiceResult result = await fx.InvokeAsync();

        Assert.Null(result.Error);
        Assert.Equal(SecondFallbackSpec.ProviderId, result.Execution!.ProviderId);
        Assert.Equal(0, fx.Requests(fx.FirstFallback));
    }

    [Fact]
    public async Task Manual_selection_wins_over_a_stale_automatic_write()
    {
        await using Hs1cFixture fx = await Hs1cFixture.StartAsync();
        fx.Primary.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson("primary")));
        Assert.Null((await fx.InvokeAsync()).Error);
        ThreadSelectionSnapshot observed = fx.Selection();

        // Request start saw generation G. The user then picks a model manually
        // (generation G+1) before the automatic write lands: the write loses.
        ThreadSelectionOperationResult manual = fx.Store.SetSelection(
            Hs1cFixture.ThreadRef, SecondFallbackSpec.ClientModelId, observed.SelectionGeneration);
        Assert.Equal(ThreadSelectionOperationStatus.Applied, manual.Status);

        bool applied = fx.Store.TryApplyAutomaticSelection(
            Hs1cFixture.ThreadRef,
            PrimarySpec.ClientModelId,
            observed.SelectionGeneration,
            FirstFallbackSpec.ClientModelId,
            DateTimeOffset.UtcNow);

        Assert.False(applied);
        Assert.Equal(SecondFallbackSpec.ClientModelId, fx.Selection().SelectionModel);
    }

    [Fact]
    public async Task Output_already_streamed_is_never_replayed_on_another_model()
    {
        await using Hs1cFixture fx = await Hs1cFixture.StartAsync();
        string partialThenQuotaFailure = string.Join("\n\n",
        [
            "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_hs1c\",\"object\":\"response\",\"status\":\"in_progress\",\"model\":\"fake-model\",\"output\":[],\"usage\":null}}",
            "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_hs1c\",\"output_index\":0,\"content_index\":0,\"delta\":\"partial\"}",
            "event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"id\":\"resp_hs1c\",\"object\":\"response\",\"status\":\"failed\",\"model\":\"fake-model\",\"output\":[],\"usage\":null,\"error\":{\"code\":\"insufficient_quota\",\"message\":\"synthetic\"}}}",
        ]) + "\n\n";
        fx.Primary.SetScenario(FakeProviderScenario.Sse(200, partialThenQuotaFailure));
        fx.FirstFallback.SetScenario(FakeProviderScenario.Sse(200, SseFixtureBuilder.BasicStream("must-not-run")));

        ResponsesServiceResult result = await fx.InvokeAsync(stream: true);
        Assert.NotNull(result.EventStream);
        await DrainAsync(result.EventStream!);

        Assert.Equal(0, fx.Requests(fx.FirstFallback));
        Assert.Equal(0, fx.Requests(fx.SecondFallback));
        Assert.NotEqual(ThreadSelectionState.Active, fx.Selection().SelectionState);
    }

    [Fact]
    public async Task Pre_output_stream_exhaustion_fails_over_and_sticks()
    {
        await using Hs1cFixture fx = await Hs1cFixture.StartAsync();
        fx.Primary.SetScenario(FakeProviderScenario.Json(429, OpenAiQuota429));
        fx.FirstFallback.SetScenario(FakeProviderScenario.Sse(200, SseFixtureBuilder.BasicStream("fallback-stream")));

        ResponsesServiceResult result = await fx.InvokeAsync(stream: true);
        Assert.NotNull(result.EventStream);
        await DrainAsync(result.EventStream!);

        Assert.Equal(FirstFallbackSpec.ProviderId, result.Execution!.ProviderId);
        Assert.Equal(FirstFallbackSpec.ClientModelId, fx.Selection().SelectionModel);
    }

    [Fact]
    public async Task Disabled_by_default_keeps_the_pre_hs1c_behavior()
    {
        Assert.False(new ThreadSelectionConfig().QuotaFailoverEnabled);

        await using Hs1cFixture fx = await Hs1cFixture.StartAsync(quotaFailoverEnabled: false);
        fx.Primary.SetScenario(FakeProviderScenario.Json(429, OpenAiQuota429));
        fx.FirstFallback.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson("must-not-run")));

        ResponsesServiceResult quota429 = await fx.InvokeAsync();

        // Exactly the old status-only mapping: an exhausted-quota 429 is still
        // rate_limited, nothing is classified, tracked, or switched.
        Assert.Equal(RouterErrorCode.RateLimited, quota429.Error!.Code);
        Assert.Equal(QuotaAvailabilityState.Unknown, fx.Service.QuotaAvailability.Get(PrimarySpec.RouteId).State);
        AssertNoSwitch(fx);

        fx.Primary.SetScenario(FakeProviderScenario.Json(402, "{\"error\":{\"code\":\"credit_balance_exhausted\"}}"));
        ResponsesServiceResult credit402 = await fx.InvokeAsync();
        Assert.Equal(RouterErrorCode.Provider4xx, credit402.Error!.Code);
        AssertNoSwitch(fx);
    }

    private static readonly string[] QuotaCodes =
    [
        RouterErrorCode.QuotaExhausted,
        RouterErrorCode.CreditExhausted,
        RouterErrorCode.QuotaFallbacksExhausted,
    ];

    private static void AssertNoSwitch(Hs1cFixture fx)
    {
        Assert.Equal(0, fx.Requests(fx.FirstFallback));
        Assert.Equal(0, fx.Requests(fx.SecondFallback));
        Assert.Equal(ThreadSelectionState.None, fx.Selection().SelectionState);
        Assert.NotEqual(QuotaAvailabilityState.Exhausted, fx.Service.QuotaAvailability.Get(PrimarySpec.RouteId).State);
    }

    private static async Task DrainAsync(IAsyncEnumerable<CanonicalEvent> stream)
    {
        try
        {
            await foreach (CanonicalEvent _ in stream)
            {
            }
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            // A terminal stream failure is the expected outcome for the
            // no-replay case; the assertions are about what happened upstream.
        }
    }

    /// <summary>Counts upstream requests per fake-provider port.</summary>
    private sealed class CountingHandler : DelegatingHandler
    {
        private readonly ConcurrentDictionary<int, int> _counts = new();

        public CountingHandler()
            : base(new LoopbackOnlyHandler())
        {
        }

        public int Count(int port) => _counts.TryGetValue(port, out int value) ? value : 0;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.RequestUri is { } uri)
            {
                _counts.AddOrUpdate(uri.Port, 1, static (_, value) => value + 1);
            }

            return base.SendAsync(request, cancellationToken);
        }
    }

    private sealed class Hs1cFixture : IAsyncDisposable
    {
        private readonly CountingHandler _handler;
        private readonly EffectiveRouterConfigSnapshot _snapshot;
        private readonly IClock _clock;

        private Hs1cFixture(
            FakeProviderServer primary,
            FakeProviderServer firstFallback,
            FakeProviderServer secondFallback,
            CountingHandler handler,
            EffectiveRouterConfigSnapshot snapshot,
            IClock clock,
            ThreadSelectionStore store,
            RouterExecutionResponsesService service)
        {
            Primary = primary;
            FirstFallback = firstFallback;
            SecondFallback = secondFallback;
            _handler = handler;
            _snapshot = snapshot;
            _clock = clock;
            Store = store;
            Service = service;
        }

        public FakeProviderServer Primary { get; }

        public FakeProviderServer FirstFallback { get; }

        public FakeProviderServer SecondFallback { get; }

        public ThreadSelectionStore Store { get; }

        public RouterExecutionResponsesService Service { get; }

        public static string ThreadRef
        {
            get
            {
                Assert.True(CanonicalThreadId.TryParse(ThreadId, out CanonicalThreadId? canonical));
                return Router.Core.Context.ThreadRef.From(canonical!);
            }
        }

        public static async Task<Hs1cFixture> StartAsync(
            bool quotaFailoverEnabled = true,
            IReadOnlyList<string>? clientAllowedRouteIds = null,
            bool firstFallbackEnabled = true)
        {
            var primary = new FakeProviderServer();
            var firstFallback = new FakeProviderServer();
            var secondFallback = new FakeProviderServer();
            await primary.StartAsync();
            await firstFallback.StartAsync();
            await secondFallback.StartAsync();

            RouterRouteConfig first = ExecutionTestConfigFactory.Route(
                FirstFallbackSpec.ProviderId, FirstFallbackSpec.RouteId, enabled: firstFallbackEnabled);
            RouterRouteConfig second = ExecutionTestConfigFactory.Route(
                SecondFallbackSpec.ProviderId, SecondFallbackSpec.RouteId);
            RouterRouteConfig main = ExecutionTestConfigFactory.Route(PrimarySpec.ProviderId, PrimarySpec.RouteId) with
            {
                FallbackRouteIds = [first.RouteId, second.RouteId],
            };

            EffectiveRouterConfigSnapshot baseSnapshot = ExecutionTestConfigFactory.Snapshot(
                [main, first, second],
                "hs1c-acceptance",
                clientAllowedRouteIds: clientAllowedRouteIds);
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
                            QuotaFailoverEnabled = quotaFailoverEnabled,
                        },
                    },
                },
            };

            var secrets = new FakeSecretResolver();
            foreach (ProviderExecutionSpec spec in new[] { PrimarySpec, FirstFallbackSpec, SecondFallbackSpec })
            {
                secrets.Configure(spec.ProviderId, spec.SecretEnvironmentName, "synthetic-" + spec.Slug);
            }

            var endpointOverrides = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                [PrimarySpec.EndpointBaseUrlReference] = new Uri(primary.BaseUri, PrimarySpec.FakeBasePath).ToString(),
                [FirstFallbackSpec.EndpointBaseUrlReference] = new Uri(firstFallback.BaseUri, FirstFallbackSpec.FakeBasePath).ToString(),
                [SecondFallbackSpec.EndpointBaseUrlReference] = new Uri(secondFallback.BaseUri, SecondFallbackSpec.FakeBasePath).ToString(),
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

            var handler = new CountingHandler();
            RouterExecutionServiceFactoryResult created = RouterExecutionServiceFactory.Create(
                snapshot,
                secrets,
                transportHandler: handler,
                endpointOverrides: endpointOverrides,
                passiveHealthPolicy: PassiveHealthPolicy.Default,
                threadModelSelectionSource: store);
            Assert.True(created.IsSuccess, created.Error?.Code + ": " + created.Error?.Message + " (" + created.Error?.Param + ")");

            return new Hs1cFixture(primary, firstFallback, secondFallback, handler, snapshot, clock, store, created.Service!);
        }

        public int Requests(FakeProviderServer server) => _handler.Count(server.BaseUri.Port);

        public ThreadSelectionSnapshot Selection() => Store.TryGet(ThreadRef)!;

        public Task<ResponsesServiceResult> InvokeAsync(bool stream = false, TimeSpan? deadline = null)
        {
            Assert.True(CanonicalThreadId.TryParse(ThreadId, out CanonicalThreadId? canonical));
            var ids = new UuidV7IdGenerator(_clock);
            DateTimeOffset now = _clock.UtcNow;
            RequestContext context = RequestContext.Create(
                ids.NewRequestId(),
                ids.NewTraceId(),
                ExecutionTestConfigFactory.ClientId,
                now,
                "responses:invoke",
                deadlineAt: deadline is { } d ? now + d : null,
                configGeneration: _snapshot.ConfigGeneration,
                thread: new ThreadIdentity
                {
                    ThreadId = canonical!,
                    Ref = Router.Core.Context.ThreadRef.From(canonical!),
                    RequestKind = ThreadIdentity.TurnRequestKind,
                });

            return Service.InvokeAsync(
                new CanonicalResponsesRequest { Model = PrimarySpec.ClientModelId, Input = [], Stream = stream },
                context,
                CancellationToken.None);
        }

        public async ValueTask DisposeAsync()
        {
            Service.Dispose();
            await Primary.DisposeAsync();
            await FirstFallback.DisposeAsync();
            await SecondFallback.DisposeAsync();
        }
    }
}
