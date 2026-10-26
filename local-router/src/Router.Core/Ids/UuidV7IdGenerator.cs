using System.Security.Cryptography;
using Router.Core.Abstractions;

namespace Router.Core.Ids;

/// <summary>
/// Thread-safe UUIDv7 generator with a 12-bit sub-millisecond counter and a
/// monotonic clock clamp. Uses the injected <see cref="IClock"/> so tests can
/// drive time deterministically.
/// </summary>
public sealed class UuidV7IdGenerator : IIdGenerator
{
    private const ushort SubMillisecondMask = 0x0FFF;

    private readonly object _sync = new();
    private readonly IClock _clock;
    private long _lastUnixTimeMilliseconds = long.MinValue;
    private ushort _subMillisecondCounter;

    public UuidV7IdGenerator(IClock clock)
    {
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
    }

    /// <inheritdoc />
    public RequestId NewRequestId() => RequestId.Create(NewUuidV7());

    /// <inheritdoc />
    public TraceId NewTraceId() => TraceId.Create(NewUuidV7());

    /// <inheritdoc />
    public AttemptId NewAttemptId() => AttemptId.Create(NewUuidV7());

    /// <summary>Creates a new UUIDv7 from the current clock instant.</summary>
    public UuidV7 NewUuidV7()
    {
        long now = _clock.UtcNow.ToUnixTimeMilliseconds();
        byte[] randomBytes = RandomNumberGenerator.GetBytes(8);

        lock (_sync)
        {
            if (now < _lastUnixTimeMilliseconds)
            {
                now = _lastUnixTimeMilliseconds;
            }

            if (now == _lastUnixTimeMilliseconds)
            {
                _subMillisecondCounter++;
                if (_subMillisecondCounter > SubMillisecondMask)
                {
                    _subMillisecondCounter = 0;
                    now = _lastUnixTimeMilliseconds + 1;
                }
            }
            else
            {
                _subMillisecondCounter = 0;
            }

            _lastUnixTimeMilliseconds = now;
            return UuidV7.FromUnixTimeMilliseconds(now, _subMillisecondCounter, randomBytes);
        }
    }
}
