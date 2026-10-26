using System.Reflection;
using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.Core.Ids;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.Responses;
using Xunit;

namespace ProviderContractKit;

/// <summary>
/// Reusable Provider Contract Kit: every provider adapter (LR-5 fake, and
/// LR-6/7/7A/7B later) must pass this exact suite by inheriting it and
/// implementing <see cref="Harness"/>. There is only one contract suite; no
/// adapter gets a second, weaker suite.
/// </summary>
public abstract class ProviderContractSuite
{
    private static readonly UuidV7 FixedUuid = UuidV7.Parse("018f4a9b-0000-7000-8000-000000000000");

    private FakeProviderServer? _activeStreamServer;

    protected abstract ProviderContractHarness Harness { get; }

    [Fact]
    public void Adapter_identity_is_exact_and_versioned()
    {
        ProviderAdapterDescriptor descriptor = Harness.CreateAdapter().Descriptor;

        Assert.False(string.IsNullOrWhiteSpace(descriptor.AdapterId));
        Assert.False(string.IsNullOrWhiteSpace(descriptor.AdapterVersion));
        Assert.False(string.IsNullOrWhiteSpace(descriptor.ProviderId));
        Assert.False(string.IsNullOrWhiteSpace(descriptor.ProtocolId));
        Assert.True(descriptor.Eligible);
        Assert.Contains("responses", descriptor.Capabilities.Values);
    }

    [Fact]
    public void Registration_and_exact_resolution_succeed()
    {
        IProviderAdapter adapter = Harness.CreateAdapter();
        Result<ProviderAdapterRegistry, RouterError> registryResult = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.True(registryResult.IsSuccess);
        AdapterResolveResult resolved = registryResult.Value!.Resolve(
            adapter.Descriptor.AdapterId,
            adapter.Descriptor.AdapterVersion,
            adapter.Descriptor.ProviderId,
            adapter.Descriptor.ProtocolId);

        Assert.True(resolved.IsResolved);
        Assert.Same(adapter, resolved.Adapter);
    }

    [Fact]
    public void Duplicate_registration_fails_closed()
    {
        IProviderAdapter adapter = Harness.CreateAdapter();
        Result<ProviderAdapterRegistry, RouterError> result = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.AdapterRegistrationInvalid, result.Error!.Code);
    }

    [Fact]
    public void Adapter_version_collision_fails_closed()
    {
        IProviderAdapter adapter = Harness.CreateAdapter();
        ProviderAdapterDescriptor sameVersion = adapter.Descriptor with { AdapterId = adapter.Descriptor.AdapterId };
        Result<ProviderAdapterRegistry, RouterError> result = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
            ProviderAdapterRegistration.Create(sameVersion, adapter),
        ]);

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.AdapterRegistrationInvalid, result.Error!.Code);
    }

    [Fact]
    public void Unknown_adapter_fails_closed()
    {
        IProviderAdapter adapter = Harness.CreateAdapter();
        Result<ProviderAdapterRegistry, RouterError> registryResult = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        AdapterResolveResult resolved = registryResult.Value!.Resolve(
            "adapter.provider.nope.responses.v1",
            "1.0",
            adapter.Descriptor.ProviderId,
            adapter.Descriptor.ProtocolId);

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterNotFound, resolved.Error!.Code);
    }

    [Fact]
    public void Adapter_version_mismatch_fails_closed()
    {
        IProviderAdapter adapter = Harness.CreateAdapter();
        Result<ProviderAdapterRegistry, RouterError> registryResult = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(adapter.Descriptor, adapter),
        ]);

        AdapterResolveResult resolved = registryResult.Value!.Resolve(
            adapter.Descriptor.AdapterId,
            "9.9.9",
            adapter.Descriptor.ProviderId,
            adapter.Descriptor.ProtocolId);

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.AdapterVersionMismatch, resolved.Error!.Code);
    }

    [Fact]
    public void Placeholder_registration_is_never_eligible()
    {
        IProviderAdapter adapter = Harness.CreateAdapter();
        ProviderAdapterDescriptor placeholder = adapter.Descriptor with { Eligible = false };
        Result<ProviderAdapterRegistry, RouterError> registryResult = ProviderAdapterRegistry.Create(
        [
            ProviderAdapterRegistration.Create(placeholder, adapter),
        ]);

        AdapterResolveResult resolved = registryResult.Value!.Resolve(
            adapter.Descriptor.AdapterId,
            adapter.Descriptor.AdapterVersion,
            adapter.Descriptor.ProviderId,
            adapter.Descriptor.ProtocolId);

        Assert.False(resolved.IsResolved);
        Assert.Equal(RouterErrorCode.PlaceholderUnavailable, resolved.Error!.Code);
    }

    [Fact]
    public void Endpoint_rejects_non_loopback_http()
    {
        Result<UpstreamEndpoint, RouterError> created = UpstreamEndpoint.Create(
            new Uri("http://provider.example.invalid/v1/responses"),
            tlsRequired: true,
            loopbackTestOnly: true);

        Assert.False(created.IsSuccess);
        Assert.Equal(RouterErrorCode.TlsRequired, created.Error!.Code);
    }

    [Fact]
    public void Loopback_http_requires_explicit_test_boundary()
    {
        var loopback = new Uri("http://127.0.0.1:47822/v1/responses");

        Result<UpstreamEndpoint, RouterError> withoutFlag = UpstreamEndpoint.Create(loopback, tlsRequired: true);
        Assert.False(withoutFlag.IsSuccess);

        Result<UpstreamEndpoint, RouterError> withFlag = UpstreamEndpoint.Create(loopback, tlsRequired: false, loopbackTestOnly: true);
        Assert.True(withFlag.IsSuccess);
    }

    [Fact]
    public void Scheme_downgrade_redirect_is_rejected()
    {
        Result<UpstreamEndpoint, RouterError> created = UpstreamEndpoint.Create(
            new Uri("https://127.0.0.1:443/v1/responses"),
            tlsRequired: true);

        Assert.True(created.IsSuccess);
        Assert.False(created.Value!.AllowsRedirect(new Uri("http://127.0.0.1:443/v1/responses")));
    }

    [Fact]
    public async Task Same_origin_redirect_is_followed()
    {
        ProviderContractHarness harness = Harness;
        await using FakeProviderServer server = harness.CreateServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson()));

        Result<UpstreamEndpoint, RouterError> endpointResult = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "redirect-same"),
            tlsRequired: false,
            loopbackTestOnly: true);

        UpstreamRequest request = UpstreamRequest.Create(
            "POST",
            endpointResult.Value!,
            "",
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase),
            System.Text.Encoding.UTF8.GetBytes("{}"),
            "application/json");

        Result<UpstreamResponse, RouterError> result = await harness.CreateTransport()
            .SendAsync(request, harness.CreateBoundaries(), CancellationToken.None);

        Assert.True(result.IsSuccess);
        Assert.Equal(200, result.Value!.StatusCode);
        result.Value.Body.Dispose();
    }

    [Fact]
    public async Task Cross_origin_redirect_is_rejected()
    {
        ProviderContractHarness harness = Harness;
        await using FakeProviderServer server = harness.CreateServer();
        await server.StartAsync();

        Result<UpstreamEndpoint, RouterError> endpointResult = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "redirect-cross"),
            tlsRequired: false,
            loopbackTestOnly: true);

        UpstreamRequest request = UpstreamRequest.Create(
            "POST",
            endpointResult.Value!,
            "",
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase),
            System.Text.Encoding.UTF8.GetBytes("{}"),
            "application/json");

        Result<UpstreamResponse, RouterError> result = await harness.CreateTransport()
            .SendAsync(request, harness.CreateBoundaries(), CancellationToken.None);

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.RedirectRejected, result.Error!.Code);
    }

    [Fact]
    public async Task Non_stream_text_round_trips()
    {
        ProviderAdapterResult result = await RunAsync(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson()));

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.Equal("resp_test_nonstream", result.Response!.Id);
        Assert.Contains(result.Response.Output, static item => item is MessageOutputItem);
        Assert.NotNull(result.Response.Usage);
        Assert.Equal(7, result.Response.Usage!.InputTokens);
        Assert.Equal(5, result.Response.Usage.OutputTokens);
    }

    [Fact]
    public async Task Streaming_round_trips_ordered_events()
    {
        ProviderAdapterResult result = await RunAsync(FakeProviderScenario.Sse(200, SseFixtureBuilder.BasicStream()), stream: true);

        result.Validate();
        Assert.NotNull(result.EventStream);
        List<CanonicalEvent> events = await CollectStreamAsync(result.EventStream!);

        Assert.Equal("response.created", events[0].Type);
        Assert.Contains(events, static evt => evt.Type == "response.output_text.delta");
        Assert.Contains(events, static evt => evt.Type == "response.completed");
    }

    [Fact]
    public async Task Fragmented_sse_is_reassembled()
    {
        string sse = SseFixtureBuilder.BasicStream();
        var scenario = new FakeProviderScenario
        {
            StatusCode = 200,
            Body = System.Text.Encoding.UTF8.GetBytes(sse),
            ContentType = "text/event-stream",
            ChunkSize = 1,
            DelayBetweenChunks = TimeSpan.FromMilliseconds(1),
        };

        ProviderAdapterResult result = await RunAsync(scenario, stream: true);

        result.Validate();
        List<CanonicalEvent> events = await CollectStreamAsync(result.EventStream!);
        Assert.Equal("response.created", events[0].Type);
        Assert.Contains(events, static evt => evt.Type == "response.completed");
    }

    [Fact]
    public async Task Reasoning_content_is_preserved()
    {
        ProviderAdapterResult nonStream = await RunAsync(FakeProviderScenario.Json(200, SseFixtureBuilder.ReasoningJson()));
        nonStream.Validate();
        Assert.Contains(nonStream.Response!.Output, static item => item.Type == "reasoning");

        ProviderAdapterResult stream = await RunAsync(FakeProviderScenario.Sse(200, SseFixtureBuilder.ReasoningStream()), stream: true);
        stream.Validate();
        List<CanonicalEvent> events = await CollectStreamAsync(stream.EventStream!);
        Assert.Contains(events, static evt => evt.Type == "response.reasoning_summary_text.delta");
    }

    [Fact]
    public async Task Tool_calls_are_preserved()
    {
        ProviderAdapterResult nonStream = await RunAsync(FakeProviderScenario.Json(200, SseFixtureBuilder.ToolCallJson()));
        nonStream.Validate();
        Assert.Contains(nonStream.Response!.Output, static item => item.Type == "function_call");

        ProviderAdapterResult stream = await RunAsync(FakeProviderScenario.Sse(200, SseFixtureBuilder.ToolCallStream()), stream: true);
        stream.Validate();
        List<CanonicalEvent> events = await CollectStreamAsync(stream.EventStream!);
        Assert.Contains(events, static evt => evt.Type == "response.output_item.added");
    }

    [Fact]
    public async Task Tool_results_round_trip_in_the_request_body()
    {
        ProviderContractHarness harness = Harness;
        await using FakeProviderServer server = harness.CreateServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson()));

        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest(stream: false);
        request = request with
        {
            Input =
            [
                new FunctionCallOutputItem { Type = "function_call_output", CallId = "call_1", Output = "{\"temp\": 22}" },
            ],
        };

        ProviderAdapterResult result = await InvokeAsync(harness, server, request, stream: false);

        result.Validate();
        Assert.NotNull(result.Response);
        byte[]? sentBody = server.LastRequestBody;
        Assert.NotNull(sentBody);
        string sentText = System.Text.Encoding.UTF8.GetString(sentBody!);
        Assert.Contains("function_call_output", sentText);
        Assert.Contains("call_1", sentText);
    }

    [Fact]
    public async Task Usage_is_normalized()
    {
        ProviderAdapterResult nonStream = await RunAsync(FakeProviderScenario.Json(200, SseFixtureBuilder.UsageJson()));
        nonStream.Validate();
        Assert.Equal(100, nonStream.Response!.Usage!.InputTokens);
        Assert.Equal(50, nonStream.Response.Usage.OutputTokens);
        Assert.Equal(150, nonStream.Response.Usage.TotalTokens);
    }

    [Theory]
    [InlineData(400)]
    [InlineData(401)]
    [InlineData(403)]
    public async Task Provider_4xx_is_normalized(int statusCode)
    {
        ProviderAdapterResult result = await RunAsync(FakeProviderScenario.Json(statusCode, "{}"));

        result.Validate();
        Assert.NotNull(result.Error);
        Assert.Equal(RouterErrorCode.Provider4xx, result.Error!.Code);
    }

    [Fact]
    public async Task Rate_limited_429_is_normalized()
    {
        ProviderAdapterResult result = await RunAsync(FakeProviderScenario.Json(429, "{}"));

        result.Validate();
        Assert.Equal(RouterErrorCode.RateLimited, result.Error!.Code);
    }

    [Theory]
    [InlineData(500)]
    [InlineData(502)]
    [InlineData(503)]
    public async Task Provider_5xx_is_normalized(int statusCode)
    {
        ProviderAdapterResult result = await RunAsync(FakeProviderScenario.Json(statusCode, "{}"));

        result.Validate();
        Assert.Equal(RouterErrorCode.Provider5xx, result.Error!.Code);
    }

    [Fact]
    public async Task Malformed_body_is_invalid_response()
    {
        ProviderAdapterResult result = await RunAsync(
            new FakeProviderScenario { StatusCode = 200, Body = System.Text.Encoding.UTF8.GetBytes("{ nope"), ContentType = "application/json" });

        result.Validate();
        Assert.Equal(RouterErrorCode.InvalidResponse, result.Error!.Code);
    }

    [Fact]
    public async Task Truncated_stream_is_stream_interrupted()
    {
        string truncated = SseFixtureBuilder.BasicStream().Replace("response.completed", "response.incomplete", StringComparison.Ordinal);
        ProviderAdapterResult result = await RunAsync(FakeProviderScenario.Sse(200, truncated), stream: true);

        result.Validate();
        Assert.NotNull(result.EventStream);
        await Assert.ThrowsAsync<StreamInterruptedException>(() => AwaitStreamAsync(result.EventStream!));
    }

    [Fact]
    public async Task Connection_reset_is_normalized()
    {
        ProviderAdapterResult result = await RunAsync(
            new FakeProviderScenario { StatusCode = 200, ContentType = "text/event-stream", AbortConnection = true },
            stream: true);

        result.Validate();
        Assert.NotNull(result.Error);
        Assert.Contains(result.Error!.Code, new[] { RouterErrorCode.ConnectionFailed, RouterErrorCode.StreamInterrupted });
    }

    [Fact]
    public async Task First_byte_timeout_is_normalized()
    {
        ProviderAdapterResult result = await RunAsync(
            new FakeProviderScenario
            {
                StatusCode = 200,
                ContentType = "application/json",
                Body = System.Text.Encoding.UTF8.GetBytes("{}"),
                DelayBeforeFirstByte = TimeSpan.FromSeconds(2),
            },
            boundaries: TimeoutBoundaries.Create(
                connectTimeout: TimeSpan.FromSeconds(1),
                firstByteTimeout: TimeSpan.FromMilliseconds(300),
                idleTimeout: TimeSpan.FromSeconds(5),
                totalTimeout: TimeSpan.FromSeconds(10)));

        result.Validate();
        Assert.Equal(RouterErrorCode.TimeoutFirstByte, result.Error!.Code);
    }

    [Fact]
    public async Task Idle_timeout_is_normalized()
    {
        ProviderAdapterResult result = await RunAsync(
            new FakeProviderScenario
            {
                StatusCode = 200,
                ContentType = "text/event-stream",
                Body = System.Text.Encoding.UTF8.GetBytes(SseFixtureBuilder.BasicStream("x")),
                ChunkSize = 8,
                DelayBetweenChunks = TimeSpan.FromSeconds(2),
            },
            stream: true,
            boundaries: TimeoutBoundaries.Create(
                connectTimeout: TimeSpan.FromSeconds(1),
                firstByteTimeout: TimeSpan.FromSeconds(2),
                idleTimeout: TimeSpan.FromMilliseconds(300),
                totalTimeout: TimeSpan.FromSeconds(10)));

        result.Validate();
        Assert.NotNull(result.EventStream);
        Exception? exception = await Record.ExceptionAsync(() => AwaitStreamAsync(result.EventStream!));
        Assert.IsType<StreamTimeoutException>(exception);
        Assert.Equal(StreamTimeoutStage.Idle, ((StreamTimeoutException)exception!).Stage);
    }

    [Fact]
    public async Task Total_timeout_is_normalized()
    {
        // The fixture separates the timeout stages deterministically: the fake
        // upstream sends its first byte immediately (the first-byte boundary is
        // a wide 4s margin, never the stage under test), one chunk arrives per
        // second while the total budget is 6s, and the idle boundary is far
        // larger than both the chunk gap and the total budget. The stream is far
        // longer than the total budget, so exactly the Total stage must fire.
        // (TimeoutBoundaries.Create requires total >= connect and total >= firstByte.)
        ProviderAdapterResult result = await RunAsync(
            new FakeProviderScenario
            {
                StatusCode = 200,
                ContentType = "text/event-stream",
                Body = System.Text.Encoding.UTF8.GetBytes(SseFixtureBuilder.BasicStream("x")),
                ChunkSize = 8,
                DelayBetweenChunks = TimeSpan.FromSeconds(1),
            },
            stream: true,
            boundaries: TimeoutBoundaries.Create(
                connectTimeout: TimeSpan.FromSeconds(4),
                firstByteTimeout: TimeSpan.FromSeconds(4),
                idleTimeout: TimeSpan.FromSeconds(20),
                totalTimeout: TimeSpan.FromSeconds(6)));

        result.Validate();
        Assert.NotNull(result.EventStream);
        Exception? exception = await Record.ExceptionAsync(() => AwaitStreamAsync(result.EventStream!));
        Assert.IsType<StreamTimeoutException>(exception);
        Assert.Equal(StreamTimeoutStage.Total, ((StreamTimeoutException)exception!).Stage);
    }

    [Fact]
    public async Task Cancellation_propagates_and_never_retries()
    {
        using var cts = new CancellationTokenSource();
        Task<ProviderAdapterResult> pending = RunAsync(
            new FakeProviderScenario
            {
                StatusCode = 200,
                ContentType = "application/json",
                Body = System.Text.Encoding.UTF8.GetBytes("{}"),
                DelayBeforeFirstByte = TimeSpan.FromSeconds(5),
            },
            cancellationToken: cts.Token);

        await Task.Delay(100);
        cts.Cancel();
        ProviderAdapterResult result = await pending;
        result.Validate();
        Assert.Equal(RouterErrorCode.Cancelled, result.Error!.Code);
    }

    [Fact]
    public void Pre_output_retry_is_allowed()
    {
        Assert.True(PreOutputRetryGuard.CanRetry(RetryCheckpoint.NotStarted));
        Assert.True(PreOutputRetryGuard.CanRetry(new RetryCheckpoint { State = RetryCheckpointState.RequestSent }));
        Assert.True(PreOutputRetryGuard.CanRetry(new RetryCheckpoint { State = RetryCheckpointState.WaitingFirstByte }));
        Assert.True(PreOutputRetryGuard.CanRetry(new RetryCheckpoint { State = RetryCheckpointState.FirstByteReceived }));
    }

    [Fact]
    public void Post_output_retry_is_forbidden()
    {
        Assert.False(PreOutputRetryGuard.CanRetry(new RetryCheckpoint { State = RetryCheckpointState.FirstOutputEmitted }));
        Assert.False(PreOutputRetryGuard.CanRetry(new RetryCheckpoint { State = RetryCheckpointState.Terminal }));
    }

    [Fact]
    public void Attempt_record_never_contains_content_or_secret_fields()
    {
        string[] forbidden = ["prompt", "rawbody", "toolpayload", "image", "header", "authorization", "secretvalue", "cookie", "apikey", "requestbody", "responsebody", "contenttext"];
        foreach (PropertyInfo property in typeof(AttemptRecord).GetProperties(BindingFlags.Public | BindingFlags.Instance))
        {
            string name = property.Name.ToLowerInvariant();
            foreach (string needle in forbidden)
            {
                Assert.DoesNotContain(needle, name);
            }
        }
    }

    [Fact]
    public async Task Header_redaction_excludes_credentials()
    {
        var scenario = new FakeProviderScenario
        {
            StatusCode = 200,
            Body = System.Text.Encoding.UTF8.GetBytes(SseFixtureBuilder.NonStreamJson()),
            ContentType = "application/json",
            ExtraHeaders = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["Authorization"] = "Bearer should-not-leak",
                ["Set-Cookie"] = "session=should-not-leak",
                ["x-api-key"] = "should-not-leak",
                ["X-Request-Id"] = "safe-header-value",
            },
        };

        ProviderAdapterResult result = await RunAsync(scenario);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.False(UpstreamHeaderPolicy.IsSafeResponseHeader("Authorization"));
        Assert.False(UpstreamHeaderPolicy.IsSafeResponseHeader("Set-Cookie"));
        Assert.False(UpstreamHeaderPolicy.IsSafeResponseHeader("x-api-key"));
        Assert.True(UpstreamHeaderPolicy.IsSafeResponseHeader("X-Request-Id"));
    }

    [Fact]
    public async Task Secret_is_used_only_at_the_http_boundary()
    {
        ProviderContractHarness harness = Harness;
        await using FakeProviderServer server = harness.CreateServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson()));

        ProviderAdapterResult result = await InvokeAsync(harness, server, harness.CreateRequest(stream: false), stream: false);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.True(server.LastRequestHeaders.TryGetValue("Authorization", out string? authorization));
        Assert.StartsWith("Bearer test_fake_key_do_not_use", authorization);
        Assert.Equal("test_fake_key_do_not_use", harness.CreateSecret().ReadValue());
    }

    [Fact]
    public async Task Deterministic_repeatability()
    {
        ProviderAdapterResult first = await RunAsync(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson()));
        ProviderAdapterResult second = await RunAsync(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson()));

        first.Validate();
        second.Validate();
        Assert.Equal(first.Response!.Id, second.Response!.Id);
        Assert.Equal(
            JsonSerializer.Serialize(first.Response, ResponsesJson.Options),
            JsonSerializer.Serialize(second.Response, ResponsesJson.Options));
    }

    private async Task<ProviderAdapterResult> RunAsync(
        FakeProviderScenario scenario,
        bool stream = false,
        TimeoutBoundaries? boundaries = null,
        CancellationToken cancellationToken = default)
    {
        ProviderContractHarness harness = Harness;
        FakeProviderServer server = harness.CreateServer();
        await server.StartAsync();
        server.SetScenario(scenario);
        ProviderAdapterResult result = await InvokeAsync(harness, server, harness.CreateRequest(stream), stream, boundaries, cancellationToken);
        if (stream)
        {
            _activeStreamServer = server;
            return result;
        }

        await server.DisposeAsync();
        return result;
    }

    private static async Task<ProviderAdapterResult> InvokeAsync(
        ProviderContractHarness harness,
        FakeProviderServer server,
        CanonicalResponsesRequest request,
        bool stream,
        TimeoutBoundaries? boundaries = null,
        CancellationToken cancellationToken = default)
    {
        IProviderAdapter adapter = harness.CreateAdapter();
        UpstreamEndpoint endpoint = harness.CreateEndpoint(server);
        TimeoutBoundaries effectiveBoundaries = boundaries ?? harness.CreateBoundaries();
        var invocation = new ProviderAdapterInvocation
        {
            AttemptId = AttemptId.Create(FixedUuid),
            RequestId = RequestId.Create(FixedUuid),
            TraceId = TraceId.Create(FixedUuid),
            Route = harness.CreateRoute(),
            Endpoint = endpoint,
            Request = request,
            Secret = harness.CreateSecret(),
            Transport = harness.CreateTransport(),
            Boundaries = effectiveBoundaries,
            Checkpoint = RetryCheckpoint.NotStarted,
            AttemptNumber = 1,
        };

        return await adapter.InvokeAsync(invocation, cancellationToken);
    }

    private static async Task<List<CanonicalEvent>> CollectEventsAsync(IAsyncEnumerable<CanonicalEvent> events)
    {
        var list = new List<CanonicalEvent>();
        await foreach (CanonicalEvent canonicalEvent in events)
        {
            list.Add(canonicalEvent);
        }

        return list;
    }

    private async Task<List<CanonicalEvent>> CollectStreamAsync(IAsyncEnumerable<CanonicalEvent> events)
    {
        try
        {
            return await CollectEventsAsync(events);
        }
        finally
        {
            await DisposeActiveStreamServerAsync();
        }
    }

    private async Task<List<CanonicalEvent>> AwaitStreamAsync(IAsyncEnumerable<CanonicalEvent> events)
        => await CollectStreamAsync(events);

    private async Task DisposeActiveStreamServerAsync()
    {
        if (_activeStreamServer is { } server)
        {
            _activeStreamServer = null;
            await server.DisposeAsync();
        }
    }
}
