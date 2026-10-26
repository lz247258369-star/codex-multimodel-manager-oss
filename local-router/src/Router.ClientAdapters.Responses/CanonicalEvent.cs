using System.Text.Json;

namespace Router.ClientAdapters.Responses;

/// <summary>
/// Canonical streaming event: a validated event name plus a JSON data payload.
/// Data is serialized compactly so raw newlines can never inject SSE framing.
/// </summary>
public sealed record CanonicalEvent
{
    private const int MaxEventNameLength = 64;

    public required string Type { get; init; }

    public required JsonElement Data { get; init; }

    /// <summary>True for events that terminate a stream (completed, failed, error).</summary>
    public bool IsTerminal => Type is "response.completed" or "response.failed" or "error";

    /// <summary>Creates an event from a payload object serialized with canonical options.</summary>
    public static CanonicalEvent Create(string type, object data)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(type);
        if (type.Length > MaxEventNameLength || !IsValidEventName(type))
        {
            throw new ArgumentException("The event name is not a valid SSE event name.", nameof(type));
        }

        JsonElement payload;
        if (data is JsonElement element)
        {
            payload = element;
        }
        else
        {
            using MemoryStream stream = new();
            using (Utf8JsonWriter writer = new(stream))
            {
                JsonSerializer.Serialize(writer, data, data.GetType(), ResponsesJson.Options);
            }

            using JsonDocument document = JsonDocument.Parse(stream.ToArray());
            payload = document.RootElement.Clone();
        }

        return new CanonicalEvent { Type = type, Data = payload };
    }

    private static bool IsValidEventName(string name)
        => name.All(static c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-');
}
