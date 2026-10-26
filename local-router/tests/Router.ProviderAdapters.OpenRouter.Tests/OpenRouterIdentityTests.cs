using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.OpenRouter;
using Xunit;

namespace Router.ProviderAdapters.OpenRouter.Tests;

public sealed class OpenRouterIdentityTests
{
    [Fact]
    public void Identity_is_exact_mm_openrouter()
    {
        ProviderAdapterDescriptor descriptor = new OpenRouterProviderAdapter().Descriptor;

        Assert.Equal("adapter.provider.mm_openrouter.responses.v1", descriptor.AdapterId);
        Assert.Equal("1.0", descriptor.AdapterVersion);
        Assert.Equal("mm_openrouter", descriptor.ProviderId);
        Assert.Equal("protocol.openai.responses.v1", descriptor.ProtocolId);
        Assert.True(descriptor.Eligible);
        Assert.Contains("streaming", descriptor.Capabilities.Values);
        Assert.Contains("tools", descriptor.Capabilities.Values);
        Assert.Contains("usage", descriptor.Capabilities.Values);
    }

    [Fact]
    public void Registration_and_exact_resolution_succeed()
    {
        var adapter = new OpenRouterProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.True(registry.IsSuccess);
        AdapterResolveResult resolved = registry.Value!.Resolve(
            OpenRouterProviderAdapter.AdapterId,
            OpenRouterProviderAdapter.AdapterVersion,
            OpenRouterProviderAdapter.ProviderId,
            OpenRouterProviderAdapter.ProtocolId);

        Assert.True(resolved.IsResolved);
        Assert.Same(adapter, resolved.Adapter);
    }

    [Fact]
    public void Duplicate_registration_fails_closed()
    {
        var adapter = new OpenRouterProviderAdapter();
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
        var adapter = new OpenRouterProviderAdapter();
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
        var adapter = new OpenRouterProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        AdapterResolveResult resolved = registry.Value!.Resolve(
            OpenRouterProviderAdapter.AdapterId,
            OpenRouterProviderAdapter.AdapterVersion,
            "mm_mimo",
            OpenRouterProviderAdapter.ProtocolId);

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterNotFound, resolved.Error!.Code);
    }

    [Fact]
    public void Wrong_protocol_is_rejected()
    {
        var adapter = new OpenRouterProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        AdapterResolveResult resolved = registry.Value!.Resolve(
            OpenRouterProviderAdapter.AdapterId,
            OpenRouterProviderAdapter.AdapterVersion,
            OpenRouterProviderAdapter.ProviderId,
            "protocol.anthropic.messages.v1");

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterNotFound, resolved.Error!.Code);
    }
}
