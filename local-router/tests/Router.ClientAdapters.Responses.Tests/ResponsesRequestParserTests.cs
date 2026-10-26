using Router.Core.Errors;
using Xunit;

namespace Router.ClientAdapters.Responses.Tests;

public sealed class ResponsesRequestParserTests
{
    [Fact]
    public void Text_string_input_parses_to_user_message()
    {
        RouterError? error = ResponsesRequestParser.TryParse(
            """{"model":"gpt-test","input":"hello"}""",
            out CanonicalResponsesRequest? request);

        Assert.Null(error);
        Assert.NotNull(request);
        Assert.Equal("gpt-test", request!.Model);
        Assert.False(request.Stream);
        MessageInputItem message = Assert.IsType<MessageInputItem>(Assert.Single(request.Input));
        Assert.Equal("user", message.Role);
        Assert.Equal("hello", Assert.Single(message.Content).Text);
    }

    [Fact]
    public void Instructions_reasoning_and_stream_are_parsed()
    {
        const string json =
            """{"model":"gpt-test","input":"hi","stream":true,"instructions":"be brief","reasoning":{"effort":"high","summary":"auto"}}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.Null(error);
        Assert.True(request!.Stream);
        Assert.Equal("be brief", request.Instructions);
        Assert.Equal(ReasoningEffort.High, request.Reasoning!.Effort);
        Assert.Equal(ReasoningSummaryMode.Auto, request.Reasoning.Summary);
    }

    [Fact]
    public void Function_tool_definition_parses_as_data()
    {
        const string json =
            """{"model":"gpt-test","input":"hi","tools":[{"type":"function","name":"get_weather","description":"weather","parameters":{"type":"object","properties":{}},"strict":true}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.Null(error);
        FunctionToolDefinition tool = Assert.Single(request!.Tools);
        Assert.Equal("get_weather", tool.Name);
        Assert.Equal("weather", tool.Description);
        Assert.True(tool.Strict);
        Assert.True(tool.Parameters.HasValue);
    }

    [Fact]
    public void Tool_choice_string_and_function_forms_parse()
    {
        RouterError? stringError = ResponsesRequestParser.TryParse(
            """{"model":"gpt-test","input":"hi","tool_choice":"required"}""",
            out CanonicalResponsesRequest? stringRequest);
        Assert.Null(stringError);
        Assert.Equal(ToolChoiceKind.Required, stringRequest!.ToolChoice!.Kind);

        RouterError? objectError = ResponsesRequestParser.TryParse(
            """{"model":"gpt-test","input":"hi","tool_choice":{"type":"function","name":"get_weather"}}""",
            out CanonicalResponsesRequest? objectRequest);
        Assert.Null(objectError);
        Assert.Equal(ToolChoiceKind.Function, objectRequest!.ToolChoice!.Kind);
        Assert.Equal("get_weather", objectRequest.ToolChoice.FunctionName);
    }

    [Fact]
    public void Function_call_and_result_inputs_round_trip()
    {
        const string json =
            """{"model":"gpt-test","input":[{"type":"function_call","call_id":"call_1","name":"get_weather","arguments":"{\"city\":\"sh\"}"},{"type":"function_call_output","call_id":"call_1","output":"{\"temp\":20}"}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.Null(error);
        Assert.Equal(2, request!.Input.Count);
        FunctionCallInputItem call = Assert.IsType<FunctionCallInputItem>(request.Input[0]);
        Assert.Equal("call_1", call.CallId);
        Assert.Equal("get_weather", call.Name);
        FunctionCallOutputItem result = Assert.IsType<FunctionCallOutputItem>(request.Input[1]);
        Assert.Equal("call_1", result.CallId);
    }

    [Fact]
    public void Reasoning_input_item_parses()
    {
        const string json =
            """{"model":"gpt-test","input":[{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"plan"}]}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.Null(error);
        ReasoningInputItem reasoning = Assert.IsType<ReasoningInputItem>(Assert.Single(request!.Input));
        Assert.Equal("plan", Assert.Single(reasoning.Summary).Text);
    }

    [Fact]
    public void Metadata_flat_strings_parse_and_nested_is_rejected()
    {
        RouterError? flatError = ResponsesRequestParser.TryParse(
            """{"model":"gpt-test","input":"hi","metadata":{"k":"v"}}""",
            out CanonicalResponsesRequest? request);
        Assert.Null(flatError);
        Assert.Equal("v", request!.Metadata["k"]);

        RouterError? nestedError = ResponsesRequestParser.TryParse(
            """{"model":"gpt-test","input":"hi","metadata":{"k":{"nested":true}}}""",
            out _);
        Assert.NotNull(nestedError);
        Assert.Equal(RouterErrorCode.InvalidRequest, nestedError!.Code);
    }

    [Theory]
    [InlineData("""{"input":"hi"}""", "model")]
    [InlineData("""{"model":"gpt-test"}""", "input")]
    public void Missing_required_field_is_invalid_request(string json, string expectedParam)
    {
        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.InvalidRequest, error!.Code);
        Assert.Equal(expectedParam, error.Param);
    }

    [Fact]
    public void Malformed_json_is_invalid_request()
    {
        RouterError? error = ResponsesRequestParser.TryParse("{ not json", out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.InvalidRequest, error!.Code);
    }

    [Theory]
    [InlineData("""{"model":"gpt-test","input":"hi","temperature":0.7}""", "temperature")]
    [InlineData("""{"model":"gpt-test","input":"hi","user":"someone"}""", "user")]
    // max_output_tokens is deliberately absent from this list: DSR1-FIX1 makes
    // it a supported canonical field (see the dedicated valid/invalid cases).
    [InlineData("""{"model":"gpt-test","input":"hi","future_standard_field":1}""", "future_standard_field")]
    [InlineData("""{"Model":"gpt-test","input":"hi"}""", "Model")]
    public void Unknown_or_unsupported_parameters_are_rejected(string json, string expectedParam)
    {
        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedParameter, error!.Code);
        Assert.Equal(expectedParam, error.Param);
    }

    [Theory]
    [InlineData("""{"model":"gpt-test","input":"hi","background":true}""", "background")]
    [InlineData("""{"model":"gpt-test","input":"hi","store":true}""", "store")]
    [InlineData("""{"model":"gpt-test","input":"hi","modalities":["image"]}""", "modalities")]
    [InlineData("""{"model":"gpt-test","input":"hi","modalities":["text","audio"]}""", "modalities")]
    [InlineData("""{"model":"gpt-test","input":"hi","previous_response_id":"resp_1"}""", "previous_response_id")]
    // DSR7-C-FIX1: the fail-closed capability error must name the SAFE field
    // path so the caller can tell which capability gate rejected the request.
    public void Deferred_capabilities_are_rejected_with_unsupported_capability(string json, string expectedParam)
    {
        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal(expectedParam, error.Param);
        Assert.False(error.Retryable);
        Assert.Equal("The route cannot preserve the required semantics.", error.Message);
    }

    [Fact]
    public void Multimodal_content_part_is_rejected()
    {
        const string json =
            """{"model":"gpt-test","input":[{"type":"message","role":"user","content":[{"type":"input_image","image_url":"https://x/y.png"}]}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("input[0].content[0].type", error.Param);
    }

    [Fact]
    public void Remote_file_item_is_rejected()
    {
        const string json =
            """{"model":"gpt-test","input":[{"type":"file","file_data":{"file_id":"file_1"}}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("input[0].type", error.Param);
    }

    [Fact]
    public void Item_reference_is_rejected()
    {
        const string json =
            """{"model":"gpt-test","input":[{"type":"item_reference","id":"item_1"}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("input[0].type", error.Param);
    }

    [Fact]
    public void Executable_tool_types_are_rejected()
    {
        const string json =
            """{"model":"gpt-test","input":"hi","tools":[{"type":"web_search","name":"search"}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("tools[0].type", error.Param);
        Assert.Equal("web_search", error.SafeDiagnosticClass);
    }

    // DSR7-C-FIX3: the class is a FIXED taxonomy label; the raw tool type is
    // never carried, and the index always comes from the structural position.
    [Theory]
    [InlineData("shell", "tools[0].type", "shell")]
    [InlineData("local_shell", "tools[0].type", "local_shell")]
    [InlineData("apply_patch", "tools[0].type", "apply_patch")]
    [InlineData("custom", "tools[0].type", "custom")]
    [InlineData("mcp", "tools[0].type", "mcp")]
    [InlineData("web_search_preview", "tools[0].type", "web_search_preview")]
    [InlineData("file_search", "tools[0].type", "file_search")]
    [InlineData("computer_use_preview", "tools[0].type", "computer_use_preview")]
    [InlineData("code_interpreter", "tools[0].type", "code_interpreter")]
    [InlineData("image_generation", "tools[0].type", "image_generation")]
    public void Rejected_tool_types_carry_a_fixed_class(string rawType, string expectedParam, string expectedClass)
    {
        string json = $$"""{"model":"gpt-test","input":"hi","tools":[{"type":"{{rawType}}","name":"never_log_me"}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal(expectedParam, error.Param);
        Assert.Equal(expectedClass, error.SafeDiagnosticClass);
        Assert.DoesNotContain(rawType, error.ToJson(), StringComparison.Ordinal);
    }

    [Fact]
    public void Unknown_secret_shaped_tool_type_is_classified_without_leaking_it()
    {
        const string rawType = "sk-test-DO_NOT_LEAK";
        string json = $$"""{"model":"gpt-test","input":"hi","tools":[{"type":"{{rawType}}","name":"SUPER_SECRET_TOOL_NAME"}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal("tools[0].type", error!.Param);
        Assert.Equal("unknown_non_function", error.SafeDiagnosticClass);
        string serialized = error.ToJson();
        Assert.DoesNotContain(rawType, serialized, StringComparison.Ordinal);
        Assert.DoesNotContain("SUPER_SECRET_TOOL_NAME", serialized, StringComparison.Ordinal);
    }

    [Fact]
    public void Classified_index_follows_the_structural_position()
    {
        const string json =
            """{"model":"gpt-test","input":"hi","tools":[{"type":"function","name":"ok","parameters":{"type":"object"}},{"type":"function","name":"ok2","parameters":{"type":"object"}},{"type":"function","name":"ok3","parameters":{"type":"object"}},{"type":"function","name":"ok4","parameters":{"type":"object"}},{"type":"function","name":"ok5","parameters":{"type":"object"}},{"type":"function","name":"ok6","parameters":{"type":"object"}},{"type":"local_shell","name":"never_log_me"}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal("tools[6].type", error!.Param);
        Assert.Equal("local_shell", error.SafeDiagnosticClass);
    }

    [Fact]
    public void Classified_index_scales_with_the_structural_position()
    {
        string[] tools = Enumerable.Range(0, 12)
            .Select(index => "{\"type\":\"function\",\"name\":\"ok" + index + "\",\"parameters\":{\"type\":\"object\"}}")
            .Append("""{"type":"apply_patch","name":"never_log_me"}""")
            .ToArray();
        string json = "{\"model\":\"gpt-test\",\"input\":\"hi\",\"tools\":[" + string.Join(",", tools) + "]}";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal("tools[12].type", error!.Param);
        Assert.Equal("apply_patch", error.SafeDiagnosticClass);
    }

    // DSR7-C-FIX6-B1: the two real Codex Desktop tool-array shapes captured by
    // FIX6-A - a 13-tool shape (0-5 function, 6 custom, 7 function, 8 namespace,
    // 9-11 function, 12 tool_search) and a 15-tool shape (0-6 function, 7-10
    // namespace, 11-13 function, 14 web_search).
    //
    // Only type/index are reproduced, and the arrays are hand-built here: no
    // captured Desktop payload is ever copied into the repository. The fixtures
    // carry an inert name/description so a leak would be detectable.
    [Fact]
    public void Desktop_13_tool_shape_classifies_namespace_at_its_structural_index()
    {
        string json = BuildDesktopToolsJson(13, new Dictionary<int, string>
        {
            [6] = "custom",
            [8] = "namespace",
            [12] = "tool_search",
        });

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("tools[8].type", error.Param);
        Assert.Equal("namespace", error.SafeDiagnosticClass);
        Assert.Null(request);
    }

    [Fact]
    public void Desktop_13_tool_shape_classifies_tool_search_at_its_structural_index()
    {
        // Same 13-tool shape, except index 8 is a function so the scan reaches
        // the trailing tool_search at index 12.
        string json = BuildDesktopToolsJson(13, new Dictionary<int, string>
        {
            [6] = "custom",
            [12] = "tool_search",
        });

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("tools[12].type", error.Param);
        Assert.Equal("tool_search", error.SafeDiagnosticClass);
        Assert.Null(request);
    }

    [Fact]
    public void Desktop_15_tool_shape_classifies_namespace_at_its_structural_index()
    {
        string json = BuildDesktopToolsJson(15, new Dictionary<int, string>
        {
            [7] = "namespace",
            [8] = "namespace",
            [9] = "namespace",
            [10] = "namespace",
            [14] = "web_search",
        });

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("tools[7].type", error.Param);
        Assert.Equal("namespace", error.SafeDiagnosticClass);
        Assert.Null(request);
    }

    [Fact]
    public void Desktop_15_tool_shape_keeps_web_search_classification_unchanged()
    {
        // The 15-tool shape with the namespace block replaced by functions: the
        // trailing web_search must still classify exactly as before FIX6-B1.
        string json = BuildDesktopToolsJson(15, new Dictionary<int, string>
        {
            [14] = "web_search",
        });

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("tools[14].type", error.Param);
        Assert.Equal("web_search", error.SafeDiagnosticClass);
        Assert.Null(request);
    }

    // The class follows the structural position, never a hard-coded index.
    [Fact]
    public void Desktop_namespace_and_tool_search_do_not_depend_on_a_fixed_index()
    {
        string namespaceElsewhere = BuildDesktopToolsJson(15, new Dictionary<int, string> { [3] = "namespace" });
        RouterError? namespaceError = ResponsesRequestParser.TryParse(namespaceElsewhere, out _);

        Assert.NotNull(namespaceError);
        Assert.Equal("tools[3].type", namespaceError!.Param);
        Assert.Equal("namespace", namespaceError.SafeDiagnosticClass);

        string toolSearchElsewhere = BuildDesktopToolsJson(15, new Dictionary<int, string> { [13] = "tool_search" });
        RouterError? toolSearchError = ResponsesRequestParser.TryParse(toolSearchElsewhere, out _);

        Assert.NotNull(toolSearchError);
        Assert.Equal("tools[13].type", toolSearchError!.Param);
        Assert.Equal("tool_search", toolSearchError.SafeDiagnosticClass);
    }

    // The two new categories stay rejected: unsupported_capability, fail-closed,
    // no canonical request, and none of the tool declaration leaks.
    [Theory]
    [InlineData("namespace")]
    [InlineData("tool_search")]
    public void Desktop_namespace_and_tool_search_stay_rejected_without_leaking(string rawType)
    {
        string json = $$"""{"model":"gpt-test","input":"hi","tools":[{"type":"{{rawType}}","name":"SUPER_SECRET_TOOL_NAME","description":"DO_NOT_LEAK_12345"}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("tools[0].type", error.Param);
        Assert.Equal(rawType, error.SafeDiagnosticClass);
        Assert.False(error.Retryable);
        Assert.Null(request);

        string serialized = error.ToJson();
        Assert.DoesNotContain("SUPER_SECRET_TOOL_NAME", serialized, StringComparison.Ordinal);
        Assert.DoesNotContain("DO_NOT_LEAK_12345", serialized, StringComparison.Ordinal);
    }

    // The recognised-but-rejected categories must not change the accepted shapes:
    // the same 13-tool array with the namespace/tool_search placeholders replaced
    // by functions still parses, and the apply_patch custom tool is preserved.
    [Fact]
    public void Desktop_function_and_custom_behaviour_is_unchanged()
    {
        string json = BuildDesktopToolsJson(13, new Dictionary<int, string> { [6] = "custom" });

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.Null(error);
        Assert.NotNull(request);
        Assert.NotNull(request!.ApplyPatchTool);
        Assert.Equal("apply_patch", request.ApplyPatchTool!.Name);
        Assert.Equal(12, request.Tools.Count);
    }

    /// <summary>
    /// Builds a synthetic tool array of <paramref name="toolCount"/> entries where
    /// every position is a plain function unless <paramref name="overrides"/> maps
    /// it to another type. Only the type is varied; no captured payload is used.
    /// </summary>
    private static string BuildDesktopToolsJson(int toolCount, Dictionary<int, string> overrides)
    {
        var bodies = new List<string>(toolCount);
        for (int index = 0; index < toolCount; index++)
        {
            string type = overrides.TryGetValue(index, out string? overridden) ? overridden : "function";
            bodies.Add(type switch
            {
                "function" => $"{{\"type\":\"function\",\"name\":\"fn{index}\",\"parameters\":{{\"type\":\"object\"}}}}",
                "custom" => "{\"type\":\"custom\",\"name\":\"apply_patch\",\"format\":{\"type\":\"grammar\",\"syntax\":\"lark\",\"definition\":\"start: patch\"}}",
                _ => $"{{\"type\":\"{type}\",\"name\":\"never_log_me\"}}",
            });
        }

        return "{\"model\":\"gpt-test\",\"input\":\"hi\",\"tools\":[" + string.Join(",", bodies) + "]}";
    }

    // DSR7-C-FIX5-A: custom/apply_patch is no longer a rejection - it parses into
    // the dedicated canonical type, and the grammar body is never logged.
    [Fact]
    public void Custom_apply_patch_tool_is_accepted_as_a_canonical_custom_tool()
    {
        const string json =
            """{"model":"gpt-test","input":"hi","tools":[{"type":"custom","name":"apply_patch","format":{"type":"grammar","syntax":"lark","definition":"DO_NOT_LEAK_12345"}}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.Null(error);
        Assert.NotNull(request!.ApplyPatchTool);
        Assert.Equal("apply_patch", request.ApplyPatchTool!.Name);
        Assert.Empty(request.Tools);
    }

    [Theory]
    [InlineData("SUPER_SECRET_TOOL_NAME")]
    [InlineData("sk-test-DO_NOT_LEAK")]
    [InlineData("https://secret.example/private")]
    [InlineData("Apply_Patch")]
    [InlineData("patch")]
    public void Rejected_custom_tool_with_unknown_name_is_unknown_custom(string name)
    {
        string json = $$"""{"model":"gpt-test","input":"hi","tools":[{"type":"custom","name":"{{name}}"}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal("tools[0].type", error!.Param);
        Assert.Equal("custom", error.SafeDiagnosticClass);
        Assert.Equal("unknown_custom", error.SafeDiagnosticIdentity);
        string serialized = error.ToJson();
        Assert.DoesNotContain(name, serialized, StringComparison.Ordinal);
        Assert.DoesNotContain("unknown_custom", serialized, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("""{"type":"custom"}""")]
    [InlineData("""{"type":"custom","name":null}""")]
    [InlineData("""{"type":"custom","name":42}""")]
    [InlineData("""{"type":"custom","name":{"nested":"apply_patch"}}""")]
    [InlineData("""{"type":"custom","name":["apply_patch"]}""")]
    [InlineData("""{"type":"custom","name":"apply_patch","name":"SUPER_SECRET_TOOL_NAME"}""")]
    [InlineData("""{"type":"custom","name":"SUPER_SECRET_TOOL_NAME","name":"apply_patch"}""")]
    public void Malformed_or_duplicate_custom_name_is_unknown_custom(string toolJson)
    {
        string json = "{\"model\":\"gpt-test\",\"input\":\"hi\",\"tools\":[" + toolJson + "]}";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal("tools[0].type", error!.Param);
        Assert.Equal("custom", error.SafeDiagnosticClass);
        Assert.Equal("unknown_custom", error.SafeDiagnosticIdentity);
        string serialized = error.ToJson();
        Assert.DoesNotContain("SUPER_SECRET_TOOL_NAME", serialized, StringComparison.Ordinal);
        Assert.DoesNotContain("apply_patch", serialized, StringComparison.Ordinal);
    }

    [Fact]
    public void Custom_identity_index_follows_the_structural_position()
    {
        string[] tools = Enumerable.Range(0, 6)
            .Select(index => "{\"type\":\"function\",\"name\":\"ok" + index + "\",\"parameters\":{\"type\":\"object\"}}")
            .Append("""{"type":"custom","name":"SUPER_SECRET_TOOL_NAME"}""")
            .ToArray();
        string json = "{\"model\":\"gpt-test\",\"input\":\"hi\",\"tools\":[" + string.Join(",", tools) + "]}";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal("tools[6].type", error!.Param);
        Assert.Equal("custom", error.SafeDiagnosticClass);
        Assert.Equal("unknown_custom", error.SafeDiagnosticIdentity);
        Assert.DoesNotContain("SUPER_SECRET_TOOL_NAME", error.ToJson(), StringComparison.Ordinal);
    }

    [Fact]
    public void Function_tool_named_apply_patch_still_parses_and_carries_no_diagnostic()
    {
        const string json =
            """{"model":"gpt-test","input":"hi","tools":[{"type":"function","name":"apply_patch","parameters":{"type":"object","properties":{}}}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.Null(error);
        Assert.NotNull(request);
    }

    // DSR7-C-FIX1: the diagnostic index must track the real position in the
    // array, never a hard-coded [0], and it must never echo the rejected value.
    [Fact]
    public void Unsupported_tool_type_reports_the_second_index_without_echoing_the_value()
    {
        const string json =
            """{"model":"gpt-test","input":"hi","tools":[{"type":"function","name":"ok","parameters":{"type":"object"}},{"type":"file_search","name":"SUPER_SECRET_TOOL_NAME","description":"DO_NOT_LEAK_12345"}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("tools[1].type", error.Param);

        string serialized = error.ToJson();
        Assert.Contains("tools[1].type", serialized, StringComparison.Ordinal);
        Assert.DoesNotContain("file_search", serialized, StringComparison.Ordinal);
        Assert.DoesNotContain("SUPER_SECRET_TOOL_NAME", serialized, StringComparison.Ordinal);
        Assert.DoesNotContain("DO_NOT_LEAK_12345", serialized, StringComparison.Ordinal);
    }

    [Fact]
    public void Unsupported_input_item_reports_the_second_index_without_echoing_the_value()
    {
        const string json =
            """{"model":"gpt-test","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"ok"}]},{"type":"computer_call","id":"DO_NOT_LEAK_12345"}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("input[1].type", error.Param);
        Assert.DoesNotContain("computer_call", error.ToJson(), StringComparison.Ordinal);
        Assert.DoesNotContain("DO_NOT_LEAK_12345", error.ToJson(), StringComparison.Ordinal);
    }

    [Fact]
    public void Unsupported_multimodal_part_never_leaks_its_source_url()
    {
        const string json =
            """{"model":"gpt-test","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"ok"},{"type":"input_image","image_url":"https://secret.example/private"}]}]}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("input[0].content[1].type", error.Param);
        string serialized = error.ToJson();
        Assert.DoesNotContain("https://secret.example/private", serialized, StringComparison.Ordinal);
        Assert.DoesNotContain("input_image", serialized, StringComparison.Ordinal);
    }

    [Fact]
    public void Unsupported_previous_response_id_never_leaks_the_identifier()
    {
        const string json =
            """{"model":"gpt-test","input":"hi","previous_response_id":"resp_secret_123"}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("previous_response_id", error.Param);
        Assert.DoesNotContain("resp_secret_123", error.ToJson(), StringComparison.Ordinal);
    }

    [Fact]
    public void Unsupported_tool_choice_type_reports_the_static_field_path_only()
    {
        const string json =
            """{"model":"gpt-test","input":"hi","tool_choice":{"type":"web_search","name":"SUPER_SECRET_TOOL_NAME"}}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
        Assert.Equal("tool_choice.type", error.Param);
        string serialized = error.ToJson();
        Assert.DoesNotContain("web_search", serialized, StringComparison.Ordinal);
        Assert.DoesNotContain("SUPER_SECRET_TOOL_NAME", serialized, StringComparison.Ordinal);
    }

    [Fact]
    public void Background_false_and_store_false_are_harmless()
    {
        const string json =
            """{"model":"gpt-test","input":"hi","background":false,"store":false}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.Null(error);
        Assert.NotNull(request);
    }

    [Fact]
    public void Duplicate_fields_are_rejected()
    {
        const string json =
            """{"model":"gpt-test","model":"other","input":"hi"}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.InvalidRequest, error!.Code);
    }

    [Fact]
    public void Unsupported_reasoning_control_is_rejected()
    {
        const string json =
            """{"model":"gpt-test","input":"hi","reasoning":{"effort":"ultra"}}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedParameter, error!.Code);
        Assert.Equal("reasoning.effort", error.Param);
    }

    [Fact]
    public void Reasoning_effort_max_is_a_supported_canonical_value()
    {
        RouterError? error = ResponsesRequestParser.TryParse(
            """{"model":"gpt-test","input":"hi","reasoning":{"effort":"max"}}""",
            out CanonicalResponsesRequest? request);

        Assert.Null(error);
        Assert.Equal(ReasoningEffort.Max, request!.Reasoning!.Effort);
    }

    [Fact]
    public void Error_messages_never_contain_request_content()
    {
        const string json =
            """{"model":"gpt-test","input":"super-secret-prompt-content","temperature":1}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.DoesNotContain("super-secret-prompt-content", error!.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("super-secret-prompt-content", error.ToJson(), StringComparison.Ordinal);
    }

    [Fact]
    public void Overlong_idempotency_relevant_strings_fail_closed()
    {
        string huge = new('x', 1_000_001);
        string json = "{\"model\":\"gpt-test\",\"input\":\"" + huge + "\"}";

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.InvalidRequest, error!.Code);
        Assert.Equal("input", error.Param);
    }

    [Theory]
    [InlineData(16)]
    [InlineData(100)]
    [InlineData(1)]
    public void Max_output_tokens_positive_integer_is_parsed(int value)
    {
        string json = "{\"model\":\"gpt-test\",\"input\":\"hi\",\"max_output_tokens\":" + value + "}";

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.Null(error);
        Assert.NotNull(request);
        Assert.Equal(value, request!.MaxOutputTokens);
    }

    [Fact]
    public void Missing_max_output_tokens_stays_null()
    {
        RouterError? error = ResponsesRequestParser.TryParse(
            """{"model":"gpt-test","input":"hi"}""",
            out CanonicalResponsesRequest? request);

        Assert.Null(error);
        Assert.Null(request!.MaxOutputTokens);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("-1")]
    [InlineData("1.5")]
    [InlineData("\"100\"")]
    [InlineData("null")]
    [InlineData("2147483648")]
    [InlineData("true")]
    public void Max_output_tokens_invalid_values_fail_closed(string rawValue)
    {
        string json = "{\"model\":\"gpt-test\",\"input\":\"hi\",\"max_output_tokens\":" + rawValue + "}";

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.InvalidRequest, error!.Code);
        Assert.Equal("max_output_tokens", error.Param);
        Assert.Null(request);
    }

    [Fact]
    public void Neighbouring_unknown_field_still_fails_closed()
    {
        // Adding max_output_tokens must not open a general "accept arbitrary
        // root properties" door.
        const string json =
            """{"model":"gpt-test","input":"hi","max_completion_tokens":16}""";

        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedParameter, error!.Code);
        Assert.Equal("max_completion_tokens", error.Param);
        Assert.Null(request);
    }
}
