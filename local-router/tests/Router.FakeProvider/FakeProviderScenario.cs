using System.Text;

namespace Router.FakeProvider;

/// <summary>
/// Deterministic fake-upstream scenario. All behavior is offline and loopback;
/// no real provider or network is ever contacted.
/// </summary>
public sealed class FakeProviderScenario
{
    public required int StatusCode { get; init; }

    public byte[]? Body { get; init; }

    public string? ContentType { get; init; }

    public TimeSpan DelayBeforeFirstByte { get; init; } = TimeSpan.Zero;

    public TimeSpan DelayBetweenChunks { get; init; } = TimeSpan.Zero;

    public int ChunkSize { get; init; } = int.MaxValue;

    /// <summary>Extra response headers used to test header redaction (values never asserted).</summary>
    public IReadOnlyDictionary<string, string> ExtraHeaders { get; init; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    /// <summary>True aborts the connection instead of writing a body.</summary>
    public bool AbortConnection { get; init; }

    public static FakeProviderScenario Json(int statusCode, string json)
        => new()
        {
            StatusCode = statusCode,
            Body = Encoding.UTF8.GetBytes(json),
            ContentType = "application/json",
        };

    public static FakeProviderScenario Sse(int statusCode, string sse)
        => new()
        {
            StatusCode = statusCode,
            Body = Encoding.UTF8.GetBytes(sse),
            ContentType = "text/event-stream",
        };
}
