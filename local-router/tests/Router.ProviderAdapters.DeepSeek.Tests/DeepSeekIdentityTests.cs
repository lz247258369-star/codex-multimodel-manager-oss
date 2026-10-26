using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

public sealed class DeepSeekIdentityTests
{
    [Fact]
    public void Identity_is_exact_deepseek()
    {
        ProviderAdapterDescriptor descriptor = new DeepSeekProviderAdapter().Descriptor;

        Assert.Equal("adapter.provider.deepseek.responses.v1", descriptor.AdapterId);
        Assert.Equal("1.0", descriptor.AdapterVersion);
        Assert.Equal("deepseek", descriptor.ProviderId);
        Assert.Equal("protocol.openai.responses.v1", descriptor.ProtocolId);
        Assert.True(descriptor.Eligible);
        Assert.Contains("responses", descriptor.Capabilities.Values);
        Assert.Contains("text", descriptor.Capabilities.Values);
        Assert.Contains("streaming", descriptor.Capabilities.Values);
        Assert.Contains("reasoning", descriptor.Capabilities.Values);
        Assert.Contains("tools", descriptor.Capabilities.Values);
        Assert.Contains("usage", descriptor.Capabilities.Values);
        Assert.Contains("cancellation", descriptor.Capabilities.Values);
    }

    [Fact]
    public void Capability_table_is_the_declared_offline_contract()
    {
        Assert.Equal("/responses", DeepSeekCapabilities.UpstreamPath);
        Assert.Equal("provider-config:deepseek.base_url", DeepSeekCapabilities.BaseUrlReference);
        Assert.Equal(
            ["Authorization", "Content-Type", "Accept"],
            DeepSeekCapabilities.RequestHeaderAllowlist);
        Assert.DoesNotContain(
            DeepSeekCapabilities.SupportedRequestSemantics.Values,
            value => value.Contains("image", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Registration_and_exact_resolution_succeed()
    {
        var adapter = new DeepSeekProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.True(registry.IsSuccess);
        AdapterResolveResult resolved = registry.Value!.Resolve(
            DeepSeekProviderAdapter.AdapterId,
            DeepSeekProviderAdapter.AdapterVersion,
            DeepSeekProviderAdapter.ProviderId,
            DeepSeekProviderAdapter.ProtocolId);

        Assert.True(resolved.IsResolved);
        Assert.Same(adapter, resolved.Adapter);
    }

    [Fact]
    public void Duplicate_registration_fails_closed()
    {
        var adapter = new DeepSeekProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.False(registry.IsSuccess);
        Assert.Equal(RouterErrorCode.AdapterRegistrationInvalid, registry.Error!.Code);
    }

    [Fact]
    public void Wrong_provider_is_rejected()
    {
        var adapter = new DeepSeekProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        AdapterResolveResult resolved = registry.Value!.Resolve(
            DeepSeekProviderAdapter.AdapterId,
            DeepSeekProviderAdapter.AdapterVersion,
            "mm_modelstudio",
            DeepSeekProviderAdapter.ProtocolId);

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterNotFound, resolved.Error!.Code);
    }

    [Fact]
    public void Unsupported_protocol_is_rejected()
    {
        var adapter = new DeepSeekProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        AdapterResolveResult resolved = registry.Value!.Resolve(
            DeepSeekProviderAdapter.AdapterId,
            DeepSeekProviderAdapter.AdapterVersion,
            DeepSeekProviderAdapter.ProviderId,
            "protocol.anthropic.messages.v1");

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterNotFound, resolved.Error!.Code);
    }

    [Theory]
    [InlineData("mm_deepseek", "adapter.provider.mm_deepseek.responses.v1")]
    [InlineData("deepseek_direct", "adapter.provider.deepseek_direct.responses.v1")]
    [InlineData("deepseek_official", "adapter.provider.deepseek_official.responses.v1")]
    [InlineData("mm_deepseek_api", "adapter.provider.mm_deepseek_api.responses.v1")]
    public void No_alias_provider_identity_can_resolve_the_deepseek_adapter(string providerId, string adapterId)
    {
        var adapter = new DeepSeekProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.False(registry.Value!.Resolve(
            adapterId,
            "1.0",
            providerId,
            DeepSeekProviderAdapter.ProtocolId).IsResolved);
    }
}
