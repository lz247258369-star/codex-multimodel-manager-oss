using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.OpenAI;
using Xunit;

namespace Router.ProviderAdapters.OpenAI.Tests;

public sealed class OpenAIIdentityTests
{
    [Fact]
    public void Identity_is_exact_mm_openai_api()
    {
        ProviderAdapterDescriptor descriptor = new OpenAIProviderAdapter().Descriptor;

        Assert.Equal("adapter.provider.mm_openai_api.responses.v1", descriptor.AdapterId);
        Assert.Equal("1.0", descriptor.AdapterVersion);
        Assert.Equal("mm_openai_api", descriptor.ProviderId);
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
        var adapter = new OpenAIProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.True(registry.IsSuccess);
        AdapterResolveResult resolved = registry.Value!.Resolve(
            OpenAIProviderAdapter.AdapterId,
            OpenAIProviderAdapter.AdapterVersion,
            OpenAIProviderAdapter.ProviderId,
            OpenAIProviderAdapter.ProtocolId);

        Assert.True(resolved.IsResolved);
        Assert.Same(adapter, resolved.Adapter);
    }

    [Fact]
    public void Duplicate_registration_fails_closed()
    {
        var adapter = new OpenAIProviderAdapter();
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
        var adapter = new OpenAIProviderAdapter();
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
        var adapter = new OpenAIProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        AdapterResolveResult resolved = registry.Value!.Resolve(
            OpenAIProviderAdapter.AdapterId,
            OpenAIProviderAdapter.AdapterVersion,
            "mm_modelstudio",
            OpenAIProviderAdapter.ProtocolId);

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterNotFound, resolved.Error!.Code);
    }

    [Fact]
    public void Wrong_protocol_is_rejected()
    {
        var adapter = new OpenAIProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        AdapterResolveResult resolved = registry.Value!.Resolve(
            OpenAIProviderAdapter.AdapterId,
            OpenAIProviderAdapter.AdapterVersion,
            OpenAIProviderAdapter.ProviderId,
            "protocol.anthropic.messages.v1");

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterNotFound, resolved.Error!.Code);
    }

    [Fact]
    public void ChatGPT_account_identity_never_resolves_the_openai_api_adapter()
    {
        var adapter = new OpenAIProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        AdapterResolveResult resolved = registry.Value!.Resolve(
            OpenAIProviderAdapter.AdapterId,
            OpenAIProviderAdapter.AdapterVersion,
            "chatgpt",
            OpenAIProviderAdapter.ProtocolId);

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterNotFound, resolved.Error!.Code);
    }

    [Fact]
    public void ChatGPT_provider_stays_direct_only_in_the_built_in_table()
    {
        Router.Registries.ProviderDescriptor chatgpt = Router.Registries.BuiltInProviders.All["chatgpt"];

        Assert.Equal(Router.Registries.ProviderAvailability.DirectOnly, chatgpt.Availability);
        Assert.Equal("adapter.provider.chatgpt.responses.v1", chatgpt.AdapterId);
        Assert.NotEqual(OpenAIProviderAdapter.AdapterId, chatgpt.AdapterId);
        Assert.False(chatgpt.HasEligibleAdapter);
        Assert.False(chatgpt.IsUsable);
    }

    [Fact]
    public void Model_brand_never_implies_provider_identity()
    {
        // GPT-style model names never resolve through another provider, and
        // the OpenAI API adapter is only reachable through its exact identity.
        var adapter = new OpenAIProviderAdapter();
        Result<ProviderAdapterRegistry, RouterError> registry = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.False(registry.Value!.Resolve(
            "adapter.provider.chatgpt.responses.v1",
            "1.0",
            "chatgpt",
            OpenAIProviderAdapter.ProtocolId).IsResolved);
        Assert.False(registry.Value!.Resolve(
            "adapter.provider.mm_openrouter.responses.v1",
            "1.0",
            "mm_openrouter",
            OpenAIProviderAdapter.ProtocolId).IsResolved);
    }
}
