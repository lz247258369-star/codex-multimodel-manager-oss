using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Router.Core.Tests.Fakes;
using Router.Host;
using Router.Ingress.Fakes;
using Router.Secrets;
using Router.State;
using Router.State.Ownership;
using Xunit;

namespace Router.Core.Tests.Host;

public sealed class Lr3HostEnabledTests
{
    private const string ClientsJson = """
        "clients": [
          {"client_id":"client.local_test","adapter_id":"adapter.client.local_test.responses.v1","enabled":true,"auth_scope":"responses:invoke","capabilities":["text","streaming","responses"],"version":1},
          {"client_id":"client.local_status","adapter_id":"adapter.client.local_status.responses.v1","enabled":true,"auth_scope":"router:status","capabilities":["responses"],"version":1}
        ],
        """;

    [Fact]
    public async Task Enabled_router_mode_starts_serves_and_stops_cleanly()
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox);
            Directory.CreateDirectory(Path.GetDirectoryName(pathProvider.DefaultsPath)!);
            string defaults = await File.ReadAllTextAsync(TestPaths.DefaultsPath);
            defaults = defaults
                .Replace("\"enabled\": false", "\"enabled\": true")
                .Replace("\"mode\": \"direct\"", "\"mode\": \"router\"")
                .Replace("\"port\": 47821", $"\"port\": {port}")
                .Replace("\"clients\": [],", ClientsJson);
            await File.WriteAllTextAsync(pathProvider.DefaultsPath, defaults);

            FakeSecretResolver resolver = new();
            resolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", "host-test-token");

            using CancellationTokenSource cts = new();
            Task<int> runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: resolver,
                responsesService: new FakeResponsesService(),
                cancellationToken: cts.Token);

            using HttpClient client = new();
            bool ready = await HostTestHarness.WaitUntilReadyAsync(client, port);
            Assert.True(ready, "Router health did not become ready within the timeout.");

            using HttpRequestMessage request = new(HttpMethod.Post, $"http://127.0.0.1:{port}/v1/responses")
            {
                Content = new StringContent("""{"model":"gpt-test","input":"hi"}""", Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "host-test-token");
            using HttpResponseMessage response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);

            Assert.True(File.Exists(pathProvider.RuntimeStatePath), "Runtime state file was not written.");
            Assert.True(File.Exists(pathProvider.OwnerRecordPath), "Owner record was not written.");

            Assert.True(
                await HostTestHarness.WaitUntilReadyStateAsync(pathProvider, TimeSpan.FromSeconds(15)),
                "Router did not persist the durable READY state before shutdown.");
            cts.Cancel();
            int exitCode = await runTask.WaitAsync(TimeSpan.FromSeconds(15));
            Assert.Equal(0, exitCode);

            string stateJson = await File.ReadAllTextAsync(pathProvider.RuntimeStatePath);
            using JsonDocument state = JsonDocument.Parse(stateJson);
            Assert.Equal("STOPPED", state.RootElement.GetProperty("lifecycle").GetString());

            Assert.False(File.Exists(pathProvider.OwnerRecordPath), "Owner record must be archived, not left live.");
            Assert.True(
                Directory.Exists(pathProvider.QuarantineRootPath)
                && Directory.EnumerateFiles(pathProvider.QuarantineRootPath, "*", SearchOption.AllDirectories).Any(),
                "Owner record was not archived to quarantine.");
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Foreign_owner_record_blocks_startup_without_killing_process()
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox);
            Directory.CreateDirectory(Path.GetDirectoryName(pathProvider.DefaultsPath)!);
            string defaults = await File.ReadAllTextAsync(TestPaths.DefaultsPath);
            defaults = defaults
                .Replace("\"enabled\": false", "\"enabled\": true")
                .Replace("\"mode\": \"direct\"", "\"mode\": \"router\"")
                .Replace("\"port\": 47821", $"\"port\": {port}")
                .Replace("\"clients\": [],", ClientsJson);
            await File.WriteAllTextAsync(pathProvider.DefaultsPath, defaults);

            using Process self = Process.GetCurrentProcess();
            DateTimeOffset startTime = self.StartTime.ToUniversalTime();
            DateTimeOffset foreignStart = startTime.AddSeconds(-5);
            OwnerRecord foreign = new()
            {
                SchemaVersion = OwnerRecord.CurrentSchemaVersion,
                Pid = self.Id,
                ProcessFingerprint = ProcessFingerprint.Compute(self.Id, foreignStart),
                ProcessStartTicks = foreignStart.Ticks,
                Host = "127.0.0.1",
                Port = port,
                CreatedAt = DateTimeOffset.UtcNow,
                Version = 1,
            };
            Directory.CreateDirectory(Path.GetDirectoryName(pathProvider.OwnerRecordPath)!);
            await File.WriteAllTextAsync(pathProvider.OwnerRecordPath, JsonSerializer.Serialize(foreign, StateJson.Options));

            FakeSecretResolver resolver = new();
            resolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", "token");

            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: resolver,
                cancellationToken: CancellationToken.None);

            Assert.Equal(RouterHostBootstrap.ConfigErrorExitCode, exitCode);
            Assert.False(self.HasExited, "A foreign process must never be killed.");
            Assert.True(File.Exists(pathProvider.OwnerRecordPath), "A foreign record must not be archived or deleted.");
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Live_owner_record_blocks_startup()
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox);
            Directory.CreateDirectory(Path.GetDirectoryName(pathProvider.DefaultsPath)!);
            string defaults = await File.ReadAllTextAsync(TestPaths.DefaultsPath);
            defaults = defaults
                .Replace("\"enabled\": false", "\"enabled\": true")
                .Replace("\"mode\": \"direct\"", "\"mode\": \"router\"")
                .Replace("\"port\": 47821", $"\"port\": {port}")
                .Replace("\"clients\": [],", ClientsJson);
            await File.WriteAllTextAsync(pathProvider.DefaultsPath, defaults);

            using Process self = Process.GetCurrentProcess();
            DateTimeOffset startTime = self.StartTime.ToUniversalTime();
            OwnerRecord live = new()
            {
                SchemaVersion = OwnerRecord.CurrentSchemaVersion,
                Pid = self.Id,
                ProcessFingerprint = ProcessFingerprint.Compute(self.Id, startTime),
                ProcessStartTicks = startTime.Ticks,
                Host = "127.0.0.1",
                Port = port,
                CreatedAt = DateTimeOffset.UtcNow,
                Version = 1,
            };
            Directory.CreateDirectory(Path.GetDirectoryName(pathProvider.OwnerRecordPath)!);
            await File.WriteAllTextAsync(pathProvider.OwnerRecordPath, JsonSerializer.Serialize(live, StateJson.Options));

            FakeSecretResolver resolver = new();
            resolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", "token");

            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: resolver,
                cancellationToken: CancellationToken.None);

            Assert.Equal(RouterHostBootstrap.ConfigErrorExitCode, exitCode);
            Assert.True(File.Exists(pathProvider.OwnerRecordPath));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
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
}
