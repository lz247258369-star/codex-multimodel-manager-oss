namespace Router.Core.Abstractions;

/// <summary>
/// Source of the current UTC instant. Implementations must be thread-safe.
/// </summary>
public interface IClock
{
    /// <summary>Gets the current UTC instant.</summary>
    DateTimeOffset UtcNow { get; }
}

/// <summary>
/// Production clock backed by <see cref="DateTimeOffset.UtcNow"/>.
/// </summary>
public sealed class SystemClock : IClock
{
    /// <inheritdoc />
    public DateTimeOffset UtcNow => DateTimeOffset.UtcNow;
}
