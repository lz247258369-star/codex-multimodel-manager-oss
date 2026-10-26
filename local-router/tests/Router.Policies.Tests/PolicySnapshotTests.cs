using Router.Policies;
using Xunit;

namespace Router.Policies.Tests;

public sealed class PolicySnapshotTests
{
    [Fact]
    public void Policy_snapshot_is_immutable_and_generation_bound()
    {
        PolicySnapshot first = PolicySnapshot.Create("gen-1", RetryPolicy.Default, TimeoutPolicy.Default, FailoverPolicy.Off);
        PolicySnapshot second = PolicySnapshot.Create("gen-2", RetryPolicy.Default, TimeoutPolicy.Default, FailoverPolicy.Off);

        Assert.Equal("gen-1", first.ConfigGeneration);
        Assert.NotEqual(first.ConfigGeneration, second.ConfigGeneration);
        Assert.Equal(RetryPolicy.Default.MaxAttempts, first.Retry.MaxAttempts);
    }

    [Fact]
    public void Deterministic_weighted_choice_is_repeatable()
    {
        WeightedCandidate[] candidates =
        [
            new() { Key = "route.a", Weight = 1 },
            new() { Key = "route.b", Weight = 3 },
        ];

        string first = DeterministicWeightedSelector.Select(candidates, "request-seed-1");
        string second = DeterministicWeightedSelector.Select(candidates, "request-seed-1");
        string other = DeterministicWeightedSelector.Select(candidates, "request-seed-2");
        string[] allowed = ["route.a", "route.b"];

        Assert.Equal(first, second);
        Assert.Contains(first, allowed);
        Assert.NotNull(other);
    }
}
