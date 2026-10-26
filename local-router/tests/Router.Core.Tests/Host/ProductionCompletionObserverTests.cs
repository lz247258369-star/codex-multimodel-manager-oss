using Router.ClientAdapters.Responses;
using Router.Core.Tests.Fakes;
using Router.Host;
using Router.Ingress;
using Router.Metering;
using Router.Observability;
using Xunit;
using CanonicalUsage = Router.ClientAdapters.Responses.UsageRecord;

namespace Router.Core.Tests.Host;

public sealed class ProductionCompletionObserverTests
{
    [Fact]
    public async Task Queue_full_drops_safely_with_observable_degradation_and_one_record()
    {
        RequestMeteringService metering = new();
        TestObservabilityFileSystem fileSystem = new();
        DurableRequestLog log = CreateLog(fileSystem);
        ProductionCompletionObserver observer = new(
            metering,
            log,
            new FakeClock(),
            queueCapacity: 1,
            startConsumerOnEnqueue: false);

        await observer.OnUsageCompletedAsync(Completion("req_queue_full_1", inputTokens: 100));
        await observer.OnUsageCompletedAsync(Completion("req_queue_full_2", inputTokens: 200));

        Assert.Equal(1, observer.DroppedJobCount);
        Assert.Equal(ProductionCompletionObserver.QueueFullCode, observer.LastDegradationCode);

        await observer.DrainAsync(CancellationToken.None);
        Assert.True(observer.DrainCompleted);
        Assert.Equal(1, observer.ProcessedJobCount);
        RequestMeteringRecord record = Assert.Single(metering.Store.Recent(20));
        Assert.Equal("req_queue_full_1", record.RequestId);
    }

    [Fact]
    public async Task Durable_log_failure_is_isolated_and_observable()
    {
        RequestMeteringService metering = new();
        TestObservabilityFileSystem fileSystem = new() { ThrowOnWrite = true };
        DurableRequestLog log = CreateLog(fileSystem);
        ProductionCompletionObserver observer = new(metering, log, new FakeClock());

        await observer.OnUsageCompletedAsync(Completion("req_log_fail", inputTokens: 100));
        await WaitUntilAsync(() => observer.ProcessedJobCount == 1, TimeSpan.FromSeconds(5));

        Assert.Equal(1, observer.DurableLogFailureCount);
        Assert.Equal(ProductionCompletionObserver.DurableLogFailedCode, observer.LastDegradationCode);
        Assert.True(log.Snapshot().Degraded);

        RequestMeteringRecord record = Assert.Single(metering.Store.Recent(20));
        Assert.Equal(RequestMeteringStatus.Recorded, record.Status);
        Assert.Equal(100, record.Usage!.InputTokens);

        await observer.DrainAsync(CancellationToken.None);
    }

    [Fact]
    public async Task Duplicate_completion_redelivery_keeps_one_logical_record()
    {
        RequestMeteringService metering = new();
        TestObservabilityFileSystem fileSystem = new();
        DurableRequestLog log = CreateLog(fileSystem);
        ProductionCompletionObserver observer = new(metering, log, new FakeClock(), queueCapacity: 4);

        await observer.OnUsageCompletedAsync(Completion("req_dedup", inputTokens: 100));
        await observer.OnUsageCompletedAsync(Completion("req_dedup", inputTokens: 200));
        await observer.DrainAsync(CancellationToken.None);

        Assert.True(observer.DrainCompleted);
        Assert.Equal(2, observer.ProcessedJobCount);
        Assert.Equal(1, metering.Store.Count);
        RequestMeteringRecord record = Assert.Single(metering.Store.Recent(20));
        Assert.Equal(200, record.Usage!.InputTokens);
    }

    [Fact]
    public async Task Drain_timeout_is_bounded_and_never_hangs_shutdown()
    {
        RequestMeteringService metering = new();
        TaskCompletionSource gate = new();
        TestObservabilityFileSystem fileSystem = new() { WriteGate = gate };
        DurableRequestLog log = CreateLog(fileSystem);
        ProductionCompletionObserver observer = new(metering, log, new FakeClock());

        await observer.OnUsageCompletedAsync(Completion("req_drain_blocked", inputTokens: 100));
        await WaitUntilAsync(() => fileSystem.AttemptedWriteCount == 1, TimeSpan.FromSeconds(5));

        using CancellationTokenSource timeout = new(TimeSpan.FromMilliseconds(250));
        await observer.DrainAsync(timeout.Token);

        Assert.False(observer.DrainCompleted);
        Assert.Equal(ProductionCompletionObserver.DrainTimeoutCode, observer.LastDegradationCode);

        gate.SetResult();
        await observer.DrainAsync(CancellationToken.None);

        Assert.True(observer.DrainCompleted);
        Assert.Equal(1, observer.ProcessedJobCount);
        Assert.Single(metering.Store.Recent(20));
    }

    private static DurableRequestLog CreateLog(IObservabilityFileSystem fileSystem)
    {
        string logDirectory = Path.Combine(
            Path.GetTempPath(),
            "lr10-observer-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(logDirectory);
        return new DurableRequestLog(ObservabilityOptions.Defaults(logDirectory), fileSystem);
    }

    private static RequestUsageCompletion Completion(
        string requestId,
        int inputTokens)
        => new()
        {
            RequestId = requestId,
            TraceId = "trc_" + requestId,
            ClientId = "client.local_test",
            ConfigGeneration = new string('a', 64),
            ModelId = "gpt-5.6-terra",
            Identity = new RequestUsageIdentity
            {
                ProviderId = "chatgpt",
                RouteId = "route.chatgpt-terra",
                ModelRouteId = "model_route.chatgpt-terra",
                CatalogModelId = "gpt-5.6-terra",
                UpstreamModelId = "gpt-5.6-terra",
            },
            Usage = new CanonicalUsage
            {
                InputTokens = inputTokens,
                OutputTokens = 25,
                TotalTokens = inputTokens + 25,
            },
            Stream = false,
            CompletedAt = DateTimeOffset.UtcNow,
            DurationMs = 42,
        };

    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        using CancellationTokenSource deadline = new(timeout);
        while (!condition())
        {
            if (deadline.IsCancellationRequested)
            {
                Assert.Fail("Condition was not met before timeout.");
                return;
            }

            await Task.Delay(TimeSpan.FromMilliseconds(25), deadline.Token).ConfigureAwait(false);
        }
    }
}
