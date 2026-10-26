using System.Text.Json;
using System.Text.Json.Nodes;
using Router.Configuration;
using Router.Registries;
using Router.TestSupport;
using Xunit;

namespace Router.Routing.Tests;

public sealed class ResolvedRouteGoldenTests
{
    [Fact]
    public void Resolved_route_matches_the_golden_fixture()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig();
        RegistrySnapshotBuildResult build = RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config),
            adapterRegistrations: TestRouterConfigFactory.StandardAdapterRegistrations());
        build.Validate();

        RouteResolutionResult resolution = new RouteResolver().Resolve(
            RouteRequest.Create(TestRouterConfigFactory.ClientId, TestRouterConfigFactory.ClientModelId, CapabilitySet.From(["text"])),
            build.Snapshot!);
        resolution.Validate();

        JsonObject actual = GoldenProjection(resolution.Route!);
        JsonObject expected = JsonNode.Parse(File.ReadAllText(TestPaths.RoutingFixture("golden/resolved.openrouter-glm53.json")))!.AsObject();

        Assert.Equal(Compact(expected), Compact(actual));
    }

    [Fact]
    public void Weighted_selection_matches_the_golden_fixture()
    {
        JsonObject expected = JsonNode.Parse(File.ReadAllText(TestPaths.RoutingFixture("golden/weighted-selection.json")))!.AsObject();
        var candidates = new List<WeightedCandidate>();
        foreach (JsonNode? candidate in expected["candidates"]!.AsArray())
        {
            candidates.Add(new WeightedCandidate(
                candidate!["route_id"]!.GetValue<string>(),
                candidate["weight"]!.GetValue<int>()));
        }

        var expectedSelections = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (KeyValuePair<string, JsonNode?> pair in expected["selection"]!.AsObject())
        {
            expectedSelections[pair.Key] = pair.Value!.GetValue<string>();
        }

        foreach (KeyValuePair<string, string> entry in expectedSelections)
        {
            string? selected = DeterministicWeightSelector.Select(candidates, TestRouterConfigFactory.TestGeneration, entry.Key);
            Assert.Equal(entry.Value, selected);
        }
    }

    private static JsonObject GoldenProjection(ResolvedRoute route)
    {
        return new JsonObject
        {
            ["route_id"] = route.RouteId,
            ["client_id"] = route.ClientId,
            ["provider_route_id"] = route.ProviderRoute.ProviderRouteId,
            ["protocol_route_id"] = route.ProtocolRoute.ProtocolRouteId,
            ["model_route_id"] = route.ModelRoute.ModelRouteId,
            ["endpoint_id"] = route.Endpoint.EndpointId,
            ["effective_capabilities"] = new JsonArray(route.EffectiveCapabilities.Values.Select(static value => JsonValue.Create(value)).ToArray()),
            ["timeout_policy_id"] = route.TimeoutPolicyId,
            ["retry_policy_id"] = route.RetryPolicyId,
            ["failover_policy_id"] = route.FailoverPolicyId,
            ["pricing_snapshot_id"] = route.PricingSnapshotId,
            ["secret_ref_name"] = route.SecretRef?.Name,
        };
    }

    private static string Compact(JsonNode node)
        => node.ToJsonString(new JsonSerializerOptions { WriteIndented = false });

}
