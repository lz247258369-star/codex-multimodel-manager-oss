using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Router.Core.Abstractions;
using Router.Core.Lifecycle;
using Router.Core.Tests.Fakes;
using Router.Host;
using Router.Ingress;
using Router.Ingress.Fakes;
using Router.Metering;
using Router.Observability;
using Xunit;

namespace Router.Core.Tests.Host;

/// <summary>
/// DSR7-C-FIX2: local safe failure diagnostics end to end. A capability
/// rejection writes exactly one five-field diagnostic file next to the runtime;
/// any other error, an unsafe field path, or an unwritable diagnostics path
/// changes nothing about the HTTP semantics.
/// </summary>
public sealed class Dsr7cFailureDiagnosticTests
{
    private const string UnsupportedToolBody =
        """{"model":"gpt-test","input":"PROMPT_DO_NOT_LEAK_123","tools":[{"type":"web_search","name":"never_log_me","description":"SUPER_SECRET_TOOL_NAME"}]}""";

    private const string UnsupportedParameterBody =
        """{"model":"gpt-test","input":"hi","temperature":0.7}""";

    private static readonly string[] ExpectedDiagnosticFields =
    [
        "completed_at",
        "error_code",
        "request_id",
        "safe_param",
        "schema_version",
    ];

    /// <summary>DSR7-C-FIX3: a rejected tool type carries the fixed class (schema v2).</summary>
    private static readonly string[] ExpectedClassifiedDiagnosticFields =
    [
        "completed_at",
        "error_code",
        "request_id",
        "safe_class",
        "safe_param",
        "schema_version",
    ];

    /// <summary>DSR7-C-FIX4: a rejected custom tool carries the fixed identity (schema v3).</summary>
    private static readonly string[] ExpectedIdentifiedDiagnosticFields =
    [
        "completed_at",
        "error_code",
        "request_id",
        "safe_class",
        "safe_identity",
        "safe_param",
        "schema_version",
    ];

    /// <summary>
    /// Request content that must never reach a diagnostic file. The rejected
    /// tool TYPE is deliberately absent from this list: for a known type the
    /// fixed taxonomy label is the only representation, and it is asserted
    /// explicitly instead.
    /// </summary>
    private static readonly string[] LeakDecoys =
    [
        "never_log_me",
        "SUPER_SECRET_TOOL_NAME",
        "PROMPT_DO_NOT_LEAK_123",
        "gpt-test",
        "sk-test-DO_NOT_LEAK",
        "https://secret.example/private",
        "resp_secret_123",
    ];

    [Fact]
    public async Task Unsupported_capability_writes_exactly_one_safe_diagnostic()
    {
        int port = HostTestHarness.GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox);
            await HostTestHarness.WriteEnabledRouterDefaultsAsync(pathProvider, port);

            using CancellationTokenSource cts = new();
            Task<int> runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: HostTestHarness.SecretResolver(),
                responsesService: new FakeResponsesService(),
                cancellationToken: cts.Token);

            using HttpClient client = new();
            Assert.True(await HostTestHarness.WaitUntilReadyAsync(client, port), "Router did not become ready.");

            using HttpRequestMessage request = new(HttpMethod.Post, $"http://127.0.0.1:{port}/v1/responses")
            {
                Content = new StringContent(UnsupportedToolBody, Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", HostTestHarness.TestToken);

            using HttpResponseMessage response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.UnprocessableEntity, response.StatusCode);
            string body = await response.Content.ReadAsStringAsync();
            Assert.Contains("\"param\":\"tools[0].type\"", body, StringComparison.Ordinal);

            string? diagnosticFile = await WaitForDiagnosticAsync(pathProvider);
            Assert.False(string.IsNullOrEmpty(diagnosticFile), "No safe failure diagnostic was written.");

            string json = await File.ReadAllTextAsync(diagnosticFile!);
            using JsonDocument document = JsonDocument.Parse(json);
            string[] fields = document.RootElement.EnumerateObject().Select(static p => p.Name).OrderBy(static n => n, StringComparer.Ordinal).ToArray();
            Assert.Equal(ExpectedClassifiedDiagnosticFields, fields);
            Assert.Equal(2, document.RootElement.GetProperty("schema_version").GetInt32());
            Assert.Equal("unsupported_capability", document.RootElement.GetProperty("error_code").GetString());
            Assert.Equal("tools[0].type", document.RootElement.GetProperty("safe_param").GetString());
            Assert.Equal("web_search", document.RootElement.GetProperty("safe_class").GetString());
            Assert.StartsWith("req_", document.RootElement.GetProperty("request_id").GetString(), StringComparison.Ordinal);

            Assert.Contains("\"safe_class\":\"web_search\"", json, StringComparison.Ordinal);
            foreach (string decoy in LeakDecoys)
            {
                Assert.DoesNotContain(decoy, json, StringComparison.Ordinal);
            }

            Assert.Equal(1, await CountDiagnosticFilesAsync(pathProvider));

            Assert.True(
                await HostTestHarness.WaitUntilReadyStateAsync(pathProvider, TimeSpan.FromSeconds(15)),
                "Router did not persist the durable READY state before shutdown.");
            cts.Cancel();
            Assert.Equal(0, await runTask.WaitAsync(TimeSpan.FromSeconds(15)));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Unsupported_parameter_writes_no_diagnostic()
    {
        int port = HostTestHarness.GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox);
            await HostTestHarness.WriteEnabledRouterDefaultsAsync(pathProvider, port);

            using CancellationTokenSource cts = new();
            Task<int> runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: HostTestHarness.SecretResolver(),
                responsesService: new FakeResponsesService(),
                cancellationToken: cts.Token);

            using HttpClient client = new();
            Assert.True(await HostTestHarness.WaitUntilReadyAsync(client, port), "Router did not become ready.");

            using HttpRequestMessage request = new(HttpMethod.Post, $"http://127.0.0.1:{port}/v1/responses")
            {
                Content = new StringContent(UnsupportedParameterBody, Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", HostTestHarness.TestToken);

            using HttpResponseMessage response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
            Assert.Contains("\"code\":\"unsupported_parameter\"", await response.Content.ReadAsStringAsync(), StringComparison.Ordinal);

            await Task.Delay(500);
            Assert.Equal(0, await CountDiagnosticFilesAsync(pathProvider));

            Assert.True(
                await HostTestHarness.WaitUntilReadyStateAsync(pathProvider, TimeSpan.FromSeconds(15)),
                "Router did not persist the durable READY state before shutdown.");
            cts.Cancel();
            Assert.Equal(0, await runTask.WaitAsync(TimeSpan.FromSeconds(15)));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    // DSR7-C-FIX3: only a rejected TOOL TYPE carries a class. A different
    // capability gate keeps the schema-v1 five-field diagnostic.
    [Fact]
    public async Task Non_tool_capability_failure_writes_the_unclassified_v1_diagnostic()
    {
        int port = HostTestHarness.GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox);
            await HostTestHarness.WriteEnabledRouterDefaultsAsync(pathProvider, port);

            using CancellationTokenSource cts = new();
            Task<int> runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: HostTestHarness.SecretResolver(),
                responsesService: new FakeResponsesService(),
                cancellationToken: cts.Token);

            using HttpClient client = new();
            Assert.True(await HostTestHarness.WaitUntilReadyAsync(client, port), "Router did not become ready.");

            using HttpRequestMessage request = new(HttpMethod.Post, $"http://127.0.0.1:{port}/v1/responses")
            {
                Content = new StringContent("""{"model":"gpt-test","input":"hi","store":true}""", Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", HostTestHarness.TestToken);

            using HttpResponseMessage response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.UnprocessableEntity, response.StatusCode);
            Assert.Contains("\"param\":\"store\"", await response.Content.ReadAsStringAsync(), StringComparison.Ordinal);

            string? diagnosticFile = await WaitForDiagnosticAsync(pathProvider);
            Assert.False(string.IsNullOrEmpty(diagnosticFile), "No safe failure diagnostic was written.");
            using JsonDocument document = JsonDocument.Parse(await File.ReadAllTextAsync(diagnosticFile!));
            string[] fields = document.RootElement.EnumerateObject().Select(static p => p.Name).OrderBy(static n => n, StringComparer.Ordinal).ToArray();
            Assert.Equal(ExpectedDiagnosticFields, fields);
            Assert.Equal(1, document.RootElement.GetProperty("schema_version").GetInt32());
            Assert.Equal("store", document.RootElement.GetProperty("safe_param").GetString());
            Assert.False(document.RootElement.TryGetProperty("safe_class", out _));

            Assert.True(
                await HostTestHarness.WaitUntilReadyStateAsync(pathProvider, TimeSpan.FromSeconds(15)),
                "Router did not persist the durable READY state before shutdown.");
            cts.Cancel();
            Assert.Equal(0, await runTask.WaitAsync(TimeSpan.FromSeconds(15)));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    // DSR7-C-FIX5-A: custom/apply_patch is now an accepted canonical tool, so it is
    // no longer a capability failure and must never write a FIX4 diagnostic. The
    // provider path (not the injected fake service) is what fails closed until the
    // FIX5-B bridge exists - see the DeepSeek bridge tests.
    [Fact]
    public async Task Accepted_custom_apply_patch_tool_writes_no_diagnostic()
    {
        int port = HostTestHarness.GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox);
            await HostTestHarness.WriteEnabledRouterDefaultsAsync(pathProvider, port);

            using CancellationTokenSource cts = new();
            Task<int> runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: HostTestHarness.SecretResolver(),
                responsesService: new FakeResponsesService(),
                cancellationToken: cts.Token);

            using HttpClient client = new();
            Assert.True(await HostTestHarness.WaitUntilReadyAsync(client, port), "Router did not become ready.");

            const string body =
                """{"model":"gpt-test","input":"hi","tools":[{"type":"custom","name":"apply_patch","format":{"type":"grammar","syntax":"lark","definition":"DO_NOT_LEAK_12345"}}]}""";
            using HttpRequestMessage request = new(HttpMethod.Post, $"http://127.0.0.1:{port}/v1/responses")
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", HostTestHarness.TestToken);

            using HttpResponseMessage response = await client.SendAsync(request);
            Assert.True(
                response.StatusCode == HttpStatusCode.OK,
                "unexpected status " + (int)response.StatusCode + ": " + await response.Content.ReadAsStringAsync());

            await Task.Delay(500);
            Assert.Equal(0, await CountDiagnosticFilesAsync(pathProvider));

            Assert.True(
                await HostTestHarness.WaitUntilReadyStateAsync(pathProvider, TimeSpan.FromSeconds(15)),
                "Router did not persist the durable READY state before shutdown.");
            cts.Cancel();
            Assert.Equal(0, await runTask.WaitAsync(TimeSpan.FromSeconds(15)));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Unwritable_diagnostics_path_never_changes_request_semantics()
    {
        int port = HostTestHarness.GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox);
            await HostTestHarness.WriteEnabledRouterDefaultsAsync(pathProvider, port);

            // Occupy the diagnostics path with a FILE so the log can never create
            // its directory: every diagnostic write must degrade silently.
            string runtimeDirectory = Path.GetDirectoryName(pathProvider.RuntimeStatePath)!;
            Directory.CreateDirectory(runtimeDirectory);
            string blocked = Path.Combine(runtimeDirectory, "diagnostics");
            await File.WriteAllTextAsync(blocked, "not a directory");

            using CancellationTokenSource cts = new();
            Task<int> runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: HostTestHarness.SecretResolver(),
                responsesService: new FakeResponsesService(),
                cancellationToken: cts.Token);

            using HttpClient client = new();
            Assert.True(await HostTestHarness.WaitUntilReadyAsync(client, port), "Router did not become ready.");

            using HttpRequestMessage request = new(HttpMethod.Post, $"http://127.0.0.1:{port}/v1/responses")
            {
                Content = new StringContent(UnsupportedToolBody, Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", HostTestHarness.TestToken);

            using HttpResponseMessage response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.UnprocessableEntity, response.StatusCode);
            Assert.Contains("\"param\":\"tools[0].type\"", await response.Content.ReadAsStringAsync(), StringComparison.Ordinal);

            // The router keeps serving: the diagnostic failure is isolated.
            using HttpResponseMessage health = await client.GetAsync($"http://127.0.0.1:{port}/health");
            Assert.Equal(HttpStatusCode.OK, health.StatusCode);

            Assert.True(
                await HostTestHarness.WaitUntilReadyStateAsync(pathProvider, TimeSpan.FromSeconds(15)),
                "Router did not persist the durable READY state before shutdown.");
            cts.Cancel();
            Assert.Equal(0, await runTask.WaitAsync(TimeSpan.FromSeconds(15)));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Theory]
    [InlineData("tools[0].type=web_search")]
    [InlineData("https://secret.example/private")]
    [InlineData("SUPER_SECRET_TOOL_NAME")]
    [InlineData("sk-test-DO_NOT_LEAK")]
    public async Task Unsafe_error_param_never_reaches_the_diagnostic_log(string unsafeParam)
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string directory = Path.Combine(sandbox, "diagnostics");
            var log = new SafeFailureDiagnosticLog(directory);
            var observer = new ProductionCompletionObserver(
                new RequestMeteringService(),
                requestLog: null,
                new FakeClock(),
                failureDiagnosticLog: log);

            observer.OnCompleted(new RequestExecutionResult
            {
                RequestId = "req_unsafe",
                TraceId = "trc_unsafe",
                ClientId = "client.codex_cli",
                Scope = "responses:invoke",
                State = RequestState.Failed,
                HttpStatus = 422,
                ErrorCode = "unsupported_capability",
                ErrorParam = unsafeParam,
            });
            await observer.DrainAsync(CancellationToken.None);

            Assert.False(Directory.Exists(directory) && Directory.EnumerateFiles(directory, "capability-*.json").Any());
            Assert.Equal(0, log.WrittenCount);
            // The observer drops an unsafe path before it ever reaches the log,
            // so the sink must not have been asked to record anything either.
            Assert.Equal(0, log.DroppedCount);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Non_capability_failure_never_reaches_the_diagnostic_log()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string directory = Path.Combine(sandbox, "diagnostics");
            var log = new SafeFailureDiagnosticLog(directory);
            var observer = new ProductionCompletionObserver(
                new RequestMeteringService(),
                requestLog: null,
                new FakeClock(),
                failureDiagnosticLog: log);

            observer.OnCompleted(new RequestExecutionResult
            {
                RequestId = "req_other",
                TraceId = "trc_other",
                ClientId = "client.codex_cli",
                Scope = "responses:invoke",
                State = RequestState.Failed,
                HttpStatus = 400,
                ErrorCode = "unsupported_parameter",
                ErrorParam = "temperature",
            });
            await observer.DrainAsync(CancellationToken.None);

            Assert.Equal(0, log.WrittenCount);
            Assert.False(Directory.Exists(directory) && Directory.EnumerateFiles(directory, "capability-*.json").Any());
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    private static string GetDiagnosticsDirectory(TestPathProvider pathProvider)
        => Path.Combine(Path.GetDirectoryName(pathProvider.RuntimeStatePath)!, "diagnostics");

    private static Task<int> CountDiagnosticFilesAsync(TestPathProvider pathProvider)
    {
        string directory = GetDiagnosticsDirectory(pathProvider);
        if (!Directory.Exists(directory))
        {
            return Task.FromResult(0);
        }

        return Task.FromResult(Directory.EnumerateFiles(directory, "capability-*.json").Count());
    }

    private static async Task<string?> WaitForDiagnosticAsync(TestPathProvider pathProvider)
    {
        string directory = GetDiagnosticsDirectory(pathProvider);
        DateTimeOffset deadline = DateTimeOffset.UtcNow.AddSeconds(10);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (Directory.Exists(directory))
            {
                string? file = Directory.EnumerateFiles(directory, "capability-*.json").FirstOrDefault();
                if (file is not null)
                {
                    // Ensure the file is fully written (atomic move completed).
                    try
                    {
                        using JsonDocument _ = JsonDocument.Parse(await File.ReadAllTextAsync(file));
                        return file;
                    }
                    catch (JsonException)
                    {
                        // Mid-write; retry.
                    }
                }
            }

            await Task.Delay(50);
        }

        return null;
    }
}
