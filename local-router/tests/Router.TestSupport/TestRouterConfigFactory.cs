using Router.CatalogProjection;
using Router.Configuration;
using Router.Core.Support;
using Router.Registries;
using Router.Secrets;

namespace Router.TestSupport;

/// <summary>
/// Deterministic test fixtures for LR-4 registry and resolver tests. All data
/// is synthetic; no provider, key, or network access exists.
/// </summary>
public static class TestRouterConfigFactory
{
    public static string TestGeneration { get; } = SafeHasher.Sha256Hex("lr4-test-generation");

    public const string ClientId = "client.codex_cli";
    public const string ProtocolRouteId = "protocol-route.responses-pass-through";
    public const string ProviderRouteId = "provider-route.openrouter-primary";
    public const string EndpointId = "endpoint.openrouter-primary";
    public const string ModelRouteId = "model-route.glm53-openrouter";
    public const string RouteId = "route.openrouter-glm53";
    public const string ClientModelId = "z-ai/glm-5.3";

    public const string ProtocolAdapterId = "adapter.protocol.responses-compatible.v1";
    public const string ProviderAdapterId = "adapter.provider.mm_openrouter.responses.v1";
    public const string TimeoutPolicyId = "policy.timeout-default";
    public const string RetryPolicyId = "policy.retry-safe-default";
    public const string FailoverPolicyId = "policy.failover-off";

    /// <summary>Standard resolvable schema-v1 config (openrouter primary route).</summary>
    public static RouterConfig StandardConfig()
    {
        return new RouterConfig
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
            Clients = [Client()],
            ProtocolRoutes = [ProtocolRoute()],
            ProviderRoutes = [ProviderRoute()],
            Endpoints = [Endpoint()],
            ModelRoutes = [ModelRoute()],
            Routes = [Route()],
            Policies =
            [
                new PolicyConfig { PolicyId = TimeoutPolicyId, Version = 1 },
                new PolicyConfig { PolicyId = RetryPolicyId, Version = 1 },
                new PolicyConfig { PolicyId = FailoverPolicyId, Version = 1 },
            ],
            UpdatedAt = DateTimeOffset.Parse("2026-08-27T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal),
        };
    }

    public static ClientConfig Client(
        string clientId = ClientId,
        bool enabled = true,
        IReadOnlyList<string>? capabilities = null,
        IReadOnlyList<string>? allowedRouteIds = null)
        => new()
        {
            ClientId = clientId,
            AdapterId = "adapter.client.codex_cli.responses.v1",
            Enabled = enabled,
            AuthScope = "responses:invoke",
            AllowedRouteIds = allowedRouteIds ?? [],
            Capabilities = capabilities ?? DefaultClientCapabilities(),
            Version = 1,
        };

    public static ProtocolRouteConfig ProtocolRoute(
        string protocolRouteId = ProtocolRouteId,
        string adapterId = ProtocolAdapterId,
        string ingressProtocol = "protocol.openai.responses.v1",
        string upstreamProtocol = "protocol.openai.responses.v1",
        IReadOnlyList<string>? capabilities = null)
        => new()
        {
            ProtocolRouteId = protocolRouteId,
            IngressProtocol = ingressProtocol,
            UpstreamProtocol = upstreamProtocol,
            AdapterId = adapterId,
            AdapterVersion = "1.0",
            Capabilities = capabilities ?? FullCapabilities(),
            LossPolicy = "fail_closed",
            Version = 1,
        };

    public static ProviderRouteConfig ProviderRoute(
        string providerRouteId = ProviderRouteId,
        string providerId = "mm_openrouter",
        string adapterId = ProviderAdapterId,
        IReadOnlyList<string>? endpointIds = null,
        bool enabled = true,
        IReadOnlyList<string>? capabilities = null)
        => new()
        {
            ProviderRouteId = providerRouteId,
            ProviderId = providerId,
            AdapterId = adapterId,
            AdapterVersion = "1.0",
            EndpointIds = endpointIds ?? [EndpointId],
            SecretRef = SecretRefFor(providerId),
            BaseUrlRef = "provider-config:" + providerId + ".base_url",
            Enabled = enabled,
            Capabilities = capabilities ?? FullCapabilities(),
            Version = 1,
        };

    public static EndpointConfig Endpoint(
        string endpointId = EndpointId,
        bool enabled = true,
        int priority = 100,
        int weight = 100)
        => new()
        {
            EndpointId = endpointId,
            BaseUrlRef = "provider-config:mm_openrouter.base_url",
            Enabled = enabled,
            DataBoundary = "provider-default",
            TlsRequired = true,
            Priority = priority,
            Weight = weight,
            Version = 1,
        };

    public static ModelRouteConfig ModelRoute(
        string modelRouteId = ModelRouteId,
        string providerId = "mm_openrouter",
        string clientModelId = ClientModelId,
        string modelId = ClientModelId,
        string? upstreamModelId = null,
        IReadOnlyList<string>? aliases = null,
        IReadOnlyList<string>? capabilities = null,
        bool enabled = true,
        string? pricingRef = null)
        => new()
        {
            ModelRouteId = modelRouteId,
            ProviderId = providerId,
            ClientModelId = clientModelId,
            ModelId = modelId,
            UpstreamModelId = upstreamModelId ?? clientModelId,
            Aliases = aliases ?? [],
            Capabilities = capabilities ?? ModelCapabilities(),
            PricingRef = pricingRef ?? "pricing.mm_openrouter.z-ai-glm-5-3",
            IdentityVerification = "explicit_config",
            Enabled = enabled,
            Version = 1,
        };

    public static RouterRouteConfig Route(
        string routeId = RouteId,
        IReadOnlyList<string>? clientIds = null,
        string providerRouteId = ProviderRouteId,
        string protocolRouteId = ProtocolRouteId,
        string modelRouteId = ModelRouteId,
        bool enabled = true,
        int priority = 100,
        int weight = 100,
        string healthState = "UNKNOWN",
        string timeoutPolicyId = TimeoutPolicyId,
        string retryPolicyId = RetryPolicyId,
        string failoverPolicyId = FailoverPolicyId,
        IReadOnlyList<string>? fallbackRouteIds = null)
        => new()
        {
            RouteId = routeId,
            ClientIds = clientIds ?? [ClientId],
            ProviderRouteId = providerRouteId,
            ProtocolRouteId = protocolRouteId,
            ModelRouteId = modelRouteId,
            Enabled = enabled,
            Priority = priority,
            Weight = weight,
            HealthState = healthState,
            TimeoutPolicyId = timeoutPolicyId,
            RetryPolicyId = retryPolicyId,
            FailoverPolicyId = failoverPolicyId,
            FallbackRouteIds = fallbackRouteIds ?? [],
            CreatedAt = DateTimeOffset.Parse("2026-08-27T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal),
            UpdatedAt = DateTimeOffset.Parse("2026-08-27T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal),
            Version = 1,
        };

    public static SecretReference OpenRouterSecretRef(string providerId = "mm_openrouter")
        => new()
        {
            Resolver = "environment",
            Name = EnvironmentNameFor(providerId) ?? "OPENROUTER_API_KEY",
            Scope = SecretScope.UserOrProcess,
            AllowedProviderIds = [providerId],
            Version = 1,
        };

    private static SecretReference? SecretRefFor(string providerId)
        => EnvironmentNameFor(providerId) is { } name
            ? new SecretReference
            {
                Resolver = "environment",
                Name = name,
                Scope = SecretScope.UserOrProcess,
                AllowedProviderIds = [providerId],
                Version = 1,
            }
            : null;

    private static string? EnvironmentNameFor(string providerId)
        => providerId switch
        {
            "mm_openrouter" => "OPENROUTER_API_KEY",
            "mm_mimo" => "MIMO_API_KEY",
            "mm_modelstudio" => "CODEX_DASHSCOPE_API_KEY",
            "mm_openai_api" => "CODEX_OPENAI_API_KEY",
            "deepseek" => "DEEPSEEK_API_KEY",
            _ => null,
        };

    public static EffectiveRouterConfigSnapshot Snapshot(RouterConfig config, string? generation = null)
        => new()
        {
            Config = config,
            ConfigGeneration = generation ?? TestGeneration,
            LoadedAt = DateTimeOffset.UnixEpoch,
            Source = new ConfigSourceProvenance
            {
                DefaultsPath = "test-defaults.json",
                HasUserConfig = false,
                DefaultsSha256 = "test",
            },
        };

    /// <summary>Eligible fake adapter registrations for the standard config.</summary>
    public static IReadOnlyList<AdapterRegistration> StandardAdapterRegistrations()
        =>
        [
            AdapterRegistration.Protocol(ProtocolAdapterId, "protocol.openai.responses.v1", FullCapabilities()),
            AdapterRegistration.Provider(ProviderAdapterId, "mm_openrouter", FullCapabilities()),
        ];

    /// <summary>Projects the canonical catalog fixture (read-only).</summary>
    public static RouterCatalogProjection StandardCatalogProjection()
    {
        CatalogProjectionResult result = ModelCatalogProjector.Project(
            File.ReadAllBytes(TestPaths.CatalogFixture("catalog.v3.representative.json")),
            TestPaths.CatalogFixture("catalog.v3.representative.json"),
            SafeHasher.Sha256Hex(File.ReadAllBytes(TestPaths.CatalogFixture("catalog.v3.representative.json"))));
        result.Validate();
        return result.Projection!;
    }

    public static IReadOnlyList<string> DefaultClientCapabilities()
        => ["text", "streaming", "reasoning", "tools", "usage", "cancellation"];

    public static IReadOnlyList<string> FullCapabilities()
        => ["responses", "text", "streaming", "reasoning", "tools", "usage", "cancellation"];

    public static IReadOnlyList<string> ModelCapabilities()
        => ["text", "streaming", "reasoning", "tools", "usage"];
}

/// <summary>Deterministic request-context helper for resolver tests.</summary>
public static class TestRequestContext
{
    public static Core.Context.RequestContext Create(string clientId, string? configGeneration = null)
    {
        Core.Ids.UuidV7 uuid = Core.Ids.UuidV7.Parse("018f4a9b-0000-7000-8000-000000000000");
        return Core.Context.RequestContext.Create(
            Core.Ids.RequestId.Create(uuid),
            Core.Ids.TraceId.Create(uuid),
            clientId,
            DateTimeOffset.UnixEpoch,
            "responses:invoke",
            configGeneration: configGeneration);
    }
}
