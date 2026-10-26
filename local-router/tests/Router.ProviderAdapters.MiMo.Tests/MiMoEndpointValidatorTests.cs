using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.MiMo;
using Xunit;

namespace Router.ProviderAdapters.MiMo.Tests;

public sealed class MiMoEndpointValidatorTests
{
    [Fact]
    public void Pay_as_you_go_production_endpoint_is_accepted()
    {
        Result<UpstreamEndpoint, RouterError> result = MiMoEndpointValidator.Validate(
            new Uri("https://api.xiaomimimo.com/v1"));

        Assert.True(result.IsSuccess);
        Assert.True(result.Value!.TlsRequired);
        Assert.False(result.Value.LoopbackTestOnly);
    }

    [Fact]
    public void Token_plan_production_endpoint_is_accepted()
    {
        Assert.True(MiMoEndpointValidator.Validate(
            new Uri("https://token-plan-cn.xiaomimimo.com/v1")).IsSuccess);
    }

    [Fact]
    public void Approved_production_hosts_match_exactly()
    {
        Assert.True(MiMoEndpointValidator.IsAllowedProductionHost("api.xiaomimimo.com"));
        Assert.True(MiMoEndpointValidator.IsAllowedProductionHost("token-plan-cn.xiaomimimo.com"));
        Assert.False(MiMoEndpointValidator.IsAllowedProductionHost("mimo.xiaomi.com"));
        Assert.False(MiMoEndpointValidator.IsAllowedProductionHost("api.mimo.example.com"));
        Assert.False(MiMoEndpointValidator.IsAllowedProductionHost("token-plan-cn.xiaomimimo.com.evil.example"));
        Assert.False(MiMoEndpointValidator.IsAllowedProductionHost("{region}.xiaomimimo.com"));
    }

    [Fact]
    public void Http_non_loopback_is_rejected_with_tls_required()
    {
        Result<UpstreamEndpoint, RouterError> result = MiMoEndpointValidator.Validate(
            new Uri("http://api.xiaomimimo.com/v1"));

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.TlsRequired, result.Error!.Code);
    }

    [Fact]
    public void Loopback_http_is_accepted_only_inside_the_test_boundary()
    {
        var loopback = new Uri("http://127.0.0.1:47822/v1");

        Assert.False(MiMoEndpointValidator.Validate(loopback).IsSuccess);
        Result<UpstreamEndpoint, RouterError> accepted = MiMoEndpointValidator.Validate(loopback, loopbackTestOnly: true);
        Assert.True(accepted.IsSuccess);
        Assert.True(accepted.Value!.LoopbackTestOnly);
    }

    [Fact]
    public void Arbitrary_production_host_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> result = MiMoEndpointValidator.Validate(
            new Uri("https://attacker.example.com/v1"));

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.InvalidEndpointReference, result.Error!.Code);
    }

    [Fact]
    public void Automatic_region_or_endpoint_selection_is_not_allowed()
    {
        Assert.False(MiMoEndpointValidator.IsAllowedProductionHost("auto.xiaomimimo.com"));
        Assert.False(MiMoEndpointValidator.IsAllowedProductionHost("cn-north.xiaomimimo.com"));
        Assert.False(MiMoEndpointValidator.IsAllowedProductionHost("api.xiaomimimo.com.cn"));
    }

    [Fact]
    public void Non_v1_base_path_is_rejected()
    {
        Assert.False(MiMoEndpointValidator.Validate(
            new Uri("https://api.xiaomimimo.com/v2")).IsSuccess);
        Assert.False(MiMoEndpointValidator.Validate(
            new Uri("https://api.xiaomimimo.com/")).IsSuccess);
        Assert.False(MiMoEndpointValidator.Validate(
            new Uri("https://api.xiaomimimo.com")).IsSuccess);
        Assert.False(MiMoEndpointValidator.Validate(
            new Uri("https://api.xiaomimimo.com/v1/responses")).IsSuccess);
    }

    [Fact]
    public void Chat_only_path_is_rejected()
    {
        Assert.False(MiMoEndpointValidator.Validate(
            new Uri("https://api.xiaomimimo.com/v1/chat/completions")).IsSuccess);
    }

    [Fact]
    public void Query_fragment_and_userinfo_are_rejected()
    {
        Assert.False(MiMoEndpointValidator.Validate(
            new Uri("https://api.xiaomimimo.com/v1?project=1")).IsSuccess);
        Assert.False(MiMoEndpointValidator.Validate(
            new Uri("https://api.xiaomimimo.com/v1#frag")).IsSuccess);
        Assert.False(MiMoEndpointValidator.Validate(
            new Uri("https://user@api.xiaomimimo.com/v1")).IsSuccess);
    }

    [Fact]
    public void Non_default_port_is_rejected()
    {
        Assert.False(MiMoEndpointValidator.Validate(
            new Uri("https://api.xiaomimimo.com:8443/v1")).IsSuccess);
    }

    [Fact]
    public void Unsupported_scheme_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> result = MiMoEndpointValidator.Validate(
            new Uri("ftp://api.xiaomimimo.com/v1"));

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.TlsRequired, result.Error!.Code);
    }

    [Fact]
    public void Redirect_to_another_origin_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> created = MiMoEndpointValidator.Validate(
            new Uri("https://api.xiaomimimo.com/v1"));

        Assert.True(created.IsSuccess);
        Assert.False(created.Value!.AllowsRedirect(new Uri("https://attacker.example.com/v1/responses")));
    }

    [Fact]
    public void Https_to_http_downgrade_redirect_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> created = MiMoEndpointValidator.Validate(
            new Uri("https://api.xiaomimimo.com/v1"));

        Assert.True(created.IsSuccess);
        Assert.False(created.Value!.AllowsRedirect(new Uri("http://api.xiaomimimo.com/v1/responses")));
    }

    [Fact]
    public void Same_origin_redirect_is_allowed()
    {
        Result<UpstreamEndpoint, RouterError> created = MiMoEndpointValidator.Validate(
            new Uri("https://api.xiaomimimo.com/v1"));

        Assert.True(created.IsSuccess);
        Assert.True(created.Value!.AllowsRedirect(new Uri("https://api.xiaomimimo.com/v1/responses")));
    }
}
