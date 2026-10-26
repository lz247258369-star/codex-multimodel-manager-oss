using System.Text.Json;
using System.Text.Json.Serialization;

namespace Router.Ingress.ControlPlane;

/// <summary>
/// Canonical JSON options for the versioned control-plane contract. Response
/// nulls are always written so the DTO shape is stable and "unavailable" is
/// explicit; request parsing rejects unknown fields (strict JSON schema).
/// </summary>
public static class ControlPlaneJson
{
    public static readonly JsonSerializerOptions WriteOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = false,
        WriteIndented = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    public static readonly JsonSerializerOptions RequestOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };
}
