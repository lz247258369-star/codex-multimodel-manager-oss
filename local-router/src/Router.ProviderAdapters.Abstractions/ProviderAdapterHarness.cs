using Router.Core.Abstractions;
using Router.Core.Context;
using Router.Core.Errors;
using Router.Core.Ids;
using Router.Routing;
using Router.Secrets;
using Router.ClientAdapters.Responses;

namespace Router.ProviderAdapters.Abstractions;

/// <summary>Outcome of one harness execution: normalized result plus safe attempt record.</summary>
public sealed record AttemptExecutionResult
{
    public required ProviderAdapterResult Result { get; init; }

    public required AttemptRecord Record { get; init; }
}

/// <summary>
/// Mechanical provider attempt orchestrator. It creates the attempt, invokes
/// exactly one resolved adapter, observes cancellation, normalizes failures to
/// typed errors, and finalizes a safe <see cref="AttemptRecord"/>. It never
/// decides retries (LR-11), never performs failover, and never emits output.
/// </summary>
public sealed class ProviderAdapterHarness
{
    private readonly IClock _clock;
    private readonly IIdGenerator _idGenerator;

    public ProviderAdapterHarness(IClock? clock = null, IIdGenerator? idGenerator = null)
    {
        _clock = clock ?? new SystemClock();
        _idGenerator = idGenerator ?? new UuidV7IdGenerator(_clock);
    }

    /// <summary>
    /// Executes exactly one attempt through the given resolved adapter. No
    /// retry decision is made here; retry eligibility is decided by
    /// <see cref="PreOutputRetryGuard"/> before another call.
    /// </summary>
    public async Task<AttemptExecutionResult> ExecuteOnceAsync(
        IProviderAdapter adapter,
        ResolvedRoute route,
        UpstreamEndpoint endpoint,
        CanonicalResponsesRequest request,
        SecretHandle secret,
        IUpstreamTransport transport,
        TimeoutBoundaries boundaries,
        RequestContext context,
        int attemptNumber,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(adapter);
        ArgumentNullException.ThrowIfNull(route);
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(secret);
        ArgumentNullException.ThrowIfNull(transport);
        ArgumentNullException.ThrowIfNull(context);

        DateTimeOffset startedAt = _clock.UtcNow;
        AttemptId attemptId = _idGenerator.NewAttemptId();

        var invocation = new ProviderAdapterInvocation
        {
            AttemptId = attemptId,
            RequestId = context.RequestId,
            TraceId = context.TraceId,
            Route = route,
            Endpoint = endpoint,
            Request = request,
            Secret = secret,
            Transport = transport,
            Boundaries = boundaries,
            Checkpoint = RetryCheckpoint.NotStarted,
            AttemptNumber = attemptNumber,
        };

        AttemptOutcome outcome = AttemptOutcome.Failed;
        CancellationReason cancellationReason = CancellationReason.None;
        RouterError? normalizedError = null;
        ProviderAdapterResult result;

        try
        {
            result = await adapter.InvokeAsync(invocation, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            outcome = AttemptOutcome.Cancelled;
            cancellationReason = cancellationToken.IsCancellationRequested
                ? CancellationReason.ClientDisconnect
                : CancellationReason.Internal;
            result = ProviderAdapterResult.Failed(RouterError.Cancelled(context.RequestId.Value));
        }
        catch (Exception exception)
        {
            normalizedError = RouterError.FromException(exception, context.RequestId.Value);
            result = ProviderAdapterResult.Failed(normalizedError);
        }

        result.Validate();

        if (result.Error is { } error)
        {
            normalizedError ??= error;
            outcome = string.Equals(error.Code, RouterErrorCode.Cancelled, StringComparison.Ordinal)
                ? AttemptOutcome.Cancelled
                : AttemptOutcome.Failed;
            if (outcome == AttemptOutcome.Cancelled && cancellationReason == CancellationReason.None)
            {
                cancellationReason = CancellationReason.RequestDeadline;
            }
        }
        else
        {
            outcome = AttemptOutcome.Succeeded;
        }

        AttemptRecord record = new()
        {
            AttemptId = attemptId,
            RequestId = context.RequestId.Value,
            TraceId = context.TraceId.Value,
            RouteId = route.RouteId,
            AdapterId = adapter.Descriptor.AdapterId,
            AdapterVersion = adapter.Descriptor.AdapterVersion,
            ProviderId = route.ProviderRoute.ProviderId,
            EndpointId = route.Endpoint.EndpointId,
            AttemptNumber = attemptNumber,
            StartedAt = startedAt,
            FirstByteAt = null,
            CompletedAt = _clock.UtcNow,
            Outcome = outcome,
            NormalizedError = normalizedError,
            FinalCheckpoint = RetryCheckpointState.Terminal,
            CancellationReason = cancellationReason,
            InputTokens = null,
            OutputTokens = null,
            CachedTokens = null,
        };

        return new AttemptExecutionResult { Result = result, Record = record };
    }
}
