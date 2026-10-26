namespace Router.TestSupport;

/// <summary>Repository fixture root helpers for LR-4 tests.</summary>
public static class TestPaths
{
    public static string CatalogFixtureRoot
        => Path.Combine(AppContext.BaseDirectory, "fixtures", "local-router", "v1", "catalog");

    public static string RoutingFixtureRoot
        => Path.Combine(AppContext.BaseDirectory, "fixtures", "local-router", "v1", "routing");

    public static string CatalogFixture(string name) => Path.Combine(CatalogFixtureRoot, name);

    public static string RoutingFixture(string name) => Path.Combine(RoutingFixtureRoot, name);
}
