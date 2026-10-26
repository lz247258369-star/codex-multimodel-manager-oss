using System.Net;
using System.Net.Sockets;
using Router.Core.Errors;
using Router.Core.Lifecycle;
using Router.Ingress.Fakes;
using Router.Ingress.Tests.Support;
using Router.Secrets;
using Xunit;

namespace Router.Ingress.Tests;

public sealed class IngressBindingTests
{
    [Fact]
    public async Task Loopback_binds_and_reports_address()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        Assert.Equal(LifecycleState.Ready, server.Ingress.LifecycleState);
        Assert.Equal("127.0.0.1", server.Ingress.ListenAddress!.Host);
        Assert.True(server.Ingress.ListenAddress.Port > 0);
    }

    [Theory]
    [InlineData("0.0.0.0")]
    [InlineData("::")]
    [InlineData("[::]")]
    [InlineData("localhost")]
    [InlineData("192.168.1.50")]
    public async Task Non_loopback_bind_targets_fail_closed(string host)
    {
        IngressRuntimeOptions options = BuildOptions(host, 47821);

        IngressStartResult result = await ResponsesIngress.StartAsync(
            options,
            new FakeResponsesService(),
            new FakeSecretResolver(),
            new Router.Core.Abstractions.SystemClock(),
            new Router.Core.Ids.UuidV7IdGenerator(new Router.Core.Abstractions.SystemClock()));

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.ConfigSecurityViolation, result.Error!.Code);
        Assert.NotNull(result.Ingress);
        Assert.Equal(LifecycleState.Failed, result.Ingress!.LifecycleState);
        Assert.Null(result.Ingress.ListenAddress);
    }

    [Fact]
    public async Task Port_conflict_fails_closed_without_silent_port_change()
    {
        int port = TestHttp.GetFreePort();
        TcpListener holder = new(IPAddress.Loopback, port);
        holder.Start();
        try
        {
            FakeSecretResolver resolver = new();
            resolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", "token");
            IngressRuntimeOptions options = BuildOptions("127.0.0.1", port);
            IngressStartResult result = await ResponsesIngress.StartAsync(
                options,
                new FakeResponsesService(),
                resolver,
                new Router.Core.Abstractions.SystemClock(),
                new Router.Core.Ids.UuidV7IdGenerator(new Router.Core.Abstractions.SystemClock()));

            Assert.False(result.IsSuccess);
            Assert.Equal(RouterErrorCode.RouterPortInUse, result.Error!.Code);
            Assert.Equal(LifecycleState.Failed, result.Ingress!.LifecycleState);
            Assert.Null(result.Ingress.ListenAddress);
        }
        finally
        {
            holder.Stop();
        }
    }

    [Fact]
    public async Task Restart_same_port_after_release_succeeds()
    {
        int port = TestHttp.GetFreePort();
        IngressRuntimeOptions options = BuildOptions("127.0.0.1", port);
        FakeSecretResolver resolver = new();
        resolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", "token");

        IngressStartResult first = await ResponsesIngress.StartAsync(
            options,
            new FakeResponsesService(),
            resolver,
            new Router.Core.Abstractions.SystemClock(),
            new Router.Core.Ids.UuidV7IdGenerator(new Router.Core.Abstractions.SystemClock()));
        Assert.True(first.IsSuccess);

        await first.Ingress!.StopAsync();
        await first.Ingress.DisposeAsync();
        Assert.Equal(LifecycleState.Stopped, first.Ingress.LifecycleState);

        IngressStartResult second = await ResponsesIngress.StartAsync(
            options,
            new FakeResponsesService(),
            resolver,
            new Router.Core.Abstractions.SystemClock(),
            new Router.Core.Ids.UuidV7IdGenerator(new Router.Core.Abstractions.SystemClock()));

        Assert.True(second.IsSuccess);
        Assert.Equal(port, second.Ingress!.ListenAddress!.Port);
        await second.Ingress.DisposeAsync();
    }

    [Fact]
    public async Task Missing_token_fails_closed_without_binding()
    {
        IngressRuntimeOptions options = BuildOptions("127.0.0.1", TestHttp.GetFreePort());
        FakeSecretResolver resolver = new(); // no token configured

        IngressStartResult result = await ResponsesIngress.StartAsync(
            options,
            new FakeResponsesService(),
            resolver,
            new Router.Core.Abstractions.SystemClock(),
            new Router.Core.Ids.UuidV7IdGenerator(new Router.Core.Abstractions.SystemClock()));

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.SecretMissing, result.Error!.Code);
        Assert.Equal(LifecycleState.Failed, result.Ingress!.LifecycleState);
        Assert.Null(result.Ingress.ListenAddress);
    }

    private static IngressRuntimeOptions BuildOptions(string host, int port)
        => new()
        {
            Host = host,
            Port = port,
            Limits = new Router.Configuration.LimitsConfig
            {
                MaxRequestBytes = 16_777_216,
                MaxHeaderBytes = 32_768,
                MaxConnections = 32,
                ShutdownGraceMs = 15_000,
            },
            ConfigGeneration = new string('a', 64),
            TokenReferenceName = "CODEX_LOCAL_ROUTER_TOKEN",
            Clients = IngressTestServer.DefaultClients,
        };
}
