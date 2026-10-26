using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Router.ProviderAdapters.Responses;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

/// <summary>
/// DSR7-C-FIX5-B2: the DeepSeek-only streaming apply_patch bridge. A synthetic
/// function call is buffered per call, validated with the same strict decoder as
/// the non-stream restore, and released only as one complete restored item; the
/// synthetic identity and the patch text are never partially released, ordinary
/// events keep their order and their instances, and every unprovable stream fails
/// closed with a single content-free error event.
/// </summary>
public sealed class DeepSeekApplyPatchStreamBridgeTests
{
    private const string SyntheticName = "mm_apply_patch_bridge_v1";
    private const string Sentinel = "PATCH_STREAM_DO_NOT_PARTIALLY_RELEASE_61937";

    // --- Restore ------------------------------------------------------------

    [Fact]
    public async Task Synthetic_stream_is_restored_and_never_exposes_the_synthetic_name()
    {
        string arguments = PatchArguments(Sentinel);

        List<CanonicalEvent> events = await BridgeAsync(
            [
                Created(),
                SyntheticAdded(),
                ArgsDelta("{\"pat"),
                ArgsDelta("ch\":\"" + Sentinel + "\"}"),
                ArgsDone(arguments),
                SyntheticItemDone(arguments),
                CompletedWithOutput(SyntheticItemJson(arguments)),
            ],
            bridgeIsActive: true);

        AssertNoSyntheticLeak(events);

        CanonicalEvent added = Assert.Single(events, static evt => evt.Type == "response.output_item.added");
        JsonElement item = added.Data.GetProperty("item");
        Assert.Equal("custom_tool_call", item.GetProperty("type").GetString());
        Assert.Equal("apply_patch", item.GetProperty("name").GetString());
        Assert.Equal("fc_1", item.GetProperty("id").GetString());
        Assert.Equal("call_patch_1", item.GetProperty("call_id").GetString());
        Assert.Equal(Sentinel, item.GetProperty("input").GetString());
        Assert.Equal(1, added.Data.GetProperty("output_index").GetInt32());

        CanonicalEvent done = Assert.Single(events, static evt => evt.Type == "response.output_item.done");
        Assert.Equal("custom_tool_call", done.Data.GetProperty("item").GetProperty("type").GetString());

        // The terminal body carries the restored item too - never the synthetic one.
        CanonicalEvent completed = Assert.Single(events, static evt => evt.Type == "response.completed");
        JsonElement completedItems = completed.Data.GetProperty("response").GetProperty("output");
        Assert.Equal("custom_tool_call", completedItems[0].GetProperty("type").GetString());
        Assert.Equal(Sentinel, completedItems[0].GetProperty("input").GetString());
        Assert.Equal(7, completed.Data.GetProperty("response").GetProperty("usage").GetProperty("input_tokens").GetInt32());
    }

    [Fact]
    public async Task Deltas_split_at_arbitrary_boundaries_are_reassembled()
    {
        string patch = "*** Begin Patch\n*** Update File: a.txt\n*** End Patch";
        string arguments = PatchArguments(patch);

        List<CanonicalEvent> events = await BridgeAsync(
            [
                Created(),
                SyntheticAdded(),
                ArgsDelta(arguments[..2]),
                ArgsDelta(arguments[2..7]),
                ArgsDelta(arguments[7..(arguments.Length - 1)]),
                ArgsDelta(arguments[^1..]),
                SyntheticItemDone(arguments),
                CompletedWithOutput(SyntheticItemJson(arguments)),
            ],
            bridgeIsActive: true);

        CanonicalEvent added = Assert.Single(events, static evt => evt.Type == "response.output_item.added");
        Assert.Equal(patch, added.Data.GetProperty("item").GetProperty("input").GetString());
    }

    [Fact]
    public async Task Arguments_done_without_deltas_is_restored()
    {
        string arguments = PatchArguments(Sentinel);

        List<CanonicalEvent> events = await BridgeAsync(
            [Created(), SyntheticAdded(), ArgsDone(arguments), SyntheticItemDone(arguments)],
            bridgeIsActive: true);

        Assert.Equal(Sentinel, Assert.Single(events, static evt => evt.Type == "response.output_item.added")
            .Data.GetProperty("item").GetProperty("input").GetString());
    }

    [Fact]
    public async Task Unicode_patch_round_trips_exactly()
    {
        string patch = "*** Begin Patch\n@@\n-中文行\n+emoji \U0001F600 and \\ backslash and \" quote\n*** End Patch";
        string arguments = PatchArguments(patch);

        List<CanonicalEvent> events = await BridgeAsync(
            [Created(), SyntheticAdded(), ArgsDelta(arguments), SyntheticItemDone(arguments)],
            bridgeIsActive: true);

        CanonicalEvent added = Assert.Single(events, static evt => evt.Type == "response.output_item.added");
        Assert.Equal(patch, added.Data.GetProperty("item").GetProperty("input").GetString());
    }

    [Fact]
    public async Task Multiple_synthetic_calls_are_restored_independently()
    {
        string first = PatchArguments("patch-one");
        string second = PatchArguments("patch-two");

        List<CanonicalEvent> events = await BridgeAsync(
            [
                Created(),
                SyntheticAdded(id: "fc_1", callId: "call_1", outputIndex: 1),
                SyntheticAdded(id: "fc_2", callId: "call_2", outputIndex: 2),
                ArgsDelta(second, itemId: "fc_2"),
                ArgsDelta(first, itemId: "fc_1"),
                SyntheticItemDone(first, id: "fc_1", callId: "call_1"),
                SyntheticItemDone(second, id: "fc_2", callId: "call_2"),
                CompletedWithOutput(SyntheticItemJson(first, "fc_1", "call_1"), SyntheticItemJson(second, "fc_2", "call_2")),
            ],
            bridgeIsActive: true);

        List<JsonElement> restored = [.. events
            .Where(static evt => evt.Type == "response.output_item.added")
            .Select(static evt => evt.Data.GetProperty("item"))];
        Assert.Equal(2, restored.Count);
        Assert.Equal("fc_1", restored[0].GetProperty("id").GetString());
        Assert.Equal("call_1", restored[0].GetProperty("call_id").GetString());
        Assert.Equal("patch-one", restored[0].GetProperty("input").GetString());
        Assert.Equal("fc_2", restored[1].GetProperty("id").GetString());
        Assert.Equal("call_2", restored[1].GetProperty("call_id").GetString());
        Assert.Equal("patch-two", restored[1].GetProperty("input").GetString());
    }

    [Fact]
    public async Task Mixed_stream_order_is_preserved()
    {
        string arguments = PatchArguments(Sentinel);

        List<CanonicalEvent> events = await BridgeAsync(
            [
                Created(),
                TextDelta("before"),
                OrdinaryItemAdded(),
                SyntheticAdded(),
                ArgsDelta(arguments),
                SyntheticItemDone(arguments),
                TextDelta("after"),
                CompletedWithOutput(SyntheticItemJson(arguments)),
            ],
            bridgeIsActive: true);

        Assert.Equal(
            [
                "response.created",
                "response.output_text.delta",
                "response.output_item.added",
                "response.output_item.added",
                "response.output_item.done",
                "response.output_text.delta",
                "response.completed",
            ],
            events.Select(static evt => evt.Type));

        // The ordinary item is the untouched upstream instance.
        Assert.Equal("get_weather", events[2].Data.GetProperty("item").GetProperty("name").GetString());
    }

    [Fact]
    public async Task Ordinary_stream_events_are_yielded_by_reference()
    {
        CanonicalEvent created = Created();
        CanonicalEvent text = TextDelta("hello");
        CanonicalEvent completed = CompletedNoOutput();

        List<CanonicalEvent> events = await BridgeAsync([created, text, completed], bridgeIsActive: true);

        Assert.Same(created, events[0]);
        Assert.Same(text, events[1]);
        Assert.Same(completed, events[2]);
    }

    [Fact]
    public async Task Inactive_bridge_yields_ordinary_streams_unchanged()
    {
        CanonicalEvent[] upstream =
        [
            Created(),
            TextDelta("hello"),
            OrdinaryItemAdded(),
            CompletedNoOutput(),
        ];

        List<CanonicalEvent> events = await BridgeAsync(upstream, bridgeIsActive: false);

        Assert.Equal(upstream.Length, events.Count);
        for (int index = 0; index < upstream.Length; index++)
        {
            Assert.Same(upstream[index], events[index]);
        }
    }

    // --- Fail closed --------------------------------------------------------

    [Fact]
    public async Task Synthetic_injection_without_an_active_bridge_fails_closed()
    {
        List<CanonicalEvent> events = await BridgeAsync(
            [Created(), SyntheticAdded(), CompletedNoOutput()],
            bridgeIsActive: false);

        AssertFailClosed(events);
    }

    [Fact]
    public async Task Synthetic_injection_in_the_terminal_body_fails_closed()
    {
        string arguments = PatchArguments(Sentinel);

        List<CanonicalEvent> events = await BridgeAsync(
            [Created(), CompletedWithOutput(SyntheticItemJson(arguments))],
            bridgeIsActive: false);

        AssertFailClosed(events);
    }

    [Theory]
    [InlineData("""{"patch":null}""")]
    [InlineData("""{"patch":123}""")]
    [InlineData("""{"patch":"a","patch":"b"}""")]
    [InlineData("""{"patch":"a","extra":"b"}""")]
    [InlineData("{}")]
    [InlineData("not json")]
    [InlineData("")]
    public async Task Malformed_final_arguments_fail_closed(string malformed)
    {
        List<CanonicalEvent> events = await BridgeAsync(
            [Created(), SyntheticAdded(), ArgsDone(malformed), SyntheticItemDone(malformed)],
            bridgeIsActive: true);

        AssertFailClosed(events);
    }

    [Fact]
    public async Task Oversized_streamed_arguments_fail_closed()
    {
        string oversized = new('x', ApplyPatchStreamBridge.MaxSyntheticArgumentsLength + 1);

        List<CanonicalEvent> events = await BridgeAsync(
            [Created(), SyntheticAdded(), ArgsDelta(oversized), SyntheticItemDone(oversized)],
            bridgeIsActive: true);

        AssertFailClosed(events);
    }

    [Fact]
    public async Task Oversized_decoded_patch_fails_closed()
    {
        string oversized = new('x', ApplyPatchRequestBridge.MaxPatchInputLength + 1);
        string arguments = PatchArguments(oversized);

        List<CanonicalEvent> events = await BridgeAsync(
            [Created(), SyntheticAdded(), ArgsDone(arguments), SyntheticItemDone(arguments)],
            bridgeIsActive: true);

        AssertFailClosed(events);
    }

    [Fact]
    public async Task Duplicate_start_fails_closed()
    {
        List<CanonicalEvent> events = await BridgeAsync(
            [Created(), SyntheticAdded(), SyntheticAdded()],
            bridgeIsActive: true);

        AssertFailClosed(events);
    }

    [Fact]
    public async Task Duplicate_arguments_done_fails_closed()
    {
        string arguments = PatchArguments(Sentinel);

        List<CanonicalEvent> events = await BridgeAsync(
            [Created(), SyntheticAdded(), ArgsDone(arguments), ArgsDone(arguments)],
            bridgeIsActive: true);

        AssertFailClosed(events);
    }

    [Fact]
    public async Task Item_done_before_start_fails_closed()
    {
        string arguments = PatchArguments(Sentinel);

        List<CanonicalEvent> events = await BridgeAsync(
            [Created(), SyntheticItemDone(arguments), CompletedNoOutput()],
            bridgeIsActive: true);

        AssertFailClosed(events);
    }

    [Fact]
    public async Task Item_id_mutation_fails_closed()
    {
        string arguments = PatchArguments(Sentinel);

        List<CanonicalEvent> events = await BridgeAsync(
            [
                Created(),
                SyntheticAdded(),
                SyntheticItemDone(arguments, id: "fc_other", callId: "call_patch_1"),
            ],
            bridgeIsActive: true);

        AssertFailClosed(events);
    }

    [Fact]
    public async Task Call_id_mutation_fails_closed()
    {
        string arguments = PatchArguments(Sentinel);

        List<CanonicalEvent> events = await BridgeAsync(
            [
                Created(),
                SyntheticAdded(),
                SyntheticItemDone(arguments, id: "fc_1", callId: "call_other"),
            ],
            bridgeIsActive: true);

        AssertFailClosed(events);
    }

    [Fact]
    public async Task Disagreeing_argument_sources_fail_closed()
    {
        List<CanonicalEvent> events = await BridgeAsync(
            [
                Created(),
                SyntheticAdded(),
                ArgsDelta(PatchArguments("one")),
                SyntheticItemDone(PatchArguments("two")),
            ],
            bridgeIsActive: true);

        AssertFailClosed(events);
    }

    [Fact]
    public async Task Missing_arguments_fail_closed()
    {
        List<CanonicalEvent> events = await BridgeAsync(
            [Created(), SyntheticAdded(), SyntheticItemDoneWithoutArguments()],
            bridgeIsActive: true);

        AssertFailClosed(events);
    }

    [Fact]
    public async Task Synthetic_call_started_but_never_completed_fails_closed()
    {
        List<CanonicalEvent> events = await BridgeAsync(
            [Created(), SyntheticAdded(), ArgsDelta(PatchArguments(Sentinel)), CompletedNoOutput()],
            bridgeIsActive: true);

        AssertFailClosed(events);
    }

    [Fact]
    public async Task Late_synthetic_identity_fails_closed()
    {
        string arguments = PatchArguments(Sentinel);

        List<CanonicalEvent> events = await BridgeAsync(
            [
                Created(),
                SyntheticAdded(),
                SyntheticItemDone(arguments),
                CompletedWithOutput(SyntheticItemJson(arguments, "fc_unknown", "call_unknown")),
            ],
            bridgeIsActive: true);

        // The first call was legitimately released; the unexpected terminal identity
        // then terminates the stream without a completed response.
        AssertTerminatedWithError(events, expectNoSentinel: false);
    }

    [Fact]
    public async Task One_malformed_call_stops_the_stream_without_releasing_it()
    {
        string good = PatchArguments("good");

        List<CanonicalEvent> events = await BridgeAsync(
            [
                Created(),
                SyntheticAdded(id: "fc_1", callId: "call_1"),
                SyntheticAdded(id: "fc_2", callId: "call_2"),
                ArgsDelta(good, itemId: "fc_1"),
                SyntheticItemDone(good, id: "fc_1", callId: "call_1"),
                ArgsDelta("""{"patch":null}""", itemId: "fc_2"),
                SyntheticItemDone("""{"patch":null}""", id: "fc_2", callId: "call_2"),
                CompletedWithOutput(SyntheticItemJson(good, "fc_1", "call_1")),
            ],
            bridgeIsActive: true);

        // The first call was legitimately released before the second failed; the
        // failure then terminates the stream and the malformed second call is never
        // released, and never completed.
        Assert.Equal("error", events[^1].Type);
        Assert.DoesNotContain(events, static evt => evt.Type == "response.completed");
        Assert.Single(events, static evt => evt.Type == "response.output_item.done");
        Assert.DoesNotContain("fc_2", string.Join('\n', events.Select(static evt => evt.Data.GetRawText())), StringComparison.Ordinal);
    }

    [Fact]
    public async Task No_patch_content_is_released_before_validation()
    {
        string arguments = PatchArguments(Sentinel);

        List<CanonicalEvent> events = await BridgeAsync(
            [Created(), TextDelta("before"), SyntheticAdded(), ArgsDelta(arguments), CompletedNoOutput()],
            bridgeIsActive: true);

        // Only the terminal error may appear; the sentinel never reaches the client.
        AssertFailClosed(events);
    }

    // --- Cancellation, timeout and interruption -----------------------------

    [Fact]
    public async Task Cancellation_propagates_without_releasing_the_patch()
    {
        using var cts = new CancellationTokenSource();
        var emitted = new List<CanonicalEvent>();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
        {
            await foreach (CanonicalEvent evt in ApplyPatchStreamBridge.Apply(
                CancellingUpstream(cts),
                bridgeIsActive: true,
                cts.Token))
            {
                emitted.Add(evt);
            }
        });

        Assert.DoesNotContain(Sentinel, string.Join('\n', emitted.Select(static evt => evt.Data.GetRawText())), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Stream_timeout_propagates_without_releasing_the_patch()
    {
        var emitted = new List<CanonicalEvent>();

        await Assert.ThrowsAsync<StreamTimeoutException>(async () =>
        {
            await foreach (CanonicalEvent evt in ApplyPatchStreamBridge.Apply(
                ThrowingUpstream(new StreamTimeoutException(StreamTimeoutStage.Idle)),
                bridgeIsActive: true,
                CancellationToken.None))
            {
                emitted.Add(evt);
            }
        });

        Assert.DoesNotContain(Sentinel, string.Join('\n', emitted.Select(static evt => evt.Data.GetRawText())), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Stream_interruption_propagates_without_releasing_the_patch()
    {
        var emitted = new List<CanonicalEvent>();

        await Assert.ThrowsAsync<StreamInterruptedException>(async () =>
        {
            await foreach (CanonicalEvent evt in ApplyPatchStreamBridge.Apply(
                ThrowingUpstream(new StreamInterruptedException()),
                bridgeIsActive: true,
                CancellationToken.None))
            {
                emitted.Add(evt);
            }
        });

        Assert.DoesNotContain(Sentinel, string.Join('\n', emitted.Select(static evt => evt.Data.GetRawText())), StringComparison.Ordinal);
    }

    // --- Fake transport end-to-end ------------------------------------------

    [Fact]
    public async Task End_to_end_streaming_bridge_closes_the_loop()
    {
        string arguments = PatchArguments(Sentinel);
        string sse = string.Join("\n\n",
        [
            "event: response.created\ndata: " + Created().Data.GetRawText(),
            "event: response.output_item.added\ndata: " + SyntheticAdded().Data.GetRawText(),
            "event: response.function_call_arguments.delta\ndata: " + ArgsDelta(arguments[..6]).Data.GetRawText(),
            "event: response.function_call_arguments.delta\ndata: " + ArgsDelta(arguments[6..]).Data.GetRawText(),
            "event: response.function_call_arguments.done\ndata: " + ArgsDone(arguments).Data.GetRawText(),
            "event: response.output_item.done\ndata: " + SyntheticItemDone(arguments).Data.GetRawText(),
            "event: response.completed\ndata: " + CompletedWithOutput(SyntheticItemJson(arguments)).Data.GetRawText(),
        ]) + "\n\n";

        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, sse));

        CanonicalResponsesRequest request = Parse(
            "{\"model\":\"deepseek-flash\",\"input\":\"hi\",\"stream\":true,\"tools\":["
            + ApplyPatchToolJson()
            + "]}");

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, request, stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectAsync(result.EventStream!);

        AssertNoSyntheticLeak(events);
        CanonicalEvent added = Assert.Single(events, static evt => evt.Type == "response.output_item.added");
        Assert.Equal("custom_tool_call", added.Data.GetProperty("item").GetProperty("type").GetString());
        Assert.Equal("apply_patch", added.Data.GetProperty("item").GetProperty("name").GetString());
        Assert.Equal("call_patch_1", added.Data.GetProperty("item").GetProperty("call_id").GetString());
        Assert.Equal(Sentinel, added.Data.GetProperty("item").GetProperty("input").GetString());

        // The outbound request is still the B1b-1 synthetic function wire.
        using JsonDocument sent = JsonDocument.Parse(server.LastRequestBody!);
        Assert.True(sent.RootElement.GetProperty("stream").GetBoolean());
        JsonElement tool = sent.RootElement.GetProperty("tools")[0];
        Assert.Equal("function", tool.GetProperty("type").GetString());
        Assert.Equal(ApplyPatchBridgeContract.SyntheticFunctionName, tool.GetProperty("name").GetString());
    }

    [Fact]
    public async Task End_to_end_ordinary_stream_is_unchanged()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Sse(200, DeepSeekFixtures.StandardStream()));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(
                server,
                Parse("{\"model\":\"deepseek-flash\",\"input\":\"hi\",\"stream\":true}"),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectAsync(result.EventStream!);

        Assert.Equal("response.created", events[0].Type);
        Assert.Contains(events, static evt => evt.Type == "response.output_text.delta");
        Assert.Equal("response.completed", events[^1].Type);
        Assert.Equal(4, events.Count);
    }

    // --- Helpers ------------------------------------------------------------

    private static async Task<List<CanonicalEvent>> BridgeAsync(IEnumerable<CanonicalEvent> upstream, bool bridgeIsActive)
    {
        var events = new List<CanonicalEvent>();
        await foreach (CanonicalEvent evt in ApplyPatchStreamBridge.Apply(ToStream(upstream), bridgeIsActive, CancellationToken.None))
        {
            events.Add(evt);
        }

        return events;
    }

    private static async Task<List<CanonicalEvent>> CollectAsync(IAsyncEnumerable<CanonicalEvent> source)
    {
        var events = new List<CanonicalEvent>();
        await foreach (CanonicalEvent evt in source)
        {
            events.Add(evt);
        }

        return events;
    }

    private static async IAsyncEnumerable<CanonicalEvent> ToStream(IEnumerable<CanonicalEvent> events)
    {
        await Task.Yield();
        foreach (CanonicalEvent evt in events)
        {
            yield return evt;
        }
    }

    private static async IAsyncEnumerable<CanonicalEvent> CancellingUpstream(CancellationTokenSource cts)
    {
        yield return Created();
        yield return SyntheticAdded();
        yield return ArgsDelta(PatchArguments(Sentinel));
        await cts.CancelAsync();
        cts.Token.ThrowIfCancellationRequested();
        yield return CompletedNoOutput();
    }

    private static async IAsyncEnumerable<CanonicalEvent> ThrowingUpstream(Exception exception)
    {
        yield return Created();
        yield return SyntheticAdded();
        yield return ArgsDelta(PatchArguments(Sentinel));
        await Task.Yield();
        throw exception;
    }

    private static void AssertFailClosed(IReadOnlyList<CanonicalEvent> events)
    {
        AssertTerminatedWithError(events);
        Assert.DoesNotContain(events, static evt => evt.Type == "response.output_item.added");
    }

    private static void AssertTerminatedWithError(IReadOnlyList<CanonicalEvent> events, bool expectNoSentinel = true)
    {
        CanonicalEvent error = Assert.Single(events, static evt => evt.Type == "error");
        Assert.Equal(RouterErrorCode.InvalidResponse, error.Data.GetProperty("code").GetString());
        Assert.Same(error, events[^1]);
        Assert.DoesNotContain(events, static evt => evt.Type == "response.completed");
        if (expectNoSentinel)
        {
            Assert.DoesNotContain(Sentinel, string.Join('\n', events.Select(static evt => evt.Data.GetRawText())), StringComparison.Ordinal);
        }
    }

    private static void AssertNoSyntheticLeak(IReadOnlyList<CanonicalEvent> events)
    {
        foreach (CanonicalEvent evt in events)
        {
            Assert.DoesNotContain(SyntheticName, evt.Data.GetRawText(), StringComparison.Ordinal);
        }
    }

    private static CanonicalEvent Created()
        => Event("response.created", "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_stream\",\"status\":\"in_progress\",\"model\":\"deepseek-v4-pro\"}}");

    private static CanonicalEvent TextDelta(string text)
        => Event("response.output_text.delta", "{\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":" + JsonString(text) + "}");

    private static CanonicalEvent OrdinaryItemAdded()
        => Event("response.output_item.added", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"fc_weather\",\"type\":\"function_call\",\"name\":\"get_weather\",\"call_id\":\"call_weather\"}}");

    private static CanonicalEvent SyntheticAdded(string id = "fc_1", string callId = "call_patch_1", int outputIndex = 1)
        => Event(
            "response.output_item.added",
            "{\"type\":\"response.output_item.added\",\"output_index\":" + outputIndex + ",\"item\":{\"id\":" + JsonString(id)
            + ",\"type\":\"function_call\",\"name\":" + JsonString(SyntheticName) + ",\"call_id\":" + JsonString(callId) + "}}");

    private static CanonicalEvent ArgsDelta(string delta, string itemId = "fc_1")
        => Event(
            "response.function_call_arguments.delta",
            "{\"type\":\"response.function_call_arguments.delta\",\"item_id\":" + JsonString(itemId) + ",\"output_index\":1,\"delta\":" + JsonString(delta) + "}");

    private static CanonicalEvent ArgsDone(string arguments, string itemId = "fc_1")
        => Event(
            "response.function_call_arguments.done",
            "{\"type\":\"response.function_call_arguments.done\",\"item_id\":" + JsonString(itemId) + ",\"output_index\":1,\"arguments\":" + JsonString(arguments) + "}");

    private static CanonicalEvent SyntheticItemDone(string arguments, string id = "fc_1", string callId = "call_patch_1")
        => Event(
            "response.output_item.done",
            "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"id\":" + JsonString(id)
            + ",\"type\":\"function_call\",\"name\":" + JsonString(SyntheticName) + ",\"call_id\":" + JsonString(callId)
            + ",\"arguments\":" + JsonString(arguments) + "}}");

    private static CanonicalEvent SyntheticItemDoneWithoutArguments()
        => Event(
            "response.output_item.done",
            "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"id\":\"fc_1\",\"type\":\"function_call\",\"name\":" + JsonString(SyntheticName) + ",\"call_id\":\"call_patch_1\"}}");

    private static CanonicalEvent CompletedNoOutput()
        => Event("response.completed", "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_stream\",\"status\":\"completed\",\"model\":\"deepseek-v4-pro\"}}");

    private static CanonicalEvent CompletedWithOutput(params string[] items)
        => Event(
            "response.completed",
            "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_stream\",\"status\":\"completed\",\"model\":\"deepseek-v4-pro\",\"output\":["
            + string.Join(',', items)
            + "],\"usage\":{\"input_tokens\":7,\"output_tokens\":5,\"total_tokens\":12}}}");

    private static string SyntheticItemJson(string arguments, string id = "fc_1", string callId = "call_patch_1")
        => "{\"id\":" + JsonString(id) + ",\"type\":\"function_call\",\"name\":" + JsonString(SyntheticName) + ",\"call_id\":" + JsonString(callId)
            + ",\"arguments\":" + JsonString(arguments) + "}";

    private static string PatchArguments(string patch)
        => "{\"patch\":" + JsonString(patch) + "}";

    private static string JsonString(string value) => JsonSerializer.Serialize(value);

    private static string ApplyPatchToolJson()
        => "{\"type\":\"custom\",\"name\":\"apply_patch\",\"description\":\"freeform\",\"format\":{\"type\":\"grammar\",\"syntax\":\"lark\",\"definition\":\"start: /.+/\"}}";

    private static CanonicalEvent Event(string type, string json) => CanonicalEvent.Create(type, Json(json));

    private static JsonElement Json(string json)
    {
        using JsonDocument document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }

    private static CanonicalResponsesRequest Parse(string json)
    {
        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);
        Assert.Null(error);
        return request!;
    }
}
