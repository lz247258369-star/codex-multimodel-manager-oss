using Router.ClientAdapters.Responses;
using Router.Core.Errors;

namespace Router.ProtocolAdapters.Abstractions;

/// <summary>
/// One immutable Responses-family protocol adapter. The adapter maps canonical
/// Responses semantics to upstream Responses semantics (LR-8 V1 is exact
/// pass-through/normalization), reports semantic loss, and never performs
/// provider selection, secret/HTTP work, retry, failover, or health.
/// </summary>
public interface IResponsesProtocolAdapter
{
    ProtocolAdapterDescriptor Descriptor { get; }

    /// <summary>
    /// Maps a canonical request to an upstream request. Every unsupported
    /// semantic fails closed with a typed error; no silent loss ever occurs.
    /// </summary>
    Result<CanonicalResponsesRequest, RouterError> MapRequest(CanonicalResponsesRequest request);

    /// <summary>Maps a canonical non-stream response exactly (no provider shape crosses this boundary).</summary>
    Result<CanonicalResponsesResponse, RouterError> MapResponse(CanonicalResponsesResponse response);

    /// <summary>Maps one canonical event exactly; event order is preserved by the caller.</summary>
    Result<CanonicalEvent, RouterError> MapEvent(CanonicalEvent canonicalEvent);
}

/// <summary>Discriminated result used by pure protocol validators.</summary>
public sealed record Result<TValue, TError>
{
    public TValue? Value { get; init; }

    public TError? Error { get; init; }

    public bool IsSuccess => Value is not null;
}
