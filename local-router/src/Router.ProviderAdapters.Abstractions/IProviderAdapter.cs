using Router.Core.Context;
using Router.Core.Ids;
using Router.Routing;
using Router.Secrets;
using Router.ClientAdapters.Responses;

namespace Router.ProviderAdapters.Abstractions;

/// <summary>
/// One immutable provider adapter implementation. Adapters encode canonical
/// requests, send through <see cref="IUpstreamTransport"/>, decode responses
/// and events, and normalize errors. They never select routes, read arbitrary
/// environment variables, execute tools, log content, or retry independently.
/// </summary>
public interface IProviderAdapter
{
    ProviderAdapterDescriptor Descriptor { get; }

    /// <summary>
    /// Executes one attempt. The adapter must observe cancellation, must not
    /// retry, and must not leak secrets or raw headers.
    /// </summary>
    Task<ProviderAdapterResult> InvokeAsync(
        ProviderAdapterInvocation invocation,
        CancellationToken cancellationToken);
}

/// <summary>Immutable per-attempt invocation context for one adapter call.</summary>
public sealed record ProviderAdapterInvocation
{
    public required AttemptId AttemptId { get; init; }

    public required RequestId RequestId { get; init; }

    public required TraceId TraceId { get; init; }

    public required ResolvedRoute Route { get; init; }

    /// <summary>Validated transport endpoint (actual URL) for this attempt.</summary>
    public required UpstreamEndpoint Endpoint { get; init; }

    public required CanonicalResponsesRequest Request { get; init; }

    public required SecretHandle Secret { get; init; }

    public required IUpstreamTransport Transport { get; init; }

    public required TimeoutBoundaries Boundaries { get; init; }

    public required RetryCheckpoint Checkpoint { get; init; }

    public required int AttemptNumber { get; init; }
}

/// <summary>
/// Discriminated normalized result: exactly one of a canonical non-stream
/// response, a canonical event stream, or a typed error. Upstream vendor
/// shapes never cross this boundary.
/// </summary>
public sealed record ProviderAdapterResult
{
    public CanonicalResponsesResponse? Response { get; init; }

    public IAsyncEnumerable<CanonicalEvent>? EventStream { get; init; }

    public Router.Core.Errors.RouterError? Error { get; init; }

    public static ProviderAdapterResult NonStream(CanonicalResponsesResponse response)
        => new() { Response = response };

    public static ProviderAdapterResult Stream(IAsyncEnumerable<CanonicalEvent> events)
        => new() { EventStream = events };

    public static ProviderAdapterResult Failed(Router.Core.Errors.RouterError error)
        => new() { Error = error };

    /// <summary>Validates the discriminated invariant.</summary>
    public void Validate()
    {
        int set = (Response is not null ? 1 : 0) + (EventStream is not null ? 1 : 0) + (Error is not null ? 1 : 0);
        if (set != 1)
        {
            throw new InvalidOperationException("A ProviderAdapterResult must contain exactly one of response, stream, or error.");
        }
    }
}
