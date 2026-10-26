using System.Text.Json;
using System.Text.Json.Serialization;

namespace Router.Observability;

/// <summary>Canonical JSON options for observability records (typed, safe fields only).</summary>
public static class ObservabilityJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        WriteIndented = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };
}
