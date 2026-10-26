using System.Text;
using ProviderContractKit;
using Router.ClientAdapters.Responses;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Router.ProviderAdapters.Responses;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

public sealed class DeepSeekStreamTests
{
    [Fact]
    public async Task Multiple_events_per_read_are_preserved_without_a_done_sentinel()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, DeepSeekFixtures.StandardStream()));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectAsync(result.EventStream!);
        Assert.Equal("response.created", events[0].Type);
        Assert.Contains(events, static evt => evt.Type == "response.output_item.added");
        Assert.Contains(events, static evt => evt.Type == "response.output_text.delta");
        Assert.Contains(events, static evt => evt.Type == "response.completed");
    }

    [Fact]
    public async Task Flash_upstream_stream_is_preserved()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, DeepSeekFixtures.FlashStream()));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectAsync(result.EventStream!);
        Assert.Contains(events, static evt => evt.Type == "response.output_text.delta");
    }

    [Fact]
    public async Task Partial_utf8_is_reassembled()
    {
        string sse = SseFixtureBuilder.BasicStream("\u4f60\u597d\u4e16\u754c", model: DeepSeekFixtures.ProModel);
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(new FakeProviderScenario
        {
            StatusCode = 200,
            Body = Encoding.UTF8.GetBytes(sse),
            ContentType = "text/event-stream",
            ChunkSize = 1,
            DelayBetweenChunks = TimeSpan.FromMilliseconds(1),
        });

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectAsync(result.EventStream!);
        CanonicalEvent delta = Assert.Single(events, static evt => evt.Type == "response.output_text.delta");
        Assert.Contains("\u4f60\u597d\u4e16\u754c", delta.Data.GetProperty("delta").GetString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Reasoning_deltas_are_preserved()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, DeepSeekFixtures.ReasoningStream()));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectAsync(result.EventStream!);
        Assert.Contains(events, static evt => evt.Type == "response.reasoning_summary_text.delta");
    }

    [Fact]
    public async Task Function_call_argument_deltas_are_preserved()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, DeepSeekFixtures.ToolCallStream()));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectAsync(result.EventStream!);
        Assert.Contains(events, static evt => evt.Type == "response.output_item.added");
        Assert.Contains(events, static evt => evt.Type == "response.function_call_arguments.delta");
    }

    [Fact]
    public async Task Incomplete_event_is_surfaced_and_stays_non_terminal()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, DeepSeekFixtures.IncompleteStream()));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        var events = new List<CanonicalEvent>();
        await Assert.ThrowsAsync<StreamInterruptedException>(async () =>
        {
            await foreach (CanonicalEvent canonicalEvent in result.EventStream!)
            {
                events.Add(canonicalEvent);
            }
        });
        // response.incomplete is surfaced to the client but is not treated as a
        // terminal event by the canonical Responses vocabulary, so the stream
        // ends as interrupted instead of silently completing.
        Assert.Contains(events, static evt => evt.Type == "response.incomplete");
    }

    [Fact]
    public async Task Failed_status_is_a_terminal_event()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, DeepSeekFixtures.FailedStream()));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectAsync(result.EventStream!);
        Assert.Contains(events, static evt => evt.Type == "response.failed");
    }

    [Fact]
    public async Task Normalized_error_event_terminates_the_stream()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, DeepSeekFixtures.ErrorEventSse()));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectAsync(result.EventStream!);
        Assert.Contains(events, static evt => evt.Type == "error");
    }

    [Fact]
    public async Task Malformed_sse_is_a_stream_error()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, "event: response.created\ndata: { nope\n\n"));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        await Assert.ThrowsAsync<SseParseException>(() => CollectAsync(result.EventStream!));
    }

    [Fact]
    public async Task Truncated_stream_is_stream_interrupted()
    {
        string truncated = DeepSeekFixtures.StandardStream()
            .Replace("response.completed", "response.output_text.done", StringComparison.Ordinal);

        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, truncated));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        await Assert.ThrowsAsync<StreamInterruptedException>(() => CollectAsync(result.EventStream!));
    }

    private static async Task<List<CanonicalEvent>> CollectAsync(IAsyncEnumerable<CanonicalEvent> events)
    {
        var list = new List<CanonicalEvent>();
        await foreach (CanonicalEvent canonicalEvent in events)
        {
            list.Add(canonicalEvent);
        }

        return list;
    }
}
