using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.ModelStudio;
using Xunit;

namespace Router.ProviderAdapters.ModelStudio.Tests;

public sealed class ModelStudioEndpointValidatorTests
{
    [Fact]
    public void Workspace_https_endpoint_is_accepted()
    {
        Result<UpstreamEndpoint, RouterError> result = ModelStudioEndpointValidator.Validate(
            new Uri("https://ws-123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"));

        Assert.True(result.IsSuccess);
        Assert.True(result.Value!.TlsRequired);
        Assert.False(result.Value.LoopbackTestOnly);
    }

    [Fact]
    public void Token_plan_host_is_accepted()
    {
        Assert.True(ModelStudioEndpointValidator.Validate(
            new Uri("https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")).IsSuccess);
    }

    [Fact]
    public void DashScope_public_host_is_accepted()
    {
        Assert.True(ModelStudioEndpointValidator.Validate(
            new Uri("https://dashscope.aliyuncs.com/compatible-mode/v1")).IsSuccess);
    }

    [Fact]
    public void Http_non_loopback_is_rejected_with_tls_required()
    {
        Result<UpstreamEndpoint, RouterError> result = ModelStudioEndpointValidator.Validate(
            new Uri("http://ws-123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"));

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.TlsRequired, result.Error!.Code);
    }

    [Fact]
    public void Loopback_http_is_accepted_only_inside_the_test_boundary()
    {
        var loopback = new Uri("http://127.0.0.1:47822/compatible-mode/v1");

        Assert.False(ModelStudioEndpointValidator.Validate(loopback).IsSuccess);
        Result<UpstreamEndpoint, RouterError> accepted = ModelStudioEndpointValidator.Validate(loopback, loopbackTestOnly: true);
        Assert.True(accepted.IsSuccess);
        Assert.True(accepted.Value!.LoopbackTestOnly);
    }

    [Fact]
    public void Arbitrary_host_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> result = ModelStudioEndpointValidator.Validate(
            new Uri("https://not-a-workspace-host.example.com/compatible-mode/v1"));

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.InvalidEndpointReference, result.Error!.Code);
    }

    [Fact]
    public void Unresolved_workspace_template_is_rejected()
    {
        Assert.False(ModelStudioEndpointValidator.IsAllowedProductionHost("{WorkspaceId}.cn-beijing.maas.aliyuncs.com"));
        Assert.False(ModelStudioEndpointValidator.IsWorkspaceHost("{WorkspaceId}.cn-beijing.maas.aliyuncs.com"));
    }

    [Fact]
    public void Invalid_workspace_identifier_is_rejected()
    {
        Assert.False(ModelStudioEndpointValidator.IsWorkspaceHost("My_Workspace.cn-beijing.maas.aliyuncs.com"));
        Assert.False(ModelStudioEndpointValidator.IsWorkspaceHost("UPPER.cn-beijing.maas.aliyuncs.com"));
        Assert.False(ModelStudioEndpointValidator.IsWorkspaceHost("a..b.cn-beijing.maas.aliyuncs.com"));
    }

    [Fact]
    public void Chat_only_path_is_rejected()
    {
        Assert.False(ModelStudioEndpointValidator.Validate(
            new Uri("https://ws-1.cn-beijing.maas.aliyuncs.com/v1/chat/completions")).IsSuccess);
        Assert.False(ModelStudioEndpointValidator.Validate(
            new Uri("https://ws-1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")).IsSuccess);
        Assert.False(ModelStudioEndpointValidator.Validate(
            new Uri("https://ws-1.cn-beijing.maas.aliyuncs.com/")).IsSuccess);
    }

    [Fact]
    public void Query_fragment_and_userinfo_are_rejected()
    {
        Assert.False(ModelStudioEndpointValidator.Validate(
            new Uri("https://ws-1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1?workspace=1")).IsSuccess);
        Assert.False(ModelStudioEndpointValidator.Validate(
            new Uri("https://ws-1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1#frag")).IsSuccess);
        Assert.False(ModelStudioEndpointValidator.Validate(
            new Uri("https://user@ws-1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")).IsSuccess);
    }

    [Fact]
    public void Non_default_port_is_rejected()
    {
        Assert.False(ModelStudioEndpointValidator.Validate(
            new Uri("https://ws-1.cn-beijing.maas.aliyuncs.com:8443/compatible-mode/v1")).IsSuccess);
    }

    [Fact]
    public void Redirect_to_another_origin_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> created = ModelStudioEndpointValidator.Validate(
            new Uri("https://ws-1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"));

        Assert.True(created.IsSuccess);
        Assert.False(created.Value!.AllowsRedirect(new Uri("https://attacker.example.com/compatible-mode/v1")));
    }

    [Fact]
    public void Https_to_http_downgrade_redirect_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> created = ModelStudioEndpointValidator.Validate(
            new Uri("https://ws-1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"));

        Assert.True(created.IsSuccess);
        Assert.False(created.Value!.AllowsRedirect(new Uri("http://ws-1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")));
    }

    [Fact]
    public void Same_origin_redirect_is_allowed()
    {
        Result<UpstreamEndpoint, RouterError> created = ModelStudioEndpointValidator.Validate(
            new Uri("https://ws-1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"));

        Assert.True(created.IsSuccess);
        Assert.True(created.Value!.AllowsRedirect(new Uri("https://ws-1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/responses")));
    }
}
