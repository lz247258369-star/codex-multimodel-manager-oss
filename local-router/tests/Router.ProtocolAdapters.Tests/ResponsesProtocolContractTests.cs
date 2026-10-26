using Router.ProtocolAdapters.Abstractions;
using Router.ProtocolAdapters.Responses;

namespace Router.ProtocolAdapters.Tests;

/// <summary>
/// The Responses-to-Responses protocol adapter must pass the reusable LR-8
/// protocol conformance suite. There is no Responses-specific second suite.
/// </summary>
public sealed class ResponsesProtocolContractTests : ProtocolAdapterContractSuite
{
    private readonly ProtocolAdapterContractHarness _harness = new ResponsesProtocolContractHarness();

    protected override ProtocolAdapterContractHarness Harness => _harness;
}

internal sealed class ResponsesProtocolContractHarness : ProtocolAdapterContractHarness
{
    public override IResponsesProtocolAdapter CreateAdapter()
        => new ResponsesProtocolAdapter();
}
