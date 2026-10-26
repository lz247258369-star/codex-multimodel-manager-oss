using System.Text.Json;
using Router.Core.Errors;
using Xunit;

namespace Router.ClientAdapters.Responses.Tests;

/// <summary>
/// DSR7-C-FIX5-A: the client contract for Codex's freeform apply_patch tool.
/// Only the exact custom/apply_patch identity is representable; unknown custom
/// tools keep the FIX4 fail-closed diagnostics, a malformed apply_patch shape is
/// an invalid request, the Router-owned synthetic name is reserved, and the two
/// replayed custom item shapes are structurally strict.
/// </summary>
public sealed class ApplyPatchContractTests
{
    private const string ValidApplyPatchTool =
        """{"type":"custom","name":"apply_patch","description":"freeform","format":{"type":"grammar","syntax":"lark","definition":"start: /.+/"}}""";

    private static RouterError? Parse(string toolsJson, out CanonicalResponsesRequest? request)
        => ResponsesRequestParser.TryParse("{\"model\":\"gpt-test\",\"input\":\"hi\",\"tools\":[" + toolsJson + "]}", out request);

    [Fact]
    public void Valid_apply_patch_tool_becomes_a_distinct_canonical_type()
    {
        RouterError? error = Parse(ValidApplyPatchTool, out CanonicalResponsesRequest? request);

        Assert.Null(error);
        Assert.NotNull(request);
        Assert.Empty(request!.Tools);
        ApplyPatchCustomToolDefinition applyPatch = Assert.IsType<ApplyPatchCustomToolDefinition>(request.ApplyPatchTool);
        Assert.Equal("apply_patch", applyPatch.Name);
        Assert.Equal("freeform", applyPatch.Description);
        Assert.Equal("grammar", applyPatch.FormatType);
        Assert.Equal("lark", applyPatch.FormatSyntax);
        Assert.Equal("start: /.+/", applyPatch.FormatDefinition);
    }

    [Fact]
    public void Apply_patch_tool_without_description_is_accepted()
    {
        RouterError? error = Parse(
            """{"type":"custom","name":"apply_patch","format":{"type":"grammar","syntax":"lark","definition":"x"}}""",
            out CanonicalResponsesRequest? request);

        Assert.Null(error);
        Assert.NotNull(request!.ApplyPatchTool);
        Assert.Null(request.ApplyPatchTool!.Description);
    }

    [Theory]
    [InlineData("SUPER_SECRET_TOOL_NAME")]
    [InlineData("Apply_Patch")]
    [InlineData("APPLY_PATCH")]
    [InlineData("patch")]
    [InlineData("mm_apply_patch_bridge_v1")]
    public void Unknown_custom_name_keeps_the_fix4_fail_closed_diagnostic(string name)
    {
        RouterError? error = Parse(
            "{\"type\":\"custom\",\"name\":\"" + name + "\",\"format\":{\"type\":\"grammar\",\"syntax\":\"lark\",\"definition\":\"x\"}}",
            out CanonicalResponsesRequest? request);

        Assert.NotNull(error);
        Assert.Null(request);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("tools[0].type", error.Param);
        Assert.Equal("custom", error.SafeDiagnosticClass);
        Assert.Equal("unknown_custom", error.SafeDiagnosticIdentity);
        Assert.DoesNotContain(name, error.ToJson(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("""{"type":"custom"}""")]
    [InlineData("""{"type":"custom","name":null}""")]
    [InlineData("""{"type":"custom","name":42}""")]
    [InlineData("""{"type":"custom","name":"apply_patch","name":"other"}""")]
    public void Malformed_custom_identity_still_fails_closed_as_unknown_custom(string toolJson)
    {
        RouterError? error = Parse(toolJson, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("unknown_custom", error.SafeDiagnosticIdentity);
    }

    [Theory]
    [InlineData("""{"type":"custom","name":"apply_patch"}""")]
    [InlineData("""{"type":"custom","name":"apply_patch","format":{"type":"grammar","syntax":"lark"}}""")]
    [InlineData("""{"type":"custom","name":"apply_patch","format":{"type":"grammar","syntax":"lark","definition":""}}""")]
    [InlineData("""{"type":"custom","name":"apply_patch","format":{"type":"text","syntax":"lark","definition":"x"}}""")]
    [InlineData("""{"type":"custom","name":"apply_patch","format":{"type":"grammar","syntax":"regex","definition":"x"}}""")]
    [InlineData("""{"type":"custom","name":"apply_patch","format":{"type":"grammar","syntax":"lark","definition":"x","definition":"y"}}""")]
    public void Malformed_apply_patch_shape_is_an_invalid_request(string toolJson)
    {
        RouterError? error = Parse(toolJson, out CanonicalResponsesRequest? request);

        Assert.NotNull(error);
        Assert.Null(request);
        Assert.Equal(RouterErrorCode.InvalidRequest, error!.Code);
        Assert.StartsWith("tools[0]", error.Param, StringComparison.Ordinal);
    }

    // Strict policy: an unproven field is never silently swallowed.
    [Theory]
    [InlineData("""{"type":"custom","name":"apply_patch","format":{"type":"grammar","syntax":"lark","definition":"x"},"unexpected":true}""", "tools[0].unexpected")]
    [InlineData("""{"type":"custom","name":"apply_patch","format":{"type":"grammar","syntax":"lark","definition":"x","defer_loading":true}}""", "tools[0].format.defer_loading")]
    public void Unknown_apply_patch_fields_are_unsupported_parameters(string toolJson, string expectedParam)
    {
        RouterError? error = Parse(toolJson, out CanonicalResponsesRequest? request);

        Assert.NotNull(error);
        Assert.Null(request);
        Assert.Equal(RouterErrorCode.UnsupportedParameter, error!.Code);
        Assert.Equal(expectedParam, error.Param);
    }

    [Fact]
    public void Overlong_grammar_definition_is_rejected()
    {
        string definition = new('x', ApplyPatchBridgeContract.MaxFormatDefinitionLength + 1);
        RouterError? error = Parse(
            "{\"type\":\"custom\",\"name\":\"apply_patch\",\"format\":{\"type\":\"grammar\",\"syntax\":\"lark\",\"definition\":\"" + definition + "\"}}",
            out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.InvalidRequest, error!.Code);
        Assert.Equal("tools[0].format.definition", error.Param);
    }

    [Fact]
    public void Reserved_synthetic_name_is_rejected_on_a_client_function()
    {
        RouterError? error = Parse(
            """{"type":"function","name":"mm_apply_patch_bridge_v1","parameters":{"type":"object"}}""",
            out CanonicalResponsesRequest? request);

        Assert.NotNull(error);
        Assert.Null(request);
        Assert.Equal(RouterErrorCode.InvalidRequest, error!.Code);
        Assert.Equal("tools[0].name", error.Param);
    }

    [Fact]
    public void Ordinary_function_tools_are_unchanged_next_to_apply_patch()
    {
        RouterError? error = Parse(
            """{"type":"function","name":"f","parameters":{"type":"object","properties":{}}},""" + ValidApplyPatchTool,
            out CanonicalResponsesRequest? request);

        Assert.Null(error);
        FunctionToolDefinition function = Assert.Single(request!.Tools);
        Assert.Equal("f", function.Name);
        Assert.NotNull(request.ApplyPatchTool);
    }

    [Fact]
    public void Two_apply_patch_tools_fail_closed()
    {
        RouterError? error = Parse(ValidApplyPatchTool + "," + ValidApplyPatchTool, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.InvalidRequest, error!.Code);
    }

    [Fact]
    public void Custom_apply_patch_tool_never_serializes_on_the_canonical_wire()
    {
        RouterError? error = Parse(ValidApplyPatchTool, out CanonicalResponsesRequest? request);
        Assert.Null(error);

        string json = JsonSerializer.Serialize(request!, ResponsesJson.Options);

        Assert.DoesNotContain("apply_patch", json, StringComparison.Ordinal);
        Assert.DoesNotContain("\"custom\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Custom_tool_call_replay_parses_and_preserves_the_call_id()
    {
        RouterError? error = ResponsesRequestParser.TryParse(
            """{"model":"gpt-test","input":[{"type":"custom_tool_call","call_id":"call_1","name":"apply_patch","input":"*** Begin Patch\n*** End Patch"}]}""",
            out CanonicalResponsesRequest? request);

        Assert.Null(error);
        CustomToolCallInputItem item = Assert.IsType<CustomToolCallInputItem>(Assert.Single(request!.Input));
        Assert.Equal("call_1", item.CallId);
        Assert.Equal("apply_patch", item.Name);
        Assert.Equal("*** Begin Patch\n*** End Patch", item.Input);
    }

    [Fact]
    public void Custom_tool_call_output_requires_a_matching_custom_tool_call()
    {
        RouterError? matched = ResponsesRequestParser.TryParse(
            """{"model":"gpt-test","input":[{"type":"custom_tool_call","call_id":"call_1","name":"apply_patch","input":"p"},{"type":"custom_tool_call_output","call_id":"call_1","output":{"success":true,"detail":"ok"}}]}""",
            out CanonicalResponsesRequest? request);

        Assert.Null(matched);
        CustomToolCallOutputInputItem output = Assert.IsType<CustomToolCallOutputInputItem>(request!.Input[1]);
        Assert.Equal("call_1", output.CallId);
        Assert.Equal(JsonValueKind.Object, output.Output.ValueKind);

        RouterError? orphan = ResponsesRequestParser.TryParse(
            """{"model":"gpt-test","input":[{"type":"custom_tool_call_output","call_id":"call_missing","output":"x"}]}""",
            out CanonicalResponsesRequest? orphanRequest);

        Assert.NotNull(orphan);
        Assert.Null(orphanRequest);
        Assert.Equal(RouterErrorCode.InvalidRequest, orphan!.Code);
        Assert.Equal("input[0].call_id", orphan.Param);
    }

    [Theory]
    [InlineData("""{"type":"custom_tool_call","call_id":"call_1","name":"other","input":"p"}""")]
    [InlineData("""{"type":"custom_tool_call","call_id":"call_1","name":"apply_patch"}""")]
    [InlineData("""{"type":"custom_tool_call","call_id":"call_1","name":"apply_patch","input":12}""")]
    [InlineData("""{"type":"custom_tool_call","name":"apply_patch","input":"p"}""")]
    [InlineData("""{"type":"custom_tool_call","call_id":"call_1","name":"apply_patch","input":"p","unexpected":1}""")]
    public void Malformed_custom_tool_call_replay_fails_closed(string itemJson)
    {
        RouterError? error = ResponsesRequestParser.TryParse(
            "{\"model\":\"gpt-test\",\"input\":[" + itemJson + "]}",
            out CanonicalResponsesRequest? request);

        Assert.NotNull(error);
        Assert.Null(request);
    }

    [Fact]
    public void Custom_tool_call_response_item_round_trips_through_the_canonical_json()
    {
        var response = new CanonicalResponsesResponse
        {
            Id = "resp_1",
            ObjectType = "response",
            CreatedAt = 1,
            Status = "completed",
            Model = "deepseek-flash",
            Output =
            [
                new CustomToolCallResponseItem
                {
                    Type = "custom_tool_call",
                    CallId = "call_1",
                    Name = "apply_patch",
                    Input = "*** Begin Patch\n*** End Patch",
                },
            ],
        };

        byte[] json = JsonSerializer.SerializeToUtf8Bytes(response, ResponsesJson.Options);
        CanonicalResponsesResponse? roundTripped = JsonSerializer.Deserialize<CanonicalResponsesResponse>(json, ResponsesJson.Options);

        CustomToolCallResponseItem item = Assert.IsType<CustomToolCallResponseItem>(Assert.Single(roundTripped!.Output));
        Assert.Equal("custom_tool_call", item.Type);
        Assert.Equal("call_1", item.CallId);
        Assert.Equal("apply_patch", item.Name);
        Assert.Equal("*** Begin Patch\n*** End Patch", item.Input);
    }
}
