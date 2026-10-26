using Router.TestSupport;
using Xunit;

namespace Router.Routing.Tests;

public sealed class DeterministicWeightSelectorTests
{
    [Fact]
    public void Same_inputs_always_select_the_same_candidate()
    {
        string generation = TestRouterConfigFactory.TestGeneration;
        string key = "client.codex_cli|z-ai/glm-5.3|";
        IReadOnlyList<WeightedCandidate> candidates =
        [
            new("route.openrouter-primary", 70),
            new("route.openrouter-secondary", 30),
        ];

        string? first = null;
        for (int iteration = 0; iteration < 1000; iteration++)
        {
            string? selected = DeterministicWeightSelector.Select(candidates, generation, key);
            Assert.NotNull(selected);
            first ??= selected;
            Assert.Equal(first, selected);
        }
    }

    [Fact]
    public void Different_selection_keys_can_select_different_candidates()
    {
        IReadOnlyList<WeightedCandidate> candidates =
        [
            new("route.openrouter-primary", 70),
            new("route.openrouter-secondary", 30),
        ];

        var winners = new HashSet<string>(StringComparer.Ordinal);
        for (int seed = 0; seed < 64; seed++)
        {
            string? selected = DeterministicWeightSelector.Select(candidates, TestRouterConfigFactory.TestGeneration, "seed:" + seed.ToString("D4"));
            Assert.NotNull(selected);
            winners.Add(selected!);
        }

        Assert.True(winners.Count > 1, "A deterministic hash over distinct selection keys must not collapse to one candidate for a weighted set.");
    }

    [Fact]
    public void Selection_is_stable_for_every_config_generation()
    {
        IReadOnlyList<WeightedCandidate> candidates =
        [
            new("route.openrouter-primary", 70),
            new("route.openrouter-secondary", 30),
        ];

        string genA = TestRouterConfigFactory.TestGeneration;
        string genB = Router.Core.Support.SafeHasher.Sha256Hex("another-generation");

        foreach (string generation in new[] { genA, genB })
        {
            string? first = null;
            for (int iteration = 0; iteration < 200; iteration++)
            {
                string? selected = DeterministicWeightSelector.Select(candidates, generation, "seed:0001");
                Assert.NotNull(selected);
                first ??= selected;
                Assert.Equal(first, selected);
            }
        }
    }

    [Fact]
    public void Empty_candidate_set_returns_null()
    {
        Assert.Null(DeterministicWeightSelector.Select([], "generation", "key"));
    }

    [Fact]
    public void Zero_weight_candidates_fall_back_to_smallest_stable_hash()
    {
        IReadOnlyList<WeightedCandidate> candidates =
        [
            new("route.alpha", 0),
            new("route.beta", 0),
        ];

        string? first = DeterministicWeightSelector.Select(candidates, TestRouterConfigFactory.TestGeneration, "seed:0001");
        for (int iteration = 0; iteration < 100; iteration++)
        {
            Assert.Equal(first, DeterministicWeightSelector.Select(candidates, TestRouterConfigFactory.TestGeneration, "seed:0001"));
        }
    }
}
