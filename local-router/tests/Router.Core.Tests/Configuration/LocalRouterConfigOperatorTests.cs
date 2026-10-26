using Router.Configuration;
using Router.Core.Errors;
using Router.Core.Tests.Fakes;
using Xunit;

namespace Router.Core.Tests.Configuration;

/// <summary>
/// LR-14P host-independent config operator tests. All operations run against an
/// in-memory file system and never touch a real Router config, provider
/// secret, or HTTP server.
/// </summary>
public sealed class LocalRouterConfigOperatorTests
{
    private const string DefaultsPath = @"C:\lr14p-operator-tests\defaults.json";
    private const string UserConfigPath = @"C:\lr14p-operator-tests\user.json";

    private static readonly System.Text.Json.JsonSerializerOptions RichConfigWriteOptions = new()
    {
        PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.SnakeCaseLower,
        WriteIndented = true,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    [Fact]
    public async Task Feature_mutation_advances_generation_and_preserves_other_fields()
    {
        (LocalRouterConfigOperator operatorUnderTest, FakeFileSystem fileSystem) = CreateOperator(defaultsText: DefaultsText());
        LocalRouterConfigReadResult initial = await operatorUnderTest.ReadAsync(CancellationToken.None);
        Assert.True(initial.IsSuccess);
        Assert.False(initial.View!.Config.LocalRouter.Enabled);
        Assert.Equal(RouterMode.Direct, initial.View.Config.Mode);
        string generation0 = initial.View.ConfigGeneration;

        LocalRouterConfigMutationResult enabled = await operatorUnderTest.SetFeatureEnabledAsync(
            generation0,
            enabled: true,
            CancellationToken.None);
        Assert.True(enabled.IsSuccess, enabled.Error?.Code);
        Assert.True(enabled.View!.Config.LocalRouter.Enabled);
        Assert.Equal(RouterMode.Router, enabled.View.Config.Mode);
        Assert.NotEqual(generation0, enabled.View.ConfigGeneration);

        LocalRouterConfigReadResult reloaded = await operatorUnderTest.ReadAsync(CancellationToken.None);
        Assert.True(reloaded.IsSuccess);
        Assert.True(reloaded.View!.Config.LocalRouter.Enabled);
        Assert.Equal(RouterMode.Router, reloaded.View.Config.Mode);
        Assert.Equal(enabled.View.ConfigGeneration, reloaded.View.ConfigGeneration);
        Assert.True(fileSystem.HasFile(UserConfigPath));
        string userText = fileSystem.ReadFileText(UserConfigPath)!;
        Assert.Contains("\"enabled\": true", userText, StringComparison.Ordinal);
        Assert.Contains("\"mode\": \"router\"", userText, StringComparison.Ordinal);

        LocalRouterConfigMutationResult disabled = await operatorUnderTest.SetFeatureEnabledAsync(
            reloaded.View.ConfigGeneration,
            enabled: false,
            CancellationToken.None);
        Assert.True(disabled.IsSuccess, disabled.Error?.Code);
        Assert.False(disabled.View!.Config.LocalRouter.Enabled);
        Assert.Equal(RouterMode.Direct, disabled.View.Config.Mode);
        Assert.NotEqual(reloaded.View.ConfigGeneration, disabled.View.ConfigGeneration);
    }

    [Fact]
    public async Task Feature_mutation_with_stale_generation_is_rejected_without_writes()
    {
        (LocalRouterConfigOperator operatorUnderTest, FakeFileSystem fileSystem) = CreateOperator(defaultsText: DefaultsText());
        LocalRouterConfigReadResult initial = await operatorUnderTest.ReadAsync(CancellationToken.None);
        string stale = initial.View!.ConfigGeneration;
        LocalRouterConfigMutationResult first = await operatorUnderTest.SetFeatureEnabledAsync(
            stale,
            true,
            CancellationToken.None);
        Assert.True(first.IsSuccess, first.Error?.Code);
        string current = first.View!.ConfigGeneration;
        Assert.NotEqual(stale, current);

        LocalRouterConfigMutationResult conflict = await operatorUnderTest.SetFeatureEnabledAsync(
            stale,
            false,
            CancellationToken.None);
        Assert.False(conflict.IsSuccess);
        Assert.Equal(RouterErrorCode.ControlGenerationConflict, conflict.Error!.Code);
        LocalRouterConfigReadResult after = await operatorUnderTest.ReadAsync(CancellationToken.None);
        Assert.True(after.View!.Config.LocalRouter.Enabled);
        Assert.Equal(current, after.View.ConfigGeneration);
        Assert.True(fileSystem.HasFile(UserConfigPath));
    }

    [Fact]
    public async Task Feature_failed_atomic_write_preserves_previous_valid_config()
    {
        (LocalRouterConfigOperator operatorUnderTest, FakeFileSystem fileSystem) = CreateOperator(defaultsText: DefaultsText());
        LocalRouterConfigReadResult initial = await operatorUnderTest.ReadAsync(CancellationToken.None);
        Assert.True((await operatorUnderTest.SetFeatureEnabledAsync(
            initial.View!.ConfigGeneration,
            true,
            CancellationToken.None)).IsSuccess);

        LocalRouterConfigReadResult before = await operatorUnderTest.ReadAsync(CancellationToken.None);
        fileSystem.FailNextReplace = true;
        LocalRouterConfigMutationResult failed = await operatorUnderTest.SetFeatureEnabledAsync(
            before.View!.ConfigGeneration,
            false,
            CancellationToken.None);
        Assert.False(failed.IsSuccess);
        Assert.NotNull(failed.Error);

        LocalRouterConfigReadResult after = await operatorUnderTest.ReadAsync(CancellationToken.None);
        Assert.True(after.IsSuccess);
        Assert.True(after.View!.Config.LocalRouter.Enabled);
        Assert.Equal(before.View.ConfigGeneration, after.View.ConfigGeneration);
    }

    [Fact]
    public async Task Policy_mutation_replaces_body_advances_generation_and_preserves_rest()
    {
        (LocalRouterConfigOperator operatorUnderTest, _) = CreateOperator(defaultsText: PolicyDefaultsText());
        LocalRouterConfigReadResult initial = await operatorUnderTest.ReadAsync(CancellationToken.None);
        PolicyConfig original = Assert.Single(initial.View!.Config.Policies);
        Assert.Null(original.RetryBody);
        string generation0 = initial.View.ConfigGeneration;

        PolicyRetryBodyConfig body = new()
        {
            SchemaVersionValue = PolicyRetryBodyConfig.SchemaVersion,
            MaxAttempts = 3,
            BaseDelayMs = 200,
            MaxDelayMs = 5000,
            Jitter = 0.2m,
            RespectRetryAfter = true,
            MaxRetryAfterMs = 30000,
        };

        LocalRouterConfigMutationResult mutated = await operatorUnderTest.SetPolicyRetryBodyAsync(
            generation0,
            original.PolicyId,
            body,
            CancellationToken.None);
        Assert.True(mutated.IsSuccess, mutated.Error?.Code);
        Assert.NotEqual(generation0, mutated.View!.ConfigGeneration);
        PolicyConfig updated = Assert.Single(mutated.View.Config.Policies);
        Assert.Equal(3, updated.RetryBody!.MaxAttempts);
        Assert.Equal(200, updated.RetryBody.BaseDelayMs);
        Assert.Null(updated.TimeoutBody);
        Assert.False(mutated.View.Config.LocalRouter.Enabled);
        Assert.Equal(RouterMode.Direct, mutated.View.Config.Mode);
        LocalRouterConfigReadResult afterReload = await operatorUnderTest.ReadAsync(CancellationToken.None);
        Assert.True(afterReload.IsSuccess, afterReload.Error?.Code);
        Assert.Equal(mutated.View.ConfigGeneration, afterReload.View!.ConfigGeneration);
    }

    [Fact]
    public async Task Policy_mutation_stale_generation_is_rejected()
    {
        (LocalRouterConfigOperator operatorUnderTest, _) = CreateOperator(defaultsText: PolicyDefaultsText());
        LocalRouterConfigReadResult initial = await operatorUnderTest.ReadAsync(CancellationToken.None);
        string generation0 = initial.View!.ConfigGeneration;
        PolicyConfig policy = Assert.Single(initial.View.Config.Policies);

        LocalRouterConfigMutationResult first = await operatorUnderTest.SetPolicyRetryBodyAsync(
            generation0,
            policy.PolicyId,
            RetryBody(maxAttempts: 4),
            CancellationToken.None);
        Assert.True(first.IsSuccess, first.Error?.Code);
        string current = first.View!.ConfigGeneration;
        Assert.NotEqual(generation0, current);

        LocalRouterConfigMutationResult conflict = await operatorUnderTest.SetPolicyRetryBodyAsync(
            generation0,
            policy.PolicyId,
            RetryBody(maxAttempts: 5),
            CancellationToken.None);
        Assert.False(conflict.IsSuccess);
        Assert.Equal(RouterErrorCode.ControlGenerationConflict, conflict.Error!.Code);

        LocalRouterConfigMutationResult invalid = await operatorUnderTest.SetPolicyRetryBodyAsync(
            generation0 + "0",
            policy.PolicyId,
            RetryBody(maxAttempts: 4),
            CancellationToken.None);
        Assert.False(invalid.IsSuccess);
        Assert.Equal(RouterErrorCode.ControlGenerationConflict, invalid.Error!.Code);
    }

    [Fact]
    public async Task Policy_mutation_rejects_invalid_body_values()
    {
        (LocalRouterConfigOperator operatorUnderTest, _) = CreateOperator(defaultsText: PolicyDefaultsText());
        LocalRouterConfigReadResult initial = await operatorUnderTest.ReadAsync(CancellationToken.None);
        PolicyConfig policy = Assert.Single(initial.View!.Config.Policies);

        LocalRouterConfigMutationResult zeroAttempts = await operatorUnderTest.SetPolicyRetryBodyAsync(
            initial.View.ConfigGeneration,
            policy.PolicyId,
            RetryBody(maxAttempts: 0),
            CancellationToken.None);
        Assert.False(zeroAttempts.IsSuccess);
        Assert.Equal(RouterErrorCode.ConfigInvalid, zeroAttempts.Error!.Code);

        LocalRouterConfigMutationResult invertedDelays = await operatorUnderTest.SetPolicyRetryBodyAsync(
            initial.View.ConfigGeneration,
            policy.PolicyId,
            RetryBody(maxAttempts: 2, baseDelayMs: 5000, maxDelayMs: 200),
            CancellationToken.None);
        Assert.False(invertedDelays.IsSuccess);
        Assert.Equal(RouterErrorCode.ConfigInvalid, invertedDelays.Error!.Code);
    }

    [Fact]
    public async Task Policy_mutation_for_unknown_policy_is_rejected()
    {
        (LocalRouterConfigOperator operatorUnderTest, _) = CreateOperator(defaultsText: PolicyDefaultsText());
        LocalRouterConfigReadResult initial = await operatorUnderTest.ReadAsync(CancellationToken.None);

        LocalRouterConfigMutationResult notFound = await operatorUnderTest.SetPolicyRetryBodyAsync(
            initial.View!.ConfigGeneration,
            "policy.does-not-exist",
            RetryBody(maxAttempts: 2),
            CancellationToken.None);
        Assert.False(notFound.IsSuccess);
        Assert.Equal(RouterErrorCode.ControlPolicyNotFound, notFound.Error!.Code);
    }

    [Fact]
    public async Task Concurrent_same_generation_feature_mutations_have_exactly_one_winner()
    {
        FakeFileSystem fileSystem = new();
        fileSystem.SeedFile(DefaultsPath, DefaultsText());
        LocalRouterConfigOperator first = Create(fileSystem);
        LocalRouterConfigOperator second = Create(fileSystem);
        LocalRouterConfigReadResult initial = await first.ReadAsync(CancellationToken.None);
        string generation = initial.View!.ConfigGeneration;

        Task<LocalRouterConfigMutationResult> taskA = first.SetFeatureEnabledAsync(generation, true, CancellationToken.None);
        Task<LocalRouterConfigMutationResult> taskB = second.SetFeatureEnabledAsync(generation, false, CancellationToken.None);
        LocalRouterConfigMutationResult[] results = await Task.WhenAll(taskA, taskB);

        Assert.Equal(1, results.Count(result => result.IsSuccess));
        Assert.Equal(1, results.Count(result =>
            !result.IsSuccess
            && result.Error!.Code is RouterErrorCode.ControlGenerationConflict or RouterErrorCode.ControlMutationBusy));
        LocalRouterConfigReadResult after = await first.ReadAsync(CancellationToken.None);
        Assert.True(after.IsSuccess);
        Assert.NotEqual(generation, after.View!.ConfigGeneration);
        Assert.NotNull(after.View.Config.LocalRouter);
    }

    [Fact]
    public async Task Concurrent_feature_and_policy_mutations_have_exactly_one_winner()
    {
        FakeFileSystem fileSystem = new();
        fileSystem.SeedFile(DefaultsPath, PolicyDefaultsText());
        LocalRouterConfigOperator first = Create(fileSystem);
        LocalRouterConfigOperator second = Create(fileSystem);
        LocalRouterConfigReadResult initial = await first.ReadAsync(CancellationToken.None);
        string generation = initial.View!.ConfigGeneration;
        PolicyConfig policy = Assert.Single(initial.View.Config.Policies);

        Task<LocalRouterConfigMutationResult> featureTask = first.SetFeatureEnabledAsync(generation, true, CancellationToken.None);
        Task<LocalRouterConfigMutationResult> policyTask = second.SetPolicyRetryBodyAsync(
            generation,
            policy.PolicyId,
            RetryBody(maxAttempts: 4),
            CancellationToken.None);
        LocalRouterConfigMutationResult[] results = await Task.WhenAll(featureTask, policyTask);

        Assert.Equal(1, results.Count(result => result.IsSuccess));
        Assert.Equal(1, results.Count(result =>
            !result.IsSuccess
            && result.Error!.Code is RouterErrorCode.ControlGenerationConflict or RouterErrorCode.ControlMutationBusy));
    }

    [Fact]
    public async Task Concurrent_same_generation_policy_mutations_have_exactly_one_winner()
    {
        FakeFileSystem fileSystem = new();
        fileSystem.SeedFile(DefaultsPath, PolicyDefaultsText());
        LocalRouterConfigOperator first = Create(fileSystem);
        LocalRouterConfigOperator second = Create(fileSystem);
        LocalRouterConfigReadResult initial = await first.ReadAsync(CancellationToken.None);
        string generation = initial.View!.ConfigGeneration;
        PolicyConfig policy = Assert.Single(initial.View.Config.Policies);

        Task<LocalRouterConfigMutationResult> taskA = first.SetPolicyRetryBodyAsync(
            generation,
            policy.PolicyId,
            RetryBody(maxAttempts: 4),
            CancellationToken.None);
        Task<LocalRouterConfigMutationResult> taskB = second.SetPolicyRetryBodyAsync(
            generation,
            policy.PolicyId,
            RetryBody(maxAttempts: 5),
            CancellationToken.None);
        LocalRouterConfigMutationResult[] results = await Task.WhenAll(taskA, taskB);

        Assert.Equal(1, results.Count(result => result.IsSuccess));
        Assert.Equal(1, results.Count(result =>
            !result.IsSuccess
            && result.Error!.Code is RouterErrorCode.ControlGenerationConflict or RouterErrorCode.ControlMutationBusy));
        LocalRouterConfigReadResult after = await first.ReadAsync(CancellationToken.None);
        PolicyConfig winner = Assert.Single(after.View!.Config.Policies);
        Assert.NotNull(winner.RetryBody);
    }

    [Fact]
    public async Task Feature_and_policy_mutations_preserve_unrelated_schema_valid_fields()
    {
        FakeFileSystem fileSystem = new();
        fileSystem.SeedFile(DefaultsPath, RichDefaultsText());
        LocalRouterConfigOperator operatorUnderTest = Create(fileSystem);
        LocalRouterConfigReadResult initial = await operatorUnderTest.ReadAsync(CancellationToken.None);
        Assert.True(initial.IsSuccess, initial.Error?.Code + " (" + initial.Error?.Param + ")");
        RouterConfig original = initial.View!.Config;
        string generation = initial.View.ConfigGeneration;

        LocalRouterConfigMutationResult feature = await operatorUnderTest.SetFeatureEnabledAsync(
            generation,
            true,
            CancellationToken.None);
        Assert.True(feature.IsSuccess, feature.Error?.Code);

        LocalRouterConfigMutationResult policy = await operatorUnderTest.SetPolicyRetryBodyAsync(
            feature.View!.ConfigGeneration,
            "policy.retry-safe-default",
            RetryBody(maxAttempts: 3),
            CancellationToken.None);
        Assert.True(policy.IsSuccess, policy.Error?.Code);

        RouterConfig updated = policy.View!.Config;
        Assert.Equal(Json(original.Clients), Json(updated.Clients));
        Assert.Equal(Json(original.ProtocolRoutes), Json(updated.ProtocolRoutes));
        Assert.Equal(Json(original.ProviderRoutes), Json(updated.ProviderRoutes));
        Assert.Equal(Json(original.Endpoints), Json(updated.Endpoints));
        Assert.Equal(Json(original.ModelRoutes), Json(updated.ModelRoutes));
        Assert.Equal(Json(original.Routes), Json(updated.Routes));
        Assert.Equal(original.LocalRouter.Host, updated.LocalRouter.Host);
        Assert.Equal(original.LocalRouter.Port, updated.LocalRouter.Port);
        Assert.Equal(original.LocalRouter.ClientAuth, updated.LocalRouter.ClientAuth);
        Assert.Equal(original.LocalRouter.Limits, updated.LocalRouter.Limits);
        Assert.True(updated.LocalRouter.Enabled);
        Assert.Equal(RouterMode.Router, updated.Mode);

        PolicyConfig retryPolicy = Assert.Single(
            updated.Policies,
            policyEntry => string.Equals(policyEntry.PolicyId, "policy.retry-safe-default", StringComparison.Ordinal));
        Assert.Equal(3, retryPolicy.RetryBody!.MaxAttempts);
        PolicyConfig unrelated = Assert.Single(
            updated.Policies,
            policyEntry => string.Equals(policyEntry.PolicyId, "policy.failover-off", StringComparison.Ordinal));
        Assert.Null(unrelated.RetryBody);
        Assert.Null(unrelated.FailoverBody);
        Assert.Null(unrelated.TimeoutBody);
    }

    [Fact]
    public async Task Successful_mutation_publishes_inside_the_gate_and_matches_durable_generation()
    {
        FakeFileSystem fileSystem = new();
        fileSystem.SeedFile(DefaultsPath, DefaultsText());
        LocalRouterConfigOperator offline = Create(fileSystem);
        LocalRouterConfigReadResult initial = await offline.ReadAsync(CancellationToken.None);
        CurrentRouterState state = new(
            PublishedRouterState.From(initial.View!.Config, initial.View.ConfigGeneration));
        LocalRouterConfigOperator live = offline.WithPublicationSink(state);

        LocalRouterConfigMutationResult result = await live.SetFeatureEnabledAsync(
            initial.View.ConfigGeneration,
            true,
            CancellationToken.None);

        Assert.True(result.IsSuccess, result.Error?.Code);
        string returnedGeneration = result.View!.ConfigGeneration;
        Assert.Equal(returnedGeneration, state.Snapshot.ConfigGeneration);
        Assert.True(state.Snapshot.LocalRouterEnabled);
        LocalRouterConfigReadResult durable = await live.ReadAsync(CancellationToken.None);
        Assert.Equal(returnedGeneration, durable.View!.ConfigGeneration);
    }

    [Fact]
    public async Task Post_commit_cancellation_still_publishes_the_committed_generation()
    {
        FakeFileSystem fileSystem = new();
        fileSystem.SeedFile(DefaultsPath, DefaultsText());
        LocalRouterConfigOperator offline = Create(fileSystem);
        LocalRouterConfigReadResult initial = await offline.ReadAsync(CancellationToken.None);
        CurrentRouterState state = new(
            PublishedRouterState.From(initial.View!.Config, initial.View.ConfigGeneration));
        LocalRouterConfigOperator live = offline.WithPublicationSink(state);

        LocalRouterConfigMutationResult enabled = await live.SetFeatureEnabledAsync(
            initial.View!.ConfigGeneration,
            true,
            CancellationToken.None);
        Assert.True(enabled.IsSuccess, enabled.Error?.Code);

        using CancellationTokenSource postCommitCancellation = new();
        fileSystem.OnAfterReplace = postCommitCancellation.Cancel;
        LocalRouterConfigMutationResult disabled = await live.SetFeatureEnabledAsync(
            enabled.View!.ConfigGeneration,
            false,
            postCommitCancellation.Token);

        Assert.True(disabled.IsSuccess, disabled.Error?.Code);
        string returnedGeneration = disabled.View!.ConfigGeneration;
        Assert.Equal(returnedGeneration, state.Snapshot.ConfigGeneration);
        Assert.False(state.Snapshot.LocalRouterEnabled);
        LocalRouterConfigReadResult durable = await live.ReadAsync(CancellationToken.None);
        Assert.Equal(returnedGeneration, durable.View!.ConfigGeneration);
        Assert.False(durable.View!.Config.LocalRouter.Enabled);
    }

    [Fact]
    public async Task Persist_and_stale_failures_never_publish_runtime_state()
    {
        FakeFileSystem fileSystem = new();
        fileSystem.SeedFile(DefaultsPath, DefaultsText());
        LocalRouterConfigOperator offline = Create(fileSystem);
        LocalRouterConfigReadResult initial = await offline.ReadAsync(CancellationToken.None);
        CurrentRouterState state = new(
            PublishedRouterState.From(initial.View!.Config, initial.View.ConfigGeneration));
        LocalRouterConfigOperator live = offline.WithPublicationSink(state);

        LocalRouterConfigMutationResult enabled = await live.SetFeatureEnabledAsync(
            initial.View!.ConfigGeneration,
            true,
            CancellationToken.None);
        Assert.True(enabled.IsSuccess, enabled.Error?.Code);
        PublishedRouterState runtimeBefore = state.Snapshot;

        fileSystem.FailNextReplace = true;
        LocalRouterConfigMutationResult persistFailure = await live.SetFeatureEnabledAsync(
            enabled.View!.ConfigGeneration,
            false,
            CancellationToken.None);
        Assert.False(persistFailure.IsSuccess);
        Assert.Same(runtimeBefore, state.Snapshot);

        LocalRouterConfigMutationResult stale = await live.SetFeatureEnabledAsync(
            initial.View!.ConfigGeneration,
            false,
            CancellationToken.None);
        Assert.False(stale.IsSuccess);
        Assert.Equal(RouterErrorCode.ControlGenerationConflict, stale.Error!.Code);
        Assert.Same(runtimeBefore, state.Snapshot);
    }

    private static PolicyRetryBodyConfig RetryBody(
        int maxAttempts,
        long baseDelayMs = 200,
        long maxDelayMs = 5000)
        => new()
        {
            SchemaVersionValue = PolicyRetryBodyConfig.SchemaVersion,
            MaxAttempts = maxAttempts,
            BaseDelayMs = baseDelayMs,
            MaxDelayMs = maxDelayMs,
            Jitter = 0.2m,
            RespectRetryAfter = true,
            MaxRetryAfterMs = 30000,
        };

    private static (LocalRouterConfigOperator Operator, FakeFileSystem FileSystem) CreateOperator(string defaultsText)
    {
        FakeFileSystem fileSystem = new();
        fileSystem.SeedFile(DefaultsPath, defaultsText);
        return (Create(fileSystem), fileSystem);
    }

    private static LocalRouterConfigOperator Create(FakeFileSystem fileSystem)
        => new(fileSystem, new FakeClock(), DefaultsPath, UserConfigPath);

    private static string Json<T>(T value)
        => System.Text.Json.JsonSerializer.Serialize(value, RichConfigWriteOptions);

    private static string DefaultsText()
        => File.ReadAllText(TestPaths.DefaultsPath);

    private static string PolicyDefaultsText()
        => File.ReadAllText(TestPaths.DefaultsPath)
            .Replace(
                "\"policies\": [],",
                "\"policies\": [{\"policy_id\":\"policy.retry-safe-default\",\"version\":1}],",
                StringComparison.Ordinal);

    private static string RichDefaultsText()
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
            Clients =
            [
                new ClientConfig
                {
                    ClientId = "client.codex_cli",
                    AdapterId = "adapter.client.codex_cli.responses.v1",
                    Enabled = true,
                    AuthScope = "responses:invoke",
                    Capabilities = ["text", "streaming", "responses"],
                    Version = 1,
                },
            ],
            ProtocolRoutes =
            [
                new ProtocolRouteConfig
                {
                    ProtocolRouteId = "protocol-route.responses-pass-through",
                    IngressProtocol = "protocol.openai.responses.v1",
                    UpstreamProtocol = "protocol.openai.responses.v1",
                    AdapterId = "adapter.protocol.responses-compatible.v1",
                    AdapterVersion = "1.0",
                    Capabilities = ["responses"],
                    LossPolicy = "fail_closed",
                    Version = 1,
                },
            ],
            ProviderRoutes =
            [
                new ProviderRouteConfig
                {
                    ProviderRouteId = "provider-route.openrouter",
                    ProviderId = "mm_openrouter",
                    AdapterId = "adapter.provider.mm_openrouter.responses.v1",
                    AdapterVersion = "1.0",
                    EndpointIds = ["endpoint.openrouter"],
                    BaseUrlRef = "provider-config:mm_openrouter.base_url",
                    Enabled = true,
                    Capabilities = ["responses"],
                    Version = 1,
                },
            ],
            Endpoints =
            [
                new EndpointConfig
                {
                    EndpointId = "endpoint.openrouter",
                    BaseUrlRef = "provider-config:mm_openrouter.base_url",
                    Enabled = true,
                    DataBoundary = "provider-default",
                    TlsRequired = true,
                    Priority = 100,
                    Weight = 100,
                    Version = 1,
                },
            ],
            ModelRoutes =
            [
                new ModelRouteConfig
                {
                    ModelRouteId = "model-route.openrouter",
                    ProviderId = "mm_openrouter",
                    ClientModelId = "client-model",
                    ModelId = "catalog-model",
                    UpstreamModelId = "upstream-model",
                    IdentityVerification = "explicit_config",
                    Capabilities = ["responses"],
                    Enabled = true,
                    Version = 1,
                },
            ],
            Routes =
            [
                new RouterRouteConfig
                {
                    RouteId = "route.openrouter",
                    ClientIds = ["client.codex_cli"],
                    ProviderRouteId = "provider-route.openrouter",
                    ProtocolRouteId = "protocol-route.responses-pass-through",
                    ModelRouteId = "model-route.openrouter",
                    Enabled = true,
                    Priority = 100,
                    Weight = 100,
                    HealthState = "UNKNOWN",
                    TimeoutPolicyId = "policy.timeout-default",
                    RetryPolicyId = "policy.retry-safe-default",
                    FailoverPolicyId = "policy.failover-off",
                    CreatedAt = DateTimeOffset.UnixEpoch,
                    UpdatedAt = DateTimeOffset.UnixEpoch,
                    Version = 1,
                },
            ],
            Policies =
            [
                new PolicyConfig { PolicyId = "policy.retry-safe-default", Version = 1 },
                new PolicyConfig { PolicyId = "policy.timeout-default", Version = 1 },
                new PolicyConfig { PolicyId = "policy.failover-off", Version = 1 },
            ],
            UpdatedAt = DateTimeOffset.UnixEpoch,
        };
        return System.Text.Json.JsonSerializer.Serialize(config, RichConfigWriteOptions);
    }
}
