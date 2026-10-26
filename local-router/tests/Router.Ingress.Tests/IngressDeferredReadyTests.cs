using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using Router.Core.Lifecycle;
using Router.Ingress.Tests.Support;
using Xunit;

namespace Router.Ingress.Tests;

/// <summary>
/// Reliability Fix 2A: a bound listener is not READY. The ingress can start in
/// a deferred mode where the public lifecycle stays STARTING until the caller
/// publishes READY, and the same one state is what /health, /v1/router/status
/// and the control-plane status report. Standalone/component callers keep the
/// historical immediate-READY behaviour, and a deferred ingress can still be
/// stopped through the normal STOPPING path without ever reaching READY.
/// </summary>
public sealed class IngressDeferredReadyTests
{
    [Fact]
    public async Task Deferred_ingress_reports_starting_until_ready_is_published()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync(
            options => options.DeferReadyPublication = true);

        Assert.Equal(LifecycleState.Starting, server.Ingress.LifecycleState);

        using HttpResponseMessage notReady = await server.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/health"));
        Assert.Equal(HttpStatusCode.ServiceUnavailable, notReady.StatusCode);
        using JsonDocument notReadyBody = JsonDocument.Parse(await server.GetBodyAsync(notReady));
        Assert.Equal(1, notReadyBody.RootElement.GetProperty("schema_version").GetInt32());
        Assert.Equal("STARTING", notReadyBody.RootElement.GetProperty("lifecycle").GetString());
        Assert.False(notReadyBody.RootElement.GetProperty("ready").GetBoolean());
        Assert.Equal(3, notReadyBody.RootElement.EnumerateObject().Count());

        using HttpResponseMessage statusBeforeReady = await server.SendAsync(
            new HttpRequestMessage(HttpMethod.Get, "/v1/router/status"));
        using JsonDocument statusBeforeBody = JsonDocument.Parse(await server.GetBodyAsync(statusBeforeReady));
        Assert.Equal("STARTING", statusBeforeBody.RootElement.GetProperty("lifecycle").GetString());
        Assert.False(statusBeforeBody.RootElement.GetProperty("ready").GetBoolean());

        Assert.True(server.PublishReady());
        Assert.Equal(LifecycleState.Ready, server.Ingress.LifecycleState);

        using HttpResponseMessage ready = await server.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/health"));
        Assert.Equal(HttpStatusCode.OK, ready.StatusCode);
        using JsonDocument readyBody = JsonDocument.Parse(await server.GetBodyAsync(ready));
        Assert.Equal("READY", readyBody.RootElement.GetProperty("lifecycle").GetString());
        Assert.True(readyBody.RootElement.GetProperty("ready").GetBoolean());

        using HttpResponseMessage statusAfterReady = await server.SendAsync(
            new HttpRequestMessage(HttpMethod.Get, "/v1/router/status"));
        using JsonDocument statusAfterBody = JsonDocument.Parse(await server.GetBodyAsync(statusAfterReady));
        Assert.Equal("READY", statusAfterBody.RootElement.GetProperty("lifecycle").GetString());
        Assert.True(statusAfterBody.RootElement.GetProperty("ready").GetBoolean());

        // READY is published once: the publication only ever performs the legal
        // STARTING -> READY transition, so a repeat call cannot claim success.
        Assert.False(server.PublishReady());
        Assert.Equal(LifecycleState.Ready, server.Ingress.LifecycleState);
    }

    [Fact]
    public async Task Deferred_ingress_can_stop_without_ever_reaching_ready()
    {
        IngressTestServer server = await IngressTestServer.StartAsync(
            options => options.DeferReadyPublication = true);
        int port = server.BaseUri.Port;
        try
        {
            Assert.Equal(LifecycleState.Starting, server.Ingress.LifecycleState);

            await server.Ingress.StopAsync(CancellationToken.None);

            Assert.Equal(LifecycleState.Stopped, server.Ingress.LifecycleState);
            Assert.False(IsPortListening(port), "the listener must be released after a startup stop");

            // A stopped ingress can never be resurrected into READY.
            Assert.False(server.PublishReady());
            Assert.Equal(LifecycleState.Stopped, server.Ingress.LifecycleState);
        }
        finally
        {
            await server.DisposeAsync();
        }
    }

    [Fact]
    public async Task Default_ingress_start_still_publishes_ready_immediately()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync();

        Assert.Equal(LifecycleState.Ready, server.Ingress.LifecycleState);

        using HttpResponseMessage response = await server.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/health"));
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        using JsonDocument body = JsonDocument.Parse(await server.GetBodyAsync(response));
        Assert.Equal("READY", body.RootElement.GetProperty("lifecycle").GetString());
        Assert.True(body.RootElement.GetProperty("ready").GetBoolean());
    }

    private static bool IsPortListening(int port)
    {
        try
        {
            using TcpClient client = new();
            return client.ConnectAsync(IPAddress.Loopback, port).Wait(TimeSpan.FromMilliseconds(500));
        }
        catch (Exception)
        {
            return false;
        }
    }
}
