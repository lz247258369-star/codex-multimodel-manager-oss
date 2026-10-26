namespace Router.ProviderAdapters.Abstractions;

/// <summary>
/// Immutable, positive timeout boundaries for one upstream attempt. Every
/// boundary is cancellation-aware and normalizes to a typed timeout error;
/// LR-11 later owns policy decisions that produce these boundaries.
/// </summary>
public sealed record TimeoutBoundaries
{
    public required TimeSpan ConnectTimeout { get; init; }

    public required TimeSpan FirstByteTimeout { get; init; }

    public required TimeSpan IdleTimeout { get; init; }

    public required TimeSpan TotalTimeout { get; init; }

    public static TimeoutBoundaries Default { get; } = new()
    {
        ConnectTimeout = TimeSpan.FromSeconds(10),
        FirstByteTimeout = TimeSpan.FromSeconds(30),
        IdleTimeout = TimeSpan.FromSeconds(60),
        TotalTimeout = TimeSpan.FromMinutes(10),
    };

    public static TimeoutBoundaries Create(
        TimeSpan connectTimeout,
        TimeSpan firstByteTimeout,
        TimeSpan idleTimeout,
        TimeSpan totalTimeout)
    {
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(connectTimeout, TimeSpan.Zero, nameof(connectTimeout));
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(firstByteTimeout, TimeSpan.Zero, nameof(firstByteTimeout));
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(idleTimeout, TimeSpan.Zero, nameof(idleTimeout));
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(totalTimeout, TimeSpan.Zero, nameof(totalTimeout));
        ArgumentOutOfRangeException.ThrowIfLessThan(totalTimeout, connectTimeout, nameof(totalTimeout));
        ArgumentOutOfRangeException.ThrowIfLessThan(totalTimeout, firstByteTimeout, nameof(totalTimeout));

        return new TimeoutBoundaries
        {
            ConnectTimeout = connectTimeout,
            FirstByteTimeout = firstByteTimeout,
            IdleTimeout = idleTimeout,
            TotalTimeout = totalTimeout,
        };
    }
}
