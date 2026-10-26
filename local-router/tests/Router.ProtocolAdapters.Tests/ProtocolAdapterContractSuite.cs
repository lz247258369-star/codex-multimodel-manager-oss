using Router.Core.Errors;
using Router.ProtocolAdapters.Abstractions;
using Router.ProtocolAdapters.Responses;
using Router.Registries;
using Xunit;

namespace Router.ProtocolAdapters.Tests;

/// <summary>
/// Reusable LR-8 protocol conformance suite. Every protocol adapter must pass
/// the same suite; no protocol gets a second, weaker suite. Placeholders are
/// tested separately and can never satisfy this suite as eligible.
/// </summary>
public abstract class ProtocolAdapterContractSuite
{
    protected abstract ProtocolAdapterContractHarness Harness { get; }

    [Fact]
    public void Protocol_identity_is_exact_and_versioned()
    {
        ProtocolAdapterDescriptor descriptor = Harness.CreateAdapter().Descriptor;

        Assert.False(string.IsNullOrWhiteSpace(descriptor.AdapterId));
        Assert.False(string.IsNullOrWhiteSpace(descriptor.AdapterVersion));
        Assert.Equal("protocol.openai.responses.v1", descriptor.CanonicalProtocolId);
        Assert.Equal("protocol.openai.responses.v1", descriptor.UpstreamProtocolId);
        Assert.True(descriptor.Eligible);
        Assert.False(descriptor.IsPlaceholder);
        Assert.Equal(ProtocolLossPolicy.LosslessOnly, descriptor.LossPolicy);
    }

    [Fact]
    public void Registry_exact_resolution_succeeds()
    {
        IResponsesProtocolAdapter adapter = Harness.CreateAdapter();
        ProtocolAdapterDescriptor descriptor = adapter.Descriptor;

        Result<ProtocolAdapterRegistry, RouterError> registry = ProtocolAdapterRegistry.Create(
        [
            ProtocolAdapterRegistration.Create(descriptor, adapter),
        ]);

        Assert.True(registry.IsSuccess);
        ProtocolAdapterResolveResult resolved = registry.Value!.Resolve(
            descriptor.CanonicalProtocolId,
            descriptor.UpstreamProtocolId,
            descriptor.AdapterVersion);

        Assert.True(resolved.IsResolved);
        Assert.Same(adapter, resolved.Adapter);
    }

    [Fact]
    public void Duplicate_registration_fails_closed()
    {
        IResponsesProtocolAdapter adapter = Harness.CreateAdapter();
        ProtocolAdapterDescriptor descriptor = adapter.Descriptor;

        Result<ProtocolAdapterRegistry, RouterError> registry = ProtocolAdapterRegistry.Create(
        [
            ProtocolAdapterRegistration.Create(descriptor, adapter),
            ProtocolAdapterRegistration.Create(descriptor, adapter),
        ]);

        Assert.False(registry.IsSuccess);
        Assert.Equal(RouterErrorCode.AdapterRegistrationInvalid, registry.Error!.Code);
    }

    [Fact]
    public void Incompatible_version_fails_closed()
    {
        IResponsesProtocolAdapter adapter = Harness.CreateAdapter();
        ProtocolAdapterDescriptor descriptor = adapter.Descriptor;
        Result<ProtocolAdapterRegistry, RouterError> registry = ProtocolAdapterRegistry.Create(
        [
            ProtocolAdapterRegistration.Create(descriptor, adapter),
        ]);

        ProtocolAdapterResolveResult resolved = registry.Value!.Resolve(
            descriptor.CanonicalProtocolId,
            descriptor.UpstreamProtocolId,
            "9.9.9");

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterVersionMismatch, resolved.Error!.Code);
    }

    [Fact]
    public void Unsupported_protocol_pair_fails_closed()
    {
        IResponsesProtocolAdapter adapter = Harness.CreateAdapter();
        ProtocolAdapterDescriptor descriptor = adapter.Descriptor;
        Result<ProtocolAdapterRegistry, RouterError> registry = ProtocolAdapterRegistry.Create(
        [
            ProtocolAdapterRegistration.Create(descriptor, adapter),
        ]);

        ProtocolAdapterResolveResult resolved = registry.Value!.Resolve(
            "protocol.openai.responses.v1",
            "protocol.anthropic.messages.v1",
            descriptor.AdapterVersion);

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterNotFound, resolved.Error!.Code);
    }

    [Fact]
    public void Placeholder_is_never_eligible()
    {
        ProtocolAdapterDescriptor placeholder = Harness.CreatePlaceholder();
        var stub = new ResponsesProtocolAdapter();
        Result<ProtocolAdapterRegistry, RouterError> registry = ProtocolAdapterRegistry.Create(
        [
            ProtocolAdapterRegistration.Create(placeholder, stub),
        ]);

        Assert.True(registry.IsSuccess);
        ProtocolAdapterResolveResult resolved = registry.Value!.Resolve(
            placeholder.CanonicalProtocolId,
            placeholder.UpstreamProtocolId,
            placeholder.AdapterVersion);

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.PlaceholderUnavailable, resolved.Error!.Code);
    }

    [Fact]
    public void Capability_matrix_is_explicit()
    {
        CapabilitySet capabilities = Harness.CreateAdapter().Descriptor.Capabilities;

        Assert.Contains("responses", capabilities.Values);
        Assert.Contains("text", capabilities.Values);
        Assert.Contains("streaming", capabilities.Values);
        Assert.Contains("reasoning", capabilities.Values);
        Assert.Contains("tools", capabilities.Values);
        Assert.Contains("usage", capabilities.Values);
        Assert.Contains("cancellation", capabilities.Values);
        Assert.False(capabilities.Contains("multimodal"));
        Assert.False(capabilities.Contains("background"));
        Assert.False(capabilities.Contains("chat_completions"));
    }

    [Fact]
    public void Lossless_policy_never_defaults_to_lossy()
    {
        Assert.Equal("LOSSLESS_ONLY", Harness.CreateAdapter().Descriptor.LossPolicy.ToWireName());
    }

    [Fact]
    public void Descriptor_never_contains_secret_or_content_fields()
    {
        ProtocolAdapterDescriptor descriptor = Harness.CreateAdapter().Descriptor;
        string[] forbidden = ["secret", "authorization", "apikey", "prompt", "toolpayload", "rawbody", "cookie"];

        foreach (string value in new[]
                 {
                     descriptor.AdapterId,
                     descriptor.AdapterVersion,
                     descriptor.CanonicalProtocolId,
                     descriptor.UpstreamProtocolId,
                     descriptor.Description ?? string.Empty,
                 })
        {
            foreach (string needle in forbidden)
            {
                Assert.DoesNotContain(needle, value, StringComparison.OrdinalIgnoreCase);
            }
        }
    }
}
