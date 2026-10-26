using Router.ProviderAdapters.Abstractions;

namespace Router.ProviderAdapters.Responses;

/// <summary>Timeout stage that fired during stream decode.</summary>
public enum StreamTimeoutStage
{
    Idle,
    Total,
}

/// <summary>Thrown when an idle or total boundary fires during stream decode.</summary>
public sealed class StreamTimeoutException : Exception
{
    public StreamTimeoutException(StreamTimeoutStage stage)
        : base("Stream timeout.")
    {
        Stage = stage;
    }

    public StreamTimeoutStage Stage { get; }
}

/// <summary>
/// Cancellation-aware read guard for upstream bodies: every read is bounded by
/// the idle timeout and the remaining total deadline. Fires map to typed
/// <c>timeout_idle</c> / <c>timeout_total</c>; user cancellation propagates
/// unchanged.
/// </summary>
public sealed class StreamTimeoutGuard
{
    private readonly Stream _stream;
    private readonly TimeSpan _idle;
    private readonly TimeSpan _total;
    private readonly DateTimeOffset _started;
    private readonly CancellationToken _userToken;

    public StreamTimeoutGuard(Stream stream, TimeoutBoundaries boundaries, DateTimeOffset started, CancellationToken userToken)
    {
        _stream = stream;
        _idle = boundaries.IdleTimeout;
        _total = boundaries.TotalTimeout;
        _started = started;
        _userToken = userToken;
    }

    /// <summary>The wrapped upstream body stream.</summary>
    public Stream Stream => _stream;

    public async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken)
    {
        TimeSpan elapsed = DateTimeOffset.UtcNow - _started;
        TimeSpan remaining = _total - elapsed;
        if (remaining <= TimeSpan.Zero)
        {
            throw new StreamTimeoutException(StreamTimeoutStage.Total);
        }

        // The boundary that expires first decides the stage deterministically;
        // never re-measured afterwards, so classification cannot race.
        bool totalBoundaryIsShorter = remaining <= _idle;
        TimeSpan effective = totalBoundaryIsShorter ? remaining : _idle;

        using CancellationTokenSource readCts = CancellationTokenSource.CreateLinkedTokenSource(_userToken, cancellationToken);
        readCts.CancelAfter(effective);

        try
        {
            return await _stream.ReadAsync(buffer, readCts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!_userToken.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            throw new StreamTimeoutException(totalBoundaryIsShorter ? StreamTimeoutStage.Total : StreamTimeoutStage.Idle);
        }
    }

    public async Task<byte[]> ReadToEndAsync(CancellationToken cancellationToken)
    {
        using var memory = new MemoryStream();
        var buffer = new byte[81920];
        while (true)
        {
            int read = await ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return memory.ToArray();
            }

            await memory.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
        }
    }
}
