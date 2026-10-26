namespace Router.Policies;

/// <summary>Deterministic random source used by backoff/jitter and weighted choice.</summary>
public interface IDeterministicRandom
{
    double NextDouble();
}

/// <summary>
/// Seed-stable xorshift random source. Identical seed + identical call order
/// produce identical decisions; no global Random state is ever used.
/// </summary>
public sealed class DeterministicRandom : IDeterministicRandom
{
    private ulong _state;

    public DeterministicRandom(string seed)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(seed);
        _state = 14695981039346656037UL;
        foreach (char c in seed)
        {
            _state ^= c;
            _state *= 1099511628211UL;
        }

        if (_state == 0)
        {
            _state = 0x9E3779B97F4A7C15UL;
        }
    }

    public double NextDouble()
    {
        _state ^= _state << 13;
        _state ^= _state >> 7;
        _state ^= _state << 17;
        return (_state >> 11) / (double)(1UL << 53);
    }
}
