using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.ModelStudio;
using Xunit;

namespace Router.ProviderAdapters.ModelStudio.Tests;

public sealed class ModelStudioIdentityTests
{
    [Fact]
    public void Identity_is_exact_mm_modelstudio()
    {
        ProviderAdapterDescriptor descriptor = new ModelStudioProviderAdapter().Descriptor;

        Assert.Equal("adapter.provider.mm_modelstudio.responses.v1", descriptor.AdapterId);
        Assert.Equal("1.0", descriptor.AdapterVersion);
        Assert.Equal("mm_modelstudio", descriptor.ProviderId);
        Assert.Equal("protocol.openai.responses.v1", descriptor.ProtocolId);
        Assert.True(descriptor.Eligible);
        Assert.Contains("responses", descriptor.Capabilities.Values);
        Assert.Contains("streaming", descriptor.Capabilities.Values);
        Assert.Contains("reasoning", descriptor.Capabilities.Values);
        Assert.Contains("tools", descriptor.Capabilities.Values);
        Assert.Contains("usage", descriptor.Capabilities.Values);
    }

    [Fact]
    public void Registration_and_exact_resolution_succeed()
    {
        var adapter = new ModelStudioProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.True(registry.IsSuccess);
        AdapterResolveResult resolved = registry.Value!.Resolve(
            ModelStudioProviderAdapter.AdapterId,
            ModelStudioProviderAdapter.AdapterVersion,
            ModelStudioProviderAdapter.ProviderId,
            ModelStudioProviderAdapter.ProtocolId);

        Assert.True(resolved.IsResolved);
        Assert.Same(adapter, resolved.Adapter);
    }

    [Fact]
    public void Duplicate_registration_fails_closed()
    {
        var adapter = new ModelStudioProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.False(registry.IsSuccess);
        Assert.Equal(RouterErrorCode.AdapterRegistrationInvalid, registry.Error!.Code);
    }

    [Fact]
    public void Version_collision_fails_closed()
    {
        var adapter = new ModelStudioProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
            ProviderAdapterRegistration.Create(adapter.Descriptor with { AdapterId = adapter.Descriptor.AdapterId }, adapter),
        ]);

        Assert.False(registry.IsSuccess);
        Assert.Equal(RouterErrorCode.AdapterRegistrationInvalid, registry.Error!.Code);
    }

    [Fact]
    public void Wrong_provider_is_rejected()
    {
        var adapter = new ModelStudioProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        AdapterResolveResult resolved = registry.Value!.Resolve(
            ModelStudioProviderAdapter.AdapterId,
            ModelStudioProviderAdapter.AdapterVersion,
            "mm_mimo",
            ModelStudioProviderAdapter.ProtocolId);

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterNotFound, resolved.Error!.Code);
    }

    [Fact]
    public void Wrong_protocol_is_rejected()
    {
        var adapter = new ModelStudioProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        AdapterResolveResult resolved = registry.Value!.Resolve(
            ModelStudioProviderAdapter.AdapterId,
            ModelStudioProviderAdapter.AdapterVersion,
            ModelStudioProviderAdapter.ProviderId,
            "protocol.anthropic.messages.v1");

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterNotFound, resolved.Error!.Code);
    }

    [Fact]
    public void Model_brand_never_implies_provider_identity()
    {
        // Qwen/DeepSeek hosted through Model Studio still resolve only through
        // the exact mm_modelstudio registration; brand names prove nothing.
        var adapter = new ModelStudioProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.False(registry.Value!.Resolve(
            "adapter.provider.qwen_direct.responses.v1",
            "1.0",
            "qwen_direct",
            ModelStudioProviderAdapter.ProtocolId).IsResolved);
        Assert.False(registry.Value!.Resolve(
            "adapter.provider.deepseek_direct.responses.v1",
            "1.0",
            "deepseek_direct",
            ModelStudioProviderAdapter.ProtocolId).IsResolved);
    }
}
