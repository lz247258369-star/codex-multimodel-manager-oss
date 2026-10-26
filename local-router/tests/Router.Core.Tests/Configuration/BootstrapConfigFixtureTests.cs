using Router.Configuration;
using Router.Core.Abstractions;
using Router.Core.Tests.Fakes;
using Router.Execution;
using Router.Registries;
using Router.State;
using Xunit;

namespace Router.Core.Tests.Configuration;

/// <summary>
/// HS1B-RB1 Local Router bootstrap acceptance. The committed golden fixture is
/// the exact document <c>installer/scripts/router-codex-cli.ps1 -Action
/// Initialize</c> writes for the committed approval/secret fixture pair, so the
/// canonical implementation must load it as a schema-v1 user config, build a
/// production registry snapshot from it, and consider every generated route
/// structurally approved. No provider, network, or secret value is involved.
/// </summary>
public sealed class BootstrapConfigFixtureTests
{
    private static string GoldenConfigPath
        => TestPaths.Fixture(Path.Combine("bootstrap", "router-config.expected.json"));

    private const string CodexClientId = "client.codex_cli";

    [Fact]
    public async Task Bootstrap_golden_fixture_is_a_valid_schema_v1_user_config()
    {
        RouterConfigLoadResult result = await LoadGoldenAsync();

        Assert.True(result.IsSuccess, result.Error?.Code.ToString());
        RouterConfig config = result.Snapshot!.Config;
        Assert.Equal(RouterMode.Router, config.Mode);
        Assert.True(config.LocalRouter.Enabled);
        Assert.Equal("127.0.0.1", config.LocalRouter.Host);
        Assert.Equal(47821, config.LocalRouter.Port);
        Assert.Equal("CODEX_LOCAL_ROUTER_TOKEN", config.LocalRouter.ClientAuth.TokenRef);
        Assert.False(config.LocalRouter.ThreadSelection.Enabled);

        // DSR7-B-FIX1: the bootstrap now generates the execution client AND the
        // dedicated control-plane client (the Control Plane requires the
        // "router:control-plane" scope, and ClientScopeRegistry resolves a scope
        // to exactly one enabled client). Both are part of the golden fixture.
        Assert.Equal(2, config.Clients.Count);
        ClientConfig client = Assert.Single(config.Clients, c => c.ClientId == CodexClientId);
        Assert.Equal("responses:invoke", client.AuthScope);
        ClientConfig controlPlane = Assert.Single(config.Clients, c => c.ClientId == "client.control_plane");
        Assert.Equal("router:control-plane", controlPlane.AuthScope);
        Assert.True(controlPlane.Enabled);
        Assert.Equal("adapter.client.control_plane.responses.v1", controlPlane.AdapterId);

        Assert.Single(config.ProtocolRoutes);
        // DSR2: the direct DeepSeek provider joins the bootstrap route set.
        Assert.Equal(4, config.ProviderRoutes.Count);
        Assert.Equal(4, config.Endpoints.Count);
        Assert.Equal(5, config.ModelRoutes.Count);
        Assert.Equal(5, config.Routes.Count);
        Assert.Equal(3, config.Policies.Count);

        // Cross-model automatic fallback stays OFF: the failover policy exists
        // but carries no body, and no policy body can express a cross-model hop.
        Assert.All(config.Policies, policy => Assert.Null(policy.FailoverBody));
    }

    [Fact]
    public async Task Bootstrap_golden_fixture_builds_a_usable_production_registry()
    {
        RouterConfigLoadResult result = await LoadGoldenAsync();
        Assert.True(result.IsSuccess, result.Error?.Code.ToString());

        RegistrySnapshotBuildResult build = RegistrySnapshotBuilder.Build(
            result.Snapshot!,
            catalogProjection: null,
            RouterExecutionDefaults.RegistryRegistrations);

        Assert.True(build.Snapshot is not null, build.Error?.Code.ToString());
        RouterRegistrySnapshot snapshot = build.Snapshot!;
        Assert.Equal(4, snapshot.ProviderRoutes.Count);
        Assert.Equal(5, snapshot.ModelRoutes.Count);
        Assert.Equal(5, snapshot.Routes.Count);

        // Every generated provider route resolves against a real production
        // adapter and a repository-approved endpoint.
        Assert.All(snapshot.ProviderRoutes.Values, route =>
        {
            Assert.True(route.Enabled);
            Assert.True(route.HasEligibleAdapter, route.ProviderRouteId);
            Assert.NotNull(snapshot.TryGetProvider(route.ProviderId));
            Assert.True(snapshot.TryGetProvider(route.ProviderId)!.IsUsable, route.ProviderId);
            Assert.NotEmpty(route.EndpointIds);
            Assert.All(route.EndpointIds, endpointId =>
            {
                EndpointRegistryEntry? endpoint = snapshot.TryGetEndpoint(endpointId);
                Assert.NotNull(endpoint);
                Assert.True(endpoint!.Enabled);
            });
        });

        Assert.All(snapshot.Routes.Values, route =>
        {
            Assert.True(route.Enabled, route.RouteId);
            Assert.Contains(CodexClientId, route.ClientIds);
            Assert.True(snapshot.TryGetProtocolRoute(route.ProtocolRouteId)!.IsUsable, route.ProtocolRouteId);
        });

        // The approved-model validator is the production gate used by the
        // thread-scoped selection control plane; every bootstrapped model must
        // pass it for the client that owns the generated routes.
        RouterExecutionApprovedModelValidator validator = new(snapshot);
        foreach (ModelRouteRegistryEntry modelRoute in snapshot.ModelRoutes.Values)
        {
            Assert.True(
                validator.IsApprovedForClient(CodexClientId, modelRoute.ClientModelId),
                modelRoute.ClientModelId);
        }

        // A model that the canonical catalog knows but the user never approved
        // is not silently routable.
        Assert.False(validator.IsApprovedForClient(CodexClientId, "qwen3.8-max"));
        // DSR2 bootstraps the direct DeepSeek provider for real: the identity is
        // eligible and the golden fixture carries a deepseek provider route plus
        // the canonical flash/pro model routes.
        ProviderDescriptor? deepSeek = snapshot.TryGetProvider("deepseek");
        Assert.NotNull(deepSeek);
        Assert.NotEmpty(deepSeek!.Capabilities);
        ProviderRouteRegistryEntry deepSeekRoute = Assert.Single(
            snapshot.ProviderRoutes.Values,
            route => route.ProviderId == "deepseek");
        Assert.True(deepSeekRoute.HasEligibleAdapter);
        Assert.Equal("adapter.provider.deepseek.responses.v1", deepSeekRoute.AdapterId);
        Assert.Equal("provider-config:deepseek.base_url", deepSeekRoute.BaseUrlRef);
        ModelRouteRegistryEntry flashRoute = Assert.Single(
            snapshot.ModelRoutes.Values,
            route => route.ProviderId == "deepseek" && route.ClientModelId == "deepseek-flash");
        Assert.Equal("deepseek-flash", flashRoute.UpstreamModelId);
        Assert.Equal(
            ["deepseek-v4-flash", "deepseek-v4-flash-vision-exp"],
            flashRoute.Aliases);
        ModelRouteRegistryEntry proRoute = Assert.Single(
            snapshot.ModelRoutes.Values,
            route => route.ProviderId == "deepseek" && route.ClientModelId == "deepseek-v4-pro");
        Assert.Equal("deepseek-v4-pro", proRoute.UpstreamModelId);
        Assert.Empty(proRoute.Aliases);
        // The paused Model Studio catalog records never become active routes for
        // the slugs the direct provider owns.
        Assert.DoesNotContain(
            snapshot.ModelRoutes.Values,
            route => route.ProviderId == "mm_modelstudio" && route.ClientModelId is "deepseek-v4-pro" or "deepseek-v4-flash");
        // The reserved placeholder identity is still never usable.
        Assert.False(snapshot.TryGetProvider("deepseek_direct")!.IsUsable);
    }

    [Fact]
    public void Bootstrap_golden_fixture_declares_exactly_one_local_router_provider_identity()
    {
        string golden = File.ReadAllText(GoldenConfigPath);

        Assert.Contains("\"token_ref\": \"CODEX_LOCAL_ROUTER_TOKEN\"", golden, StringComparison.Ordinal);
        Assert.DoesNotContain("wire_api", golden, StringComparison.Ordinal);
        // Endpoints are referenced, never inlined: no absolute URL is persisted.
        Assert.DoesNotContain("https://", golden, StringComparison.Ordinal);
        Assert.Contains("\"base_url_ref\": \"provider-config:mm_", golden, StringComparison.Ordinal);
        Assert.DoesNotContain("api.deepseek.com", golden, StringComparison.Ordinal);
    }

    private static async Task<RouterConfigLoadResult> LoadGoldenAsync()
    {
        RouterConfigurationLoader loader = new(new WindowsFileSystem(), new SystemClock());
        return await loader
            .LoadAsync(TestPaths.DefaultsPath, GoldenConfigPath, CancellationToken.None);
    }
}
