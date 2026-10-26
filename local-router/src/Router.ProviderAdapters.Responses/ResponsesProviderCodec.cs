using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;

namespace Router.ProviderAdapters.Responses;

/// <summary>
/// Responses-compatible provider codec (canonical protocol only). Encodes a
/// canonical request for an upstream and decodes canonical non-stream
/// responses. Provider-style nested usage details (for example cached input
/// and reasoning output tokens) are normalized into the canonical usage
/// record when present; no protocol conversion exists.
/// </summary>
public static class ResponsesProviderCodec
{
    public static byte[] EncodeRequest(CanonicalResponsesRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        // DSR7-C-FIX5-B1a: the outbound body is the provider-wire projection, not
        // the canonical request. The canonical FunctionToolDefinition carries no
        // provider discriminator, and the upstream Responses API requires every
        // function tool to declare "type":"function". Every non-tool field is
        // projected unchanged.
        ResponsesProviderRequestWire wire = ResponsesProviderRequestWire.FromCanonical(request);
        return JsonSerializer.SerializeToUtf8Bytes(wire, ResponsesJson.Options);
    }

    public static Result<CanonicalResponsesResponse, RouterError> DecodeResponse(byte[] json)
    {
        ArgumentNullException.ThrowIfNull(json);
        try
        {
            CanonicalResponsesResponse? response = JsonSerializer.Deserialize<CanonicalResponsesResponse>(json, ResponsesJson.Options);
            if (response is null)
            {
                return new Result<CanonicalResponsesResponse, RouterError> { Error = ProviderAdapterErrors.InvalidResponse() };
            }

            return new Result<CanonicalResponsesResponse, RouterError> { Value = NormalizeUsage(response, json) };
        }
        catch (JsonException)
        {
            return new Result<CanonicalResponsesResponse, RouterError> { Error = ProviderAdapterErrors.InvalidResponse() };
        }
    }

    /// <summary>
    /// Enriches canonical usage with nested upstream detail fields without
    /// overwriting flat values already supplied by the upstream.
    /// </summary>
    private static CanonicalResponsesResponse NormalizeUsage(CanonicalResponsesResponse response, byte[] json)
    {
        if (response.Usage is not { } usage)
        {
            return response;
        }

        int? cachedTokens = usage.CachedTokens;
        int? reasoningTokens = usage.ReasoningTokens;
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("usage", out JsonElement usageElement)
                && usageElement.ValueKind == JsonValueKind.Object)
            {
                cachedTokens ??= ReadNestedInt32(usageElement, "input_tokens_details", "cached_tokens");
                reasoningTokens ??= ReadNestedInt32(usageElement, "output_tokens_details", "reasoning_tokens");
            }
        }
        catch (JsonException)
        {
            // The canonical body already parsed; optional detail enrichment
            // failures never invalidate the response.
        }

        if (cachedTokens == usage.CachedTokens && reasoningTokens == usage.ReasoningTokens)
        {
            return response;
        }

        return response with
        {
            Usage = usage with
            {
                CachedTokens = cachedTokens,
                ReasoningTokens = reasoningTokens,
            },
        };
    }

    private static int? ReadNestedInt32(JsonElement parent, string objectName, string propertyName)
    {
        if (parent.ValueKind != JsonValueKind.Object
            || !parent.TryGetProperty(objectName, out JsonElement nested)
            || nested.ValueKind != JsonValueKind.Object
            || !nested.TryGetProperty(propertyName, out JsonElement value))
        {
            return null;
        }

        return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out int parsed) ? parsed : null;
    }
}
