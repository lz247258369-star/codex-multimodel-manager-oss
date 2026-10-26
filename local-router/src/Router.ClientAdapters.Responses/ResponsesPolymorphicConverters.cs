using System.Text.Json;
using System.Text.Json.Serialization;

namespace Router.ClientAdapters.Responses;

/// <summary>
/// Serializes canonical input items using the runtime type so derived
/// properties are never dropped by the declared base-type contract.
/// </summary>
internal sealed class ResponsesInputItemConverter : JsonConverter<ResponsesInputItem>
{
    public override ResponsesInputItem? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => throw new NotSupportedException("Responses input deserialization is not part of LR-3.");

    public override void Write(Utf8JsonWriter writer, ResponsesInputItem value, JsonSerializerOptions options)
        => JsonSerializer.Serialize(writer, value, value.GetType(), options);
}

/// <summary>
/// Serializes canonical output items using the runtime type so derived
/// properties are never dropped by the declared base-type contract.
/// </summary>
internal sealed class ResponseOutputItemConverter : JsonConverter<ResponseOutputItem>
{
    public override ResponseOutputItem? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using JsonDocument document = JsonDocument.ParseValue(ref reader);
        JsonElement root = document.RootElement;
        string type = root.TryGetProperty("type", out JsonElement typeElement) ? typeElement.GetString() ?? string.Empty : string.Empty;

        switch (type)
        {
            case "message":
                return JsonSerializer.Deserialize<MessageOutputItem>(root.GetRawText(), options);
            case "reasoning":
                return JsonSerializer.Deserialize<ReasoningOutputItem>(root.GetRawText(), options);
            case "function_call":
                return JsonSerializer.Deserialize<FunctionCallResponseItem>(root.GetRawText(), options);
            // DSR7-C-FIX5-A: the restored client-facing item of the apply_patch
            // compatibility bridge.
            case "custom_tool_call":
                return JsonSerializer.Deserialize<CustomToolCallResponseItem>(root.GetRawText(), options);
            default:
                throw new JsonException("Unsupported canonical response output item type: " + type);
        }
    }

    public override void Write(Utf8JsonWriter writer, ResponseOutputItem value, JsonSerializerOptions options)
        => JsonSerializer.Serialize(writer, value, value.GetType(), options);
}
