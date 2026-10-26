using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.MiMo;
using Xunit;

namespace Router.ProviderAdapters.MiMo.Tests;

public sealed class MiMoIdentityTests
{
    [Fact]
    public void Identity_is_exact_mm_mimo()
    {
        ProviderAdapterDescriptor descriptor = new MiMoProviderAdapter().Descriptor;

        Assert.Equal("adapter.provider.mm_mimo.responses.v1", descriptor.AdapterId);
        Assert.Equal("1.0", descriptor.AdapterVersion);
        Assert.Equal("mm_mimo", descriptor.ProviderId);
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
        var adapter = new MiMoProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.True(registry.IsSuccess);
        AdapterResolveResult resolved = registry.Value!.Resolve(
            MiMoProviderAdapter.AdapterId,
            MiMoProviderAdapter.AdapterVersion,
            MiMoProviderAdapter.ProviderId,
            MiMoProviderAdapter.ProtocolId);

        Assert.True(resolved.IsResolved);
        Assert.Same(adapter, resolved.Adapter);
    }

    [Fact]
    public void Duplicate_registration_fails_closed()
    {
        var adapter = new MiMoProviderAdapter();
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
        var adapter = new MiMoProviderAdapter();
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
        var adapter = new MiMoProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        AdapterResolveResult resolved = registry.Value!.Resolve(
            MiMoProviderAdapter.AdapterId,
            MiMoProviderAdapter.AdapterVersion,
            "mm_openai_api",
            MiMoProviderAdapter.ProtocolId);

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterNotFound, resolved.Error!.Code);
    }

    [Fact]
    public void Wrong_protocol_is_rejected()
    {
        var adapter = new MiMoProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        AdapterResolveResult resolved = registry.Value!.Resolve(
            MiMoProviderAdapter.AdapterId,
            MiMoProviderAdapter.AdapterVersion,
            MiMoProviderAdapter.ProviderId,
            "protocol.anthropic.messages.v1");

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterNotFound, resolved.Error!.Code);
    }

    [Theory]
    [InlineData("mimo", "adapter.provider.mimo.responses.v1")]
    [InlineData("xiaomi_mimo", "adapter.provider.xiaomi_mimo.responses.v1")]
    public void No_second_provider_identity_can_resolve_the_mimo_adapter(string providerId, string adapterId)
    {
        var adapter = new MiMoProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.False(registry.Value!.Resolve(
            adapterId,
            "1.0",
            providerId,
            MiMoProviderAdapter.ProtocolId).IsResolved);
    }
}
