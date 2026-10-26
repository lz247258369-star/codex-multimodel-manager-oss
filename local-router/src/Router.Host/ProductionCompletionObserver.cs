using System.Threading.Channels;
using Microsoft.AspNetCore.Http;
using Router.Core.Abstractions;
using Router.Core.Lifecycle;
using Router.Core.Support;
using Router.Ingress;
using Router.Ingress.Handlers;
using Router.Metering;
using Router.Observability;

namespace Router.Host;

/// <summary>
/// Production completion observer. Successful completions are enqueued into a
/// single bounded in-memory completion queue; one background consumer records
/// the safe metering record and mirrors redacted request metadata into the
/// LR-9 durable log. The response path never waits on disk I/O and never spins
/// up a task per request. Router shutdown drains the bounded queue with a hard
/// timeout, so a just-completed response is not silently dropped.
/// </summary>
public sealed class ProductionCompletionObserver : IngressRequestObserver
{
    public const int DefaultQueueCapacity = 256;
    public const string QueueFullCode = "completion_queue_full";
    public const string DispatcherDrainedCode = "completion_dispatcher_drained";
    public const string ConsumerFailedCode = "completion_consumer_failed";
    public const string DurableLogFailedCode = "durable_log_failed";
    public const string DrainTimeoutCode = "completion_drain_timeout";

    /// <summary>Maximum wall-clock time Router shutdown waits for the bounded drain.</summary>
    public static readonly TimeSpan DefaultShutdownDrainTimeout = TimeSpan.FromSeconds(5);

    private readonly RequestMeteringService _metering;
    private readonly DurableRequestLog? _requestLog;
    private readonly SafeFailureDiagnosticLog? _failureDiagnosticLog;
    private readonly IClock _clock;
    private readonly Channel<CompletionJob> _queue;
    private readonly Lazy<Task> _consumer;
    private readonly object _stateSync = new();
    private readonly int _queueCapacity;
    private readonly bool _startConsumerOnEnqueue;

    private int _accepting = 1;
    private long _processedJobs;
    private long _droppedJobs;
    private long _durableLogFailures;
    private string? _lastDegradationCode;
    private bool _drainCompleted;

    public ProductionCompletionObserver(
        RequestMeteringService metering,
        DurableRequestLog? requestLog,
        IClock clock,
        int queueCapacity = DefaultQueueCapacity,
        bool startConsumerOnEnqueue = true,
        SafeFailureDiagnosticLog? failureDiagnosticLog = null)
    {
        _metering = metering ?? throw new ArgumentNullException(nameof(metering));
        _requestLog = requestLog;
        _failureDiagnosticLog = failureDiagnosticLog;
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _startConsumerOnEnqueue = startConsumerOnEnqueue;
        _queueCapacity = Math.Clamp(queueCapacity, 1, 4096);
        _queue = Channel.CreateBounded<CompletionJob>(new BoundedChannelOptions(_queueCapacity)
        {
            // TryWrite never blocks; when the bounded queue is full it returns
            // false so the observer can record an explicit degraded drop.
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = true,
            SingleWriter = false,
        });
        _consumer = new Lazy<Task>(
            () => Task.Factory.StartNew(
                    static state => ((ProductionCompletionObserver)state!).ConsumeAsync(),
                    this,
                    CancellationToken.None,
                    TaskCreationOptions.DenyChildAttach,
                    TaskScheduler.Default)
                .Unwrap(),
            LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public int QueueCapacity => _queueCapacity;

    public long ProcessedJobCount => Interlocked.Read(ref _processedJobs);

    public long DroppedJobCount => Interlocked.Read(ref _droppedJobs);

    public long DurableLogFailureCount => Interlocked.Read(ref _durableLogFailures);

    /// <summary>DSR7-C-FIX2 local safe failure diagnostic sink (never the request log).</summary>
    public SafeFailureDiagnosticLog? FailureDiagnosticLog => _failureDiagnosticLog;

    public bool IsDraining => Volatile.Read(ref _accepting) == 0;

    public bool DrainCompleted
    {
        get
        {
            lock (_stateSync)
            {
                return _drainCompleted;
            }
        }
    }

    public string? LastDegradationCode
    {
        get
        {
            lock (_stateSync)
            {
                return _lastDegradationCode;
            }
        }
    }

    public override void OnCompleted(RequestExecutionResult result)
    {
        // Successful responses:invoke requests are logged from the usage
        // completion path with correct usage-present metadata.
        if (result.Scope == ResponsesHandler.RequiredScope
            && result.State == RequestState.Completed)
        {
            return;
        }

        Enqueue(new ExecutionLogJob(result));
    }

    public override Task OnUsageCompletedAsync(
        RequestUsageCompletion completion,
        CancellationToken cancellationToken = default)
    {
        _ = cancellationToken;
        Enqueue(new UsageCompletionJob(completion));
        return Task.CompletedTask;
    }

    /// <summary>
    /// Stops accepting new completions and drains the bounded queue. Never
    /// blocks longer than the supplied cancellation token (Router supplies the
    /// default shutdown drain timeout). After a drain the observer stays
    /// degraded-safe: late completions are counted as dropped, never guessed.
    /// </summary>
    public async Task DrainAsync(CancellationToken cancellationToken = default)
    {
        if (Interlocked.Exchange(ref _accepting, 0) != 0)
        {
            _queue.Writer.TryComplete();
        }

        Task consumer = _consumer.Value;
        try
        {
            await consumer.WaitAsync(cancellationToken).ConfigureAwait(false);
            lock (_stateSync)
            {
                _drainCompleted = true;
            }
        }
        catch (OperationCanceledException)
        {
            RecordDegradation(DrainTimeoutCode);
        }
    }

    private void Enqueue(CompletionJob job)
    {
        if (Volatile.Read(ref _accepting) == 0)
        {
            RecordDegradation(DispatcherDrainedCode);
            return;
        }

        if (_queue.Writer.TryWrite(job))
        {
            if (_startConsumerOnEnqueue)
            {
                _ = _consumer.Value;
            }

            return;
        }

        RecordDegradation(QueueFullCode);
    }

    private async Task ConsumeAsync()
    {
        try
        {
            await foreach (CompletionJob job in _queue.Reader.ReadAllAsync().ConfigureAwait(false))
            {
                try
                {
                    await ProcessJobAsync(job).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    RecordDegradation(DrainTimeoutCode);
                }
                catch (Exception)
                {
                    RecordDegradation(ConsumerFailedCode);
                }
                finally
                {
                    Interlocked.Increment(ref _processedJobs);
                }
            }
        }
        catch (OperationCanceledException)
        {
            // A completed channel ends the loop normally; cancellation is not
            // expected because the consumer never observes user tokens.
            RecordDegradation(DrainTimeoutCode);
        }
        catch (Exception)
        {
            RecordDegradation(ConsumerFailedCode);
        }
    }

    private async Task ProcessJobAsync(CompletionJob job)
    {
        switch (job)
        {
            case UsageCompletionJob usageJob:
                RequestMeteringInput input = BuildInput(usageJob.Completion);
                _metering.Record(input);
                await WriteLogForUsageAsync(usageJob.Completion).ConfigureAwait(false);
                break;

            case ExecutionLogJob executionJob:
                await WriteLogSafeAsync(executionJob.Result, usagePresent: false).ConfigureAwait(false);
                WriteSafeFailureDiagnostic(executionJob.Result);
                break;
        }
    }

    /// <summary>
    /// DSR7-C-FIX2: records a local safe failure diagnostic only for a failed
    /// request whose error code is <c>unsupported_capability</c> and whose field
    /// path passes the strict safe-path allowlist. Every other outcome (deny,
    /// cancel, success, any other error code, an unsafe path) writes nothing.
    /// The write is best effort and can never affect request semantics.
    /// </summary>
    private void WriteSafeFailureDiagnostic(RequestExecutionResult result)
    {
        if (_failureDiagnosticLog is null)
        {
            return;
        }

        if (result.State != RequestState.Failed
            || !string.Equals(result.ErrorCode, SafeFailureDiagnosticRecord.UnsupportedCapabilityCode, StringComparison.Ordinal)
            || !SafeFailureDiagnosticPath.IsSafe(result.ErrorParam))
        {
            return;
        }

        // DSR7-C-FIX3: only a rejected tool type carries a fixed class label;
        // every other capability gate keeps the schema-v1 five-field record.
        // DSR7-C-FIX4: a rejected custom tool additionally carries a fixed
        // identity label (schema v3).
        if (SafeFailureDiagnosticPath.IsToolTypePath(result.ErrorParam)
            && string.Equals(result.ErrorDiagnosticClass, SafeToolTypeClassifier.Custom, StringComparison.Ordinal)
            && SafeCustomToolIdentityClassifier.IsKnownIdentity(result.ErrorDiagnosticIdentity))
        {
            _failureDiagnosticLog.TryWriteIdentified(
                result.RequestId,
                result.ErrorCode,
                result.ErrorParam,
                result.ErrorDiagnosticClass,
                result.ErrorDiagnosticIdentity);
            return;
        }

        if (SafeFailureDiagnosticPath.IsToolTypePath(result.ErrorParam)
            && SafeToolTypeClassifier.IsKnownLabel(result.ErrorDiagnosticClass))
        {
            _failureDiagnosticLog.TryWriteClassified(
                result.RequestId,
                result.ErrorCode,
                result.ErrorParam,
                result.ErrorDiagnosticClass);
            return;
        }

        _failureDiagnosticLog.TryWrite(result.RequestId, result.ErrorCode, result.ErrorParam);
    }

    private static RequestMeteringInput BuildInput(RequestUsageCompletion completion)
        => new()
        {
            RequestId = completion.RequestId,
            TraceId = completion.TraceId,
            ClientId = completion.ClientId,
            ConfigGeneration = completion.ConfigGeneration,
            ModelId = completion.ModelId,
            ProviderId = completion.Identity?.ProviderId,
            RouteId = completion.Identity?.RouteId,
            ModelRouteId = completion.Identity?.ModelRouteId,
            CatalogModelId = completion.Identity?.CatalogModelId,
            UpstreamModelId = completion.Identity?.UpstreamModelId,
            Usage = completion.Usage,
            Stream = completion.Stream,
            CompletedAt = completion.CompletedAt,
            DurationMs = completion.DurationMs,
        };

    private Task WriteLogForUsageAsync(RequestUsageCompletion completion)
    {
        RequestExecutionResult result = new()
        {
            RequestId = completion.RequestId,
            TraceId = completion.TraceId,
            ClientId = completion.ClientId,
            Scope = ResponsesHandler.RequiredScope,
            State = RequestState.Completed,
            HttpStatus = StatusCodes.Status200OK,
            ErrorCode = null,
            IdempotencyKeyHash = null,
            Ttft = null,
            LatencyMs = completion.DurationMs,
            Stream = completion.Stream,
        };
        return WriteLogSafeAsync(result, usagePresent: completion.Usage is not null);
    }

    private async Task WriteLogSafeAsync(RequestExecutionResult result, bool usagePresent)
    {
        if (_requestLog is null)
        {
            return;
        }

        DateTimeOffset completedAt = _clock.UtcNow;
        DateTimeOffset startedAt = result.LatencyMs is { } latencyMs
            ? completedAt.AddMilliseconds(-latencyMs)
            : completedAt;

        SafeRequestRecord safe = SafeRequestRecord.Create(
            result.RequestId,
            result.TraceId,
            startedAt,
            completedAt,
            result.State,
            errorCode: result.ErrorCode,
            clientId: result.ClientId,
            httpStatus: result.HttpStatus,
            usagePresent: usagePresent,
            stream: result.Stream);

        try
        {
            bool written = await _requestLog
                .WriteSafeAsync(safe, CancellationToken.None)
                .ConfigureAwait(false);
            if (!written)
            {
                Interlocked.Increment(ref _durableLogFailures);
                RecordDegradation(DurableLogFailedCode);
            }
        }
        catch (OperationCanceledException)
        {
            RecordDegradation(DrainTimeoutCode);
        }
        catch (Exception)
        {
            Interlocked.Increment(ref _durableLogFailures);
            RecordDegradation(DurableLogFailedCode);
        }
    }

    private void RecordDegradation(string code)
    {
        if (code is QueueFullCode or DispatcherDrainedCode)
        {
            Interlocked.Increment(ref _droppedJobs);
        }

        lock (_stateSync)
        {
            _lastDegradationCode = code;
        }
    }

    private abstract record CompletionJob;

    private sealed record UsageCompletionJob(RequestUsageCompletion Completion) : CompletionJob;

    private sealed record ExecutionLogJob(RequestExecutionResult Result) : CompletionJob;
}
