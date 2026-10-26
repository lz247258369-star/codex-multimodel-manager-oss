using System.Text.Json;
using System.Text.Json.Serialization;

namespace Router.ClientAdapters.Responses;

/// <summary>
/// Canonical JSON options for Responses client-adapter payloads. Property names
/// follow OpenAI Responses snake_case semantics; null fields are omitted.
/// </summary>
public static class ResponsesJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = false,
        WriteIndented = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new ResponsesInputItemConverter(), new ResponseOutputItemConverter() },
    };
}
