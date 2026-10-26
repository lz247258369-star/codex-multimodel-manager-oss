namespace Router.Observability;

/// <summary>Thrown when a record cannot be redacted safely; the event is dropped.</summary>
public sealed class RedactionFailureException : Exception
{
    public RedactionFailureException()
        : base("The observability record failed redaction.")
    {
    }
}

/// <summary>
/// Typed redaction boundary. Only safe records may cross into sinks; any
/// record containing forbidden content is rejected and the event is dropped.
/// </summary>
public static class RedactionBoundary
{
    private static readonly string[] ForbiddenMarkers =
    [
        "prompt", "instruction", "tool argument", "tool result", "image",
        "authorization", "api key", "cookie", "raw response", "secret",
        "C:\\Users", "/home/",
    ];

    public static RedactedRequestRecord Redact(SafeRequestRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);

        foreach (string value in new[]
                 {
                     record.RequestId,
                     record.TraceId,
                     record.ClientId ?? string.Empty,
                     record.RouteId ?? string.Empty,
                     record.ProviderId ?? string.Empty,
                     record.ProtocolId ?? string.Empty,
                     record.ModelRouteId ?? string.Empty,
                     record.ErrorCode ?? string.Empty,
                 })
        {
            foreach (string marker in ForbiddenMarkers)
            {
                if (value.Contains(marker, StringComparison.OrdinalIgnoreCase))
                {
                    throw new RedactionFailureException();
                }
            }
        }

        return RedactedRequestRecord.From(record);
    }
}
