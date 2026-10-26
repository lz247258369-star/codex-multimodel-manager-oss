using System.Text.Json.Nodes;

namespace Router.Configuration;

/// <summary>
/// Field-level merge of defaults and optional user config. Unknown properties
/// are rejected as security violations; arrays and scalars replace defaults.
/// The merged object retains schema-v1 key order for deterministic output.
/// </summary>
public static class RouterConfigMerger
{
    private static readonly HashSet<string> TopLevelProperties = new(StringComparer.Ordinal)
    {
        "schema_version", "version", "mode", "local_router", "clients",
        "protocol_routes", "provider_routes", "endpoints", "model_routes",
        "routes", "policies", "updated_at",
    };

    private static readonly HashSet<string> LocalRouterProperties = new(StringComparer.Ordinal)
    {
        "enabled", "host", "port", "client_auth", "limits", "thread_selection",
    };

    private static readonly HashSet<string> ClientAuthProperties = new(StringComparer.Ordinal)
    {
        "mode", "token_ref",
    };

    private static readonly HashSet<string> LimitsProperties = new(StringComparer.Ordinal)
    {
        "max_request_bytes", "max_header_bytes", "max_connections", "shutdown_grace_ms",
    };

    private static readonly HashSet<string> ThreadSelectionProperties = new(StringComparer.Ordinal)
    {
        "enabled", "pending_ttl_ms", "active_idle_ttl_ms", "quota_failover_enabled",
    };

    /// <summary>Merges user config over defaults. Returns a deep-cloned merged object.</summary>
    public static JsonObject Merge(JsonObject defaults, JsonObject? user)
    {
        ArgumentNullException.ThrowIfNull(defaults);

        var result = (JsonObject)defaults.DeepClone();
        if (user is null)
        {
            return result;
        }

        MergeTopLevel(result, user);
        return result;
    }

    /// <summary>
    /// Rejects unknown fields in a full config document (used for defaults
    /// files, which are not merged with a user object).
    /// </summary>
    public static void EnsureKnownFields(JsonObject config)
    {
        ArgumentNullException.ThrowIfNull(config);

        CheckKeys(config, TopLevelProperties, "config");
        if (config["local_router"] is JsonObject local)
        {
            CheckKeys(local, LocalRouterProperties, "local_router");
            if (local["client_auth"] is JsonObject auth)
            {
                CheckKeys(auth, ClientAuthProperties, "local_router.client_auth");
            }

            if (local["limits"] is JsonObject limits)
            {
                CheckKeys(limits, LimitsProperties, "local_router.limits");
            }

            if (local["thread_selection"] is JsonObject threadSelection)
            {
                CheckKeys(threadSelection, ThreadSelectionProperties, "local_router.thread_selection");
            }
        }
    }

    private static void CheckKeys(JsonObject obj, HashSet<string> allowed, string path)
    {
        foreach (string key in obj.Select(static property => property.Key))
        {
            if (!allowed.Contains(key))
            {
                throw new ConfigMergeSecurityViolation(path + "." + key);
            }
        }
    }

    private static void MergeTopLevel(JsonObject target, JsonObject source)
    {
        foreach (KeyValuePair<string, JsonNode?> property in source)
        {
            if (!TopLevelProperties.Contains(property.Key))
            {
                throw new ConfigMergeSecurityViolation(property.Key);
            }

            if (property.Key == "local_router" && property.Value is JsonObject userLocal)
            {
                MergeLocalRouter((JsonObject)target["local_router"]!, userLocal);
            }
            else
            {
                target[property.Key] = property.Value?.DeepClone();
            }
        }
    }

    private static void MergeLocalRouter(JsonObject target, JsonObject source)
    {
        foreach (KeyValuePair<string, JsonNode?> property in source)
        {
            if (!LocalRouterProperties.Contains(property.Key))
            {
                throw new ConfigMergeSecurityViolation("local_router." + property.Key);
            }

            if (property.Key == "client_auth" && property.Value is JsonObject userAuth)
            {
                MergeObject((JsonObject)target["client_auth"]!, userAuth, ClientAuthProperties);
            }
            else if (property.Key == "limits" && property.Value is JsonObject userLimits)
            {
                MergeObject((JsonObject)target["limits"]!, userLimits, LimitsProperties);
            }
            else if (property.Key == "thread_selection" && property.Value is JsonObject userThreadSelection)
            {
                MergeObject((JsonObject)target["thread_selection"]!, userThreadSelection, ThreadSelectionProperties);
            }
            else
            {
                target[property.Key] = property.Value?.DeepClone();
            }
        }
    }

    private static void MergeObject(JsonObject target, JsonObject source, HashSet<string> allowed)
    {
        foreach (KeyValuePair<string, JsonNode?> property in source)
        {
            if (!allowed.Contains(property.Key))
            {
                throw new ConfigMergeSecurityViolation(property.Key);
            }

            target[property.Key] = property.Value?.DeepClone();
        }
    }
}

/// <summary>Thrown when a config field outside the schema whitelist is merged.</summary>
internal sealed class ConfigMergeSecurityViolation : Exception
{
    public ConfigMergeSecurityViolation(string propertyPath)
        : base(propertyPath)
    {
        PropertyPath = propertyPath;
    }

    public string PropertyPath { get; }
}
