using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.ProviderAdapters.Responses;
using Xunit;

namespace Router.ProviderAdapters.Tests;

/// <summary>
/// DSR7-C-FIX5-B1a: the outbound provider body is the provider-wire projection.
/// Every ordinary function tool must declare the Responses `type` discriminator
/// while every other canonical field is carried through unchanged.
/// </summary>
public sealed class ResponsesProviderCodecTests
{
    private static JsonElement Encode(CanonicalResponsesRequest request)
    {
        byte[] body = ResponsesProviderCodec.EncodeRequest(request);
        return JsonDocument.Parse(body).RootElement.Clone();
    }

    private static FunctionToolDefinition Tool(
        string name,
        string? description = "d",
        string? parameterSchema = """{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}""",
        bool strict = true)
        => new()
        {
            Name = name,
            Description = description,
            Parameters = parameterSchema is null ? null : JsonDocument.Parse(parameterSchema).RootElement.Clone(),
            Strict = strict,
        };

    private static CanonicalResponsesRequest Request(IReadOnlyList<FunctionToolDefinition> tools, bool stream = false)
        => new()
        {
            Model = "deepseek-flash",
            Input = [new MessageInputItem { Type = "message", Role = "user", Content = [new TextContentPart { Type = "input_text", Text = "hi" }] }],
            Stream = stream,
            Tools = tools,
        };

    [Fact]
    public void Function_tool_declares_the_responses_type_discriminator()
    {
        JsonElement body = Encode(Request([Tool("get_weather")]));

        JsonElement tool = body.GetProperty("tools")[0];
        Assert.Equal("function", tool.GetProperty("type").GetString());
        Assert.Equal("get_weather", tool.GetProperty("name").GetString());
        Assert.Equal("d", tool.GetProperty("description").GetString());
        Assert.True(tool.GetProperty("strict").GetBoolean());
        Assert.Equal("object", tool.GetProperty("parameters").GetProperty("type").GetString());
        Assert.True(tool.GetProperty("parameters").GetProperty("required")[0].GetString() == "city");
        Assert.False(tool.GetProperty("parameters").GetProperty("additionalProperties").GetBoolean());
    }

    [Fact]
    public void Strict_false_is_preserved()
    {
        JsonElement body = Encode(Request([Tool("t", strict: false)]));

        Assert.False(body.GetProperty("tools")[0].GetProperty("strict").GetBoolean());
    }

    [Fact]
    public void Null_description_and_parameters_are_preserved()
    {
        JsonElement body = Encode(Request([Tool("t", description: null, parameterSchema: null)]));

        JsonElement tool = body.GetProperty("tools")[0];
        Assert.Equal("function", tool.GetProperty("type").GetString());
        Assert.False(tool.TryGetProperty("description", out _));
        Assert.False(tool.TryGetProperty("parameters", out _));
    }

    [Fact]
    public void Multiple_tools_keep_their_order_and_each_carries_the_type()
    {
        JsonElement body = Encode(Request([Tool("a"), Tool("b"), Tool("c")]));

        JsonElement tools = body.GetProperty("tools");
        Assert.Equal(3, tools.GetArrayLength());
        Assert.Equal("a", tools[0].GetProperty("name").GetString());
        Assert.Equal("b", tools[1].GetProperty("name").GetString());
        Assert.Equal("c", tools[2].GetProperty("name").GetString());
        for (int index = 0; index < 3; index++)
        {
            Assert.Equal("function", tools[index].GetProperty("type").GetString());
        }
    }

    [Fact]
    public void Empty_tools_stay_an_empty_array()
    {
        JsonElement body = Encode(Request([]));

        Assert.Equal(JsonValueKind.Array, body.GetProperty("tools").ValueKind);
        Assert.Equal(0, body.GetProperty("tools").GetArrayLength());
    }

    [Fact]
    public void Non_tool_fields_are_projected_unchanged()
    {
        var request = new CanonicalResponsesRequest
        {
            Model = "deepseek-v4-pro",
            Input =
            [
                new MessageInputItem { Type = "message", Role = "user", Content = [new TextContentPart { Type = "input_text", Text = "hi" }] },
                new FunctionCallInputItem { Type = "function_call", CallId = "call_1", Name = "f", Arguments = "{}" },
                new FunctionCallOutputItem { Type = "function_call_output", CallId = "call_1", Output = "done" },
            ],
            Stream = true,
            Instructions = "be brief",
            Reasoning = new ReasoningRequest { Effort = ReasoningEffort.High, Summary = ReasoningSummaryMode.Auto },
            Tools = [Tool("f")],
            ToolChoice = new ToolChoice { Kind = ToolChoiceKind.Auto },
            MaxOutputTokens = 16,
            Metadata = new Dictionary<string, string>(StringComparer.Ordinal) { ["k"] = "v" },
        };

        JsonElement body = Encode(request);

        Assert.Equal("deepseek-v4-pro", body.GetProperty("model").GetString());
        Assert.True(body.GetProperty("stream").GetBoolean());
        Assert.Equal("be brief", body.GetProperty("instructions").GetString());
        Assert.Equal("high", body.GetProperty("reasoning").GetProperty("effort").GetString());
        // DSR7-C-FIX5-B1a2: the canonical tool choice is projected onto the
        // Responses wire (see the dedicated tool_choice tests below).
        JsonElement toolChoice = body.GetProperty("tool_choice");
        Assert.Equal(JsonValueKind.String, toolChoice.ValueKind);
        Assert.Equal("auto", toolChoice.GetString());
        Assert.Equal(16, body.GetProperty("max_output_tokens").GetInt32());
        Assert.Equal("v", body.GetProperty("metadata").GetProperty("k").GetString());
        Assert.Equal(3, body.GetProperty("input").GetArrayLength());
        Assert.Equal("function_call", body.GetProperty("input")[1].GetProperty("type").GetString());
        Assert.Equal("function_call_output", body.GetProperty("input")[2].GetProperty("type").GetString());
    }

    [Fact]
    public void Absent_max_output_tokens_is_not_invented()
    {
        JsonElement body = Encode(Request([Tool("f")]));

        Assert.False(body.TryGetProperty("max_output_tokens", out _));
    }

    [Fact]
    public void Tool_choice_string_forms_are_projected_as_strings()
    {
        foreach ((ToolChoiceKind kind, string expected) in new[]
        {
            (ToolChoiceKind.Auto, "auto"),
            (ToolChoiceKind.None, "none"),
            (ToolChoiceKind.Required, "required"),
        })
        {
            CanonicalResponsesRequest request = Request([Tool("f")]) with
            {
                ToolChoice = new ToolChoice { Kind = kind },
            };

            JsonElement toolChoice = Encode(request).GetProperty("tool_choice");

            Assert.Equal(JsonValueKind.String, toolChoice.ValueKind);
            Assert.Equal(expected, toolChoice.GetString());
        }
    }

    [Theory]
    [InlineData("get_weather")]
    [InlineData("GetWeather")]
    public void Named_function_tool_choice_uses_the_responses_object_form(string functionName)
    {
        CanonicalResponsesRequest request = Request([Tool(functionName)]) with
        {
            ToolChoice = new ToolChoice { Kind = ToolChoiceKind.Function, FunctionName = functionName },
        };

        JsonElement toolChoice = Encode(request).GetProperty("tool_choice");

        Assert.Equal(JsonValueKind.Object, toolChoice.ValueKind);
        Assert.Equal("function", toolChoice.GetProperty("type").GetString());
        Assert.Equal(functionName, toolChoice.GetProperty("name").GetString());
        Assert.False(toolChoice.TryGetProperty("kind", out _));
        Assert.False(toolChoice.TryGetProperty("function_name", out _));
    }

    [Fact]
    public void Absent_tool_choice_is_omitted_and_never_defaulted()
    {
        JsonElement body = Encode(Request([Tool("f")]));

        Assert.False(body.TryGetProperty("tool_choice", out _));
    }

    [Fact]
    public void Named_function_tool_choice_without_a_name_fails_closed()
    {
        CanonicalResponsesRequest request = Request([Tool("f")]) with
        {
            ToolChoice = new ToolChoice { Kind = ToolChoiceKind.Function, FunctionName = null },
        };

        Assert.ThrowsAny<JsonException>(() => ResponsesProviderCodec.EncodeRequest(request));
    }

    [Fact]
    public void Function_tool_and_named_tool_choice_are_both_valid_together()
    {
        CanonicalResponsesRequest request = Request([Tool("get_weather")]) with
        {
            ToolChoice = new ToolChoice { Kind = ToolChoiceKind.Function, FunctionName = "get_weather" },
        };

        JsonElement body = Encode(request);

        Assert.Equal("function", body.GetProperty("tools")[0].GetProperty("type").GetString());
        Assert.Equal("function", body.GetProperty("tool_choice").GetProperty("type").GetString());
        Assert.Equal("get_weather", body.GetProperty("tool_choice").GetProperty("name").GetString());
    }

    [Fact]
    public void Canonical_custom_tool_state_never_reaches_the_provider_wire()
    {
        var request = new CanonicalResponsesRequest
        {
            Model = "deepseek-flash",
            Input = [new MessageInputItem { Type = "message", Role = "user", Content = [new TextContentPart { Type = "input_text", Text = "hi" }] }],
            Tools = [],
            ApplyPatchTool = new ApplyPatchCustomToolDefinition
            {
                Name = "apply_patch",
                Description = "freeform",
                FormatType = "grammar",
                FormatSyntax = "lark",
                FormatDefinition = "DO_NOT_FORWARD_12345",
            },
        };

        byte[] encoded = ResponsesProviderCodec.EncodeRequest(request);
        string text = System.Text.Encoding.UTF8.GetString(encoded);

        Assert.DoesNotContain("apply_patch", text, StringComparison.Ordinal);
        Assert.DoesNotContain("DO_NOT_FORWARD_12345", text, StringComparison.Ordinal);
        Assert.Equal(0, JsonDocument.Parse(encoded).RootElement.GetProperty("tools").GetArrayLength());
    }
}
