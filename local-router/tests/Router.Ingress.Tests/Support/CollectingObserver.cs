using System.Collections.Concurrent;

namespace Router.Ingress.Tests.Support;

/// <summary>Collects safe per-request execution results for assertions.</summary>
public sealed class CollectingObserver : IngressRequestObserver
{
    private readonly ConcurrentQueue<RequestExecutionResult> _results = new();
    private readonly ConcurrentQueue<RequestUsageCompletion> _usageCompletions = new();

    public override void OnCompleted(RequestExecutionResult result) => _results.Enqueue(result);

    public override Task OnUsageCompletedAsync(
        RequestUsageCompletion completion,
        CancellationToken cancellationToken = default)
    {
        _ = cancellationToken;
        _usageCompletions.Enqueue(completion);
        return Task.CompletedTask;
    }

    public IReadOnlyList<RequestExecutionResult> Results => _results.ToArray();

    public IReadOnlyList<RequestUsageCompletion> UsageCompletions => _usageCompletions.ToArray();
}
