using System.Text.RegularExpressions;
using Router.Core.Errors;
using Router.Secrets;

namespace Router.Configuration;

/// <summary>
/// Semantic validation of the effective config. Unknown schemas, security
/// invariant violations, duplicate IDs, unknown enums, invalid limits, and
/// invalid secret references all fail closed.
/// </summary>
public static class RouterConfigValidator
{
    private static readonly HashSet<string> KnownProviderIds = new(StringComparer.Ordinal)
    {
        "chatgpt", "mm_openai_api", "mm_modelstudio", "mm_openrouter", "mm_mimo", "deepseek",
    };

    private static readonly HashSet<string> KnownCapabilities = new(StringComparer.Ordinal)
    {
        "text", "streaming", "reasoning", "tools", "usage", "cancellation", "responses",
    };

    private static readonly HashSet<string> KnownHealthStates = new(StringComparer.Ordinal)
    {
        "UNKNOWN", "HEALTHY", "DEGRADED", "UNHEALTHY", "DISABLED",
    };

    private static readonly Regex ClientIdPattern = new("^client\\.[a-z0-9_]+$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private static readonly Regex AdapterIdPattern = new("^adapter\\.[a-z0-9_.-]+$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private static readonly Regex ProtocolRouteIdPattern = new("^protocol-route\\.[a-z0-9-]+$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private static readonly Regex ProviderRouteIdPattern = new("^provider-route\\.[a-z0-9-]+$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private static readonly Regex ModelRouteIdPattern = new("^model-route\\.[a-z0-9-]+$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private static readonly Regex RouteIdPattern = new("^route\\.[a-z0-9-]+$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private static readonly Regex PolicyIdPattern = new("^policy\\.[a-z0-9-]+$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private static readonly Regex EndpointIdPattern = new("^endpoint\\.[a-z0-9-]+$", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly HashSet<string> KnownDataBoundaries = new(StringComparer.Ordinal)
    {
        "provider-default", "residency-required", "no-store",
    };

    /// <summary>Returns a normalized error when the effective config is invalid; otherwise null.</summary>
    public static RouterError? Validate(RouterConfig config)
    {
        if (config is null)
        {
            return ConfigurationErrors.Invalid();
        }

        if (config.SchemaVersion != RouterConfig.CurrentSchemaVersion)
        {
            return ConfigurationErrors.SchemaUnsupported();
        }

        if (config.Version < 1)
        {
            return ConfigurationErrors.Invalid("version");
        }

        if (config.Mode == RouterMode.Router && !config.LocalRouter.Enabled)
        {
            return ConfigurationErrors.Invalid("mode");
        }

        if (!string.Equals(config.LocalRouter.Host, "127.0.0.1", StringComparison.Ordinal))
        {
            return ConfigurationErrors.SecurityViolation("local_router.host");
        }

        if (config.LocalRouter.Port is < 1 or > 65535)
        {
            return ConfigurationErrors.SecurityViolation("local_router.port");
        }

        if (!string.Equals(config.LocalRouter.ClientAuth.Mode, "bearer_env_ref", StringComparison.Ordinal))
        {
            return ConfigurationErrors.Invalid("local_router.client_auth.mode");
        }

        if (!EnvironmentSecretAllowlist.IsLocalRouterTokenReferenceAllowed(config.LocalRouter.ClientAuth.TokenRef))
        {
            return ConfigurationErrors.SecurityViolation("local_router.client_auth.token_ref");
        }

        RouterError? limitsError = ValidateLimits(config.LocalRouter.Limits);
        if (limitsError is not null)
        {
            return limitsError;
        }

        RouterError? threadSelectionError = ValidateThreadSelection(config.LocalRouter.ThreadSelection);
        if (threadSelectionError is not null)
        {
            return threadSelectionError;
        }

        RouterError? error;
        if ((error = ValidateClients(config.Clients)) is not null
            || (error = ValidateProtocolRoutes(config.ProtocolRoutes)) is not null
            || (error = ValidateProviderRoutes(config.ProviderRoutes)) is not null
            || (error = ValidateEndpoints(config.Endpoints)) is not null
            || (error = ValidateModelRoutes(config.ModelRoutes)) is not null
            || (error = ValidateRoutes(config.Routes)) is not null
            || (error = ValidatePolicies(config.Policies)) is not null)
        {
            return error;
        }

        return null;
    }

    private static RouterError? ValidateLimits(LimitsConfig limits)
    {
        return ValidateLimitsCore(limits);
    }

    /// <summary>
    /// Validates the HS-1B thread-selection block. Durations outside the hard
    /// floors/ceilings are security violations so a hostile config can never
    /// widen the runtime bounds.
    /// </summary>
    private static RouterError? ValidateThreadSelection(ThreadSelectionConfig threadSelection)
    {
        if (threadSelection.QuotaFailoverEnabled && !threadSelection.Enabled)
        {
            return ConfigurationErrors.Invalid("local_router.thread_selection.quota_failover_enabled");
        }

        if (threadSelection.PendingTtlMs is < 30_000 or > 1_800_000)
        {
            return ConfigurationErrors.SecurityViolation("local_router.thread_selection.pending_ttl_ms");
        }

        if (threadSelection.ActiveIdleTtlMs is < 3_600_000 or > 604_800_000)
        {
            return ConfigurationErrors.SecurityViolation("local_router.thread_selection.active_idle_ttl_ms");
        }

        return null;
    }

    private static RouterError? ValidateLimitsCore(LimitsConfig limits)
    {
        if (limits.MaxRequestBytes is < 1 or > ConfigLimitCeilings.MaxRequestBytesCeiling)
        {
            return ConfigurationErrors.SecurityViolation("limits.max_request_bytes");
        }

        if (limits.MaxHeaderBytes is < 1 or > ConfigLimitCeilings.MaxHeaderBytesCeiling)
        {
            return ConfigurationErrors.SecurityViolation("limits.max_header_bytes");
        }

        if (limits.MaxConnections is < 1 or > ConfigLimitCeilings.MaxConnectionsCeiling)
        {
            return ConfigurationErrors.SecurityViolation("limits.max_connections");
        }

        if (limits.ShutdownGraceMs is < 1 or > ConfigLimitCeilings.MaxShutdownGraceMsCeiling)
        {
            return ConfigurationErrors.SecurityViolation("limits.shutdown_grace_ms");
        }

        return null;
    }

    private static RouterError? ValidateEndpoints(IReadOnlyList<EndpointConfig> endpoints)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (EndpointConfig endpoint in endpoints)
        {
            if (!EndpointIdPattern.IsMatch(endpoint.EndpointId) || !seen.Add(endpoint.EndpointId))
            {
                return ConfigurationErrors.Invalid("endpoints.endpoint_id");
            }

            if (endpoint.Version < 1)
            {
                return ConfigurationErrors.Invalid("endpoints.version");
            }

            if (string.IsNullOrWhiteSpace(endpoint.BaseUrlRef) || endpoint.BaseUrlRef.Length > 256)
            {
                return ConfigurationErrors.Invalid("endpoints.base_url_ref");
            }

            if (!KnownDataBoundaries.Contains(endpoint.DataBoundary))
            {
                return ConfigurationErrors.Invalid("endpoints.data_boundary");
            }

            if (endpoint.Priority < 0 || endpoint.Weight < 0)
            {
                return ConfigurationErrors.Invalid("endpoints.priority_weight");
            }
        }

        return null;
    }

    private static RouterError? ValidateClients(IReadOnlyList<ClientConfig> clients)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (ClientConfig client in clients)
        {
            if (!ClientIdPattern.IsMatch(client.ClientId) || !seen.Add(client.ClientId))
            {
                return ConfigurationErrors.Invalid("clients.client_id");
            }

            if (client.Version < 1)
            {
                return ConfigurationErrors.Invalid("clients.version");
            }

            if (!AdapterIdPattern.IsMatch(client.AdapterId))
            {
                return ConfigurationErrors.Invalid("clients.adapter_id");
            }

            if (string.IsNullOrWhiteSpace(client.AuthScope) || client.AuthScope.Length > 128)
            {
                return ConfigurationErrors.Invalid("clients.auth_scope");
            }

            if (!ValidateStringList(client.AllowedRouteIds, RouteIdPattern))
            {
                return ConfigurationErrors.Invalid("clients.allowed_route_ids");
            }

            if (!ValidateCapabilities(client.Capabilities))
            {
                return ConfigurationErrors.Invalid("clients.capabilities");
            }
        }

        return null;
    }

    private static RouterError? ValidateProtocolRoutes(IReadOnlyList<ProtocolRouteConfig> routes)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (ProtocolRouteConfig route in routes)
        {
            if (!ProtocolRouteIdPattern.IsMatch(route.ProtocolRouteId) || !seen.Add(route.ProtocolRouteId))
            {
                return ConfigurationErrors.Invalid("protocol_routes.protocol_route_id");
            }

            if (route.Version < 1)
            {
                return ConfigurationErrors.Invalid("protocol_routes.version");
            }

            if (!IsValidQualifiedName(route.IngressProtocol) || !IsValidQualifiedName(route.UpstreamProtocol))
            {
                return ConfigurationErrors.Invalid("protocol_routes.protocol");
            }

            if (!AdapterIdPattern.IsMatch(route.AdapterId) || string.IsNullOrEmpty(route.AdapterVersion) || route.AdapterVersion.Length > 32)
            {
                return ConfigurationErrors.Invalid("protocol_routes.adapter");
            }

            if (!string.Equals(route.LossPolicy, "fail_closed", StringComparison.Ordinal))
            {
                return ConfigurationErrors.Invalid("protocol_routes.loss_policy");
            }

            if (!ValidateCapabilities(route.Capabilities))
            {
                return ConfigurationErrors.Invalid("protocol_routes.capabilities");
            }
        }

        return null;
    }

    private static RouterError? ValidateProviderRoutes(IReadOnlyList<ProviderRouteConfig> routes)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (ProviderRouteConfig route in routes)
        {
            if (!ProviderRouteIdPattern.IsMatch(route.ProviderRouteId) || !seen.Add(route.ProviderRouteId))
            {
                return ConfigurationErrors.Invalid("provider_routes.provider_route_id");
            }

            if (route.Version < 1)
            {
                return ConfigurationErrors.Invalid("provider_routes.version");
            }

            if (!KnownProviderIds.Contains(route.ProviderId))
            {
                return ConfigurationErrors.Invalid("provider_routes.provider_id");
            }

            if (!AdapterIdPattern.IsMatch(route.AdapterId) || string.IsNullOrEmpty(route.AdapterVersion) || route.AdapterVersion.Length > 32)
            {
                return ConfigurationErrors.Invalid("provider_routes.adapter");
            }

            if (!ValidateStringList(route.EndpointIds, EndpointIdPattern))
            {
                return ConfigurationErrors.Invalid("provider_routes.endpoint_ids");
            }

            if (route.SecretRef is { } secretRef)
            {
                RouterError? secretError = SecretReferenceValidator.Validate(secretRef);
                if (secretError is not null)
                {
                    return secretError;
                }

                if (!EnvironmentSecretAllowlist.IsProviderSecretAllowed(route.ProviderId, secretRef.Name))
                {
                    return ConfigurationErrors.SecurityViolation("provider_routes.secret_ref");
                }
            }

            if (route.BaseUrlRef is { Length: > 256 })
            {
                return ConfigurationErrors.Invalid("provider_routes.base_url_ref");
            }

            if (!ValidateCapabilities(route.Capabilities))
            {
                return ConfigurationErrors.Invalid("provider_routes.capabilities");
            }
        }

        return null;
    }

    private static RouterError? ValidateModelRoutes(IReadOnlyList<ModelRouteConfig> routes)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (ModelRouteConfig route in routes)
        {
            if (!ModelRouteIdPattern.IsMatch(route.ModelRouteId) || !seen.Add(route.ModelRouteId))
            {
                return ConfigurationErrors.Invalid("model_routes.model_route_id");
            }

            if (route.Version < 1)
            {
                return ConfigurationErrors.Invalid("model_routes.version");
            }

            if (!KnownProviderIds.Contains(route.ProviderId))
            {
                return ConfigurationErrors.Invalid("model_routes.provider_id");
            }

            if (!IsValidModelId(route.ClientModelId) || !IsValidModelId(route.ModelId) || !IsValidModelId(route.UpstreamModelId))
            {
                return ConfigurationErrors.Invalid("model_routes.model_id");
            }

            if (!ValidateStringList(route.Aliases, null))
            {
                return ConfigurationErrors.Invalid("model_routes.aliases");
            }

            if (!string.Equals(route.IdentityVerification, "explicit_config", StringComparison.Ordinal))
            {
                return ConfigurationErrors.Invalid("model_routes.identity_verification");
            }

            if (!ValidateCapabilities(route.Capabilities))
            {
                return ConfigurationErrors.Invalid("model_routes.capabilities");
            }
        }

        return null;
    }

    private static RouterError? ValidateRoutes(IReadOnlyList<RouterRouteConfig> routes)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (RouterRouteConfig route in routes)
        {
            if (!RouteIdPattern.IsMatch(route.RouteId) || !seen.Add(route.RouteId))
            {
                return ConfigurationErrors.Invalid("routes.route_id");
            }

            if (route.Version < 1)
            {
                return ConfigurationErrors.Invalid("routes.version");
            }

            if (!ValidateStringList(route.ClientIds, null)
                || !ProviderRouteIdPattern.IsMatch(route.ProviderRouteId)
                || !ProtocolRouteIdPattern.IsMatch(route.ProtocolRouteId)
                || !ModelRouteIdPattern.IsMatch(route.ModelRouteId)
                || !PolicyIdPattern.IsMatch(route.TimeoutPolicyId)
                || !PolicyIdPattern.IsMatch(route.RetryPolicyId)
                || !PolicyIdPattern.IsMatch(route.FailoverPolicyId))
            {
                return ConfigurationErrors.Invalid("routes.references");
            }

            if (route.Priority < 0 || route.Weight < 0)
            {
                return ConfigurationErrors.Invalid("routes.priority_weight");
            }

            if (!KnownHealthStates.Contains(route.HealthState))
            {
                return ConfigurationErrors.Invalid("routes.health_state");
            }

            if (!ValidateStringList(route.FallbackRouteIds, RouteIdPattern))
            {
                return ConfigurationErrors.Invalid("routes.fallback_route_ids");
            }
        }

        return null;
    }

    private static RouterError? ValidatePolicies(IReadOnlyList<PolicyConfig> policies)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (PolicyConfig policy in policies)
        {
            if (!PolicyIdPattern.IsMatch(policy.PolicyId) || !seen.Add(policy.PolicyId))
            {
                return ConfigurationErrors.Invalid("policies.policy_id");
            }

            if (policy.Version < 1)
            {
                return ConfigurationErrors.Invalid("policies.version");
            }

            RouterError? bodyError = ValidatePolicyBodies(policy);
            if (bodyError is not null)
            {
                return bodyError;
            }
        }

        return null;
    }

    private static RouterError? ValidatePolicyBodies(PolicyConfig policy)
    {
        string path = "policies." + policy.PolicyId;
        if (policy.RetryBody is { } retry)
        {
            if (retry.SchemaVersionValue != PolicyRetryBodyConfig.SchemaVersion
                || retry.MaxAttempts is < 1 or > PolicyBodyLimits.MaxRetryAttempts
                || !IsBoundedDuration(retry.BaseDelayMs)
                || !IsBoundedDuration(retry.MaxDelayMs)
                || !IsBoundedDuration(retry.MaxRetryAfterMs)
                || retry.Jitter is < 0m or > 1m
                || retry.MaxDelayMs < retry.BaseDelayMs)
            {
                return ConfigurationErrors.Invalid(path + ".retry");
            }
        }

        if (policy.TimeoutBody is { } timeout)
        {
            if (timeout.SchemaVersionValue != PolicyTimeoutBodyConfig.SchemaVersion
                || !IsBoundedDuration(timeout.ConnectTimeoutMs)
                || !IsBoundedDuration(timeout.FirstByteTimeoutMs)
                || !IsBoundedDuration(timeout.IdleTimeoutMs)
                || !IsBoundedDuration(timeout.AttemptTimeoutMs)
                || !IsBoundedDuration(timeout.TotalTimeoutMs)
                || timeout.FirstByteTimeoutMs < timeout.ConnectTimeoutMs
                || timeout.AttemptTimeoutMs < timeout.FirstByteTimeoutMs
                || timeout.TotalTimeoutMs < timeout.AttemptTimeoutMs)
            {
                return ConfigurationErrors.Invalid(path + ".timeout");
            }
        }

        if (policy.FailoverBody is { } failover)
        {
            if (failover.SchemaVersionValue != PolicyFailoverBodyConfig.SchemaVersion)
            {
                return ConfigurationErrors.Invalid(path + ".failover");
            }
        }

        return null;
    }

    private static bool IsBoundedDuration(long milliseconds)
        => milliseconds is >= PolicyBodyLimits.MinDurationMs and <= PolicyBodyLimits.MaxDurationMs;

    private static bool ValidateCapabilities(IReadOnlyList<string> capabilities)
        => capabilities.Count > 0 && capabilities.All(static c => !string.IsNullOrEmpty(c) && KnownCapabilities.Contains(c));

    private static bool ValidateStringList(IReadOnlyList<string> values, Regex? pattern)
        => values.All(value => !string.IsNullOrEmpty(value)
            && value.Length <= 128
            && (pattern is null || pattern.IsMatch(value)));

    private static bool IsValidQualifiedName(string value)
        => !string.IsNullOrEmpty(value) && value.Length <= 128 && value.All(static c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '.' or '_' or '-');

    private static bool IsValidModelId(string value)
        => !string.IsNullOrEmpty(value) && value.Length <= 128 && value.All(static c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or >= 'A' and <= 'Z' or '.' or '_' or '-' or '/' or ':' or ' ');
}
