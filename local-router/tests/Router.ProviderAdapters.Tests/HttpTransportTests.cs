using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.UpstreamHttp;
using Xunit;

namespace Router.ProviderAdapters.Tests;

public sealed class HttpTransportTests
{
    [Fact]
    public async Task Connect_failure_normalizes_to_connection_failed()
    {
        using var handler = new FakeConnectHandler { FailConnect = true };
        using var transport = new HttpUpstreamTransport(handler);
        Result<UpstreamEndpoint, RouterError> endpoint = UpstreamEndpoint.Create(
            new Uri("https://127.0.0.1:1/v1"),
            tlsRequired: false,
            loopbackTestOnly: true);

        UpstreamRequest request = UpstreamRequest.Create("POST", endpoint.Value!, "/v1", body: "{}"u8.ToArray(), contentType: "application/json");
        Result<UpstreamResponse, RouterError> result = await transport.SendAsync(request, TimeoutBoundaries.Default, CancellationToken.None);

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.ConnectionFailed, result.Error!.Code);
    }

    [Fact]
    public async Task User_cancellation_is_cancelled_not_connection_failed()
    {
        using var handler = new FakeConnectHandler { HangDuration = TimeSpan.FromSeconds(10) };
        using var transport = new HttpUpstreamTransport(handler);
        Result<UpstreamEndpoint, RouterError> endpoint = UpstreamEndpoint.Create(
            new Uri("https://127.0.0.1:1/v1"),
            tlsRequired: false,
            loopbackTestOnly: true);

        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));
        UpstreamRequest request = UpstreamRequest.Create("POST", endpoint.Value!, "/v1", body: "{}"u8.ToArray(), contentType: "application/json");
        Result<UpstreamResponse, RouterError> result = await transport.SendAsync(request, TimeoutBoundaries.Default, cts.Token);

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.Cancelled, result.Error!.Code);
    }

    [Fact]
    public async Task Redirect_same_origin_is_followed()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, ProviderContractKit.SseFixtureBuilder.NonStreamJson()));

        using var transport = new HttpUpstreamTransport();
        Result<UpstreamEndpoint, RouterError> endpoint = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "redirect-same"),
            tlsRequired: false,
            loopbackTestOnly: true);

        UpstreamRequest request = UpstreamRequest.Create("POST", endpoint.Value!, "", body: "{}"u8.ToArray(), contentType: "application/json");
        Result<UpstreamResponse, RouterError> result = await transport.SendAsync(request, TimeoutBoundaries.Default, CancellationToken.None);

        Assert.True(result.IsSuccess);
        Assert.Equal(200, result.Value!.StatusCode);
        result.Value.Body.Dispose();
    }

    [Fact]
    public async Task Redirect_cross_origin_is_rejected()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();

        using var transport = new HttpUpstreamTransport();
        Result<UpstreamEndpoint, RouterError> endpoint = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "redirect-cross"),
            tlsRequired: false,
            loopbackTestOnly: true);

        UpstreamRequest request = UpstreamRequest.Create("POST", endpoint.Value!, "", body: "{}"u8.ToArray(), contentType: "application/json");
        Result<UpstreamResponse, RouterError> result = await transport.SendAsync(request, TimeoutBoundaries.Default, CancellationToken.None);

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.RedirectRejected, result.Error!.Code);
    }

    [Fact]
    public async Task First_byte_timeout_is_normalized_by_transport()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(new FakeProviderScenario
        {
            StatusCode = 200,
            ContentType = "application/json",
            Body = "{}"u8.ToArray(),
            DelayBeforeFirstByte = TimeSpan.FromSeconds(2),
        });

        using var transport = new HttpUpstreamTransport();
        Result<UpstreamEndpoint, RouterError> endpoint = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "v1/responses"),
            tlsRequired: false,
            loopbackTestOnly: true);

        UpstreamRequest request = UpstreamRequest.Create("POST", endpoint.Value!, "", body: "{}"u8.ToArray(), contentType: "application/json");
        TimeoutBoundaries boundaries = TimeoutBoundaries.Create(
            connectTimeout: TimeSpan.FromSeconds(1),
            firstByteTimeout: TimeSpan.FromMilliseconds(200),
            idleTimeout: TimeSpan.FromSeconds(5),
            totalTimeout: TimeSpan.FromSeconds(10));
        Result<UpstreamResponse, RouterError> result = await transport.SendAsync(request, boundaries, CancellationToken.None);

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.TimeoutFirstByte, result.Error!.Code);
    }
}
