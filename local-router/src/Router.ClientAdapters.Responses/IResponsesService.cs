using Router.Core.Errors;

namespace Router.ClientAdapters.Responses;

/// <summary>
/// Core boundary consumed by the ingress. Implementations return a canonical
/// non-stream response, a canonical event stream, or a normalized error. LR-3
/// production ingress depends only on this interface; the only implementation
/// is the synthetic fake service.
/// </summary>
public interface IResponsesService
{
    /// <summary>
    /// Executes one canonical request. Must observe <paramref name="cancellationToken"/>
    /// and never return after cancellation has been observed.
    /// </summary>
    Task<ResponsesServiceResult> InvokeAsync(
        CanonicalResponsesRequest request,
        Core.Context.RequestContext context,
        CancellationToken cancellationToken);
}

/// <summary>Discriminated result: exactly one of response, event stream, or error.</summary>
public sealed record ResponsesServiceResult
{
    public CanonicalResponsesResponse? Response { get; init; }

    public IAsyncEnumerable<CanonicalEvent>? EventStream { get; init; }

    public RouterError? Error { get; init; }

    /// <summary>
    /// Optional authoritative execution metadata. Production execution
    /// services always attach it; synthetic/fake services leave it null.
    /// </summary>
    public ResponsesExecutionMetadata? Execution { get; init; }

    public static ResponsesServiceResult NonStream(
        CanonicalResponsesResponse response,
        ResponsesExecutionMetadata? execution = null)
        => new() { Response = response, Execution = execution };

    public static ResponsesServiceResult Stream(
        IAsyncEnumerable<CanonicalEvent> events,
        ResponsesExecutionMetadata? execution = null)
        => new() { EventStream = events, Execution = execution };

    public static ResponsesServiceResult Failure(
        RouterError error,
        ResponsesExecutionMetadata? execution = null)
        => new() { Error = error, Execution = execution };

    /// <summary>Validates the discriminated invariant.</summary>
    public void Validate()
    {
        int set = (Response is not null ? 1 : 0) + (EventStream is not null ? 1 : 0) + (Error is not null ? 1 : 0);
        if (set != 1)
        {
            throw new InvalidOperationException("A ResponsesServiceResult must contain exactly one of response, stream, or error.");
        }
    }
}
