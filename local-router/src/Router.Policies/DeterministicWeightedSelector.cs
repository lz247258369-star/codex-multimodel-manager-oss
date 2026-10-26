namespace Router.Policies;

/// <summary>One explicit weighted candidate; key is a stable identifier, never content.</summary>
public sealed record WeightedCandidate
{
    public required string Key { get; init; }

    public required int Weight { get; init; }
}

/// <summary>
/// Deterministic weighted selection over equivalent policy candidates. Uses a
/// stable seed + local random state; never sorts by price and never depends on
/// global Random state.
/// </summary>
public static class DeterministicWeightedSelector
{
    public static string Select(IReadOnlyList<WeightedCandidate> candidates, string seed)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        ArgumentException.ThrowIfNullOrWhiteSpace(seed);
        if (candidates.Count == 0)
        {
            throw new ArgumentException("Weighted selection requires at least one candidate.", nameof(candidates));
        }

        long total = 0;
        foreach (WeightedCandidate candidate in candidates)
        {
            ArgumentException.ThrowIfNullOrWhiteSpace(candidate.Key);
            ArgumentOutOfRangeException.ThrowIfLessThan(candidate.Weight, 1, nameof(candidate.Weight));
            total += candidate.Weight;
        }

        var random = new DeterministicRandom(seed);
        double target = random.NextDouble() * total;
        double cumulative = 0d;
        foreach (WeightedCandidate candidate in candidates)
        {
            cumulative += candidate.Weight;
            if (target < cumulative)
            {
                return candidate.Key;
            }
        }

        return candidates[^1].Key;
    }
}
