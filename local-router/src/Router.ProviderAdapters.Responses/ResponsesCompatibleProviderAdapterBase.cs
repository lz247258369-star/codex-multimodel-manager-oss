using System.Runtime.CompilerServices;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;

namespace Router.ProviderAdapters.Responses;

/// <summary>
/// Shared behavior for Responses-compatible provider adapters (canonical
/// protocol only; no protocol conversion). Concrete adapters supply their exact
/// identity/capabilities; the base handles request mapping (with the upstream
/// model ID from the resolved route), HTTP send, status normalization,
/// non-stream decoding, and SSE stream decoding with idle/total boundaries and
/// truncation detection.
/// </summary>
public abstract class ResponsesCompatibleProviderAdapterBase : IProviderAdapter
{
    private readonly string _requestPath;

    protected ResponsesCompatibleProviderAdapterBase(string? requestPath = null)
    {
        _requestPath = string.IsNullOrWhiteSpace(requestPath) ? "/v1/responses" : requestPath;
    }

    public abstract ProviderAdapterDescriptor Descriptor { get; }

    public virtual async Task<ProviderAdapterResult> InvokeAsync(
        ProviderAdapterInvocation invocation,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(invocation);

        // DSR7-C-FIX5-A: a canonical custom tool is never serialized or forwarded.
        // The provider compatibility bridge that turns it into a Router-owned
        // synthetic function is FIX5-B; until then every provider, stream or not,
        // fails closed here instead of leaking a custom definition upstream or
        // silently dropping it.
        if (invocation.Request.ApplyPatchTool is not null)
        {
            return ProviderAdapterResult.Failed(RouterError.UnsupportedCapability());
        }

        UpstreamRequest request = BuildRequest(invocation);
        Result<UpstreamResponse, RouterError> sendResult = await invocation.Transport
            .SendAsync(request, invocation.Boundaries, cancellationToken)
            .ConfigureAwait(false);

        if (sendResult.Error is { } transportError)
        {
            return ProviderAdapterResult.Failed(transportError);
        }

        UpstreamResponse response = sendResult.Value!;
        if (!response.IsSuccessStatusCode)
        {
            response.Body.Dispose();
            return ProviderAdapterResult.Failed(ProviderStatusMapper.MapStatus(response.StatusCode));
        }

        DateTimeOffset started = DateTimeOffset.UtcNow;
        var guard = new StreamTimeoutGuard(response.Body, invocation.Boundaries, started, cancellationToken);
        if (invocation.Request.Stream)
        {
            return ProviderAdapterResult.Stream(DecodeEventStreamAsync(guard, cancellationToken));
        }

        try
        {
            byte[] body = await guard.ReadToEndAsync(cancellationToken).ConfigureAwait(false);
            Result<CanonicalResponsesResponse, RouterError> decoded = ResponsesProviderCodec.DecodeResponse(body);
            return decoded.Error is { } decodeError
                ? ProviderAdapterResult.Failed(decodeError)
                : ProviderAdapterResult.NonStream(decoded.Value!);
        }
        catch (StreamTimeoutException exception)
        {
            return ProviderAdapterResult.Failed(
                exception.Stage == StreamTimeoutStage.Total
                    ? ProviderAdapterErrors.TimeoutTotal()
                    : ProviderAdapterErrors.TimeoutIdle());
        }
        finally
        {
            response.Body.Dispose();
        }
    }

    private UpstreamRequest BuildRequest(ProviderAdapterInvocation invocation)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["Accept"] = invocation.Request.Stream ? "text/event-stream" : "application/json",
            ["Content-Type"] = "application/json",
        };

        if (invocation.Secret is not null)
        {
            headers["Authorization"] = "Bearer " + invocation.Secret.ReadValue();
        }

        // Provider identity is never inferred: the upstream model ID comes
        // exclusively from the resolved route's explicit model mapping.
        CanonicalResponsesRequest upstreamRequest = invocation.Request with
        {
            Model = invocation.Route.ModelRoute.UpstreamModelId,
        };

        byte[] body = ResponsesProviderCodec.EncodeRequest(upstreamRequest);
        return UpstreamRequest.Create(
            "POST",
            invocation.Endpoint,
            _requestPath,
            headers,
            body,
            "application/json");
    }

    private static async IAsyncEnumerable<CanonicalEvent> DecodeEventStreamAsync(
        StreamTimeoutGuard guard,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        bool sawTerminal = false;
        try
        {
            await foreach (CanonicalEvent canonicalEvent in SseStreamParser.ParseAsync(guard.Stream, guard, cancellationToken).ConfigureAwait(false))
            {
                sawTerminal |= canonicalEvent.IsTerminal;
                yield return canonicalEvent;
            }

            if (!sawTerminal)
            {
                throw new StreamInterruptedException();
            }
        }
        finally
        {
            guard.Stream.Dispose();
        }
    }
}
