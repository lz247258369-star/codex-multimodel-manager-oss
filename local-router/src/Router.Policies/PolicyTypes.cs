namespace Router.Policies;

/// <summary>
/// Versioned conservative retry policy. Defaults are bounded and respect the
/// pre-output retry boundary inherited from LR-5.
/// </summary>
public sealed record RetryPolicy
{
    public const int SchemaVersion = 1;
    public const int DefaultMaxAttempts = 2;

    public required int MaxAttempts { get; init; }

    public required TimeSpan BaseDelay { get; init; }

    public required TimeSpan MaxDelay { get; init; }

    public required decimal Jitter { get; init; }

    public required bool RespectRetryAfter { get; init; }

    public required TimeSpan MaxRetryAfter { get; init; }

    public static RetryPolicy Default { get; } = Create(
        maxAttempts: DefaultMaxAttempts,
        baseDelay: TimeSpan.FromMilliseconds(200),
        maxDelay: TimeSpan.FromSeconds(5),
        jitter: 0.2m,
        respectRetryAfter: true,
        maxRetryAfter: TimeSpan.FromSeconds(30));

    public static RetryPolicy Create(
        int maxAttempts,
        TimeSpan baseDelay,
        TimeSpan maxDelay,
        decimal jitter,
        bool respectRetryAfter,
        TimeSpan maxRetryAfter)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(maxAttempts, 1, nameof(maxAttempts));
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(baseDelay, TimeSpan.Zero, nameof(baseDelay));
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(maxDelay, TimeSpan.Zero, nameof(maxDelay));
        ArgumentOutOfRangeException.ThrowIfLessThan(maxDelay, baseDelay, nameof(maxDelay));
        ArgumentOutOfRangeException.ThrowIfGreaterThan(jitter, 1m, nameof(jitter));
        ArgumentOutOfRangeException.ThrowIfLessThan(jitter, 0m, nameof(jitter));

        return new RetryPolicy
        {
            MaxAttempts = maxAttempts,
            BaseDelay = baseDelay,
            MaxDelay = maxDelay,
            Jitter = jitter,
            RespectRetryAfter = respectRetryAfter,
            MaxRetryAfter = maxRetryAfter,
        };
    }
}

/// <summary>Versioned timeout policy; total deadline is always authoritative.</summary>
public sealed record TimeoutPolicy
{
    public const int SchemaVersion = 1;

    public required TimeSpan ConnectTimeout { get; init; }

    public required TimeSpan FirstByteTimeout { get; init; }

    public required TimeSpan IdleTimeout { get; init; }

    public required TimeSpan AttemptTimeout { get; init; }

    public required TimeSpan TotalTimeout { get; init; }

    public static TimeoutPolicy Default { get; } = Create(
        connectTimeout: TimeSpan.FromSeconds(10),
        firstByteTimeout: TimeSpan.FromSeconds(30),
        idleTimeout: TimeSpan.FromSeconds(60),
        attemptTimeout: TimeSpan.FromMinutes(5),
        totalTimeout: TimeSpan.FromMinutes(10));

    public static TimeoutPolicy Create(
        TimeSpan connectTimeout,
        TimeSpan firstByteTimeout,
        TimeSpan idleTimeout,
        TimeSpan attemptTimeout,
        TimeSpan totalTimeout)
    {
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(connectTimeout, TimeSpan.Zero, nameof(connectTimeout));
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(firstByteTimeout, TimeSpan.Zero, nameof(firstByteTimeout));
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(idleTimeout, TimeSpan.Zero, nameof(idleTimeout));
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(attemptTimeout, TimeSpan.Zero, nameof(attemptTimeout));
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(totalTimeout, TimeSpan.Zero, nameof(totalTimeout));
        ArgumentOutOfRangeException.ThrowIfLessThan(totalTimeout, attemptTimeout, nameof(totalTimeout));
        ArgumentOutOfRangeException.ThrowIfLessThan(attemptTimeout, firstByteTimeout, nameof(attemptTimeout));
        ArgumentOutOfRangeException.ThrowIfLessThan(firstByteTimeout, connectTimeout, nameof(firstByteTimeout));

        return new TimeoutPolicy
        {
            ConnectTimeout = connectTimeout,
            FirstByteTimeout = firstByteTimeout,
            IdleTimeout = idleTimeout,
            AttemptTimeout = attemptTimeout,
            TotalTimeout = totalTimeout,
        };
    }
}

/// <summary>The four failover classes from the contracts document.</summary>
public enum FailoverClass
{
    SameProviderRetry,
    SameModelAlternateEndpoint,
    SameModelAlternateProvider,
    CrossModelFallback,
}

/// <summary>
/// Versioned conservative failover policy. Cross-model fallback and automatic
/// alternate-provider failover are OFF by default; same-provider retry is
/// governed by the retry policy.
/// </summary>
public sealed record FailoverPolicy
{
    public const int SchemaVersion = 1;

    public required bool Enabled { get; init; }

    public required bool AllowSameModelAlternateEndpoint { get; init; }

    public required bool AllowSameModelAlternateProvider { get; init; }

    public required bool AllowCrossModelFallback { get; init; }

    public static FailoverPolicy Off { get; } = new()
    {
        Enabled = false,
        AllowSameModelAlternateEndpoint = false,
        AllowSameModelAlternateProvider = false,
        AllowCrossModelFallback = false,
    };

    public static FailoverPolicy Create(
        bool allowSameModelAlternateEndpoint,
        bool allowSameModelAlternateProvider,
        bool allowCrossModelFallback)
    {
        if (allowCrossModelFallback)
        {
            throw new InvalidOperationException("Cross-model fallback must remain OFF for LR-11.");
        }

        return new FailoverPolicy
        {
            Enabled = allowSameModelAlternateEndpoint || allowSameModelAlternateProvider,
            AllowSameModelAlternateEndpoint = allowSameModelAlternateEndpoint,
            AllowSameModelAlternateProvider = allowSameModelAlternateProvider,
            AllowCrossModelFallback = false,
        };
    }
}
