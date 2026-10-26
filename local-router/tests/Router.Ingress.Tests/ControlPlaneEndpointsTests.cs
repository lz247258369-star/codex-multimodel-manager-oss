using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Router.Configuration;
using Router.Core.Abstractions;
using Router.Ingress.ControlPlane;
using Router.Ingress.Handlers;
using Router.Ingress.Tests.Support;
using Router.Metering;
using Xunit;

namespace Router.Ingress.Tests;

/// <summary>
/// LR-14P control-plane HTTP contract tests against a real loopback ingress.
/// All endpoints reuse the existing local bearer-token authentication; no
/// provider request, model discovery, or paid inference is ever performed.
/// </summary>
public sealed class ControlPlaneEndpointsTests
{
    [Fact]
    public async Task Control_plane_endpoints_require_authentication()
    {
        await using ControlPlaneEndpointsContext context = await ControlPlaneEndpointsContext.CreateAsync();
        using HttpClient anonymous = context.Server.CreateAnonymousClient();
        using HttpResponseMessage status = await anonymous.GetAsync("/v1/router/control-plane/status");
        Assert.Equal(HttpStatusCode.Unauthorized, status.StatusCode);
    }

    [Fact]
    public async Task Control_plane_endpoints_reject_missing_scope()
    {
        await using IngressTestServer server = await IngressTestServer.StartAsync(options =>
        {
            options.Clients =
            [
                new ClientConfig
                {
                    ClientId = "client.local_test",
                    AdapterId = "adapter.client.local_test.responses.v1",
                    Enabled = true,
                    AuthScope = "responses:invoke",
                    Version = 1,
                },
            ];
        });
        using HttpRequestMessage request = server.CreateRequest(HttpMethod.Get, "/v1/router/control-plane/status");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", IngressTestServer.TestToken);
        using HttpResponseMessage status = await server.SendAsync(request);
        Assert.Equal(HttpStatusCode.Forbidden, status.StatusCode);
        Assert.Contains("scope_denied", await server.GetBodyAsync(status), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Feature_mutation_is_generation_aware_and_preserves_other_config()
    {
        await using ControlPlaneEndpointsContext context = await ControlPlaneEndpointsContext.CreateAsync();
        string generation0 = await context.ReadGenerationAsync();

        using HttpResponseMessage enabledResponse = await context.PutJsonAsync(
            "/v1/router/control-plane/feature",
            FeatureBody(generation0, enabled: true));
        string enabledBody = await context.Server.GetBodyAsync(enabledResponse);
        Assert.True(enabledResponse.IsSuccessStatusCode, enabledBody);
        using JsonDocument enabledJson = JsonDocument.Parse(enabledBody);
        Assert.True(enabledJson.RootElement.GetProperty("local_router_enabled").GetBoolean());
        Assert.False(enabledJson.RootElement.GetProperty("start_stop_available").GetBoolean());
        Assert.Equal("LIFECYCLE_CONTROL_GAP", enabledJson.RootElement.GetProperty("lifecycle_reason_code").GetString());
        string generation1 = enabledJson.RootElement.GetProperty("config_generation").GetString()!;
        Assert.NotEqual(generation0, generation1);

        using HttpResponseMessage statusResponse = await context.GetControlAsync("/v1/router/control-plane/status");
        string statusBody = await context.Server.GetBodyAsync(statusResponse);
        using JsonDocument statusJson = JsonDocument.Parse(statusBody);
        Assert.True(statusJson.RootElement.GetProperty("local_router_enabled").GetBoolean());
        Assert.Equal(generation1, statusJson.RootElement.GetProperty("config_generation").GetString());
        Assert.True(statusJson.RootElement.GetProperty("policy_mutation_available").GetBoolean());
        Assert.True(statusJson.RootElement.GetProperty("feature_mutation_available").GetBoolean());

        using HttpResponseMessage staleResponse = await context.PutJsonAsync(
            "/v1/router/control-plane/feature",
            FeatureBody(generation0, enabled: false));
        Assert.Equal(HttpStatusCode.Conflict, staleResponse.StatusCode);
        Assert.Contains("control_generation_conflict", await context.Server.GetBodyAsync(staleResponse), StringComparison.Ordinal);

        LocalRouterConfigReadResult read = await context.ConfigOperator.ReadAsync(CancellationToken.None);
        Assert.True(read.View!.Config.LocalRouter.Enabled);
        Assert.Equal(RouterMode.Router, read.View.Config.Mode);
        Assert.True(context.FileSystem.HasFile(ControlPlaneEndpointsContext.UserConfigPath));
    }

    [Fact]
    public async Task Policy_mutation_updates_effective_policy_and_rejects_conflicts_and_invalid_bodies()
    {
        await using ControlPlaneEndpointsContext context = await ControlPlaneEndpointsContext.CreateAsync(policyDefaults: true);
        string generation0 = await context.ReadGenerationAsync();

        using HttpResponseMessage readResponse = await context.GetControlAsync("/v1/router/control-plane/policy");
        string readBody = await context.Server.GetBodyAsync(readResponse);
        Assert.True(readResponse.IsSuccessStatusCode, readBody);
        Assert.Contains("\"effective_retry_source\":\"safe_defaults\"", readBody, StringComparison.Ordinal);
        Assert.Contains("\"cross_model_fallback\":\"HARD_OFF\"", readBody, StringComparison.Ordinal);

        using HttpResponseMessage mutatedResponse = await context.PutJsonAsync(
            "/v1/router/control-plane/policy",
            RetryMutationBody(generation0, "policy.retry-safe-default", maxAttempts: 4));
        string mutatedBody = await context.Server.GetBodyAsync(mutatedResponse);
        Assert.True(mutatedResponse.IsSuccessStatusCode, mutatedBody);
        using JsonDocument mutatedJson = JsonDocument.Parse(mutatedBody);
        Assert.Equal("applied", mutatedJson.RootElement.GetProperty("result_code").GetString());
        string generation1 = mutatedJson.RootElement.GetProperty("config_generation").GetString()!;
        Assert.NotEqual(generation0, generation1);
        Assert.Equal(4, mutatedJson.RootElement.GetProperty("policy").GetProperty("effective_retry").GetProperty("max_attempts").GetInt32());
        Assert.Equal("configured", mutatedJson.RootElement.GetProperty("policy").GetProperty("effective_retry_source").GetString());

        using HttpResponseMessage conflictResponse = await context.PutJsonAsync(
            "/v1/router/control-plane/policy",
            RetryMutationBody(generation0, "policy.retry-safe-default", maxAttempts: 5));
        Assert.Equal(HttpStatusCode.Conflict, conflictResponse.StatusCode);

        using HttpResponseMessage invalidResponse = await context.PutJsonAsync(
            "/v1/router/control-plane/policy",
            RetryMutationBody(generation1, "policy.retry-safe-default", maxAttempts: 0));
        Assert.Equal(HttpStatusCode.BadRequest, invalidResponse.StatusCode);
        Assert.Contains("control_policy_invalid", await context.Server.GetBodyAsync(invalidResponse), StringComparison.Ordinal);

        using HttpResponseMessage notFoundResponse = await context.PutJsonAsync(
            "/v1/router/control-plane/policy",
            RetryMutationBody(generation1, "policy.missing", maxAttempts: 2));
        Assert.Equal(HttpStatusCode.NotFound, notFoundResponse.StatusCode);

        using HttpResponseMessage unknownFieldResponse = await context.PutJsonAsync(
            "/v1/router/control-plane/policy",
            CrossModelFailoverBody(generation1));
        Assert.Equal(HttpStatusCode.BadRequest, unknownFieldResponse.StatusCode);
        Assert.Contains("control_invalid_request", await context.Server.GetBodyAsync(unknownFieldResponse), StringComparison.Ordinal);

        LocalRouterConfigReadResult preserved = await context.ConfigOperator.ReadAsync(CancellationToken.None);
        Assert.Equal(generation1, preserved.View!.ConfigGeneration);
        PolicyConfig policy = Assert.Single(preserved.View.Config.Policies);
        Assert.Equal(4, policy.RetryBody!.MaxAttempts);
    }

    [Fact]
    public async Task Usage_read_keeps_null_semantics_and_bounded_summary()
    {
        await using ControlPlaneEndpointsContext context = await ControlPlaneEndpointsContext.CreateAsync();
        context.Metering.Record(new RequestMeteringInput
        {
            RequestId = "req_complete",
            TraceId = "trc_complete",
            ClientId = "client.control_plane",
            ConfigGeneration = "g",
            ProviderId = "mm_openrouter",
            ModelId = "model",
            CatalogModelId = "model",
            Stream = false,
            CompletedAt = DateTimeOffset.UtcNow,
            DurationMs = 10,
        });

        using HttpResponseMessage response = await context.GetControlAsync("/v1/router/control-plane/usage?limit=5");
        string body = await context.Server.GetBodyAsync(response);
        Assert.True(response.IsSuccessStatusCode, body);
        using JsonDocument json = JsonDocument.Parse(body);
        JsonElement root = json.RootElement;
        Assert.Equal(1, root.GetProperty("schema_version").GetInt32());
        Assert.Equal("bounded_recent_records", root.GetProperty("scope").GetString());
        Assert.Equal(1, root.GetProperty("record_count").GetInt32());
        Assert.Equal("usage_missing", root.GetProperty("records")[0].GetProperty("metering_status").GetString());
        Assert.Equal(JsonValueKind.Null, root.GetProperty("records")[0].GetProperty("usage").ValueKind);
        Assert.Equal(JsonValueKind.Null, root.GetProperty("records")[0].GetProperty("cost_estimate").ValueKind);
        Assert.Equal(1, root.GetProperty("unknown_usage_count").GetInt32());
        Assert.Equal(1, root.GetProperty("unknown_cost_count").GetInt32());
        Assert.DoesNotContain("CONTROL_PLANE_SECRET_SENTINEL_123", body, StringComparison.Ordinal);
    }

    [Fact]
    public void Recent_read_limit_resolution_is_deterministic()
    {
        Assert.Equal(ControlPlaneProjections.ReadDefaultLimit, ControlPlaneProjections.ResolveLimit(null));
        Assert.Equal(ControlPlaneProjections.ReadDefaultLimit, ControlPlaneProjections.ResolveLimit("-5"));
        Assert.Equal(ControlPlaneProjections.ReadDefaultLimit, ControlPlaneProjections.ResolveLimit("abc"));
        Assert.Equal(1, ControlPlaneProjections.ResolveLimit("1"));
        Assert.Equal(ControlPlaneProjections.ReadHardLimit, ControlPlaneProjections.ResolveLimit("500"));
    }

    [Fact]
    public async Task Recent_requests_endpoint_reports_unavailable_without_durable_log()
    {
        await using ControlPlaneEndpointsContext context = await ControlPlaneEndpointsContext.CreateAsync();
        using HttpResponseMessage response = await context.GetControlAsync("/v1/router/control-plane/requests");
        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.Contains("control_read_unavailable", await context.Server.GetBodyAsync(response), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Mutation_body_with_known_oversized_content_length_is_rejected_before_operator()
    {
        await using ControlPlaneEndpointsContext context = await ControlPlaneEndpointsContext.CreateAsync();
        LocalRouterConfigReadResult before = await context.ConfigOperator.ReadAsync(CancellationToken.None);
        string oversized = new(' ', checked((int)ControlPlaneHandlers.MaxControlPlaneMutationBytes + 1));

        using HttpResponseMessage response = await context.PutJsonAsync(
            "/v1/router/control-plane/feature",
            oversized);

        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, response.StatusCode);
        Assert.Contains("control_payload_too_large", await context.Server.GetBodyAsync(response), StringComparison.Ordinal);
        LocalRouterConfigReadResult after = await context.ConfigOperator.ReadAsync(CancellationToken.None);
        Assert.Equal(before.View!.ConfigGeneration, after.View!.ConfigGeneration);
        Assert.False(after.View.Config.LocalRouter.Enabled);
    }

    [Fact]
    public async Task Mutation_body_with_chunked_oversized_content_is_rejected_bounded()
    {
        await using ControlPlaneEndpointsContext context = await ControlPlaneEndpointsContext.CreateAsync();
        LocalRouterConfigReadResult before = await context.ConfigOperator.ReadAsync(CancellationToken.None);
        string oversized = new(' ', checked((int)ControlPlaneHandlers.MaxControlPlaneMutationBytes + 5000));

        using HttpResponseMessage response = await context.PutChunkedJsonAsync(
            "/v1/router/control-plane/feature",
            oversized);

        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, response.StatusCode);
        Assert.Contains("control_payload_too_large", await context.Server.GetBodyAsync(response), StringComparison.Ordinal);
        LocalRouterConfigReadResult after = await context.ConfigOperator.ReadAsync(CancellationToken.None);
        Assert.Equal(before.View!.ConfigGeneration, after.View!.ConfigGeneration);
    }

    [Fact]
    public async Task Mutation_body_at_the_hard_limit_is_processed_normally()
    {
        await using ControlPlaneEndpointsContext context = await ControlPlaneEndpointsContext.CreateAsync();
        string generation = await context.ReadGenerationAsync();
        string prefix = "{\"schema_version\":1,\"expected_generation\":\"" + generation + "\",\"enabled\":true";
        int padding = checked((int)ControlPlaneHandlers.MaxControlPlaneMutationBytes) - prefix.Length - 1;
        Assert.True(padding > 0);
        string body = prefix + new string(' ', padding) + "}";

        using HttpResponseMessage response = await context.PutJsonAsync(
            "/v1/router/control-plane/feature",
            body);

        Assert.True(response.IsSuccessStatusCode, await context.Server.GetBodyAsync(response));
    }

    [Fact]
    public async Task Small_invalid_mutation_json_returns_normalized_invalid_request()
    {
        await using ControlPlaneEndpointsContext context = await ControlPlaneEndpointsContext.CreateAsync();
        using HttpResponseMessage response = await context.PutJsonAsync(
            "/v1/router/control-plane/feature",
            "{ not-json");

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("control_invalid_request", await context.Server.GetBodyAsync(response), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Usage_summary_partial_unknown_dimensions_stay_null_never_zero()
    {
        await using ControlPlaneEndpointsContext context = await ControlPlaneEndpointsContext.CreateAsync();
        context.Metering.Record(new RequestMeteringInput
        {
            RequestId = "req_partial_a",
            TraceId = "trc_partial_a",
            ClientId = "client.control_plane",
            ConfigGeneration = "g",
            ProviderId = "mm_openrouter",
            ModelId = "model",
            CatalogModelId = "model",
            Usage = new Router.ClientAdapters.Responses.UsageRecord { OutputTokens = 25 },
            Stream = false,
            CompletedAt = DateTimeOffset.UtcNow,
            DurationMs = 10,
        });
        context.Metering.Record(new RequestMeteringInput
        {
            RequestId = "req_partial_b",
            TraceId = "trc_partial_b",
            ClientId = "client.control_plane",
            ConfigGeneration = "g",
            ProviderId = "mm_openrouter",
            ModelId = "model",
            CatalogModelId = "model",
            Usage = new Router.ClientAdapters.Responses.UsageRecord { InputTokens = 100 },
            Stream = false,
            CompletedAt = DateTimeOffset.UtcNow,
            DurationMs = 10,
        });

        using HttpResponseMessage response = await context.GetControlAsync("/v1/router/control-plane/usage?limit=20");
        string body = await context.Server.GetBodyAsync(response);
        Assert.True(response.IsSuccessStatusCode, body);
        using JsonDocument json = JsonDocument.Parse(body);
        JsonElement root = json.RootElement;
        Assert.Equal(JsonValueKind.Null, root.GetProperty("input_tokens_total").ValueKind);
        Assert.Equal(JsonValueKind.Null, root.GetProperty("output_tokens_total").ValueKind);
    }

    [Fact]
    public async Task Concurrent_same_generation_http_mutations_have_exactly_one_winner_and_no_state_split()
    {
        await using ControlPlaneEndpointsContext context = await ControlPlaneEndpointsContext.CreateAsync(policyDefaults: true);
        string generation0 = await context.ReadGenerationAsync();
        LocalRouterConfigReadResult initialDurable = await context.ConfigOperator.ReadAsync(CancellationToken.None);
        Assert.True(initialDurable.IsSuccess, initialDurable.Error?.Code);
        Assert.Equal(
            generation0,
            initialDurable.View!.ConfigGeneration);

        Task<HttpResponseMessage> policyTask = context.PutJsonAsync(
            "/v1/router/control-plane/policy",
            RetryMutationBody(generation0, "policy.retry-safe-default", maxAttempts: 4));
        Task<HttpResponseMessage> featureTask = context.PutJsonAsync(
            "/v1/router/control-plane/feature",
            FeatureBody(generation0, enabled: true));
        HttpResponseMessage[] responses = await Task.WhenAll(policyTask, featureTask);

        HttpResponseMessage success = responses.Single(response => response.IsSuccessStatusCode);
        HttpResponseMessage conflict = responses.Single(response => response.StatusCode == HttpStatusCode.Conflict);
        Assert.Contains("control_generation_conflict", await context.Server.GetBodyAsync(conflict), StringComparison.Ordinal);

        string successBody = await context.Server.GetBodyAsync(success);
        using JsonDocument successJson = JsonDocument.Parse(successBody);
        string successGeneration = successJson.RootElement.GetProperty("config_generation").GetString()!;

        LocalRouterConfigReadResult durable = await context.ConfigOperator.ReadAsync(CancellationToken.None);
        Assert.True(durable.IsSuccess, durable.Error?.Code);
        Assert.Equal(successGeneration, durable.View!.ConfigGeneration);
        Assert.Equal(successGeneration, context.State!.Snapshot.ConfigGeneration);
    }

    [Fact]
    public async Task Mutation_availability_is_false_without_a_live_publication_boundary()
    {
        await using ControlPlaneEndpointsContext context = await ControlPlaneEndpointsContext.CreateAsync(live: false);
        using HttpResponseMessage response = await context.GetControlAsync("/v1/router/control-plane/status");
        string body = await context.Server.GetBodyAsync(response);
        Assert.True(response.IsSuccessStatusCode, body);
        using JsonDocument json = JsonDocument.Parse(body);
        Assert.False(json.RootElement.GetProperty("policy_mutation_available").GetBoolean());
        Assert.False(json.RootElement.GetProperty("feature_mutation_available").GetBoolean());
    }

    [Fact]
    public async Task V1_status_contract_stays_backward_compatible()
    {
        await using ControlPlaneEndpointsContext context = await ControlPlaneEndpointsContext.CreateAsync();
        using HttpRequestMessage request = context.Server.CreateRequest(HttpMethod.Get, "/v1/router/status");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", IngressTestServer.TestToken);
        using HttpResponseMessage response = await context.Server.SendAsync(request);
        string body = await context.Server.GetBodyAsync(response);
        Assert.True(response.IsSuccessStatusCode, body);
        using JsonDocument json = JsonDocument.Parse(body);
        JsonElement root = json.RootElement;
        Assert.Equal(1, root.GetProperty("schema_version").GetInt32());
        Assert.True(root.TryGetProperty("lifecycle", out _));
        Assert.True(root.TryGetProperty("ready", out _));
        Assert.True(root.TryGetProperty("config_generation", out _));
        Assert.True(root.TryGetProperty("in_flight_count", out _));
        Assert.True(root.TryGetProperty("local_router_enabled", out _));
        Assert.True(root.TryGetProperty("supported_contracts", out _));
        Assert.True(root.TryGetProperty("routes", out _));
        Assert.False(root.TryGetProperty("policy_mutation_available", out _));
    }

    private static string FeatureBody(string generation, bool enabled)
        => "{\"schema_version\":1,\"expected_generation\":\"" + generation
            + "\",\"enabled\":" + (enabled ? "true" : "false") + "}";

    private static string RetryMutationBody(string generation, string policyId, int maxAttempts)
        => "{\"schema_version\":1,\"expected_generation\":\"" + generation
            + "\",\"policy_id\":\"" + policyId
            + "\",\"retry\":{\"schema_version\":1,\"max_attempts\":" + maxAttempts
            + ",\"base_delay_ms\":300,\"max_delay_ms\":6000,\"jitter\":0.1,\"respect_retry_after\":true,\"max_retry_after_ms\":20000}}";

    private static string CrossModelFailoverBody(string generation)
        => "{\"schema_version\":1,\"expected_generation\":\"" + generation
            + "\",\"policy_id\":\"policy.retry-safe-default\",\"failover\":{\"schema_version\":1,\"allow_same_model_alternate_endpoint\":true,\"allow_same_model_alternate_provider\":false,\"allow_cross_model_fallback\":true}}";
}

/// <summary>Test ingress context with production control-plane services composed.</summary>
internal sealed class ControlPlaneEndpointsContext : IAsyncDisposable
{
    public const string DefaultsPath = @"C:\lr14p-ingress\defaults.json";
    public const string UserConfigPath = @"C:\lr14p-ingress\user.json";

    private static readonly IReadOnlyList<ClientConfig> Clients =
    [
        new ClientConfig
        {
            ClientId = "client.local_test",
            AdapterId = "adapter.client.local_test.responses.v1",
            Enabled = true,
            AuthScope = "responses:invoke",
            Version = 1,
        },
        new ClientConfig
        {
            ClientId = "client.local_status",
            AdapterId = "adapter.client.local_status.responses.v1",
            Enabled = true,
            AuthScope = "router:status",
            Version = 1,
        },
        new ClientConfig
        {
            ClientId = "client.control_plane",
            AdapterId = "adapter.client.control_plane.responses.v1",
            Enabled = true,
            AuthScope = "router:control-plane",
            Version = 1,
        },
    ];

    private ControlPlaneEndpointsContext(
        MemoryControlFileSystem fileSystem,
        LocalRouterConfigOperator configOperator,
        RequestMeteringService metering,
        IngressTestServer server,
        CurrentRouterState? state)
    {
        FileSystem = fileSystem;
        ConfigOperator = configOperator;
        Metering = metering;
        Server = server;
        State = state;
    }

    public MemoryControlFileSystem FileSystem { get; }

    public LocalRouterConfigOperator ConfigOperator { get; }

    public CurrentRouterState? State { get; }

    public RequestMeteringService Metering { get; }

    public IngressTestServer Server { get; }

    public static async Task<ControlPlaneEndpointsContext> CreateAsync(bool policyDefaults = false, bool live = true)
    {
        MemoryControlFileSystem fileSystem = new();
        fileSystem.SeedFile(DefaultsPath, policyDefaults ? PolicyDefaultsText() : DefaultsText());
        LocalRouterConfigOperator configOperator = new(
            fileSystem,
            new SystemClock(),
            DefaultsPath,
            UserConfigPath);
        LocalRouterConfigReadResult initial = await configOperator.ReadAsync(CancellationToken.None);
        Assert.True(initial.IsSuccess, initial.Error?.Code);
        CurrentRouterState currentState = new(
            PublishedRouterState.From(initial.View!.Config, initial.View.ConfigGeneration));
        if (live)
        {
            configOperator = configOperator.WithPublicationSink(currentState);
        }

        RequestMeteringService metering = new();
        IngressTestServer server = await IngressTestServer.StartAsync(options =>
        {
            options.Clients = Clients;
            options.ControlPlane = new ControlPlaneRuntimeServices
            {
                Metering = metering,
                ConfigOperator = configOperator,
                CurrentState = live ? currentState : null,
            };
        });
        return new ControlPlaneEndpointsContext(
            fileSystem,
            configOperator,
            metering,
            server,
            live ? currentState : null);
    }

    public async Task<string> ReadGenerationAsync()
    {
        using HttpResponseMessage response = await GetControlAsync("/v1/router/control-plane/status");
        string body = await Server.GetBodyAsync(response);
        using JsonDocument json = JsonDocument.Parse(body);
        return json.RootElement.GetProperty("config_generation").GetString()!;
    }

    public async Task<HttpResponseMessage> GetControlAsync(string pathAndQuery)
    {
        using HttpRequestMessage request = Server.CreateRequest(HttpMethod.Get, pathAndQuery);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", IngressTestServer.TestToken);
        return await Server.SendAsync(request);
    }

    public async Task<HttpResponseMessage> PutJsonAsync(string path, string json)
    {
        using HttpRequestMessage request = Server.CreateRequest(HttpMethod.Put, path, json);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", IngressTestServer.TestToken);
        return await Server.SendAsync(request);
    }

    public async Task<HttpResponseMessage> PutChunkedJsonAsync(string path, string content)
    {
        using HttpRequestMessage request = Server.CreateRequest(HttpMethod.Put, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", IngressTestServer.TestToken);
        request.Content = new StreamContent(new NonSeekableReadStream(Encoding.UTF8.GetBytes(content)));
        request.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
        return await Server.SendAsync(request);
    }

    public async ValueTask DisposeAsync()
        => await Server.DisposeAsync().ConfigureAwait(false);

    private static string DefaultsText()
        => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "config", "router.defaults.json"));

    private static string PolicyDefaultsText()
        => DefaultsText().Replace(
            "\"policies\": [],",
            "\"policies\": [{\"policy_id\":\"policy.retry-safe-default\",\"version\":1}],",
            StringComparison.Ordinal);
}

/// <summary>Non-seekable read stream so HttpClient uses chunked transfer.</summary>
internal sealed class NonSeekableReadStream : Stream
{
    private readonly MemoryStream _inner;

    public NonSeekableReadStream(byte[] content)
    {
        _inner = new MemoryStream(content, writable: false);
    }

    public override bool CanRead => true;

    public override bool CanSeek => false;

    public override bool CanWrite => false;

    public override long Length => throw new NotSupportedException();

    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override void Flush()
    {
    }

    public override int Read(byte[] buffer, int offset, int count)
        => _inner.Read(buffer, offset, count);

    public override long Seek(long offset, SeekOrigin origin)
        => throw new NotSupportedException();

    public override void SetLength(long value)
        => throw new NotSupportedException();

    public override void Write(byte[] buffer, int offset, int count)
        => throw new NotSupportedException();
}

/// <summary>In-memory IFileSystem for operator-backed HTTP tests.</summary>
internal sealed class MemoryControlFileSystem : IFileSystem
{
    private readonly Dictionary<string, byte[]> _files = new(StringComparer.Ordinal);
    private readonly object _sync = new();

    public void SeedFile(string path, string content)
    {
        lock (_sync)
        {
            _files[path] = Encoding.UTF8.GetBytes(content);
        }
    }

    public bool HasFile(string path)
    {
        lock (_sync)
        {
            return _files.ContainsKey(path);
        }
    }

    public bool FileExists(string path)
    {
        lock (_sync)
        {
            return _files.ContainsKey(path);
        }
    }

    public bool DirectoryExists(string path) => FileExists(path);

    public void CreateDirectory(string path)
    {
    }

    public IEnumerable<string> EnumerateFiles(string directory, string pattern)
        => _files.Keys.ToArray();

    public void DeleteFile(string path)
    {
        lock (_sync)
        {
            _files.Remove(path);
        }
    }

    public void CopyFile(string sourcePath, string destinationPath, bool overwrite)
        => throw new NotSupportedException();

    public void MoveFile(string sourcePath, string destinationPath, bool overwrite)
    {
        lock (_sync)
        {
            if (!_files.TryGetValue(sourcePath, out byte[]? content))
            {
                throw new FileNotFoundException(sourcePath);
            }

            _files.Remove(sourcePath);
            _files[destinationPath] = content;
        }
    }

    public void ReplaceFile(string sourcePath, string destinationPath)
    {
        lock (_sync)
        {
            if (!_files.TryGetValue(sourcePath, out byte[]? content))
            {
                throw new FileNotFoundException(sourcePath);
            }

            _files.Remove(sourcePath);
            _files[destinationPath] = content;
        }
    }

    public Task<string> ReadAllTextAsync(string path, CancellationToken cancellationToken)
    {
        lock (_sync)
        {
            return Task.FromResult(
                _files.TryGetValue(path, out byte[]? content)
                    ? Encoding.UTF8.GetString(content)
                    : throw new FileNotFoundException(path));
        }
    }

    public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken)
        => Task.FromResult(Array.Empty<byte>());

    public Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken)
    {
        lock (_sync)
        {
            if (_files.ContainsKey(path))
            {
                throw new IOException("Temp path already exists.");
            }

            _files[path] = content.ToArray();
        }

        return Task.CompletedTask;
    }

    public string CreateTempPath(string directory)
        => Path.Combine(directory, ".tmp-" + Guid.NewGuid().ToString("N"));
}
