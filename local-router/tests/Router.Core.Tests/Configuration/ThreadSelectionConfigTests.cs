using Router.Configuration;
using Xunit;

namespace Router.Core.Tests.Configuration;

/// <summary>
/// HS-1B configuration bounds: the capability ships disabled and every TTL is
/// clamped to the hard floors/ceilings by validation.
/// </summary>
public sealed class ThreadSelectionConfigTests
{
    [Fact]
    public void Defaults_AreDisabledWithDesignTtls()
    {
        ThreadSelectionConfig config = new();

        Assert.False(config.Enabled);
        Assert.Equal(ThreadSelectionConfig.DefaultPendingTtlMs, config.PendingTtlMs);
        Assert.Equal(ThreadSelectionConfig.DefaultActiveIdleTtlMs, config.ActiveIdleTtlMs);
    }

    [Fact]
    public void PendingTtlBelowFloor_IsASecurityViolation()
    {
        RouterConfig config = BaseConfig() with
        {
            LocalRouter = BaseConfig().LocalRouter with
            {
                ThreadSelection = new ThreadSelectionConfig { PendingTtlMs = 1_000 },
            },
        };

        var error = RouterConfigValidator.Validate(config);

        Assert.NotNull(error);
        Assert.Equal("local_router.thread_selection.pending_ttl_ms", error!.Param);
    }

    [Fact]
    public void ActiveIdleTtlAboveCeiling_IsASecurityViolation()
    {
        RouterConfig config = BaseConfig() with
        {
            LocalRouter = BaseConfig().LocalRouter with
            {
                ThreadSelection = new ThreadSelectionConfig { ActiveIdleTtlMs = 999_999_999_999 },
            },
        };

        var error = RouterConfigValidator.Validate(config);

        Assert.NotNull(error);
        Assert.Equal("local_router.thread_selection.active_idle_ttl_ms", error!.Param);
    }

    [Fact]
    public void EnabledCapabilityWithDesignTtls_IsValid()
    {
        RouterConfig config = BaseConfig() with
        {
            LocalRouter = BaseConfig().LocalRouter with
            {
                ThreadSelection = new ThreadSelectionConfig { Enabled = true },
            },
        };

        Assert.Null(RouterConfigValidator.Validate(config));
    }

    private static RouterConfig BaseConfig()
        => new()
        {
            SchemaVersion = 1,
            Version = 1,
            Mode = RouterMode.Direct,
            LocalRouter = new LocalRouterConfig
            {
                Enabled = false,
                Host = "127.0.0.1",
                Port = 47821,
                ClientAuth = new ClientAuthConfig { Mode = "bearer_env_ref", TokenRef = "CODEX_LOCAL_ROUTER_TOKEN" },
                Limits = new LimitsConfig
                {
                    MaxRequestBytes = 16_777_216,
                    MaxHeaderBytes = 32_768,
                    MaxConnections = 32,
                    ShutdownGraceMs = 15_000,
                },
            },
        };
}
