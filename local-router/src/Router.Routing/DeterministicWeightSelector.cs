using System.Security.Cryptography;
using System.Text;

namespace Router.Routing;

/// <summary>A weighted candidate with a stable key and a non-negative weight.</summary>
public sealed record WeightedCandidate(string Key, int Weight);

/// <summary>
/// Deterministic weighted selection over equally-prioritized eligible
/// candidates. The same <c>(config_generation, selection key, candidate set)</c>
/// always selects the same candidate; no process randomness, clock, or default
/// seed participates. Zero-weight candidates are excluded; when all weights are
/// zero, the smallest stable hash wins.
/// </summary>
public static class DeterministicWeightSelector
{
    /// <summary>Selects one candidate key deterministically, or null for an empty set.</summary>
    public static string? Select(
        IReadOnlyList<WeightedCandidate> candidates,
        string configGeneration,
        string selectionKey)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        ArgumentNullException.ThrowIfNull(configGeneration);
        ArgumentNullException.ThrowIfNull(selectionKey);

        if (candidates.Count == 0)
        {
            return null;
        }

        IReadOnlyList<WeightedCandidate> ordered = candidates
            .OrderBy(static candidate => candidate.Key, StringComparer.Ordinal)
            .ToArray();

        WeightedCandidate[] weighted = ordered
            .Where(static candidate => candidate.Weight > 0)
            .ToArray();

        if (weighted.Length == 0)
        {
            return ordered
                .OrderBy(candidate => Hash(configGeneration, selectionKey, candidate.Key))
                .ThenBy(static candidate => candidate.Key, StringComparer.Ordinal)
                .First()
                .Key;
        }

        long total = weighted.Sum(static candidate => (long)candidate.Weight);
        ulong remainder = Hash(configGeneration, selectionKey, weighted[0].Key) % (ulong)total;

        // The draw uses the first candidate's hash as the deterministic seed so
        // the result depends only on the stable inputs.
        foreach (WeightedCandidate candidate in weighted)
        {
            if (remainder < (ulong)candidate.Weight)
            {
                return candidate.Key;
            }

            remainder -= (ulong)candidate.Weight;
        }

        return weighted[^1].Key;
    }

    private static ulong Hash(string configGeneration, string selectionKey, string candidateKey)
    {
        string input = configGeneration + "\u001f" + selectionKey + "\u001f" + candidateKey;
        byte[] digest = SHA256.HashData(Encoding.UTF8.GetBytes(input));
        ulong value = 0;
        for (int index = 0; index < 8; index++)
        {
            value = (value << 8) | digest[index];
        }

        return value;
    }
}
