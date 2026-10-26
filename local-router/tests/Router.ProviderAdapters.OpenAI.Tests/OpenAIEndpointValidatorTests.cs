using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.OpenAI;
using Xunit;

namespace Router.ProviderAdapters.OpenAI.Tests;

public sealed class OpenAIEndpointValidatorTests
{
    [Fact]
    public void Approved_production_endpoint_is_accepted()
    {
        Result<UpstreamEndpoint, RouterError> result = OpenAIEndpointValidator.Validate(
            new Uri("https://api.openai.com/v1"));

        Assert.True(result.IsSuccess);
        Assert.True(result.Value!.TlsRequired);
        Assert.False(result.Value.LoopbackTestOnly);
    }

    [Fact]
    public void Approved_production_host_matches_exactly()
    {
        Assert.True(OpenAIEndpointValidator.IsAllowedProductionHost("api.openai.com"));
        Assert.False(OpenAIEndpointValidator.IsAllowedProductionHost("not-openai.example.com"));
        Assert.False(OpenAIEndpointValidator.IsAllowedProductionHost("chatgpt.com"));
        Assert.False(OpenAIEndpointValidator.IsAllowedProductionHost("api.chatgpt.com"));
    }

    [Fact]
    public void Http_non_loopback_is_rejected_with_tls_required()
    {
        Result<UpstreamEndpoint, RouterError> result = OpenAIEndpointValidator.Validate(
            new Uri("http://api.openai.com/v1"));

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.TlsRequired, result.Error!.Code);
    }

    [Fact]
    public void Loopback_http_is_accepted_only_inside_the_test_boundary()
    {
        var loopback = new Uri("http://127.0.0.1:47822/v1");

        Assert.False(OpenAIEndpointValidator.Validate(loopback).IsSuccess);
        Result<UpstreamEndpoint, RouterError> accepted = OpenAIEndpointValidator.Validate(loopback, loopbackTestOnly: true);
        Assert.True(accepted.IsSuccess);
        Assert.True(accepted.Value!.LoopbackTestOnly);
    }

    [Fact]
    public void Arbitrary_production_host_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> result = OpenAIEndpointValidator.Validate(
            new Uri("https://attacker.example.com/v1"));

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.InvalidEndpointReference, result.Error!.Code);
    }

    [Fact]
    public void ChatGPT_account_host_is_rejected()
    {
        Assert.False(OpenAIEndpointValidator.Validate(
            new Uri("https://chat.openai.com/v1")).IsSuccess);
        Assert.False(OpenAIEndpointValidator.Validate(
            new Uri("https://auth.openai.com/v1")).IsSuccess);
    }

    [Fact]
    public void Non_v1_path_is_rejected()
    {
        Assert.False(OpenAIEndpointValidator.Validate(
            new Uri("https://api.openai.com/v2")).IsSuccess);
        Assert.False(OpenAIEndpointValidator.Validate(
            new Uri("https://api.openai.com/")).IsSuccess);
        Assert.False(OpenAIEndpointValidator.Validate(
            new Uri("https://api.openai.com")).IsSuccess);
    }

    [Fact]
    public void Chat_completions_path_is_rejected()
    {
        Assert.False(OpenAIEndpointValidator.Validate(
            new Uri("https://api.openai.com/v1/chat/completions")).IsSuccess);
        Assert.False(OpenAIEndpointValidator.Validate(
            new Uri("https://api.openai.com/v1/responses")).IsSuccess);
    }

    [Fact]
    public void Query_fragment_and_userinfo_are_rejected()
    {
        Assert.False(OpenAIEndpointValidator.Validate(
            new Uri("https://api.openai.com/v1?project=1")).IsSuccess);
        Assert.False(OpenAIEndpointValidator.Validate(
            new Uri("https://api.openai.com/v1#frag")).IsSuccess);
        Assert.False(OpenAIEndpointValidator.Validate(
            new Uri("https://user@api.openai.com/v1")).IsSuccess);
    }

    [Fact]
    public void Non_default_port_is_rejected()
    {
        Assert.False(OpenAIEndpointValidator.Validate(
            new Uri("https://api.openai.com:8443/v1")).IsSuccess);
    }

    [Fact]
    public void Unsupported_scheme_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> result = OpenAIEndpointValidator.Validate(
            new Uri("ftp://api.openai.com/v1"));

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.TlsRequired, result.Error!.Code);
    }

    [Fact]
    public void Redirect_to_another_origin_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> created = OpenAIEndpointValidator.Validate(
            new Uri("https://api.openai.com/v1"));

        Assert.True(created.IsSuccess);
        Assert.False(created.Value!.AllowsRedirect(new Uri("https://attacker.example.com/v1/responses")));
    }

    [Fact]
    public void Https_to_http_downgrade_redirect_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> created = OpenAIEndpointValidator.Validate(
            new Uri("https://api.openai.com/v1"));

        Assert.True(created.IsSuccess);
        Assert.False(created.Value!.AllowsRedirect(new Uri("http://api.openai.com/v1/responses")));
    }

    [Fact]
    public void Same_origin_redirect_is_allowed()
    {
        Result<UpstreamEndpoint, RouterError> created = OpenAIEndpointValidator.Validate(
            new Uri("https://api.openai.com/v1"));

        Assert.True(created.IsSuccess);
        Assert.True(created.Value!.AllowsRedirect(new Uri("https://api.openai.com/v1/responses")));
    }
}
