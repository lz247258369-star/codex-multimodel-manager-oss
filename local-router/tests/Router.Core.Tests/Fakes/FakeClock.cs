namespace Router.Core.Tests.Fakes;

public sealed class FakeClock : Abstractions.IClock
{
    private long _unixTimeMilliseconds;

    public FakeClock(long unixTimeMilliseconds = 0)
    {
        _unixTimeMilliseconds = unixTimeMilliseconds;
    }

    public DateTimeOffset UtcNow => DateTimeOffset.FromUnixTimeMilliseconds(Volatile.Read(ref _unixTimeMilliseconds));

    public void AdvanceMilliseconds(long deltaMilliseconds)
        => Interlocked.Add(ref _unixTimeMilliseconds, deltaMilliseconds);

    public void SetUnixTimeMilliseconds(long unixTimeMilliseconds)
        => Interlocked.Exchange(ref _unixTimeMilliseconds, unixTimeMilliseconds);
}
