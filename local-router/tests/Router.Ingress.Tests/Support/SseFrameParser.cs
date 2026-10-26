namespace Router.Ingress.Tests.Support;

/// <summary>A parsed SSE frame.</summary>
public sealed record SseFrame(string Event, string Data);

/// <summary>Parses SSE bodies written by the canonical writer.</summary>
public static class SseFrameParser
{
    public static IReadOnlyList<SseFrame> Parse(string body)
    {
        string normalized = body.Replace("\r\n", "\n", StringComparison.Ordinal);
        var frames = new List<SseFrame>();
        foreach (string block in normalized.Split("\n\n", StringSplitOptions.None))
        {
            if (string.IsNullOrWhiteSpace(block))
            {
                continue;
            }

            string? eventName = null;
            var dataLines = new List<string>();
            foreach (string line in block.Split('\n'))
            {
                if (line.StartsWith("event:", StringComparison.Ordinal))
                {
                    eventName = line["event:".Length..].Trim();
                }
                else if (line.StartsWith("data:", StringComparison.Ordinal))
                {
                    dataLines.Add(line["data:".Length..].TrimStart());
                }
            }

            if (eventName is not null)
            {
                frames.Add(new SseFrame(eventName, string.Join("\n", dataLines)));
            }
        }

        return frames;
    }
}
