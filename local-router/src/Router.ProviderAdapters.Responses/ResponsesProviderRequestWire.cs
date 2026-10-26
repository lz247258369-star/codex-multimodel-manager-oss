using System.Text.Json;
using System.Text.Json.Serialization;
using Router.ClientAdapters.Responses;

namespace Router.ProviderAdapters.Responses;

/// <summary>
/// DSR7-C-FIX5-B1a: the Responses provider-wire shape of a function tool.
///
/// The canonical <see cref="FunctionToolDefinition"/> is a client semantic model
/// and deliberately carries no provider discriminator. The upstream Responses
/// API requires a tool object to declare <c>"type":"function"</c>, so the
/// provider wire projects it here. The value is fixed by the Router and can never
/// be influenced by a client string.
///
/// Only the five canonical fields are projected; the parameters JSON is carried
/// through verbatim and is never reinterpreted, defaulted or re-schematized.
/// </summary>
internal sealed record ResponsesFunctionToolWire
{
    /// <summary>Always the literal <c>function</c>; never client-supplied.</summary>
    [JsonPropertyName("type")]
    public required string Type { get; init; }

    public required string Name { get; init; }

    public string? Description { get; init; }

    public JsonElement? Parameters { get; init; }

    public bool Strict { get; init; }
}

/// <summary>
/// DSR7-C-FIX5-B1a: the Responses provider-wire projection of a canonical
/// request. It mirrors the canonical request field for field - model, input,
/// stream, instructions, reasoning, tool_choice, max_output_tokens, metadata -
/// and differs only in the tool array, where every ordinary function tool gains
/// its required <c>type</c> discriminator.
///
/// It deliberately carries no secret, no Authorization, no endpoint, no route, no
/// trace, no HttpContext and no apply_patch bridge state: a canonical custom tool
/// is rejected by the shared adapter base before this projection is ever used.
/// </summary>
internal sealed record ResponsesProviderRequestWire
{
    public required string Model { get; init; }

    public required IReadOnlyList<ResponsesInputItem> Input { get; init; }

    public bool Stream { get; init; }

    public string? Instructions { get; init; }

    public ReasoningRequest? Reasoning { get; init; }

    public IReadOnlyList<ResponsesFunctionToolWire> Tools { get; init; } = [];

    /// <summary>
    /// DSR7-C-FIX5-B1a2: the canonical tool choice is projected onto the Responses
    /// wire forms - the bare strings <c>auto</c>/<c>none</c>/<c>required</c>, or
    /// <c>{"type":"function","name":…}</c>. The canonical shape is semantic and is
    /// never sent upstream.
    /// </summary>
    [JsonConverter(typeof(ResponsesToolChoiceWireConverter))]
    public ToolChoice? ToolChoice { get; init; }

    [JsonPropertyName("max_output_tokens")]
    public int? MaxOutputTokens { get; init; }

    public IReadOnlyDictionary<string, string> Metadata { get; init; } = new Dictionary<string, string>(StringComparer.Ordinal);

    /// <summary>The fixed provider-wire tool discriminator.</summary>
    public const string FunctionToolType = "function";

    /// <summary>Projects a canonical request onto the provider wire.</summary>
    public static ResponsesProviderRequestWire FromCanonical(CanonicalResponsesRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        var tools = new List<ResponsesFunctionToolWire>(request.Tools.Count);
        foreach (FunctionToolDefinition tool in request.Tools)
        {
            tools.Add(new ResponsesFunctionToolWire
            {
                Type = FunctionToolType,
                Name = tool.Name,
                Description = tool.Description,
                Parameters = tool.Parameters,
                Strict = tool.Strict,
            });
        }

        return new ResponsesProviderRequestWire
        {
            Model = request.Model,
            Input = request.Input,
            Stream = request.Stream,
            Instructions = request.Instructions,
            Reasoning = request.Reasoning,
            Tools = tools,
            ToolChoice = request.ToolChoice,
            MaxOutputTokens = request.MaxOutputTokens,
            Metadata = request.Metadata,
        };
    }
}

/// <summary>
/// Projects the canonical <see cref="ToolChoice"/> onto the Responses upstream
/// wire. The mapping is exact and case-preserving; a named function choice with a
/// missing name fails closed (throws) instead of emitting a malformed choice or
/// degrading to <c>auto</c>. A null choice is omitted entirely - the Router never
/// invents a default for the client.
/// </summary>
internal sealed class ResponsesToolChoiceWireConverter : JsonConverter<ToolChoice>
{
    public override ToolChoice Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => throw new NotSupportedException("Provider-wire tool_choice is write-only.");

    public override void Write(Utf8JsonWriter writer, ToolChoice value, JsonSerializerOptions options)
    {
        switch (value.Kind)
        {
            case ToolChoiceKind.Auto:
                writer.WriteStringValue("auto");
                return;
            case ToolChoiceKind.None:
                writer.WriteStringValue("none");
                return;
            case ToolChoiceKind.Required:
                writer.WriteStringValue("required");
                return;
            case ToolChoiceKind.Function:
                if (string.IsNullOrEmpty(value.FunctionName))
                {
                    throw new JsonException("A named function tool_choice requires a function name.");
                }

                writer.WriteStartObject();
                writer.WriteString("type", FunctionToolName);
                writer.WriteString("name", value.FunctionName);
                writer.WriteEndObject();
                return;
            default:
                throw new JsonException("Unknown canonical tool_choice kind.");
        }
    }

    private const string FunctionToolName = ResponsesProviderRequestWire.FunctionToolType;
}
