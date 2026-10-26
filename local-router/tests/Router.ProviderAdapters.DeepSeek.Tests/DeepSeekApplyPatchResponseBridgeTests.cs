using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

/// <summary>
/// DSR7-C-FIX5-B1b-2: the DeepSeek-only non-stream apply_patch response restore.
/// A synthetic function call is restored only for an attempt that really enabled
/// the bridge, only for the exact reserved name, only from a strictly decoded one
/// property arguments object, and never partially: one malformed synthetic call
/// fails the whole response closed. Ordinary items, ordering, response metadata
/// and usage are preserved, and the patch never reaches an error message.
/// </summary>
public sealed class DeepSeekApplyPatchResponseBridgeTests
{
    private const string PatchSentinel = "PATCH_RESPONSE_DO_NOT_LOG_82731";
    private const string SyntheticName = "mm_apply_patch_bridge_v1";

    // --- Restore ------------------------------------------------------------

    [Fact]
    public void Active_bridge_restores_the_synthetic_call_into_a_custom_tool_call()
    {
        CanonicalResponsesResponse response = Response(SyntheticCall(Arguments(PatchSentinel)));

        CanonicalResponsesResponse restored = Restore(response, bridgeIsActive: true);

        CustomToolCallResponseItem item = Assert.IsType<CustomToolCallResponseItem>(Assert.Single(restored.Output));
        Assert.Equal(ApplyPatchBridgeContract.ClientToolCallType, item.Type);
        Assert.Equal(ApplyPatchBridgeContract.ApplyPatchToolName, item.Name);
        Assert.Equal(PatchSentinel, item.Input);
        Assert.Equal("fc_1", item.Id);
        Assert.Equal("call_patch_1", item.CallId);
    }

    [Fact]
    public void Restored_call_keeps_the_upstream_item_id_and_call_id()
    {
        CanonicalResponsesResponse response = Response(SyntheticCall(Arguments("p"), id: "fc_upstream_9", callId: "call_upstream_9"));

        CustomToolCallResponseItem item = Assert.IsType<CustomToolCallResponseItem>(
            Assert.Single(Restore(response, bridgeIsActive: true).Output));

        Assert.Equal("fc_upstream_9", item.Id);
        Assert.Equal("call_upstream_9", item.CallId);
    }

    [Fact]
    public void Synthetic_call_without_an_upstream_item_id_stays_null()
    {
        CanonicalResponsesResponse response = Response(SyntheticCall(Arguments("p"), id: null));

        CustomToolCallResponseItem item = Assert.IsType<CustomToolCallResponseItem>(
            Assert.Single(Restore(response, bridgeIsActive: true).Output));

        Assert.Null(item.Id);
    }

    [Fact]
    public void Response_without_a_synthetic_call_is_returned_unchanged()
    {
        CanonicalResponsesResponse response = Response(Message("hi"), OrdinaryCall("get_weather"));

        CanonicalResponsesResponse restored = Restore(response, bridgeIsActive: true);

        Assert.Same(response, restored);
    }

    [Fact]
    public void Ordinary_function_calls_are_preserved_next_to_a_synthetic_call()
    {
        FunctionCallResponseItem ordinary = OrdinaryCall("get_weather");
        CanonicalResponsesResponse response = Response(ordinary, SyntheticCall(Arguments("p")));

        CanonicalResponsesResponse restored = Restore(response, bridgeIsActive: true);

        Assert.Same(ordinary, restored.Output[0]);
        Assert.Equal("get_weather", Assert.IsType<FunctionCallResponseItem>(restored.Output[0]).Name);
        Assert.IsType<CustomToolCallResponseItem>(restored.Output[1]);
    }

    [Fact]
    public void Mixed_output_order_is_preserved()
    {
        ReasoningOutputItem reasoning = new() { Type = "reasoning", Id = "rs_1", Summary = [] };
        MessageOutputItem first = Message("first");
        FunctionCallResponseItem ordinary = OrdinaryCall("get_weather");
        MessageOutputItem second = Message("second");
        CanonicalResponsesResponse response = Response(
            reasoning,
            first,
            ordinary,
            SyntheticCall(Arguments("p")),
            second);

        CanonicalResponsesResponse restored = Restore(response, bridgeIsActive: true);

        Assert.Equal(
            ["reasoning", "message", "function_call", "custom_tool_call", "message"],
            restored.Output.Select(static item => item.Type));
        Assert.Same(reasoning, restored.Output[0]);
        Assert.Same(first, restored.Output[1]);
        Assert.Same(ordinary, restored.Output[2]);
        Assert.Same(second, restored.Output[4]);
    }

    [Fact]
    public void Multiple_synthetic_calls_are_restored_in_order()
    {
        CanonicalResponsesResponse response = Response(
            SyntheticCall(Arguments("p1"), id: "fc_1", callId: "call_1"),
            Message("between"),
            SyntheticCall(Arguments("p2"), id: "fc_2", callId: "call_2"));

        CanonicalResponsesResponse restored = Restore(response, bridgeIsActive: true);

        Assert.Equal(["custom_tool_call", "message", "custom_tool_call"], restored.Output.Select(static item => item.Type));
        CustomToolCallResponseItem first = Assert.IsType<CustomToolCallResponseItem>(restored.Output[0]);
        CustomToolCallResponseItem second = Assert.IsType<CustomToolCallResponseItem>(restored.Output[2]);
        Assert.Equal("fc_1", first.Id);
        Assert.Equal("call_1", first.CallId);
        Assert.Equal("p1", first.Input);
        Assert.Equal("fc_2", second.Id);
        Assert.Equal("call_2", second.CallId);
        Assert.Equal("p2", second.Input);
    }

    [Fact]
    public void Response_metadata_and_usage_are_preserved()
    {
        CanonicalResponsesResponse response = Response(SyntheticCall(Arguments("p"))) with
        {
            Usage = new UsageRecord
            {
                InputTokens = 11,
                OutputTokens = 7,
                TotalTokens = 18,
                CachedTokens = 5,
                ReasoningTokens = 3,
            },
        };

        CanonicalResponsesResponse restored = Restore(response, bridgeIsActive: true);

        Assert.Equal(response.Id, restored.Id);
        Assert.Equal(response.ObjectType, restored.ObjectType);
        Assert.Equal(response.CreatedAt, restored.CreatedAt);
        Assert.Equal(response.Status, restored.Status);
        Assert.Equal(response.Model, restored.Model);
        Assert.Equal(response.ErrorCode, restored.ErrorCode);
        Assert.Equal(response.ErrorMessage, restored.ErrorMessage);
        Assert.NotNull(restored.Usage);
        Assert.Equal(11, restored.Usage!.InputTokens);
        Assert.Equal(7, restored.Usage.OutputTokens);
        Assert.Equal(18, restored.Usage.TotalTokens);
        Assert.Equal(5, restored.Usage.CachedTokens);
        Assert.Equal(3, restored.Usage.ReasoningTokens);
    }

    // --- Injection defence ---------------------------------------------------

    [Fact]
    public void Synthetic_injection_without_an_active_bridge_fails_closed()
    {
        CanonicalResponsesResponse response = Response(Message("hi"), SyntheticCall(Arguments(PatchSentinel)));

        Result<CanonicalResponsesResponse, RouterError> restored = ApplyPatchResponseBridge.Restore(
            response,
            bridgeIsActive: false);

        Assert.Null(restored.Value);
        Assert.NotNull(restored.Error);
        Assert.Equal(RouterErrorCode.InvalidResponse, restored.Error!.Code);
    }

    [Theory]
    [InlineData("MM_APPLY_PATCH_BRIDGE_V1")]
    [InlineData("mm_apply_patch_bridge_v1 ")]
    [InlineData(" mm_apply_patch_bridge_v1")]
    [InlineData("mm_apply_patch_bridge_v1x")]
    [InlineData("xmm_apply_patch_bridge_v1")]
    [InlineData("mm_apply_patch_bridge")]
    public void Non_exact_synthetic_names_stay_ordinary_function_calls(string name)
    {
        FunctionCallResponseItem candidate = new()
        {
            Type = "function_call",
            Id = "fc_1",
            CallId = "call_1",
            Name = name,
            Arguments = Arguments(PatchSentinel),
        };
        CanonicalResponsesResponse response = Response(candidate);

        // Neither restored (active bridge) nor rejected (inactive bridge).
        CanonicalResponsesResponse restored = Restore(response, bridgeIsActive: true);
        Assert.Same(candidate, Assert.Single(restored.Output));
        Assert.Same(response, Restore(response, bridgeIsActive: false));
    }

    // --- Strict argument decoder --------------------------------------------

    [Theory]
    [InlineData("""{"patch":""}""")]
    [InlineData("""{"patch":"*** Begin Patch\n*** End Patch"}""")]
    [InlineData("""{"patch":"PATCH_RESPONSE_DO_NOT_LOG_82731"}""")]
    public void Valid_single_patch_string_is_restored(string arguments)
    {
        CanonicalResponsesResponse restored = Restore(Response(SyntheticCall(arguments)), bridgeIsActive: true);

        Assert.IsType<CustomToolCallResponseItem>(Assert.Single(restored.Output));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("""{"patch":null}""")]
    [InlineData("""{"patch":123}""")]
    [InlineData("""{"patch":true}""")]
    [InlineData("""{"patch":[]}""")]
    [InlineData("""{"patch":{}}""")]
    [InlineData("""{"patch":"x","extra":"y"}""")]
    [InlineData("""{"extra":"y","patch":"x"}""")]
    [InlineData("""{"patch":"a","patch":"b"}""")]
    [InlineData("""{"Patch":"x"}""")]
    [InlineData("""[{"patch":"x"}]""")]
    [InlineData("\"x\"")]
    [InlineData("not json")]
    [InlineData("")]
    public void Malformed_arguments_fail_closed(string arguments)
    {
        Result<CanonicalResponsesResponse, RouterError> restored = ApplyPatchResponseBridge.Restore(
            Response(SyntheticCall(arguments)),
            bridgeIsActive: true);

        Assert.Null(restored.Value);
        Assert.Equal(RouterErrorCode.InvalidResponse, restored.Error!.Code);
    }

    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData("\t")]
    public void Empty_or_whitespace_call_id_fails_closed(string callId)
    {
        Result<CanonicalResponsesResponse, RouterError> restored = ApplyPatchResponseBridge.Restore(
            Response(SyntheticCall(Arguments("p"), callId: callId)),
            bridgeIsActive: true);

        Assert.Null(restored.Value);
        Assert.Equal(RouterErrorCode.InvalidResponse, restored.Error!.Code);
    }

    [Fact]
    public void Patch_at_the_bound_is_restored_and_one_over_fails_closed()
    {
        string atBound = new('x', ApplyPatchRequestBridge.MaxPatchInputLength);
        string overBound = new('x', ApplyPatchRequestBridge.MaxPatchInputLength + 1);

        CustomToolCallResponseItem restored = Assert.IsType<CustomToolCallResponseItem>(
            Assert.Single(Restore(Response(SyntheticCall(Arguments(atBound))), bridgeIsActive: true).Output));
        Assert.Equal(atBound.Length, restored.Input.Length);

        Result<CanonicalResponsesResponse, RouterError> oversized = ApplyPatchResponseBridge.Restore(
            Response(SyntheticCall(Arguments(overBound))),
            bridgeIsActive: true);
        Assert.Null(oversized.Value);
        Assert.Equal(RouterErrorCode.InvalidResponse, oversized.Error!.Code);
    }

    // --- Whole-response contract --------------------------------------------

    [Fact]
    public void One_malformed_synthetic_call_rejects_the_whole_response()
    {
        CanonicalResponsesResponse response = Response(
            Message("before"),
            SyntheticCall(Arguments("good"), id: "fc_1", callId: "call_1"),
            SyntheticCall("""{"patch":123}""", id: "fc_2", callId: "call_2"),
            Message("after"));

        Result<CanonicalResponsesResponse, RouterError> restored = ApplyPatchResponseBridge.Restore(
            response,
            bridgeIsActive: true);

        Assert.Null(restored.Value);
        Assert.Equal(RouterErrorCode.InvalidResponse, restored.Error!.Code);
    }

    [Fact]
    public void An_ambiguous_patch_never_degrades_into_an_ordinary_function_call()
    {
        CanonicalResponsesResponse response = Response(SyntheticCall("""{"patch":null}"""));

        Result<CanonicalResponsesResponse, RouterError> restored = ApplyPatchResponseBridge.Restore(
            response,
            bridgeIsActive: true);

        Assert.Null(restored.Value);
    }

    [Fact]
    public void Error_message_never_carries_the_patch_or_the_raw_arguments()
    {
        Result<CanonicalResponsesResponse, RouterError> restored = ApplyPatchResponseBridge.Restore(
            Response(SyntheticCall("""{"patch":"PATCH_RESPONSE_DO_NOT_LOG_82731","extra":1}""")),
            bridgeIsActive: true);

        string json = restored.Error!.ToJson();
        Assert.DoesNotContain(PatchSentinel, json, StringComparison.Ordinal);
        Assert.DoesNotContain("extra", json, StringComparison.Ordinal);
        Assert.DoesNotContain("arguments", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Streamed_and_failed_results_are_returned_untouched()
    {
        ProviderAdapterResult stream = ProviderAdapterResult.Stream(EmptyStream());
        ProviderAdapterResult failure = ProviderAdapterResult.Failed(ProviderAdapterErrors.InvalidResponse());

        Assert.Same(stream, ApplyPatchResponseBridge.Apply(stream, bridgeIsActive: true));
        Assert.Same(stream, ApplyPatchResponseBridge.Apply(stream, bridgeIsActive: false));
        Assert.Same(failure, ApplyPatchResponseBridge.Apply(failure, bridgeIsActive: true));
    }

    // --- Fake transport end-to-end ------------------------------------------

    [Fact]
    public async Task End_to_end_restore_closes_the_non_stream_loop()
    {
        await using FakeProviderServer server = await StartServerAsync(SyntheticCallResponseJson(PatchSentinel));
        CanonicalResponsesRequest request = ParseApplyPatchRequest();

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, request),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);

        // Return half: the client sees the freeform tool call, never the synthetic name.
        CustomToolCallResponseItem item = Assert.IsType<CustomToolCallResponseItem>(Assert.Single(result.Response!.Output));
        Assert.Equal("custom_tool_call", item.Type);
        Assert.Equal("apply_patch", item.Name);
        Assert.Equal("fc_1", item.Id);
        Assert.Equal("call_patch_1", item.CallId);
        Assert.Equal(PatchSentinel, item.Input);

        // Outbound half: the upstream request is still the B1b-1 synthetic wire.
        string body = System.Text.Encoding.UTF8.GetString(server.LastRequestBody!);
        Assert.Contains(ApplyPatchBridgeContract.SyntheticFunctionName, body, StringComparison.Ordinal);
        Assert.DoesNotContain("\"custom\"", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Round_trip_call_id_survives_the_restore_and_the_next_replay()
    {
        await using FakeProviderServer server = await StartServerAsync(SyntheticCallResponseJson(PatchSentinel));
        ProviderAdapterResult turnOne = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, ParseApplyPatchRequest()),
            CancellationToken.None);

        CustomToolCallResponseItem restored = Assert.IsType<CustomToolCallResponseItem>(
            Assert.Single(turnOne.Response!.Output));

        // Turn 2: the client replays the restored call plus its result.
        var turnTwo = new CanonicalResponsesRequest
        {
            Model = "deepseek-flash",
            Input =
            [
                new CustomToolCallInputItem
                {
                    Type = ApplyPatchBridgeContract.ClientToolCallType,
                    CallId = restored.CallId,
                    Name = ApplyPatchBridgeContract.ApplyPatchToolName,
                    Input = restored.Input,
                },
                new CustomToolCallOutputInputItem
                {
                    Type = ApplyPatchBridgeContract.ClientToolCallOutputType,
                    CallId = restored.CallId,
                    Output = Json("\"ok\""),
                },
            ],
            ApplyPatchTool = ApplyPatchDefinition(),
        };

        ProviderAdapterResult turnTwoResult = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, turnTwo),
            CancellationToken.None);

        turnTwoResult.Validate();

        using JsonDocument replay = JsonDocument.Parse(server.LastRequestBody!);
        JsonElement input = replay.RootElement.GetProperty("input");
        JsonElement call = input[0];
        JsonElement output = input[1];
        Assert.Equal("function_call", call.GetProperty("type").GetString());
        Assert.Equal(ApplyPatchBridgeContract.SyntheticFunctionName, call.GetProperty("name").GetString());
        Assert.Equal(restored.CallId, call.GetProperty("call_id").GetString());
        using JsonDocument arguments = JsonDocument.Parse(call.GetProperty("arguments").GetString()!);
        Assert.Equal(PatchSentinel, arguments.RootElement.GetProperty("patch").GetString());
        Assert.Equal("function_call_output", output.GetProperty("type").GetString());
        Assert.Equal(restored.CallId, output.GetProperty("call_id").GetString());
    }

    [Fact]
    public async Task Synthetic_injection_without_an_active_bridge_fails_closed_end_to_end()
    {
        await using FakeProviderServer server = await StartServerAsync(SyntheticCallResponseJson(PatchSentinel));
        CanonicalResponsesRequest request = Parse(
            """{"model":"deepseek-flash","input":"hi","tools":[{"type":"function","name":"get_weather","parameters":{"type":"object","properties":{}}}]}""");

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, request),
            CancellationToken.None);

        result.Validate();
        Assert.Null(result.Response);
        Assert.NotNull(result.Error);
        Assert.Equal(RouterErrorCode.InvalidResponse, result.Error!.Code);
    }

    [Fact]
    public async Task Ordinary_function_call_responses_are_unchanged_end_to_end()
    {
        await using FakeProviderServer server = await StartServerAsync(
            """
            {"id":"resp_plain","object":"response","created_at":1752000000,"status":"completed","model":"deepseek-v4-pro","output":[{"id":"fc_plain","type":"function_call","call_id":"call_plain","name":"get_weather","arguments":"{\"city\":\"shanghai\"}"}],"usage":{"input_tokens":7,"output_tokens":5,"total_tokens":12}}
            """);
        CanonicalResponsesRequest request = Parse(ApplyPatchRequestJson());

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, request),
            CancellationToken.None);

        result.Validate();
        FunctionCallResponseItem item = Assert.IsType<FunctionCallResponseItem>(Assert.Single(result.Response!.Output));
        Assert.Equal("get_weather", item.Name);
        Assert.Equal("call_plain", item.CallId);
        Assert.Equal("""{"city":"shanghai"}""", item.Arguments);
    }

    // --- Helpers ------------------------------------------------------------

    private static CanonicalResponsesResponse Response(params ResponseOutputItem[] output)
        => new()
        {
            Id = "resp_patch",
            ObjectType = "response",
            CreatedAt = 1_752_000_000,
            Status = "completed",
            Model = "deepseek-v4-pro",
            Output = output,
        };

    private static CanonicalResponsesResponse Restore(CanonicalResponsesResponse response, bool bridgeIsActive)
    {
        Result<CanonicalResponsesResponse, RouterError> restored = ApplyPatchResponseBridge.Restore(response, bridgeIsActive);

        Assert.Null(restored.Error);
        return restored.Value!;
    }

    private static FunctionCallResponseItem SyntheticCall(string arguments, string? id = "fc_1", string callId = "call_patch_1")
        => new()
        {
            Type = "function_call",
            Id = id,
            CallId = callId,
            Name = SyntheticName,
            Arguments = arguments,
        };

    private static FunctionCallResponseItem OrdinaryCall(string name)
        => new()
        {
            Type = "function_call",
            Id = "fc_ordinary",
            CallId = "call_ordinary",
            Name = name,
            Arguments = """{"city":"shanghai"}""",
        };

    private static MessageOutputItem Message(string text)
        => new()
        {
            Type = "message",
            Id = "msg_1",
            Role = "assistant",
            Content = [new OutputTextPart { Type = "output_text", Text = text }],
        };

    private static string Arguments(string patch)
        => JsonSerializer.Serialize(new Dictionary<string, string>(StringComparer.Ordinal) { ["patch"] = patch });

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

    private static ApplyPatchCustomToolDefinition ApplyPatchDefinition()
        => new()
        {
            Name = ApplyPatchBridgeContract.ApplyPatchToolName,
            Description = "freeform",
            FormatType = "grammar",
            FormatSyntax = "lark",
            FormatDefinition = "start: /.+/",
        };

    private static string ApplyPatchRequestJson()
        => "{\"model\":\"deepseek-flash\",\"input\":\"hi\",\"tools\":[{\"type\":\"custom\",\"name\":\"apply_patch\",\"description\":\"freeform\",\"format\":{\"type\":\"grammar\",\"syntax\":\"lark\",\"definition\":\"start: /.+/\"}}]}";

    private static CanonicalResponsesRequest ParseApplyPatchRequest()
        => Parse(ApplyPatchRequestJson());

    private static string SyntheticCallResponseJson(string patch)
        => """
            {"id":"resp_patch","object":"response","created_at":1752000000,"status":"completed","model":"deepseek-v4-pro","output":[{"id":"fc_1","type":"function_call","call_id":"call_patch_1","name":"mm_apply_patch_bridge_v1","arguments":"{\"patch\":\"PATCH_RESPONSE_DO_NOT_LOG_82731\"}"}],"usage":{"input_tokens":7,"output_tokens":5,"total_tokens":12,"input_tokens_details":{"cached_tokens":2},"output_tokens_details":{"reasoning_tokens":1}}}
            """.Replace("PATCH_RESPONSE_DO_NOT_LOG_82731", patch, StringComparison.Ordinal);

    private static async IAsyncEnumerable<CanonicalEvent> EmptyStream()
    {
        await Task.Yield();
        yield break;
    }

    private static async Task<FakeProviderServer> StartServerAsync(string body)
    {
        var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(new FakeProviderScenario
        {
            StatusCode = 200,
            Body = System.Text.Encoding.UTF8.GetBytes(body),
            ContentType = "application/json",
        });
        return server;
    }
}
