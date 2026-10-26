using Router.ClientAdapters.Responses;

namespace Router.Execution;

/// <summary>
/// Optional sink for authoritative execution metadata produced by the
/// production execution service. Sinks observe identity/outcome only; they
/// never receive secrets, request content, or raw upstream text.
/// </summary>
public interface IExecutionOutcomeSink
{
    void OnExecuted(ResponsesExecutionMetadata metadata);
}
