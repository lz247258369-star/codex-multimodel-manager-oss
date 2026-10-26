namespace Router.Ingress;

/// <summary>
/// Bounded, non-queuing in-flight request limiter. When the configured maximum
/// is reached the next request is rejected immediately with a stable error; no
/// unbounded queue exists and shutdown cannot deadlock on it.
/// </summary>
public sealed class ConnectionLimiter
{
    private readonly int _max;
    private int _inFlight;

    public ConnectionLimiter(int maxConnections)
    {
        _max = Math.Max(1, maxConnections);
    }

    public int MaxConnections => _max;

    public int InFlightCount => Volatile.Read(ref _inFlight);

    /// <summary>Attempts to enter the limiter; false when at capacity.</summary>
    public bool TryEnter()
    {
        while (true)
        {
            int current = Volatile.Read(ref _inFlight);
            if (current >= _max)
            {
                return false;
            }

            if (Interlocked.CompareExchange(ref _inFlight, current + 1, current) == current)
            {
                return true;
            }
        }
    }

    /// <summary>Releases one slot. Must be paired with a successful <see cref="TryEnter"/>.</summary>
    public void Exit() => Interlocked.Decrement(ref _inFlight);
}
