using Router.Configuration;
using Router.Core.Errors;
using Router.Ingress.Tests.Support;
using Router.Secrets;
using Xunit;

namespace Router.Ingress.Tests;

public sealed class IngressUnitTests
{
    [Fact]
    public void Output_checkpoint_is_one_way()
    {
        OutputCheckpoint checkpoint = new();

        Assert.Equal(OutputCheckpointState.NoOutputEmitted, checkpoint.State);
        Assert.True(checkpoint.TryMarkOutputStarted());
        Assert.Equal(OutputCheckpointState.OutputStarted, checkpoint.State);
        Assert.False(checkpoint.TryMarkOutputStarted());
        Assert.Equal(OutputCheckpointState.OutputStarted, checkpoint.State);
    }

    [Fact]
    public void Connection_limiter_is_bounded_and_releases()
    {
        ConnectionLimiter limiter = new(2);

        Assert.True(limiter.TryEnter());
        Assert.True(limiter.TryEnter());
        Assert.False(limiter.TryEnter());
        Assert.Equal(2, limiter.InFlightCount);

        limiter.Exit();
        Assert.True(limiter.TryEnter());
        limiter.Exit();
        limiter.Exit();
        Assert.Equal(0, limiter.InFlightCount);
    }

    [Theory]
    [InlineData("0.0.0.0")]
    [InlineData("::")]
    [InlineData("[::]")]
    [InlineData("localhost")]
    [InlineData("192.168.1.50")]
    [InlineData("127.0.0.2")]
    [InlineData("example.com")]
    public void Loopback_bind_policy_rejects_non_loopback_hosts(string host)
    {
        RouterError? error = LoopbackBindPolicy.Validate(host, 47821);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.ConfigSecurityViolation, error!.Code);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(65_536)]
    [InlineData(-1)]
    public void Loopback_bind_policy_rejects_invalid_ports(int port)
    {
        RouterError? error = LoopbackBindPolicy.Validate("127.0.0.1", port);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.ConfigSecurityViolation, error!.Code);
    }

    [Fact]
    public void Loopback_bind_policy_accepts_loopback_contract()
    {
        Assert.Null(LoopbackBindPolicy.Validate("127.0.0.1", 47821));
    }

    [Fact]
    public async Task Token_authenticator_matches_only_exact_token()
    {
        FakeSecretResolver resolver = new();
        resolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", "secret-token");
        TokenAuthenticator authenticator = new(resolver, LocalRouterSecrets.CreateTokenReference("CODEX_LOCAL_ROUTER_TOKEN"));

        Assert.True((await authenticator.ValidateAsync("Bearer secret-token", CancellationToken.None)).IsSuccess);
        Assert.False((await authenticator.ValidateAsync("Bearer wrong", CancellationToken.None)).IsSuccess);
        Assert.False((await authenticator.ValidateAsync("Bearer ", CancellationToken.None)).IsSuccess);
        Assert.False((await authenticator.ValidateAsync(null, CancellationToken.None)).IsSuccess);
        Assert.False((await authenticator.ValidateAsync("Basic abc", CancellationToken.None)).IsSuccess);
    }

    [Fact]
    public async Task Token_failure_never_reveals_length_or_prefix()
    {
        FakeSecretResolver resolver = new();
        resolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", "secret-token");
        TokenAuthenticator authenticator = new(resolver, LocalRouterSecrets.CreateTokenReference("CODEX_LOCAL_ROUTER_TOKEN"));

        TokenAuthenticationResult shortWrong = await authenticator.ValidateAsync("Bearer x", CancellationToken.None);
        TokenAuthenticationResult longWrong = await authenticator.ValidateAsync("Bearer " + new string('z', 200), CancellationToken.None);

        Assert.Equal(RouterErrorCode.AuthenticationInvalid, shortWrong.Error!.Code);
        Assert.Equal(RouterErrorCode.AuthenticationInvalid, longWrong.Error!.Code);
        Assert.Equal(shortWrong.Error.Message, longWrong.Error.Message);
        Assert.Null(shortWrong.Error.Param);
    }

    [Fact]
    public void Max_request_bytes_ceiling_never_exceeds_config_ceiling()
    {
        LimitsConfig limits = new()
        {
            MaxRequestBytes = 1_000_000_000,
            MaxHeaderBytes = 1_000_000_000,
            MaxConnections = 100_000,
            ShutdownGraceMs = 1_000_000,
        };

        Assert.Equal(ConfigLimitCeilings.MaxRequestBytesCeiling, Math.Min(limits.MaxRequestBytes, ConfigLimitCeilings.MaxRequestBytesCeiling));
        Assert.Equal(ConfigLimitCeilings.MaxHeaderBytesCeiling, Math.Min(limits.MaxHeaderBytes, ConfigLimitCeilings.MaxHeaderBytesCeiling));
        Assert.Equal(ConfigLimitCeilings.MaxConnectionsCeiling, Math.Min(limits.MaxConnections, ConfigLimitCeilings.MaxConnectionsCeiling));
    }
}
