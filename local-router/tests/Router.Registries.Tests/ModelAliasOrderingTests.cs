using Router.Configuration;
using Router.Core.Errors;
using Router.Registries;
using Router.TestSupport;
using Xunit;

namespace Router.Registries.Tests;

/// <summary>
/// LR15-G1: alias safety must not depend on the declaration order of model
/// routes. An alias that collides with another route's client_model_id inside the
/// same provider fails closed no matter which of the two routes is declared
/// first, and distinct names still build. Comparison stays Ordinal and
/// provider-scoped; nothing is resolved first-wins.
/// </summary>
public sealed class ModelAliasOrderingTests
{
    private const string AliasOwnerRouteId = "model-route.alias-owner";
    private const string ExactOwnerRouteId = "model-route.exact-owner";
    private const string AliasOwnerClientModelId = "alias-owner-model";
    private const string SharedName = "shared-model-name";

    [Fact]
    public void Alias_declared_before_the_colliding_client_model_id_fails_closed()
        => AssertCollisionFailsClosed(aliasOwnerFirst: true);

    [Fact]
    public void Alias_declared_after_the_colliding_client_model_id_fails_closed()
        => AssertCollisionFailsClosed(aliasOwnerFirst: false);

    [Fact]
    public void Distinct_aliases_and_client_model_ids_still_build()
    {
        RegistrySnapshotBuildResult result = Build(CollisionConfig(aliasOwnerFirst: true, collide: false));

        Assert.Null(result.Error);
        Assert.NotNull(result.Snapshot);
        Assert.Equal(2, result.Snapshot!.ModelRoutes.Count);
    }

    [Fact]
    public void Alias_equal_to_its_own_client_model_id_fails_closed()
    {
        RouterConfig config = TestRouterConfigFactory.StandardConfig() with
        {
            ModelRoutes =
            [
                TestRouterConfigFactory.ModelRoute(
                    modelRouteId: AliasOwnerRouteId,
                    clientModelId: AliasOwnerClientModelId,
                    modelId: AliasOwnerClientModelId,
                    aliases: [AliasOwnerClientModelId],
                    pricingRef: null),
            ],
            Routes =
            [
                TestRouterConfigFactory.Route(routeId: "route.alias-owner", modelRouteId: AliasOwnerRouteId),
            ],
        };

        RegistrySnapshotBuildResult result = Build(config);

        Assert.Null(result.Snapshot);
        Assert.NotNull(result.Error);
        Assert.Equal(RouterErrorCode.AmbiguousModel, result.Error!.Code);
    }

    private static void AssertCollisionFailsClosed(bool aliasOwnerFirst)
    {
        RegistrySnapshotBuildResult result = Build(CollisionConfig(aliasOwnerFirst, collide: true));

        Assert.Null(result.Snapshot);
        Assert.NotNull(result.Error);
        Assert.Equal(RouterErrorCode.AmbiguousModel, result.Error!.Code);
        Assert.Equal("model_routes.aliases", result.Error.Param);
    }

    private static RegistrySnapshotBuildResult Build(RouterConfig config)
        => RegistrySnapshotBuilder.Build(
            TestRouterConfigFactory.Snapshot(config),
            adapterRegistrations: TestRouterConfigFactory.StandardAdapterRegistrations());

    /// <summary>
    /// Two routes in the same provider. When <paramref name="collide"/> is true the
    /// alias owner declares an alias equal to the other route's client_model_id;
    /// otherwise the names are distinct and the configuration must build.
    /// </summary>
    private static RouterConfig CollisionConfig(bool aliasOwnerFirst, bool collide)
    {
        ModelRouteConfig aliasOwner = TestRouterConfigFactory.ModelRoute(
            modelRouteId: AliasOwnerRouteId,
            clientModelId: AliasOwnerClientModelId,
            modelId: AliasOwnerClientModelId,
            aliases: [collide ? SharedName : "alias-owner-alias"],
            pricingRef: null);

        ModelRouteConfig exactOwner = TestRouterConfigFactory.ModelRoute(
            modelRouteId: ExactOwnerRouteId,
            clientModelId: collide ? SharedName : "exact-owner-model",
            modelId: collide ? SharedName : "exact-owner-model",
            pricingRef: null);

        ModelRouteConfig[] modelRoutes = aliasOwnerFirst ? [aliasOwner, exactOwner] : [exactOwner, aliasOwner];

        return TestRouterConfigFactory.StandardConfig() with
        {
            ModelRoutes = modelRoutes,
            Routes =
            [
                TestRouterConfigFactory.Route(routeId: "route.alias-owner", modelRouteId: AliasOwnerRouteId),
                TestRouterConfigFactory.Route(routeId: "route.exact-owner", modelRouteId: ExactOwnerRouteId),
            ],
        };
    }
}
