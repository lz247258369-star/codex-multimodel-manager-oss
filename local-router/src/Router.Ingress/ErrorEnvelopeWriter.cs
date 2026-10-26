using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Http;
using Router.Core.Errors;

namespace Router.Ingress;

/// <summary>Writes the canonical error envelope without leaking exception or content details.</summary>
public static class ErrorEnvelopeWriter
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    public static async Task WriteAsync(HttpResponse response, RouterError error, int statusCode, CancellationToken cancellationToken)
    {
        if (response.HasStarted)
        {
            return;
        }

        response.StatusCode = statusCode;
        response.ContentType = "application/json";
        await response.WriteAsync(JsonSerializer.Serialize(new { error }, Options), cancellationToken).ConfigureAwait(false);
    }
}
