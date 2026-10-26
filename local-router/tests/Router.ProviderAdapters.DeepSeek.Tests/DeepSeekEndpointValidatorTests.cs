using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

public sealed class DeepSeekEndpointValidatorTests
{
    [Fact]
    public void Official_production_endpoint_is_accepted()
    {
        Result<UpstreamEndpoint, RouterError> result = DeepSeekEndpointValidator.Validate(
            new Uri("https://api.deepseek.com"));

        Assert.True(result.IsSuccess);
        Assert.True(result.Value!.TlsRequired);
        Assert.False(result.Value.LoopbackTestOnly);
    }

    [Fact]
    public void Standard_trailing_slash_is_accepted()
    {
        Assert.True(DeepSeekEndpointValidator.Validate(new Uri("https://api.deepseek.com/")).IsSuccess);
    }

    [Fact]
    public void Approved_production_host_matches_exactly()
    {
        Assert.True(DeepSeekEndpointValidator.IsAllowedProductionHost("api.deepseek.com"));
        Assert.False(DeepSeekEndpointValidator.IsAllowedProductionHost("api.deepseek.com.evil.example"));
        Assert.False(DeepSeekEndpointValidator.IsAllowedProductionHost("deepseek.com"));
        Assert.False(DeepSeekEndpointValidator.IsAllowedProductionHost("api.deepseek.com.cn"));
        Assert.False(DeepSeekEndpointValidator.IsAllowedProductionHost("evilapi.deepseek.com"));
        Assert.False(DeepSeekEndpointValidator.IsAllowedProductionHost("{region}.deepseek.com"));
        Assert.False(DeepSeekEndpointValidator.IsAllowedProductionHost("localhost"));
        Assert.False(DeepSeekEndpointValidator.IsAllowedProductionHost("127.0.0.1"));
        Assert.False(DeepSeekEndpointValidator.IsAllowedProductionHost("example.com"));
    }

    [Fact]
    public void Suffix_and_subdomain_lookalikes_are_rejected()
    {
        Assert.False(DeepSeekEndpointValidator.Validate(
            new Uri("https://api.deepseek.com.evil.example")).IsSuccess);
        Assert.False(DeepSeekEndpointValidator.Validate(
            new Uri("https://evilapi.deepseek.com")).IsSuccess);
    }

    [Fact]
    public void Http_non_loopback_is_rejected_with_tls_required()
    {
        Result<UpstreamEndpoint, RouterError> result = DeepSeekEndpointValidator.Validate(
            new Uri("http://api.deepseek.com"));

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.TlsRequired, result.Error!.Code);
    }

    [Fact]
    public void Loopback_http_is_accepted_only_inside_the_test_boundary()
    {
        var loopback = new Uri("http://127.0.0.1:47822/");

        Assert.False(DeepSeekEndpointValidator.Validate(loopback).IsSuccess);
        Result<UpstreamEndpoint, RouterError> accepted = DeepSeekEndpointValidator.Validate(loopback, loopbackTestOnly: true);
        Assert.True(accepted.IsSuccess);
        Assert.True(accepted.Value!.LoopbackTestOnly);
    }

    [Fact]
    public void Non_root_base_path_is_rejected()
    {
        // The adapter composes /responses itself, so a base URL that already
        // carries a path (including /responses) would double the route.
        Assert.False(DeepSeekEndpointValidator.Validate(
            new Uri("https://api.deepseek.com/v1")).IsSuccess);
        Assert.False(DeepSeekEndpointValidator.Validate(
            new Uri("https://api.deepseek.com/responses")).IsSuccess);
        Assert.False(DeepSeekEndpointValidator.Validate(
            new Uri("https://api.deepseek.com/v1/responses")).IsSuccess);
        Assert.False(DeepSeekEndpointValidator.Validate(
            new Uri("https://api.deepseek.com/v1/chat/completions")).IsSuccess);
    }

    [Fact]
    public void Query_fragment_and_userinfo_are_rejected()
    {
        Assert.False(DeepSeekEndpointValidator.Validate(
            new Uri("https://api.deepseek.com?project=1")).IsSuccess);
        Assert.False(DeepSeekEndpointValidator.Validate(
            new Uri("https://api.deepseek.com#frag")).IsSuccess);
        Assert.False(DeepSeekEndpointValidator.Validate(
            new Uri("https://user@api.deepseek.com")).IsSuccess);
    }

    [Fact]
    public void Non_default_port_is_rejected()
    {
        Assert.False(DeepSeekEndpointValidator.Validate(
            new Uri("https://api.deepseek.com:8443")).IsSuccess);
    }

    [Fact]
    public void Unsupported_scheme_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> result = DeepSeekEndpointValidator.Validate(
            new Uri("ftp://api.deepseek.com"));

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.TlsRequired, result.Error!.Code);
    }

    [Fact]
    public void Final_endpoint_is_exactly_the_official_responses_url()
    {
        Result<UpstreamEndpoint, RouterError> created = DeepSeekEndpointValidator.Validate(
            new Uri("https://api.deepseek.com"));

        Assert.True(created.IsSuccess);
        UpstreamRequest request = UpstreamRequest.Create(
            "POST",
            created.Value!,
            DeepSeekCapabilities.UpstreamPath);

        Assert.Equal("https://api.deepseek.com/responses", request.FullUri.AbsoluteUri);
    }

    [Fact]
    public void Redirect_to_another_origin_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> created = DeepSeekEndpointValidator.Validate(
            new Uri("https://api.deepseek.com"));

        Assert.True(created.IsSuccess);
        Assert.False(created.Value!.AllowsRedirect(new Uri("https://attacker.example.com/responses")));
        Assert.False(created.Value!.AllowsRedirect(new Uri("http://api.deepseek.com/responses")));
        Assert.True(created.Value!.AllowsRedirect(new Uri("https://api.deepseek.com/responses")));
    }
}
