using System.Text;
using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;

namespace Router.Ingress;

/// <summary>
/// Safe SSE frame writer. Event names are validated and JSON data is serialized
/// compactly so raw newlines can never inject framing. Every event is flushed.
/// </summary>
public static class SseWriter
{
    private static readonly HashSet<string> TerminalEventTypes = new(StringComparer.Ordinal)
    {
        "response.completed",
        "response.failed",
        "error",
    };

    public static bool IsTerminalEvent(CanonicalEvent evt) => TerminalEventTypes.Contains(evt.Type);

    public static Task WriteEventAsync(Stream body, CanonicalEvent evt, CancellationToken cancellationToken)
    {
        string data = JsonSerializer.Serialize(evt.Data, ResponsesJson.Options);
        return WriteFrameAsync(body, evt.Type, data, cancellationToken);
    }

    public static Task WriteErrorEventAsync(Stream body, RouterError error, CancellationToken cancellationToken)
    {
        string data = JsonSerializer.Serialize(
            new
            {
                type = "error",
                code = error.Code,
                message = error.Message,
                request_id = error.RequestId,
            },
            ResponsesJson.Options);
        return WriteFrameAsync(body, "error", data, cancellationToken);
    }

    private static async Task WriteFrameAsync(Stream body, string eventType, string data, CancellationToken cancellationToken)
    {
        if (!IsValidEventName(eventType))
        {
            throw new InvalidOperationException("Invalid SSE event name.");
        }

        byte[] frame = Encoding.UTF8.GetBytes("event: " + eventType + "\ndata: " + data + "\n\n");
        await body.WriteAsync(frame, cancellationToken).ConfigureAwait(false);
        await body.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static bool IsValidEventName(string name)
        => name.Length is > 0 and <= 64
            && name.All(static c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-');
}
