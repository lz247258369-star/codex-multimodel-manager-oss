using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.Responses;

namespace Router.Execution;

/// <summary>
/// HS-1C per-attempt transport decorator, used only while quota failover is
/// enabled. For the few status/provider pairs that can carry explicit quota
/// evidence it reads a bounded error-body prefix (under the attempt's own
/// timeout boundaries), records the content-free classification, and hands the
/// provider adapter an equivalent response, so the adapter keeps its unchanged
/// status mapping. Successful responses and every other failure pass through
/// untouched. Raw provider text is never kept beyond this attempt.
/// </summary>
internal sealed class QuotaEvidenceTransport : IUpstreamTransport
{
    private readonly IUpstreamTransport _inner;
    private readonly string _providerId;

    public QuotaEvidenceTransport(IUpstreamTransport inner, string providerId)
    {
        _inner = inner ?? throw new ArgumentNullException(nameof(inner));
        ArgumentException.ThrowIfNullOrWhiteSpace(providerId);
        _providerId = providerId;
    }

    /// <summary>Explicit quota/credit exhaustion observed on this attempt, if any.</summary>
    public RouterError? Evidence { get; private set; }

    public async Task<Result<UpstreamResponse, RouterError>> SendAsync(
        UpstreamRequest request,
        TimeoutBoundaries boundaries,
        CancellationToken cancellationToken)
    {
        Result<UpstreamResponse, RouterError> sent = await _inner
            .SendAsync(request, boundaries, cancellationToken)
            .ConfigureAwait(false);
        if (sent.Value is not { } response
            || response.IsSuccessStatusCode
            || !QuotaExhaustionClassifier.CanEstablishEvidence(_providerId, response.StatusCode))
        {
            return sent;
        }

        if (!QuotaExhaustionClassifier.NeedsBody(_providerId, response.StatusCode))
        {
            Evidence = QuotaExhaustionClassifier.Classify(_providerId, response.StatusCode, ReadOnlySpan<byte>.Empty);
            return sent;
        }

        byte[] prefix;
        try
        {
            var guard = new StreamTimeoutGuard(response.Body, boundaries, DateTimeOffset.UtcNow, cancellationToken);
            prefix = await ReadBoundedAsync(guard, cancellationToken).ConfigureAwait(false);
        }
        catch (StreamTimeoutException exception)
        {
            return new Result<UpstreamResponse, RouterError>
            {
                Error = exception.Stage == StreamTimeoutStage.Total
                    ? ProviderAdapterErrors.TimeoutTotal()
                    : ProviderAdapterErrors.TimeoutIdle(),
            };
        }
        finally
        {
            response.Body.Dispose();
        }

        Evidence = QuotaExhaustionClassifier.Classify(_providerId, response.StatusCode, prefix);
        return new Result<UpstreamResponse, RouterError>
        {
            Value = response with { Body = new MemoryStream(prefix, writable: false) },
        };
    }

    private static async Task<byte[]> ReadBoundedAsync(StreamTimeoutGuard guard, CancellationToken cancellationToken)
    {
        using var memory = new MemoryStream();
        byte[] buffer = new byte[2048];
        int remaining = QuotaExhaustionClassifier.MaxErrorBodyBytes;
        while (remaining > 0)
        {
            int read = await guard
                .ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, remaining)), cancellationToken)
                .ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            await memory.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            remaining -= read;
        }

        return memory.ToArray();
    }
}
