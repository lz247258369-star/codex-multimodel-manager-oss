using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;

namespace Router.ProviderAdapters.Responses;

/// <summary>Thrown when an upstream SSE frame is malformed or unparseable.</summary>
public sealed class SseParseException : Exception
{
    public SseParseException()
        : base("The upstream SSE stream is malformed.")
    {
    }
}

/// <summary>
/// Deterministic SSE parser for upstream Responses event streams. Handles
/// arbitrary network fragmentation, multiple events per read, comments, and
/// keepalives. Malformed frames throw <see cref="SseParseException"/>.
/// </summary>
public static class SseStreamParser
{
    public static async IAsyncEnumerable<CanonicalEvent> ParseAsync(
        Stream stream,
        StreamTimeoutGuard guard,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ArgumentNullException.ThrowIfNull(guard);

        using var reader = new LineReader(stream, guard);
        while (await reader.ReadFrameAsync(cancellationToken).ConfigureAwait(false) is { } frame)
        {
            if (frame.EventName is null && frame.Data is null)
            {
                continue; // comment or keepalive
            }

            if (frame.Data is null)
            {
                throw new SseParseException();
            }

            JsonElement payload;
            try
            {
                using JsonDocument document = JsonDocument.Parse(frame.Data);
                payload = document.RootElement.Clone();
            }
            catch (JsonException)
            {
                throw new SseParseException();
            }

            string eventName = frame.EventName
                ?? (payload.ValueKind == JsonValueKind.Object && payload.TryGetProperty("type", out JsonElement type)
                    ? type.GetString()
                    : null)
                ?? string.Empty;

            CanonicalEvent canonical;
            try
            {
                canonical = CanonicalEvent.Create(eventName, payload);
            }
            catch (ArgumentException)
            {
                throw new SseParseException();
            }

            yield return canonical;
        }
    }

    private sealed record SseFrame(string? EventName, string? Data);

    /// <summary>Async line reader tolerant to arbitrary fragmentation and newline styles.</summary>
    private sealed class LineReader : IDisposable
    {
        private const int BufferSize = 16 * 1024;
        private readonly byte[] _buffer = new byte[BufferSize];
        private readonly MemoryStream _pending = new();
        private readonly Stream _stream;
        private readonly StreamTimeoutGuard _guard;
        private bool _eof;

        public LineReader(Stream stream, StreamTimeoutGuard guard)
        {
            _stream = stream;
            _guard = guard;
        }

        public async Task<SseFrame?> ReadFrameAsync(CancellationToken cancellationToken)
        {
            string? eventName = null;
            var dataLines = new List<string>();

            while (true)
            {
                string? line = await ReadLineAsync(cancellationToken).ConfigureAwait(false);
                if (line is null)
                {
                    // EOF: flush any pending data as a final event only if data exists.
                    if (dataLines.Count == 0)
                    {
                        return null;
                    }

                    return new SseFrame(eventName, string.Join("\n", dataLines));
                }

                if (line.Length == 0)
                {
                    // Blank line dispatches the current event.
                    if (dataLines.Count == 0 && eventName is null)
                    {
                        continue;
                    }

                    return new SseFrame(eventName, dataLines.Count == 0 ? null : string.Join("\n", dataLines));
                }

                if (line[0] == ':')
                {
                    continue; // comment / keepalive
                }

                string field = line;
                string value = string.Empty;
                int colon = line.IndexOf(':');
                if (colon >= 0)
                {
                    field = line[..colon];
                    value = line[(colon + 1)..];
                    if (value.StartsWith(' '))
                    {
                        value = value[1..];
                    }
                }

                if (field == "event")
                {
                    eventName = value;
                }
                else if (field == "data")
                {
                    dataLines.Add(value);
                }
                // "id" and "retry" are not used by the canonical client protocol.
            }
        }

        private async Task<string?> ReadLineAsync(CancellationToken cancellationToken)
        {
            while (true)
            {
                // Try to extract a complete line from pending bytes.
                if (TryReadLineFromPending(out string? line))
                {
                    return line;
                }

                if (_eof)
                {
                    if (_pending.Length == 0)
                    {
                        return null;
                    }

                    return ReadRestAsLine();
                }

                int read = await _guard.ReadAsync(_buffer, cancellationToken).ConfigureAwait(false);
                if (read == 0)
                {
                    _eof = true;
                    continue;
                }

                _pending.Write(_buffer, 0, read);
            }
        }

        private bool TryReadLineFromPending(out string? line)
        {
            byte[] bytes = _pending.ToArray();
            for (int index = 0; index < bytes.Length; index++)
            {
                if (bytes[index] == (byte)'\n')
                {
                    int length = index;
                    if (length > 0 && bytes[length - 1] == (byte)'\r')
                    {
                        length--;
                    }

                    line = Encoding.UTF8.GetString(bytes, 0, length);
                    ConsumePending(index + 1);
                    return true;
                }
            }

            line = null;
            return false;
        }

        private string ReadRestAsLine()
        {
            byte[] bytes = _pending.ToArray();
            int length = bytes.Length;
            if (length > 0 && bytes[length - 1] == (byte)'\r')
            {
                length--;
            }

            string line = Encoding.UTF8.GetString(bytes, 0, length);
            _pending.SetLength(0);
            return line;
        }

        private void ConsumePending(int count)
        {
            byte[] remaining = _pending.ToArray();
            _pending.SetLength(0);
            if (count < remaining.Length)
            {
                _pending.Write(remaining, count, remaining.Length - count);
            }
        }

        public void Dispose()
        {
            _pending.Dispose();
        }
    }
}
