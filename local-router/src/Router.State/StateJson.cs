using System.Text.Json;
using System.Text.Json.Serialization;

namespace Router.State;

/// <summary>Canonical JSON options for state, receipts, and owner records.</summary>
public static class StateJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        WriteIndented = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };
}
