using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Xunit;

namespace Router.ProviderAdapters.Tests;

public sealed class UpstreamEndpointSecurityTests
{
    [Fact]
    public void Https_endpoint_is_allowed()
    {
        Result<UpstreamEndpoint, RouterError> created = UpstreamEndpoint.Create(new Uri("https://api.example.com/v1"));

        Assert.True(created.IsSuccess);
        Assert.True(created.Value!.TlsRequired);
        Assert.False(created.Value.LoopbackTestOnly);
    }

    [Fact]
    public void Http_non_loopback_is_rejected_even_for_tests()
    {
        Result<UpstreamEndpoint, RouterError> created = UpstreamEndpoint.Create(
            new Uri("http://provider.example.invalid/v1"),
            tlsRequired: false,
            loopbackTestOnly: true);

        Assert.False(created.IsSuccess);
        Assert.Equal(RouterErrorCode.TlsRequired, created.Error!.Code);
    }

    [Fact]
    public void Loopback_http_is_allowed_only_with_test_flag()
    {
        var uri = new Uri("http://127.0.0.1:52311/v1");

        Assert.False(UpstreamEndpoint.Create(uri, tlsRequired: false, loopbackTestOnly: false).IsSuccess);
        Assert.True(UpstreamEndpoint.Create(uri, tlsRequired: false, loopbackTestOnly: true).IsSuccess);
    }

    [Fact]
    public void Scheme_downgrade_redirect_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> created = UpstreamEndpoint.Create(new Uri("https://127.0.0.1:443/v1"));

        Assert.True(created.IsSuccess);
        Assert.False(created.Value!.AllowsRedirect(new Uri("http://127.0.0.1:443/v2")));
    }

    [Fact]
    public void Cross_origin_redirect_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> created = UpstreamEndpoint.Create(new Uri("https://api.example.com/v1"));

        Assert.True(created.IsSuccess);
        Assert.False(created.Value!.AllowsRedirect(new Uri("https://other.example.com/v2")));
        Assert.False(created.Value.AllowsRedirect(new Uri("https://api.example.com:8443/v2")));
    }

    [Fact]
    public void Same_origin_redirect_is_allowed()
    {
        Result<UpstreamEndpoint, RouterError> created = UpstreamEndpoint.Create(new Uri("https://api.example.com/v1"));

        Assert.True(created.IsSuccess);
        Assert.True(created.Value!.AllowsRedirect(new Uri("https://api.example.com/v2")));
    }

    [Fact]
    public void Redirect_none_policy_rejects_everything()
    {
        Result<UpstreamEndpoint, RouterError> created = UpstreamEndpoint.Create(
            new Uri("https://api.example.com/v1"),
            redirectPolicy: RedirectPolicy.None);

        Assert.True(created.IsSuccess);
        Assert.False(created.Value!.AllowsRedirect(new Uri("https://api.example.com/v2")));
    }

    [Fact]
    public void Endpoint_with_query_or_fragment_is_rejected()
    {
        Assert.False(UpstreamEndpoint.Create(new Uri("https://api.example.com/v1?key=value")).IsSuccess);
        Assert.False(UpstreamEndpoint.Create(new Uri("https://api.example.com/v1#frag")).IsSuccess);
    }
}
