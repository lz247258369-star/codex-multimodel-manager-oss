using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Router.ProviderAdapters.Responses;
using Router.Registries;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

/// <summary>
/// DSR7-C-FIX5-B1b-1: the DeepSeek-only apply_patch request transform and replay
/// bridge. The bridge is eligible only for the direct DeepSeek provider route
/// with the declared compatibility bridge capability, a route tools capability
/// and a non-streaming request. The canonical request is never mutated, the
/// synthetic function is appended last, ordinary function tools and ordinary
/// function calls keep their order and semantics, the patch is serialized by the
/// JSON serializer, and every unprovable replay shape fails closed. The Router
/// never executes a patch and never forwards the freeform grammar.
/// </summary>
public sealed class DeepSeekApplyPatchRequestBridgeTests
{
    private const string GrammarSentinel = "DO_NOT_FORWARD_GRAMMAR_98765";
    private const string PatchSentinel = "*** Begin Patch\n*** Update File: a.txt\n*** End Patch";

    private const string ApplyPatchToolJson =
        """{"type":"custom","name":"apply_patch","description":"freeform","format":{"type":"grammar","syntax":"lark","definition":"DO_NOT_FORWARD_GRAMMAR_98765"}}""";

    private const string OrdinaryFunctionToolJson =
        """{"type":"function","name":"f","description":"plain","parameters":{"type":"object","properties":{}},"strict":true}""";

    private static readonly CapabilitySet RouteWithoutTools = CapabilitySet.From(
        ["text", "streaming", "reasoning", "usage", "cancellation"]);

    // --- Eligibility --------------------------------------------------------

    [Fact]
    public async Task Bridge_requires_the_declared_compatibility_bridge_capability()
    {
        await using FakeProviderServer server = new();
        ProviderAdapterInvocation invocation = Invocation(server, ApplyPatchRequest());

        Assert.False(ApplyPatchRequestBridge.IsEligible(invocation, CapabilitySet.Empty));
        Assert.True(ApplyPatchRequestBridge.IsEligible(invocation, DeepSeekCapabilities.SupportedCompatibilityBridges));
        Assert.True(
            DeepSeekCapabilities.SupportedCompatibilityBridges.Contains(ApplyPatchBridgeContract.CompatBridgeCapability),
            "the provider must declare the explicit bridge capability");
    }

    [Fact]
    public async Task Bridge_requires_the_route_tools_capability()
    {
        await using FakeProviderServer server = new();
        ProviderAdapterInvocation eligible = Invocation(server, ApplyPatchRequest());
        ProviderAdapterInvocation withoutTools = eligible with
        {
            Route = eligible.Route with { EffectiveCapabilities = RouteWithoutTools },
        };

        Assert.True(ApplyPatchRequestBridge.IsEligible(eligible, DeepSeekCapabilities.SupportedCompatibilityBridges));
        Assert.False(ApplyPatchRequestBridge.IsEligible(withoutTools, DeepSeekCapabilities.SupportedCompatibilityBridges));
    }

    [Fact]
    public async Task Bridge_requires_a_deepseek_provider_route()
    {
        await using FakeProviderServer server = new();
        ProviderAdapterInvocation eligible = Invocation(server, ApplyPatchRequest());
        ProviderAdapterInvocation foreignRoute = eligible with
        {
            Route = eligible.Route with
            {
                ProviderRoute = eligible.Route.ProviderRoute with { ProviderId = "mm_mimo" },
            },
        };

        Assert.False(ApplyPatchRequestBridge.IsEligible(foreignRoute, DeepSeekCapabilities.SupportedCompatibilityBridges));
    }

    [Fact]
    public async Task Bridge_rejects_streaming_before_any_transport_call()
    {
        await using FakeProviderServer server = await StartServerAsync();
        CanonicalResponsesRequest request = Parse(
            "{\"model\":\"deepseek-flash\",\"input\":\"hi\",\"stream\":true,\"tools\":[" + ApplyPatchToolJson + "]}");

        // DSR7-C-FIX5-B2 promotes the streaming path, so the remaining pre-transport
        // rejection is a route that cannot stream at all: the request still needs
        // tools, but the route must not declare streaming.
        ProviderAdapterInvocation invocation = Invocation(server, request);
        invocation = invocation with
        {
            Route = invocation.Route with
            {
                EffectiveCapabilities = CapabilitySet.From(["text", "reasoning", "tools", "usage", "cancellation"]),
            },
        };

        Assert.False(ApplyPatchRequestBridge.IsEligible(invocation, DeepSeekCapabilities.SupportedCompatibilityBridges));

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(invocation, CancellationToken.None);

        Assert.NotNull(result.Error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, result.Error!.Code);
        Assert.Null(result.Response);
        Assert.Null(server.LastRequestBody);
    }

    // --- Synthetic function -------------------------------------------------

    [Fact]
    public async Task Eligible_request_sends_the_synthetic_function_appended_last()
    {
        await using FakeProviderServer server = await StartServerAsync();
        CanonicalResponsesRequest request = Parse(
            "{\"model\":\"deepseek-flash\",\"input\":\"hi\",\"tools\":["
            + OrdinaryFunctionToolJson
            + ","
            + ApplyPatchToolJson
            + "]}");

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            Invocation(server, request),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);

        JsonElement tools = JsonDocument.Parse(server.LastRequestBody!).RootElement.GetProperty("tools");
        Assert.Equal(2, tools.GetArrayLength());

        // The ordinary function tool keeps its position and its semantics.
        Assert.Equal("f", tools[0].GetProperty("name").GetString());
        Assert.Equal("function", tools[0].GetProperty("type").GetString());
        Assert.Equal("plain", tools[0].GetProperty("description").GetString());

        // The synthetic function is the Router-owned identity, appended last.
        Assert.Equal("function", tools[1].GetProperty("type").GetString());
        Assert.Equal(ApplyPatchBridgeContract.SyntheticFunctionName, tools[1].GetProperty("name").GetString());
        JsonElement parameters = tools[1].GetProperty("parameters");
        Assert.Equal("object", parameters.GetProperty("type").GetString());
        Assert.Equal("string", parameters.GetProperty("properties").GetProperty("patch").GetProperty("type").GetString());
        Assert.Equal("patch", parameters.GetProperty("required")[0].GetString());
        Assert.False(parameters.GetProperty("additionalProperties").GetBoolean());
    }

    [Fact]
    public void Ordinary_function_tools_are_preserved_in_order()
    {
        CanonicalResponsesRequest request = ApplyPatchRequest(
            tools: [Function("a"), Function("b")]);

        CanonicalResponsesRequest bridged = CreateBridged(request);

        Assert.Equal(["a", "b", ApplyPatchBridgeContract.SyntheticFunctionName], bridged.Tools.Select(static t => t.Name));
    }

    [Fact]
    public void The_freeform_grammar_definition_is_never_forwarded()
    {
        CanonicalResponsesRequest bridged = CreateBridged(ApplyPatchRequest());

        string wire = System.Text.Encoding.UTF8.GetString(ResponsesProviderCodec.EncodeRequest(bridged));

        Assert.DoesNotContain(GrammarSentinel, wire, StringComparison.Ordinal);
        Assert.DoesNotContain("\"custom\"", wire, StringComparison.Ordinal);
        Assert.DoesNotContain("freeform", wire, StringComparison.Ordinal);
        Assert.DoesNotContain("grammar", wire, StringComparison.Ordinal);
    }

    // --- Replay -------------------------------------------------------------

    [Fact]
    public void Custom_tool_call_replays_as_a_function_call_with_serialized_arguments()
    {
        CanonicalResponsesRequest request = ApplyPatchRequest(
            input: [UserMessage("hi"), CustomCall("call_1", PatchSentinel)]);

        CanonicalResponsesRequest bridged = CreateBridged(request);

        FunctionCallInputItem replayed = Assert.IsType<FunctionCallInputItem>(bridged.Input[1]);
        Assert.Equal("function_call", replayed.Type);
        Assert.Equal("call_1", replayed.CallId);
        Assert.Equal(ApplyPatchBridgeContract.SyntheticFunctionName, replayed.Name);

        // The arguments are serializer output, never hand-built JSON.
        using JsonDocument arguments = JsonDocument.Parse(replayed.Arguments);
        Assert.Equal(PatchSentinel, arguments.RootElement.GetProperty("patch").GetString());
        Assert.Equal("patch", Assert.Single(arguments.RootElement.EnumerateObject()).Name);

        // The message item before the call is untouched.
        Assert.IsType<MessageInputItem>(bridged.Input[0]);
    }

    [Fact]
    public void Custom_tool_call_output_replays_as_a_function_call_output()
    {
        CanonicalResponsesRequest stringOutput = ApplyPatchRequest(
            input: [CustomCall("call_1", "p"), CustomOutput("call_1", Json("\"done\""))]);
        CanonicalResponsesRequest structuredOutput = ApplyPatchRequest(
            input: [CustomCall("call_1", "p"), CustomOutput("call_1", Json("""{"success":true,"detail":null}"""))]);

        FunctionCallOutputItem replayedString = Assert.IsType<FunctionCallOutputItem>(CreateBridged(stringOutput).Input[1]);
        FunctionCallOutputItem replayedStructured = Assert.IsType<FunctionCallOutputItem>(CreateBridged(structuredOutput).Input[1]);

        Assert.Equal("function_call_output", replayedString.Type);
        Assert.Equal("call_1", replayedString.CallId);
        Assert.Equal("done", replayedString.Output);

        Assert.Equal("call_1", replayedStructured.CallId);
        Assert.Equal("""{"success":true,"detail":null}""", replayedStructured.Output);
    }

    [Fact]
    public void Multiple_replayed_calls_keep_their_original_order_and_pairing()
    {
        CanonicalResponsesRequest request = ApplyPatchRequest(
            input:
            [
                CustomCall("call_1", "p1"),
                CustomOutput("call_1", Json("\"ok\"")),
                UserMessage("again"),
                CustomCall("call_2", "p2"),
                CustomOutput("call_2", Json("\"ok\"")),
            ]);

        CanonicalResponsesRequest bridged = CreateBridged(request);

        Assert.Equal(
            ["function_call", "function_call_output", "message", "function_call", "function_call_output"],
            bridged.Input.Select(static item => item.Type));
        Assert.Equal("call_1", Assert.IsType<FunctionCallInputItem>(bridged.Input[0]).CallId);
        Assert.Equal("call_2", Assert.IsType<FunctionCallInputItem>(bridged.Input[3]).CallId);
    }

    [Fact]
    public void Ordinary_function_calls_and_outputs_are_unchanged()
    {
        var functionCall = new FunctionCallInputItem
        {
            Type = "function_call",
            CallId = "call_plain",
            Name = "f",
            Arguments = """{"city":"shanghai"}""",
        };

        var functionOutput = new FunctionCallOutputItem
        {
            Type = "function_call_output",
            CallId = "call_plain",
            Output = """{"temp":22}""",
        };

        CanonicalResponsesRequest bridged = CreateBridged(
            ApplyPatchRequest(input: [functionCall, functionOutput, CustomCall("call_1", "p")]));

        Assert.Same(functionCall, bridged.Input[0]);
        Assert.Same(functionOutput, bridged.Input[1]);
        Assert.IsType<FunctionCallInputItem>(bridged.Input[2]);
    }

    // --- Immutability -------------------------------------------------------

    [Fact]
    public void The_transform_is_provider_local_and_never_mutates_the_canonical_request()
    {
        CanonicalResponsesRequest request = ApplyPatchRequest(
            input: [UserMessage("hi"), CustomCall("call_1", PatchSentinel)]);

        CanonicalResponsesRequest bridged = CreateBridged(request);

        Assert.NotSame(request, bridged);
        Assert.NotNull(request.ApplyPatchTool);
        Assert.Equal(GrammarSentinel, request.ApplyPatchTool!.FormatDefinition);
        Assert.Empty(request.Tools);
        Assert.IsType<CustomToolCallInputItem>(request.Input[1]);

        Assert.Null(bridged.ApplyPatchTool);
        Assert.Single(bridged.Tools);
        Assert.IsType<FunctionCallInputItem>(bridged.Input[1]);
    }

    [Fact]
    public void A_request_without_a_freeform_tool_is_returned_unchanged()
    {
        var request = new CanonicalResponsesRequest
        {
            Model = "deepseek-flash",
            Input = [UserMessage("hi")],
        };

        CanonicalResponsesRequest bridged = CreateBridged(request);

        Assert.Same(request, bridged);
    }

    // --- Fail-closed replay validation --------------------------------------

    [Fact]
    public void Reserved_synthetic_name_collision_fails_closed()
    {
        CanonicalResponsesRequest request = ApplyPatchRequest(
            tools: [Function(ApplyPatchBridgeContract.SyntheticFunctionName)]);

        AssertFailClosed(request, RouterErrorCode.InvalidRequest, "tools");
    }

    [Fact]
    public void Replayed_function_call_may_not_claim_the_reserved_synthetic_name()
    {
        var forged = new FunctionCallInputItem
        {
            Type = "function_call",
            CallId = "call_1",
            Name = ApplyPatchBridgeContract.SyntheticFunctionName,
            Arguments = "{}",
        };

        AssertFailClosed(ApplyPatchRequest(input: [forged]), RouterErrorCode.InvalidRequest, "input[0].name");
    }

    [Fact]
    public void Orphan_custom_tool_output_fails_closed()
    {
        AssertFailClosed(
            ApplyPatchRequest(input: [CustomOutput("call_missing", Json("\"ok\""))]),
            RouterErrorCode.InvalidRequest,
            "input[0].call_id");
    }

    [Fact]
    public void An_output_before_its_matching_call_fails_closed()
    {
        AssertFailClosed(
            ApplyPatchRequest(input: [CustomOutput("call_1", Json("\"ok\"")), CustomCall("call_1", "p")]),
            RouterErrorCode.InvalidRequest,
            "input[0].call_id");
    }

    [Fact]
    public void Duplicate_custom_call_id_fails_closed()
    {
        AssertFailClosed(
            ApplyPatchRequest(input: [CustomCall("call_1", "p"), CustomCall("call_1", "q")]),
            RouterErrorCode.InvalidRequest,
            "input[1].call_id");
    }

    [Fact]
    public void Duplicate_custom_tool_output_fails_closed()
    {
        AssertFailClosed(
            ApplyPatchRequest(
                input:
                [
                    CustomCall("call_1", "p"),
                    CustomOutput("call_1", Json("\"ok\"")),
                    CustomOutput("call_1", Json("\"ok\"")),
                ]),
            RouterErrorCode.InvalidRequest,
            "input[2].call_id");
    }

    [Fact]
    public void Unknown_freeform_tool_call_fails_closed()
    {
        var foreign = new CustomToolCallInputItem
        {
            Type = "custom_tool_call",
            CallId = "call_1",
            Name = "other_tool",
            Input = "p",
        };

        AssertFailClosed(ApplyPatchRequest(input: [foreign]), RouterErrorCode.UnsupportedCapability, "input[0].type");
    }

    [Fact]
    public void Oversized_patch_fails_closed()
    {
        string oversized = new('x', ApplyPatchRequestBridge.MaxPatchInputLength + 1);

        AssertFailClosed(
            ApplyPatchRequest(input: [CustomCall("call_1", oversized)]),
            RouterErrorCode.InvalidRequest,
            "input[0].input");
    }

    [Fact]
    public void A_malformed_freeform_definition_identity_fails_closed()
    {
        var request = new CanonicalResponsesRequest
        {
            Model = "deepseek-flash",
            Input = [UserMessage("hi")],
            ApplyPatchTool = new ApplyPatchCustomToolDefinition
            {
                Name = "other_tool",
                FormatType = "grammar",
                FormatSyntax = "lark",
                FormatDefinition = GrammarSentinel,
            },
        };

        AssertFailClosed(request, RouterErrorCode.UnsupportedCapability, null);
    }

    [Fact]
    public async Task Bridge_requires_the_route_streaming_capability_for_a_streaming_request()
    {
        await using FakeProviderServer server = new();
        CanonicalResponsesRequest request = ApplyPatchRequest() with { Stream = true };
        ProviderAdapterInvocation eligible = Invocation(server, request);
        ProviderAdapterInvocation withoutStreaming = eligible with
        {
            Route = eligible.Route with
            {
                EffectiveCapabilities = CapabilitySet.From(["text", "reasoning", "tools", "usage", "cancellation"]),
            },
        };

        Assert.True(ApplyPatchRequestBridge.IsEligible(eligible, DeepSeekCapabilities.SupportedCompatibilityBridges));
        Assert.False(ApplyPatchRequestBridge.IsEligible(withoutStreaming, DeepSeekCapabilities.SupportedCompatibilityBridges));
    }

    [Fact]
    public void Streaming_request_reuses_the_same_provider_local_transform()
    {
        CanonicalResponsesRequest request = ApplyPatchRequest(
            input: [UserMessage("hi"), CustomCall("call_1", PatchSentinel)]) with { Stream = true };

        CanonicalResponsesRequest bridged = CreateBridged(request);

        Assert.True(bridged.Stream);
        Assert.Null(bridged.ApplyPatchTool);
        Assert.Equal(ApplyPatchBridgeContract.SyntheticFunctionName, Assert.Single(bridged.Tools).Name);
        Assert.Equal(ApplyPatchBridgeContract.SyntheticFunctionName, Assert.IsType<FunctionCallInputItem>(bridged.Input[1]).Name);
        Assert.NotNull(request.ApplyPatchTool);
    }

    [Fact]
    public void Named_tool_choice_for_the_freeform_tool_fails_closed()
    {
        CanonicalResponsesRequest request = ApplyPatchRequest(
            toolChoice: new ToolChoice { Kind = ToolChoiceKind.Function, FunctionName = ApplyPatchBridgeContract.ApplyPatchToolName });

        AssertFailClosed(request, RouterErrorCode.UnsupportedCapability, "tool_choice.name");
    }

    [Fact]
    public void Preserved_tool_choice_is_never_rewritten()
    {
        CanonicalResponsesRequest request = ApplyPatchRequest(
            toolChoice: new ToolChoice { Kind = ToolChoiceKind.Function, FunctionName = "f" });

        CanonicalResponsesRequest bridged = CreateBridged(request);

        Assert.NotNull(bridged.ToolChoice);
        Assert.Equal(ToolChoiceKind.Function, bridged.ToolChoice!.Kind);
        Assert.Equal("f", bridged.ToolChoice.FunctionName);
    }

    // --- Helpers ------------------------------------------------------------

    private static CanonicalResponsesRequest ApplyPatchRequest(
        IReadOnlyList<ResponsesInputItem>? input = null,
        IReadOnlyList<FunctionToolDefinition>? tools = null,
        ToolChoice? toolChoice = null)
        => new()
        {
            Model = "deepseek-flash",
            Input = input ?? [UserMessage("hi")],
            Tools = tools ?? [],
            ToolChoice = toolChoice,
            ApplyPatchTool = new ApplyPatchCustomToolDefinition
            {
                Name = ApplyPatchBridgeContract.ApplyPatchToolName,
                Description = "freeform",
                FormatType = "grammar",
                FormatSyntax = "lark",
                FormatDefinition = GrammarSentinel,
            },
        };

    private static CanonicalResponsesRequest CreateBridged(CanonicalResponsesRequest request)
    {
        Result<CanonicalResponsesRequest, RouterError> bridged = ApplyPatchRequestBridge.CreateProviderLocalRequest(request);

        Assert.Null(bridged.Error);
        return bridged.Value!;
    }

    private static void AssertFailClosed(CanonicalResponsesRequest request, string expectedCode, string? expectedParam)
    {
        Result<CanonicalResponsesRequest, RouterError> bridged = ApplyPatchRequestBridge.CreateProviderLocalRequest(request);

        Assert.Null(bridged.Value);
        Assert.NotNull(bridged.Error);
        Assert.Equal(expectedCode, bridged.Error!.Code);
        Assert.Equal(expectedParam, bridged.Error.Param);
    }

    private static MessageInputItem UserMessage(string text)
        => new()
        {
            Type = "message",
            Role = "user",
            Content = [new TextContentPart { Type = "input_text", Text = text }],
        };

    private static FunctionToolDefinition Function(string name)
        => new()
        {
            Name = name,
            Description = "plain",
            Parameters = Json("""{"type":"object","properties":{}}"""),
            Strict = true,
        };

    private static CustomToolCallInputItem CustomCall(string callId, string patch)
        => new()
        {
            Type = ApplyPatchBridgeContract.ClientToolCallType,
            CallId = callId,
            Name = ApplyPatchBridgeContract.ApplyPatchToolName,
            Input = patch,
        };

    private static CustomToolCallOutputInputItem CustomOutput(string callId, JsonElement output)
        => new()
        {
            Type = ApplyPatchBridgeContract.ClientToolCallOutputType,
            CallId = callId,
            Output = output,
        };

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

    private static ProviderAdapterInvocation Invocation(FakeProviderServer server, CanonicalResponsesRequest request)
        => DeepSeekInvocationFactory.CreateInvocation(server, request);

    private static async Task<FakeProviderServer> StartServerAsync()
    {
        var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(new FakeProviderScenario
        {
            StatusCode = 200,
            Body = System.Text.Encoding.UTF8.GetBytes(DeepSeekFixtures.NonStreamJson()),
            ContentType = "application/json",
        });
        return server;
    }
}
