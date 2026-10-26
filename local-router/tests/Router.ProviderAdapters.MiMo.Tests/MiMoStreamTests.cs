using System.Text;
using ProviderContractKit;
using Router.ClientAdapters.Responses;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.MiMo;
using Router.ProviderAdapters.Responses;
using Xunit;

namespace Router.ProviderAdapters.MiMo.Tests;

public sealed class MiMoStreamTests
{
    [Fact]
    public async Task Partial_utf8_is_reassembled()
    {
        string sse = SseFixtureBuilder.BasicStream("你好世界", model: "mimo-v2.5-pro");
        var scenario = new FakeProviderScenario
        {
            StatusCode = 200,
            Body = Encoding.UTF8.GetBytes(sse),
            ContentType = "text/event-stream",
            ChunkSize = 1,
            DelayBetweenChunks = TimeSpan.FromMilliseconds(1),
        };

        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(scenario);
        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectAsync(result.EventStream!);
        CanonicalEvent delta = Assert.Single(events, static evt => evt.Type == "response.output_text.delta");
        Assert.Contains("你好世界", delta.Data.GetProperty("delta").GetString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Multiple_events_per_read_are_preserved()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, MiMoFixtures.StandardStream()));
        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectAsync(result.EventStream!);
        Assert.Equal("response.created", events[0].Type);
        Assert.Contains(events, static evt => evt.Type == "response.output_text.delta");
        Assert.Contains(events, static evt => evt.Type == "response.completed");
    }

    [Fact]
    public async Task Reasoning_deltas_are_preserved()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, MiMoFixtures.ReasoningStream()));
        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(
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
    public async Task Tool_call_deltas_are_preserved()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, MiMoFixtures.ToolCallStream()));
        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectAsync(result.EventStream!);
        Assert.Contains(events, static evt => evt.Type == "response.output_item.added");
    }

    [Fact]
    public async Task Malformed_sse_is_a_stream_error()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, "event: response.created\ndata: { nope\n\n"));
        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(
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
        string truncated = MiMoFixtures.StandardStream()
            .Replace("response.completed", "response.incomplete", StringComparison.Ordinal);

        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, truncated));
        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        await Assert.ThrowsAsync<StreamInterruptedException>(() => CollectAsync(result.EventStream!));
    }

    [Fact]
    public async Task Normalized_error_event_terminates_the_stream()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, MiMoFixtures.ErrorEventSse()));
        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectAsync(result.EventStream!);
        Assert.Contains(events, static evt => evt.Type == "error");
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
