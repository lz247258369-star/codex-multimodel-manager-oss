using Router.Configuration;
using Router.Core.Support;
using Router.Secrets;

namespace Router.Execution.Tests;

/// <summary>
/// Deterministic schema-v1 execution test configuration for one provider. All
/// data is synthetic; no provider, key, or network access exists.
/// </summary>
public sealed record ProviderExecutionSpec(
    string ProviderId,
    string AdapterId,
    string SecretEnvironmentName,
    string ClientModelId,
    string CatalogModelId,
    string UpstreamModelId,
    string EndpointBaseUrlReference,
    string FakeBasePath)
{
    public string Slug => ProviderId.Replace("_", "-", StringComparison.Ordinal);

    public string RouteId => "route." + Slug;

    public string ProviderRouteId => "provider-route." + Slug;

    public string ModelRouteId => "model-route." + Slug;

    public string EndpointId => "endpoint." + Slug;

    public string BaseUrlReference => "provider-config:" + ProviderId + ".base_url";

    public string Generation => SafeHasher.Sha256Hex("execution-composition-" + ProviderId);
}

/// <summary>Optional per-model-route identity override for multi-route tests.</summary>
public sealed record ModelRouteTestOverride(
    string ClientModelId,
    string? CatalogModelId = null,
    string? UpstreamModelId = null,
    IReadOnlyList<string>? Aliases = null,
    IReadOnlyList<string>? Capabilities = null);

/// <summary>Deterministic execution test config/snapshot factory.</summary>
public static class ExecutionTestConfigFactory
{
    public const string ClientId = "client.codex_cli";
    public const string ProtocolRouteId = "protocol-route.responses-pass-through";
    public const string TimeoutPolicyId = "policy.timeout-default";
    public const string RetryPolicyId = "policy.retry-safe-default";
    public const string FailoverPolicyId = "policy.failover-off";

    public static ProviderExecutionSpec OpenRouter { get; } = new(
        "mm_openrouter",
        "adapter.provider.mm_openrouter.responses.v1",
        "OPENROUTER_API_KEY",
        "client-model-openrouter",
        "catalog-model-openrouter",
        "upstream-model-openrouter",
        "provider-config:mm_openrouter.base_url",
        string.Empty);

    public static ProviderExecutionSpec ModelStudio { get; } = new(
        "mm_modelstudio",
        "adapter.provider.mm_modelstudio.responses.v1",
        "CODEX_DASHSCOPE_API_KEY",
        "client-model-modelstudio",
        "catalog-model-modelstudio",
        "upstream-model-modelstudio",
        "provider-config:mm_modelstudio.base_url",
        "compatible-mode/v1");

    public static ProviderExecutionSpec OpenAiApi { get; } = new(
        "mm_openai_api",
        "adapter.provider.mm_openai_api.responses.v1",
        "CODEX_OPENAI_API_KEY",
        "client-model-openai",
        "catalog-model-openai",
        "upstream-model-openai",
        "provider-config:mm_openai_api.base_url",
        "v1");

    public static ProviderExecutionSpec MiMo { get; } = new(
        "mm_mimo",
        "adapter.provider.mm_mimo.responses.v1",
        "MIMO_API_KEY",
        "client-model-mimo",
        "catalog-model-mimo",
        "upstream-model-mimo",
        "provider-config:mm_mimo.base_url",
        "v1");

    public static IReadOnlyList<ProviderExecutionSpec> AllSpecs { get; } =
    [
        OpenRouter,
        ModelStudio,
        OpenAiApi,
        MiMo,
    ];

    public static EffectiveRouterConfigSnapshot Snapshot(
        IReadOnlyList<RouterRouteConfig> routes,
        string generation,
        IReadOnlyDictionary<string, ModelRouteTestOverride>? modelOverrides = null,
        IReadOnlyList<string>? clientAllowedRouteIds = null,
        IReadOnlyList<ClientConfig>? additionalClients = null)
    {
        RouterConfig config = new()
        {
            SchemaVersion = RouterConfig.CurrentSchemaVersion,
            Version = 1,
            Mode = RouterMode.Direct,
            LocalRouter = new LocalRouterConfig
            {
                Enabled = false,
                Host = "127.0.0.1",
                Port = 47821,
                ClientAuth = new ClientAuthConfig { Mode = "bearer_env_ref", TokenRef = "CODEX_LOCAL_ROUTER_TOKEN" },
                Limits = new LimitsConfig
                {
                    MaxRequestBytes = 16_777_216,
                    MaxHeaderBytes = 32_768,
                    MaxConnections = 32,
                    ShutdownGraceMs = 15_000,
                },
            },
            Clients = new[] { Client(clientAllowedRouteIds) }
                .Concat(additionalClients ?? [])
                .ToArray(),
            ProtocolRoutes = [ProtocolRoute()],
            ProviderRoutes = routes.Select(static route => route.ProviderRouteId).Distinct(StringComparer.Ordinal)
                .Select(ProviderRouteFor).ToArray(),
            Endpoints = routes.Select(static route => route.ProviderRouteId).Distinct(StringComparer.Ordinal)
                .Select(EndpointFor).ToArray(),
            ModelRoutes = routes.Select(static route => route.ModelRouteId).Distinct(StringComparer.Ordinal)
                .Select(modelRouteId => ModelRouteFor(modelRouteId, modelOverrides)).ToArray(),
            Routes = routes.ToArray(),
            Policies =
            [
                new PolicyConfig { PolicyId = TimeoutPolicyId, Version = 1 },
                new PolicyConfig { PolicyId = RetryPolicyId, Version = 1 },
                new PolicyConfig { PolicyId = FailoverPolicyId, Version = 1 },
            ],
            UpdatedAt = DateTimeOffset.Parse("2026-08-27T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal),
        };

        return new EffectiveRouterConfigSnapshot
        {
            Config = config,
            ConfigGeneration = generation,
            LoadedAt = DateTimeOffset.UnixEpoch,
            Source = new ConfigSourceProvenance
            {
                DefaultsPath = "execution-test-defaults.json",
                HasUserConfig = false,
                DefaultsSha256 = "test",
            },
        };
    }

    public static ClientConfig Client(IReadOnlyList<string>? allowedRouteIds = null)
        => new()
        {
            ClientId = ClientId,
            AdapterId = "adapter.client.codex_cli.responses.v1",
            Enabled = true,
            AuthScope = "responses:invoke",
            AllowedRouteIds = allowedRouteIds ?? [],
            Capabilities = ["text", "streaming", "reasoning", "tools", "usage", "cancellation"],
            Version = 1,
        };

    public static ProtocolRouteConfig ProtocolRoute()
        => new()
        {
            ProtocolRouteId = ProtocolRouteId,
            IngressProtocol = "protocol.openai.responses.v1",
            UpstreamProtocol = "protocol.openai.responses.v1",
            AdapterId = "adapter.protocol.responses-compatible.v1",
            AdapterVersion = "1.0",
            Capabilities = ["responses", "text", "streaming", "reasoning", "tools", "usage", "cancellation"],
            LossPolicy = "fail_closed",
            Version = 1,
        };

    public static RouterRouteConfig Route(
        string providerId,
        string routeId,
        int priority = 100,
        int weight = 100,
        bool enabled = true,
        string healthState = "UNKNOWN",
        string? instance = null)
    {
        string suffix = instance ?? providerId.Replace("_", "-", StringComparison.Ordinal);
        return new RouterRouteConfig
        {
            RouteId = routeId,
            ClientIds = [ClientId],
            ProviderRouteId = "provider-route." + suffix,
            ProtocolRouteId = ProtocolRouteId,
            ModelRouteId = "model-route." + suffix,
            Enabled = enabled,
            Priority = priority,
            Weight = weight,
            HealthState = healthState,
            TimeoutPolicyId = TimeoutPolicyId,
            RetryPolicyId = RetryPolicyId,
            FailoverPolicyId = FailoverPolicyId,
            FallbackRouteIds = [],
            CreatedAt = DateTimeOffset.UnixEpoch,
            UpdatedAt = DateTimeOffset.UnixEpoch,
            Version = 1,
        };
    }

    private static ProviderRouteConfig ProviderRouteFor(string providerRouteId)
    {
        ProviderExecutionSpec spec = SpecFor(providerRouteId);
        return new ProviderRouteConfig
        {
            ProviderRouteId = providerRouteId,
            ProviderId = spec.ProviderId,
            AdapterId = spec.AdapterId,
            AdapterVersion = "1.0",
            EndpointIds = [EndpointIdFor(providerRouteId)],
            SecretRef = SecretRef(spec),
            BaseUrlRef = spec.BaseUrlReference,
            Enabled = true,
            Capabilities = ["responses", "text", "streaming", "reasoning", "tools", "usage", "cancellation"],
            Version = 1,
        };
    }

    private static EndpointConfig EndpointFor(string providerRouteId)
    {
        ProviderExecutionSpec spec = SpecFor(providerRouteId);
        return new EndpointConfig
        {
            EndpointId = EndpointIdFor(providerRouteId),
            BaseUrlRef = EndpointBaseUrlReferenceFor(providerRouteId),
            Enabled = true,
            DataBoundary = "provider-default",
            TlsRequired = true,
            Priority = 100,
            Weight = 100,
            Version = 1,
        };
    }

    /// <summary>
    /// Deterministic endpoint base-URL reference for one provider route. The
    /// canonical provider route uses the Manager-style provider reference so
    /// existing override conventions stay stable; additional endpoints under
    /// the same provider get explicit test-only per-endpoint references so
    /// alternate-endpoint execution is observable.
    /// </summary>
    public static string EndpointBaseUrlReferenceFor(string providerRouteId)
    {
        ProviderExecutionSpec spec = SpecFor(providerRouteId);
        const string prefix = "provider-route.";
        string suffix = providerRouteId[prefix.Length..];
        return string.Equals(suffix, spec.Slug, StringComparison.Ordinal)
            ? spec.BaseUrlReference
            : "provider-config:" + spec.ProviderId + ".endpoint." + suffix + ".base_url";
    }

    private static ModelRouteConfig ModelRouteFor(
        string modelRouteId,
        IReadOnlyDictionary<string, ModelRouteTestOverride>? modelOverrides)
    {
        ProviderExecutionSpec spec = SpecFor(modelRouteId);
        string clientModelId = spec.ClientModelId;
        string catalogModelId = spec.CatalogModelId;
        string upstreamModelId = spec.UpstreamModelId;
        IReadOnlyList<string> aliases = [];
        IReadOnlyList<string> capabilities = ["text", "streaming", "reasoning", "tools", "usage"];
        if (modelOverrides is not null && modelOverrides.TryGetValue(modelRouteId, out ModelRouteTestOverride? routeOverride))
        {
            clientModelId = routeOverride.ClientModelId;
            catalogModelId = routeOverride.CatalogModelId ?? spec.CatalogModelId;
            upstreamModelId = routeOverride.UpstreamModelId ?? spec.UpstreamModelId;
            aliases = routeOverride.Aliases ?? [];
            capabilities = routeOverride.Capabilities ?? capabilities;
        }

        return new ModelRouteConfig
        {
            ModelRouteId = modelRouteId,
            ProviderId = spec.ProviderId,
            ClientModelId = clientModelId,
            ModelId = catalogModelId,
            UpstreamModelId = upstreamModelId,
            Aliases = aliases,
            Capabilities = capabilities,
            PricingRef = "pricing." + spec.ProviderId,
            IdentityVerification = "explicit_config",
            Enabled = true,
            Version = 1,
        };
    }

    private static ProviderExecutionSpec SpecFor(string id)
    {
        ProviderExecutionSpec[] all = [OpenRouter, ModelStudio, OpenAiApi, MiMo];
        ProviderExecutionSpec? exact = all.FirstOrDefault(spec =>
            string.Equals(spec.ProviderRouteId, id, StringComparison.Ordinal)
            || string.Equals(spec.ModelRouteId, id, StringComparison.Ordinal));
        if (exact is not null)
        {
            return exact;
        }

        foreach (ProviderExecutionSpec spec in all)
        {
            if (id.StartsWith("provider-route." + spec.Slug + "-", StringComparison.Ordinal)
                || id.StartsWith("model-route." + spec.Slug + "-", StringComparison.Ordinal))
            {
                return spec;
            }
        }

        throw new ArgumentOutOfRangeException(nameof(id), id, "No provider execution spec matches the identifier.");
    }

    private static string EndpointIdFor(string providerRouteId)
    {
        ProviderExecutionSpec spec = SpecFor(providerRouteId);
        const string prefix = "provider-route.";
        string suffix = providerRouteId[prefix.Length..];
        return string.Equals(suffix, spec.Slug, StringComparison.Ordinal)
            ? spec.EndpointId
            : "endpoint." + suffix;
    }

    private static SecretReference SecretRef(ProviderExecutionSpec spec)
        => new()
        {
            Resolver = "environment",
            Name = spec.SecretEnvironmentName,
            Scope = SecretScope.UserOrProcess,
            AllowedProviderIds = [spec.ProviderId],
            Version = 1,
        };
}
