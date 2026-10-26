using Router.ProviderAdapters.Abstractions;
using Router.Registries;

namespace Router.ProviderAdapters.Responses;

/// <summary>
/// TEST-ONLY fake Responses provider adapter. It talks only to an explicit
/// loopback fake upstream and never to a real provider. It is never registered
/// in a production path.
/// </summary>
public sealed class FakeResponsesProviderAdapter : ResponsesCompatibleProviderAdapterBase
{
    public const string AdapterId = "adapter.provider.fake.responses.v1";
    public const string AdapterVersion = "1.0";
    public const string ProviderId = "fake_provider";
    public const string ProtocolId = "protocol.openai.responses.v1";

    public FakeResponsesProviderAdapter(string? requestPath = null)
        : base(requestPath)
    {
    }

    public override ProviderAdapterDescriptor Descriptor { get; } = new()
    {
        AdapterId = AdapterId,
        AdapterVersion = AdapterVersion,
        ProviderId = ProviderId,
        ProtocolId = ProtocolId,
        Capabilities = CapabilitySet.From(
        [
            "responses", "text", "streaming", "reasoning", "tools", "usage", "cancellation",
        ]),
        RequestSemantics = RequestSemantics.Both,
        ResponseSemantics = ResponseSemantics.Both,
        EndpointRequirement = EndpointRequirement.HttpsWithTestLoopback,
        SecretRequirement = SecretRequirement.RequiresProviderSecret,
        CancellationSupport = CancellationSupport.Full,
        UsageSupport = UsageSupport.Canonical,
        Eligible = true,
        Description = "TEST-ONLY loopback fake Responses provider adapter.",
    };
}

/// <summary>Thrown when an upstream SSE stream ends without a terminal event.</summary>
public sealed class StreamInterruptedException : Exception
{
    public StreamInterruptedException()
        : base("The upstream stream ended without a terminal event.")
    {
    }
}
