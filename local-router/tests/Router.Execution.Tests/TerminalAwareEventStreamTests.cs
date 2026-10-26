using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.ProtocolAdapters.Abstractions;
using Router.ProviderAdapters.Abstractions;
using Xunit;

namespace Router.Execution.Tests;

/// <summary>
/// Terminal-aware stream contract: consumers observe the protocol-adapter
/// mapped canonical event (never the raw inner event), and mapping failures
/// stay safe terminal failures observed exactly once.
/// </summary>
public sealed class TerminalAwareEventStreamTests
{
    private static readonly DateTimeOffset FixedNow = DateTimeOffset.Parse("2026-09-08T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal);
    private static readonly string[] ExpectedMappedEventSequence = ["mapped.test", "response.completed"];

    [Fact]
    public async Task Current_returns_the_protocol_mapped_event_never_the_raw_inner_event()
    {
        var adapter = new RewritingProtocolAdapter();
        var finalized = new List<(AttemptOutcome Outcome, RouterError? Error, DateTimeOffset CompletedAt)>();

        TerminalAwareEventStream stream = new(
            adapter,
            Events(
                ("original.test", new { type = "original.test", payload = "x" }),
                ("response.completed", new { type = "response.completed", response = new { id = "resp_1", status = "completed" } })),
            (outcome, error, completedAt) => finalized.Add((outcome, error, completedAt)),
            "request-1",
            () => FixedNow,
            CancellationToken.None);

        var seen = new List<string>();
        await using IAsyncEnumerator<CanonicalEvent> enumerator = stream.GetAsyncEnumerator();
        while (await enumerator.MoveNextAsync())
        {
            seen.Add(enumerator.Current.Type);
        }

        Assert.Equal(ExpectedMappedEventSequence, seen);
        Assert.DoesNotContain("original.test", seen);

        (AttemptOutcome outcome, RouterError? error, DateTimeOffset completedAt) terminal = Assert.Single(finalized);
        Assert.Equal(AttemptOutcome.Succeeded, terminal.outcome);
        Assert.Null(terminal.error);
        Assert.Equal(FixedNow, terminal.completedAt);
    }

    [Fact]
    public async Task Mapping_failure_is_a_safe_terminal_failure_observed_exactly_once()
    {
        var adapter = new RewritingProtocolAdapter();
        var finalized = new List<(AttemptOutcome Outcome, RouterError? Error, DateTimeOffset CompletedAt)>();

        TerminalAwareEventStream stream = new(
            adapter,
            Events(
                ("original.test", new { type = "original.test", payload = "x" }),
                ("original.mapping-error", new { type = "original.mapping-error" })),
            (outcome, error, completedAt) => finalized.Add((outcome, error, completedAt)),
            "request-2",
            () => FixedNow,
            CancellationToken.None);

        await using IAsyncEnumerator<CanonicalEvent> enumerator = stream.GetAsyncEnumerator();
        Assert.True(await enumerator.MoveNextAsync());
        Assert.Equal("mapped.test", enumerator.Current.Type);

        await Assert.ThrowsAsync<ProtocolEventMappingException>(() => enumerator.MoveNextAsync().AsTask());
        await enumerator.DisposeAsync();

        (AttemptOutcome outcome, RouterError? error, DateTimeOffset completedAt) terminal = Assert.Single(finalized);
        Assert.Equal(AttemptOutcome.Failed, terminal.outcome);
        Assert.NotNull(terminal.error);
        Assert.Equal(FixedNow, terminal.completedAt);
    }

    private static async IAsyncEnumerable<CanonicalEvent> Events(
        params (string Type, object Data)[] events)
    {
        foreach ((string type, object data) in events)
        {
            yield return CanonicalEvent.Create(type, data);
            await Task.Yield();
        }
    }

    /// <summary>
    /// TEST-ONLY protocol adapter: maps <c>original.test</c> to
    /// <c>mapped.test</c>, fails closed for <c>original.mapping-error</c>, and
    /// passes every other event through unchanged.
    /// </summary>
    private sealed class RewritingProtocolAdapter : IResponsesProtocolAdapter
    {
        public ProtocolAdapterDescriptor Descriptor { get; } = new()
        {
            AdapterId = "adapter.protocol.test-rewrite.v1",
            AdapterVersion = "1.0",
            CanonicalProtocolId = "protocol.openai.responses.v1",
            UpstreamProtocolId = "protocol.openai.responses.v1",
            LossPolicy = ProtocolLossPolicy.LosslessOnly,
            Eligible = true,
            Description = "TEST-ONLY event-rewriting protocol adapter.",
        };

        public Router.ProtocolAdapters.Abstractions.Result<CanonicalResponsesRequest, RouterError> MapRequest(CanonicalResponsesRequest request)
            => new() { Value = request };

        public Router.ProtocolAdapters.Abstractions.Result<CanonicalResponsesResponse, RouterError> MapResponse(CanonicalResponsesResponse response)
            => new() { Value = response };

        public Router.ProtocolAdapters.Abstractions.Result<CanonicalEvent, RouterError> MapEvent(CanonicalEvent canonicalEvent)
        {
            if (string.Equals(canonicalEvent.Type, "original.mapping-error", StringComparison.Ordinal))
            {
                return new Router.ProtocolAdapters.Abstractions.Result<CanonicalEvent, RouterError>
                {
                    Error = RouterError.SemanticLoss("event", "request-id"),
                };
            }

            CanonicalEvent mapped = string.Equals(canonicalEvent.Type, "original.test", StringComparison.Ordinal)
                ? new CanonicalEvent { Type = "mapped.test", Data = canonicalEvent.Data }
                : canonicalEvent;
            return new Router.ProtocolAdapters.Abstractions.Result<CanonicalEvent, RouterError> { Value = mapped };
        }
    }
}
