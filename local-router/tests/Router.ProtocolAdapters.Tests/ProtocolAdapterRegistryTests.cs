using Router.Core.Errors;
using Router.ProtocolAdapters.Abstractions;
using Router.ProtocolAdapters.Responses;
using Xunit;

namespace Router.ProtocolAdapters.Tests;

public sealed class ProtocolAdapterRegistryTests
{
    [Fact]
    public void Exact_resolution_is_deterministic_and_immutable()
    {
        var adapter = new ResponsesProtocolAdapter();
        Result<ProtocolAdapterRegistry, RouterError> registry = ProtocolAdapterRegistry.Create(
        [
            ProtocolAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        ProtocolAdapterResolveResult first = registry.Value!.Resolve(
            ResponsesProtocolCapabilities.CanonicalProtocolId,
            ResponsesProtocolCapabilities.UpstreamProtocolId,
            ResponsesProtocolCapabilities.AdapterVersion);
        ProtocolAdapterResolveResult second = registry.Value!.Resolve(
            ResponsesProtocolCapabilities.CanonicalProtocolId,
            ResponsesProtocolCapabilities.UpstreamProtocolId,
            ResponsesProtocolCapabilities.AdapterVersion);

        Assert.True(first.IsResolved);
        Assert.Same(first.Adapter, second.Adapter);
        Assert.Equal(RouterErrorCode.AdapterNotFound, registry.Value.Resolve(
            "protocol.anthropic.messages.v1",
            "protocol.openai.responses.v1",
            "1.0").Error!.Code);
    }

    [Fact]
    public void Placeholder_resolution_never_becomes_eligible()
    {
        ProtocolAdapterDescriptor placeholder = FutureProtocolPlaceholders.AnthropicMessagesV1;
        var stub = new ResponsesProtocolAdapter();
        Result<ProtocolAdapterRegistry, RouterError> registry = ProtocolAdapterRegistry.Create(
        [
            ProtocolAdapterRegistration.Create(placeholder, stub),
        ]);

        ProtocolAdapterResolveResult resolved = registry.Value!.Resolve(
            placeholder.CanonicalProtocolId,
            placeholder.UpstreamProtocolId,
            placeholder.AdapterVersion);

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.PlaceholderUnavailable, resolved.Error!.Code);
    }

    [Fact]
    public void No_protocol_is_inferred_from_provider_or_model_names()
    {
        var adapter = new ResponsesProtocolAdapter();
        Result<ProtocolAdapterRegistry, RouterError> registry = ProtocolAdapterRegistry.Create(
        [
            ProtocolAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.False(registry.Value!.Resolve(
            "protocol.openai.responses.v1",
            "protocol.openai.responses.v1",
            "9.9").IsResolved);
        Assert.Equal(RouterErrorCode.AdapterVersionMismatch, registry.Value.Resolve(
            ResponsesProtocolCapabilities.CanonicalProtocolId,
            ResponsesProtocolCapabilities.UpstreamProtocolId,
            "9.9").Error!.Code);
    }
}
