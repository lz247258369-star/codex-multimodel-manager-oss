using System.Text.Json;
using System.Text.Json.Serialization;

namespace Router.ClientAdapters.Responses;

/// <summary>How the model may select a tool (preserved as data; never executed).</summary>
public enum ToolChoiceKind
{
    Auto = 0,
    None = 1,
    Required = 2,
    Function = 3,
}

/// <summary>Wire-name mapping for <see cref="ToolChoiceKind"/>.</summary>
public static class ToolChoiceKinds
{
    public static string ToWireName(this ToolChoiceKind kind) => kind switch
    {
        ToolChoiceKind.Auto => "auto",
        ToolChoiceKind.None => "none",
        ToolChoiceKind.Required => "required",
        ToolChoiceKind.Function => "function",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };
}

/// <summary>
/// Function tool definition. The router validates shape and size but never
/// executes the tool; arguments are a JSON data structure only.
/// </summary>
public sealed record FunctionToolDefinition
{
    public required string Name { get; init; }

    public string? Description { get; init; }

    /// <summary>The JSON schema object, preserved verbatim as data.</summary>
    public JsonElement? Parameters { get; init; }

    public bool Strict { get; init; }
}

/// <summary>
/// Tool choice instruction, preserved as data. Object form selects one named
/// function; string form uses the automatic/none/required semantics.
/// </summary>
public sealed record ToolChoice
{
    [JsonConverter(typeof(ToolChoiceKindConverter))]
    public required ToolChoiceKind Kind { get; init; }

    public string? FunctionName { get; init; }
}

internal sealed class ToolChoiceKindConverter : JsonConverter<ToolChoiceKind>
{
    public override ToolChoiceKind Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        string? text = reader.GetString();
        return text switch
        {
            "auto" => ToolChoiceKind.Auto,
            "none" => ToolChoiceKind.None,
            "required" => ToolChoiceKind.Required,
            _ => throw new JsonException("Unknown tool_choice kind."),
        };
    }

    public override void Write(Utf8JsonWriter writer, ToolChoiceKind value, JsonSerializerOptions options)
        => writer.WriteStringValue(value.ToWireName());
}
