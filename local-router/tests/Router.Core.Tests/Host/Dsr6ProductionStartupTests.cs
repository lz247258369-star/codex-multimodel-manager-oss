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
/// DSR6 production startup contract.
///
/// The checked-in defaults are the disabled-safe baseline and an explicit user
/// router.config.json is the only opt-in source, so the host must resolve the
/// effective config (defaults + user) before it decides anything. These tests
/// pin every branch of that decision, keep the disabled paths free of secret
/// resolution, and prove that an explicitly enabled user config really reaches
/// the production startup path (READY) without touching a provider.
/// </summary>
public sealed class Dsr6ProductionStartupTests
{
    /// <summary>
    /// Test teardown only. The host writes its runtime state atomically through
    /// short-lived <c>.tmp-*</c> files; Windows can still hold that handle
    /// briefly after the run task has completed, which made a plain recursive
    /// delete flaky under CI load. Only transient sharing violations are
    /// retried, with a bounded number of attempts and a bounded total delay,
    /// and anything that is still failing is rethrown: no error is swallowed
    /// and no assertion is relaxed.
    /// </summary>
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

    private const string ClientsJson = """
        "clients": [
          {"client_id":"client.local_test","adapter_id":"adapter.client.local_test.responses.v1","enabled":true,"auth_scope":"responses:invoke","capabilities":["text","streaming","responses"],"version":1}
        ]
        """;

    [Fact]
    public async Task Missing_user_config_keeps_the_disabled_safe_exit()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            FakeSecretResolver secretResolver = new();

            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: secretResolver,
                cancellationToken: CancellationToken.None);

            Assert.Equal(0, exitCode);
            Assert.Empty(secretResolver.Calls);
            Assert.False(File.Exists(pathProvider.UserConfigPath));
            Assert.False(File.Exists(pathProvider.RuntimeStatePath));
            Assert.False(File.Exists(pathProvider.OwnerRecordPath));
            Assert.False(Directory.Exists(pathProvider.QuarantineRootPath));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Explicitly_disabled_user_config_stays_disabled()
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(
                pathProvider,
                $$"""
                {
                  "schema_version": 1,
                  "version": 1,
                  "mode": "direct",
                  "local_router": { "enabled": false, "port": {{port}} }
                }
                """);

            FakeSecretResolver secretResolver = new();
            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: secretResolver,
                cancellationToken: CancellationToken.None);

            Assert.Equal(0, exitCode);
            Assert.Empty(secretResolver.Calls);
            Assert.False(File.Exists(pathProvider.RuntimeStatePath));
            Assert.False(File.Exists(pathProvider.OwnerRecordPath));
            Assert.False(IsPortListening(port), "A disabled config must never bind the loopback port.");
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Enabled_user_config_reaches_ready_and_stops_cleanly()
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            // The defaults stay byte-for-byte the checked-in disabled baseline;
            // only the user config opts in. Reaching READY therefore proves the
            // host no longer exits from the defaults flag alone.
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(
                pathProvider,
                $$"""
                {
                  "schema_version": 1,
                  "version": 1,
                  "mode": "router",
                  "local_router": { "enabled": true, "port": {{port}} },
                  {{ClientsJson.TrimEnd()}}
                }
                """);

            FakeSecretResolver secretResolver = new();
            secretResolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", "host-test-token");

            using CancellationTokenSource cts = new();
            Task<int> runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: secretResolver,
                responsesService: new FakeResponsesService(),
                cancellationToken: cts.Token);

            using HttpClient client = new();
            bool ready = await WaitUntilReadyAsync(client, port);
            Assert.True(ready, "An explicitly enabled user config must reach READY.");

            string healthJson = await client.GetStringAsync($"http://127.0.0.1:{port}/health");
            using JsonDocument health = JsonDocument.Parse(healthJson);
            Assert.True(health.RootElement.GetProperty("ready").GetBoolean());
            Assert.Equal("READY", health.RootElement.GetProperty("lifecycle").GetString());

            Assert.True(File.Exists(pathProvider.RuntimeStatePath), "Runtime state was not written.");
            Assert.True(File.Exists(pathProvider.OwnerRecordPath), "Owner record was not written.");

            // Startup resolved the local client token and nothing else: no
            // provider secret is ever touched by the bootstrap.
            Assert.All(
                secretResolver.Calls,
                call => Assert.Equal("CODEX_LOCAL_ROUTER_TOKEN", call.Reference.Name));

            cts.Cancel();
            Assert.Equal(0, await runTask.WaitAsync(TimeSpan.FromSeconds(15)));

            using JsonDocument state = JsonDocument.Parse(await File.ReadAllTextAsync(pathProvider.RuntimeStatePath));
            Assert.Equal("STOPPED", state.RootElement.GetProperty("lifecycle").GetString());
            Assert.False(File.Exists(pathProvider.OwnerRecordPath), "The owner record must be archived, not left live.");
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    [Fact]
    public async Task Corrupt_user_config_fails_closed()
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(pathProvider, $$"""{ "schema_version": 1, "mode": "router", "local_router": { "enabled": true, "port": {{port}} }""");

            FakeSecretResolver secretResolver = new();
            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: secretResolver,
                cancellationToken: CancellationToken.None);

            Assert.Equal(RouterHostBootstrap.ConfigErrorExitCode, exitCode);
            Assert.Empty(secretResolver.Calls);
            Assert.False(File.Exists(pathProvider.RuntimeStatePath));
            Assert.False(IsPortListening(port), "A corrupt user config must never bind the loopback port.");
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Enabled_user_config_with_direct_mode_fails_closed()
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(
                pathProvider,
                $$"""
                {
                  "schema_version": 1,
                  "version": 1,
                  "mode": "direct",
                  "local_router": { "enabled": true, "port": {{port}} }
                }
                """);

            FakeSecretResolver secretResolver = new();
            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: secretResolver,
                cancellationToken: CancellationToken.None);

            Assert.Equal(RouterHostBootstrap.ConfigErrorExitCode, exitCode);
            Assert.Empty(secretResolver.Calls);
            Assert.False(IsPortListening(port), "mode=direct must never bind the loopback port.");
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Unknown_user_config_field_fails_closed()
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(
                pathProvider,
                $$"""
                {
                  "schema_version": 1,
                  "version": 1,
                  "mode": "router",
                  "local_router": { "enabled": true, "port": {{port}} },
                  "unexpected_field": true
                }
                """);

            FakeSecretResolver secretResolver = new();
            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: secretResolver,
                cancellationToken: CancellationToken.None);

            Assert.Equal(RouterHostBootstrap.ConfigErrorExitCode, exitCode);
            Assert.Empty(secretResolver.Calls);
            Assert.False(File.Exists(pathProvider.RuntimeStatePath));
            Assert.False(IsPortListening(port), "An unknown user config field must never bind the loopback port.");
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Checked_in_defaults_stay_disabled()
    {
        string defaultsJson = await File.ReadAllTextAsync(TestPaths.DefaultsPath);
        using JsonDocument defaults = JsonDocument.Parse(defaultsJson);

        Assert.Equal("direct", defaults.RootElement.GetProperty("mode").GetString());
        Assert.False(defaults.RootElement.GetProperty("local_router").GetProperty("enabled").GetBoolean());
    }

    private static async Task WriteUserConfigAsync(TestPathProvider pathProvider, string json)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(pathProvider.UserConfigPath)!);
        await File.WriteAllTextAsync(pathProvider.UserConfigPath, json);
    }

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

    private static async Task<bool> WaitUntilReadyAsync(HttpClient client, int port)
    {
        client.Timeout = TimeSpan.FromSeconds(2);
        for (int attempt = 0; attempt < 100; attempt++)
        {
            try
            {
                using HttpResponseMessage response = await client.GetAsync($"http://127.0.0.1:{port}/health");
                if (response.StatusCode == HttpStatusCode.OK)
                {
                    return true;
                }
            }
            catch (Exception)
            {
                // Not listening yet.
            }

            await Task.Delay(100);
        }

        return false;
    }

    private static int GetFreePort()
    {
        TcpListener listener = new(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }
}
