using Router.ProtocolAdapters.Abstractions;
using Router.ProtocolAdapters.Responses;

namespace Router.ProtocolAdapters.Tests;

/// <summary>
/// Adapter-specific wiring for the reusable LR-8 protocol contract suite.
/// Future protocol adapter PRs implement this harness and inherit
/// <see cref="ProtocolAdapterContractSuite"/>.
/// </summary>
public abstract class ProtocolAdapterContractHarness
{
    public abstract IResponsesProtocolAdapter CreateAdapter();

    public virtual ProtocolAdapterDescriptor CreatePlaceholder()
        => FutureProtocolPlaceholders.AnthropicMessagesV1;
}
