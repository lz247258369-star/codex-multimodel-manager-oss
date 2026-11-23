namespace Router.Core.Tests.Host;

/// <summary>
/// Starts at a pinned instant and then advances with real elapsed time, so
/// Host timing behaves normally while dates stay deterministic.
/// </summary>
internal sealed class PinnedTestClock : Router.Core.Abstractions.IClock
{
    private readonly DateTimeOffset _start;
    private readonly System.Diagnostics.Stopwatch _elapsed = System.Diagnostics.Stopwatch.StartNew();

    public PinnedTestClock(DateTimeOffset start)
    {
        _start = start;
    }

    public DateTimeOffset UtcNow => _start + _elapsed.Elapsed;
}
