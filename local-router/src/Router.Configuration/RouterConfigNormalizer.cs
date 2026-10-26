using System.Text.Json;
using System.Text.Json.Nodes;

namespace Router.Configuration;

/// <summary>
/// Deterministic normalization of the merged config: entity arrays are sorted
/// by ID, scalar string arrays are sorted, and timestamps are excluded from the
/// generation input. No locale, timestamp, or random input participates.
/// </summary>
public static class RouterConfigNormalizer
{
    private static readonly string[] EntityArrayNames =
    {
        "clients", "protocol_routes", "provider_routes", "endpoints",
        "model_routes", "routes", "policies",
    };

    private static readonly string[] EntityIdKeys =
    {
        "client_id", "protocol_route_id", "provider_route_id", "endpoint_id",
        "model_route_id", "route_id", "policy_id",
    };

    private static readonly string[] ScalarArrayNames =
    {
        "allowed_route_ids", "capabilities", "endpoint_ids", "aliases", "client_ids",
        "fallback_route_ids", "allowed_provider_ids",
    };

    private static readonly JsonSerializerOptions CompactOptions = new() { WriteIndented = false };

    /// <summary>Returns a deep-cloned, canonically ordered copy of the merged config.</summary>
    public static JsonObject Normalize(JsonObject source)
    {
        ArgumentNullException.ThrowIfNull(source);

        var copy = (JsonObject)source.DeepClone();
        SortEntityArrays(copy);
        SortScalarArrays(copy);
        return copy;
    }

    /// <summary>Serializes the normalized config to compact canonical JSON.</summary>
    public static string ToJson(JsonObject normalized)
        => normalized.ToJsonString(CompactOptions);

    /// <summary>
    /// Canonical generation input: normalized config without the updated_at
    /// timestamp, so identical semantic configs hash identically.
    /// </summary>
    public static string ToGenerationInput(JsonObject normalized)
    {
        var copy = (JsonObject)normalized.DeepClone();
        copy.Remove("updated_at");
        return copy.ToJsonString(CompactOptions);
    }

    private static void SortEntityArrays(JsonObject root)
    {
        foreach (string name in EntityArrayNames)
        {
            if (root[name] is JsonArray array)
            {
                JsonNode?[] sorted = array
                    .Where(static item => item is not null)
                    .Select(static item => item!)
                    .Select(static item => item.DeepClone())
                    .OrderBy(static item => EntitySortKey(item), StringComparer.Ordinal)
                    .ToArray();
                root[name] = new JsonArray(sorted);
            }
        }
    }

    private static string EntitySortKey(JsonNode item)
    {
        if (item is JsonObject obj)
        {
            foreach (string key in EntityIdKeys)
            {
                if (obj[key] is JsonValue value && value.TryGetValue<string>(out string? id) && !string.IsNullOrEmpty(id))
                {
                    return id;
                }
            }
        }

        return string.Empty;
    }

    private static void SortScalarArrays(JsonObject root)
    {
        foreach (JsonObject obj in Descendants(root))
        {
            foreach (string name in ScalarArrayNames)
            {
                if (obj[name] is JsonArray array && TrySortStringArray(array, out JsonArray sorted))
                {
                    obj[name] = sorted;
                }
            }
        }
    }

    private static bool TrySortStringArray(JsonArray array, out JsonArray sorted)
    {
        var values = new List<JsonValue>(array.Count);
        foreach (JsonNode? item in array)
        {
            if (item is JsonValue value && value.GetValueKind() == JsonValueKind.String)
            {
                values.Add(value);
            }
            else
            {
                sorted = array;
                return false;
            }
        }

        JsonNode?[] ordered = values
            .Select(static value => value.GetValue<string>())
            .OrderBy(static value => value, StringComparer.Ordinal)
            .Select(static value => JsonValue.Create(value))
            .ToArray();
        sorted = new JsonArray(ordered);
        return true;
    }

    private static IEnumerable<JsonObject> Descendants(JsonNode node)
    {
        if (node is JsonObject obj)
        {
            yield return obj;
            foreach (KeyValuePair<string, JsonNode?> child in obj)
            {
                if (child.Value is not null)
                {
                    foreach (JsonObject descendant in Descendants(child.Value))
                    {
                        yield return descendant;
                    }
                }
            }
        }
        else if (node is JsonArray array)
        {
            foreach (JsonNode? child in array)
            {
                if (child is not null)
                {
                    foreach (JsonObject descendant in Descendants(child))
                    {
                        yield return descendant;
                    }
                }
            }
        }
    }
}
