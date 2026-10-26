using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using Router.Core.Tests.Fakes;
using Router.Host;
using Router.Ingress.Fakes;
using Router.Secrets;
using Xunit;

namespace Router.Core.Tests.Host;

/// <summary>
/// Reliability Fix 2: one lifecycle truth. Binding the loopback listener is no
/// longer readiness - the production Host publishes READY only after the owner
/// record and the durable runtime READY state are committed, so any caller that
/// can observe <c>ready=true</c> is already outside the startup window. A
/// cancellation inside that window stops the ingress through the normal
/// STOPPING path, archives (never deletes) the owner record this process wrote,
/// does not fabricate a STOPPED state, and reports the cancellation with its own
/// exit code.
///
/// Every window assertion below is deterministic: the durable READY write is
/// held open by <see cref="BlockingRuntimeStateFileSystem"/> until the test
/// cancels, so nothing depends on timing luck.
/// </summary>
public sealed class HostReadinessLifecycleTests
{
    private const int RepeatCount = 20;

    public static TheoryData<int> Repeat20
    {
        get
        {
            TheoryData<int> data = [];
            for (int iteration = 1; iteration <= RepeatCount; iteration++)
            {
                data.Add(iteration);
            }

            return data;
        }
    }

    [Theory]
    [MemberData(nameof(Repeat20))]
    public async Task Health_200_implies_durable_ready(int iteration)
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(pathProvider, UserConfig(port));

            using CancellationTokenSource cts = new();
            Task<int> runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: HostTestHarness.SecretResolver(),
                responsesService: new FakeResponsesService(),
                cancellationToken: cts.Token);

            using HttpClient client = new();
            bool ready = await HostTestHarness.WaitUntilReadyAsync(client, port, runTask);
            Assert.True(ready, $"iteration {iteration}: the enabled router must reach READY");

            // The first observable public READY already implies durable READY:
            // there is no window in which /health says ready and the owner/state
            // commits are still missing.
            string healthJson = await client.GetStringAsync($"http://127.0.0.1:{port}/health");
            using JsonDocument health = JsonDocument.Parse(healthJson);
            Assert.Equal("READY", health.RootElement.GetProperty("lifecycle").GetString());
            Assert.True(health.RootElement.GetProperty("ready").GetBoolean());

            Assert.True(
                File.Exists(pathProvider.OwnerRecordPath),
                $"iteration {iteration}: public READY must imply the owner record is committed");
            Assert.True(
                File.Exists(pathProvider.RuntimeStatePath),
                $"iteration {iteration}: public READY must imply the durable runtime state is committed");

            using JsonDocument owner = JsonDocument.Parse(await File.ReadAllTextAsync(pathProvider.OwnerRecordPath));
            Assert.True(owner.RootElement.GetProperty("pid").GetInt32() > 0);

            using JsonDocument state = JsonDocument.Parse(await File.ReadAllTextAsync(pathProvider.RuntimeStatePath));
            Assert.Equal("READY", state.RootElement.GetProperty("lifecycle").GetString());

            cts.Cancel();
            Assert.Equal(0, await runTask.WaitAsync(TimeSpan.FromSeconds(15)));
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    [Theory]
    [MemberData(nameof(Repeat20))]
    public async Task Startup_tail_cancellation_stops_safely(int iteration)
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(pathProvider, UserConfig(port));

            BlockingRuntimeStateFileSystem fileSystem = new();
            using CancellationTokenSource cts = new();
            Task<int> runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: HostTestHarness.SecretResolver(),
                responsesService: new FakeResponsesService(),
                fileSystemOverride: fileSystem,
                cancellationToken: cts.Token);

            // Deterministic window: the listener is bound, the owner record is
            // committed, and the durable READY write is held open right now.
            await HostTestHarness.WaitForStartupBarrierAsync(fileSystem.ReadyStateWriteStarted.Task, runTask, TimeSpan.FromSeconds(15));

            using (HttpClient client = new())
            {
                using HttpResponseMessage health = await client.GetAsync($"http://127.0.0.1:{port}/health");
                Assert.Equal(HttpStatusCode.ServiceUnavailable, health.StatusCode);
                string body = await health.Content.ReadAsStringAsync();
                Assert.Contains("\"lifecycle\":\"STARTING\"", body, StringComparison.Ordinal);
                Assert.Contains("\"ready\":false", body, StringComparison.Ordinal);
            }

            Assert.True(
                File.Exists(pathProvider.OwnerRecordPath),
                $"iteration {iteration}: the owner record is committed inside the window");
            Assert.False(
                File.Exists(pathProvider.RuntimeStatePath),
                $"iteration {iteration}: no durable READY state exists inside the window");

            cts.Cancel();
            int exitCode = await runTask.WaitAsync(TimeSpan.FromSeconds(15));

            Assert.Equal(RouterHostBootstrap.CancelledExitCode, exitCode);
            Assert.Equal(130, exitCode);

            // The owner record this process wrote is archived, never deleted
            // without a copy, and never left behind as a live record.
            Assert.False(
                File.Exists(pathProvider.OwnerRecordPath),
                $"iteration {iteration}: an aborted startup must not leave a live owner record");
            Assert.True(
                QuarantinedOwnerRecords(pathProvider).Any(),
                $"iteration {iteration}: the aborted startup owner record must be archived to quarantine");

            // No fabricated STOPPED state for a process that never became ready.
            Assert.Equal(0, fileSystem.CountWritesContaining("\"lifecycle\":\"STOPPED\""));
            Assert.False(
                File.Exists(pathProvider.RuntimeStatePath),
                $"iteration {iteration}: an aborted startup must not write a runtime state");

            Assert.False(IsPortListening(port), $"iteration {iteration}: the listener must be released");
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    [Theory]
    [MemberData(nameof(Repeat20))]
    public async Task Steady_state_shutdown_remains_clean(int iteration)
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(pathProvider, UserConfig(port));

            using CancellationTokenSource cts = new();
            Task<int> runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: HostTestHarness.SecretResolver(),
                responsesService: new FakeResponsesService(),
                cancellationToken: cts.Token);

            using HttpClient client = new();
            Assert.True(
                await HostTestHarness.WaitUntilReadyAsync(client, port, runTask),
                $"iteration {iteration}: the enabled router must reach READY");
            Assert.True(
                await HostTestHarness.WaitUntilReadyStateAsync(pathProvider, TimeSpan.FromSeconds(15)),
                $"iteration {iteration}: durable READY must be committed");

            cts.Cancel();
            int exitCode = await runTask.WaitAsync(TimeSpan.FromSeconds(15));

            Assert.Equal(0, exitCode);

            using JsonDocument state = JsonDocument.Parse(await File.ReadAllTextAsync(pathProvider.RuntimeStatePath));
            Assert.Equal("STOPPED", state.RootElement.GetProperty("lifecycle").GetString());
            Assert.False(File.Exists(pathProvider.OwnerRecordPath));
            Assert.True(QuarantinedOwnerRecords(pathProvider).Any());
            Assert.False(IsPortListening(port));
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    [Fact]
    public async Task Cancelled_token_before_start_returns_the_cancel_code()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            using CancellationTokenSource cts = new();
            cts.Cancel();

            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                new TestPathProvider(sandbox, TestPaths.DefaultsPath),
                cancellationToken: cts.Token);

            Assert.Equal(RouterHostBootstrap.CancelledExitCode, exitCode);
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    [Fact]
    public async Task Cancellation_during_listener_start_returns_the_cancel_code_not_a_config_error()
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(pathProvider, UserConfig(port));

            using CancellationTokenSource cts = new();
            // The Host's own token resolution cancels the token while the ingress
            // still resolves successfully, so the cancellation lands exactly on
            // Kestrel's bind - deterministically, with no timing window.
            CancellingOnFirstResolveSecretResolver resolver = new(cts);

            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: resolver,
                responsesService: new FakeResponsesService(),
                cancellationToken: cts.Token);

            Assert.Equal(RouterHostBootstrap.CancelledExitCode, exitCode);
            Assert.NotEqual(RouterHostBootstrap.ConfigErrorExitCode, exitCode);
            Assert.False(File.Exists(pathProvider.OwnerRecordPath));
            Assert.False(File.Exists(pathProvider.RuntimeStatePath));
            Assert.False(IsPortListening(port));
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    [Fact]
    public async Task Real_configuration_error_still_returns_the_config_error_code()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(
                pathProvider,
                """{"schema_version":1,"version":1,"mode":"router","local_router":{"enabled":true},"unexpected_field":true}""");

            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: HostTestHarness.SecretResolver(),
                responsesService: new FakeResponsesService(),
                cancellationToken: CancellationToken.None);

            Assert.Equal(RouterHostBootstrap.ConfigErrorExitCode, exitCode);
            Assert.False(File.Exists(pathProvider.OwnerRecordPath));
            Assert.False(File.Exists(pathProvider.RuntimeStatePath));
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    private static string UserConfig(int port) => $$"""
        {
          "schema_version": 1,
          "version": 1,
          "mode": "router",
          "local_router": { "enabled": true, "port": {{port}} },
          "clients": [
            {"client_id":"client.local_test","adapter_id":"adapter.client.local_test.responses.v1","enabled":true,"auth_scope":"responses:invoke","capabilities":["text","streaming","responses"],"version":1}
          ]
        }
        """;

    private static async Task WriteUserConfigAsync(TestPathProvider pathProvider, string json)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(pathProvider.UserConfigPath)!);
        await File.WriteAllTextAsync(pathProvider.UserConfigPath, json);
    }

    /// <summary>Owner records archived under the quarantine root, newest last.</summary>
    private static IEnumerable<string> QuarantinedOwnerRecords(TestPathProvider pathProvider)
        => Directory.Exists(pathProvider.QuarantineRootPath)
            ? Directory.EnumerateFiles(pathProvider.QuarantineRootPath, "router.pid.json", SearchOption.AllDirectories)
            : [];

    private static bool IsPortListening(int port)
    {
        try
        {
            using TcpClient client = new();
            return client.ConnectAsync(IPAddress.Loopback, port).Wait(TimeSpan.FromMilliseconds(500));
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static int GetFreePort()
    {
        TcpListener listener = new(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static async Task DeleteSandboxWithRetryAsync(string sandbox)
    {
        const int maxAttempts = 6;
        int delayMs = 25;
        for (int attempt = 1; attempt <= maxAttempts; attempt++)
        {
            try
            {
                Directory.Delete(sandbox, recursive: true);
                return;
            }
            catch (IOException) when (attempt < maxAttempts)
            {
            }
            catch (UnauthorizedAccessException) when (attempt < maxAttempts)
            {
            }

            await Task.Delay(delayMs).ConfigureAwait(false);
            delayMs = Math.Min(delayMs * 2, 200);
        }
    }

    /// <summary>
    /// Resolves the local client token successfully but cancels the caller's
    /// token on the Host's own resolution, so the cancellation is observed by
    /// the listener start rather than by config/secret handling.
    /// </summary>
    private sealed class CancellingOnFirstResolveSecretResolver : ISecretResolver
    {
        private readonly FakeSecretResolver _inner = new();
        private readonly CancellationTokenSource _cts;
        private int _calls;

        public CancellingOnFirstResolveSecretResolver(CancellationTokenSource cts)
        {
            _cts = cts;
            _inner.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", HostTestHarness.TestToken);
        }

        public Task<SecretResolutionResult> ResolveAsync(
            SecretReference reference,
            string providerId,
            CancellationToken cancellationToken)
        {
            if (Interlocked.Increment(ref _calls) == 1)
            {
                _cts.Cancel();
            }

            return _inner.ResolveAsync(reference, providerId, CancellationToken.None);
        }
    }
}
