using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Tests.Fakes;
using Router.Metering;
using Router.Secrets;
using Xunit;

namespace Router.Core.Tests.Host;

/// <summary>Shared host-test plumbing for enabled Router Mode sandboxes.</summary>
internal static class HostTestHarness
{
    public const string TestToken = "host-test-token";

    private const string ClientsJson = """
        "clients": [
          {"client_id":"client.local_test","adapter_id":"adapter.client.local_test.responses.v1","enabled":true,"auth_scope":"responses:invoke","capabilities":["text","streaming","responses"],"version":1},
          {"client_id":"client.local_status","adapter_id":"adapter.client.local_status.responses.v1","enabled":true,"auth_scope":"router:status","capabilities":["responses"],"version":1}
        ],
        """;

    public static async Task WriteEnabledRouterDefaultsAsync(TestPathProvider pathProvider, int port)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(pathProvider.DefaultsPath)!);
        string defaults = await File.ReadAllTextAsync(TestPaths.DefaultsPath);
        defaults = defaults
            .Replace("\"enabled\": false", "\"enabled\": true")
            .Replace("\"mode\": \"direct\"", "\"mode\": \"router\"")
            .Replace("\"port\": 47821", $"\"port\": {port}")
            .Replace("\"clients\": [],", ClientsJson);
        await File.WriteAllTextAsync(pathProvider.DefaultsPath, defaults);
    }

    public static FakeSecretResolver SecretResolver()
    {
        FakeSecretResolver resolver = new();
        resolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", TestToken);
        return resolver;
    }

    public static int GetFreePort()
    {
        TcpListener listener = new(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    public static async Task<bool> WaitUntilReadyAsync(HttpClient client, int port, Task<int>? hostTask = null)
    {
        using CancellationTokenSource timeout = new(TimeSpan.FromSeconds(10));
        while (!timeout.IsCancellationRequested)
        {
            if (hostTask?.IsCompleted == true) { await FailEarlyHostExitAsync(hostTask); }
            try
            {
                using HttpResponseMessage health = await client.GetAsync($"http://127.0.0.1:{port}/health", timeout.Token);
                if (health.StatusCode == HttpStatusCode.OK)
                {
                    return true;
                }
            }
            catch (Exception)
            {
                // Not listening yet.
            }

            await Task.Delay(TimeSpan.FromMilliseconds(100), timeout.Token).ConfigureAwait(false);
        }

        return false;
    }

    // FIX2: a refused/faulted Host is an actual startup failure, not a READY
    // polling timeout. Preserve the original deadline and all lifecycle checks.
    public static async Task WaitForStartupBarrierAsync(Task barrier, Task<int> hostTask, TimeSpan timeout)
    {
        await Task.WhenAny(barrier, hostTask).WaitAsync(timeout);
        if (!barrier.IsCompleted) { await FailEarlyHostExitAsync(hostTask); }
        await barrier;
    }

    private static async Task FailEarlyHostExitAsync(Task<int> hostTask)
    {
        int exitCode;
        try { exitCode = await hostTask; }
        catch (Exception error)
        {
            // Never print Exception.Message: it can contain private paths/data.
            Assert.Fail($"Host exited before startup barrier: exception={error.GetType().Name} hresult={error.HResult:x8}");
            return;
        }
        Assert.Fail($"Host exited before startup barrier: exit_code={exitCode}");
    }

    /// <summary>
    /// Waits until Router.Host persisted the READY runtime state. The listener
    /// accepts /health before this write completes, so tests that cancel the
    /// host must first pass this barrier or the cancellation token can race the
    /// state write and produce exit code 130 instead of a clean stop.
    /// </summary>
    public static async Task<bool> WaitUntilReadyStateAsync(
        TestPathProvider pathProvider,
        TimeSpan timeout)
    {
        using CancellationTokenSource deadline = new(timeout);
        while (!deadline.IsCancellationRequested)
        {
            if (File.Exists(pathProvider.RuntimeStatePath))
            {
                try
                {
                    string json = await File.ReadAllTextAsync(pathProvider.RuntimeStatePath, deadline.Token).ConfigureAwait(false);
                    using JsonDocument document = JsonDocument.Parse(json);
                    if (string.Equals(
                        document.RootElement.GetProperty("lifecycle").GetString(),
                        "READY",
                        StringComparison.Ordinal))
                    {
                        return true;
                    }
                }
                catch (Exception)
                {
                    // State file may still be mid-write; retry.
                }
            }

            await Task.Delay(TimeSpan.FromMilliseconds(25), deadline.Token).ConfigureAwait(false);
        }

        return false;
    }

    public static async Task<RequestMeteringRecord> WaitForMeteringRecordAsync(
        RequestMeteringService metering,
        TimeSpan timeout)
    {
        using CancellationTokenSource deadline = new(timeout);
        while (!deadline.IsCancellationRequested)
        {
            IReadOnlyList<RequestMeteringRecord> records = metering.Store.Recent(20);
            if (records.Count > 0)
            {
                return records[^1];
            }

            await Task.Delay(TimeSpan.FromMilliseconds(50), deadline.Token).ConfigureAwait(false);
        }

        Assert.Fail("No production metering record was written before timeout.");
        return null!;
    }

    public static async Task<bool> WaitForLogFileAsync(string logDirectory, TimeSpan timeout)
    {
        using CancellationTokenSource deadline = new(timeout);
        while (!deadline.IsCancellationRequested)
        {
            if (Directory.Exists(logDirectory)
                && Directory.EnumerateFiles(logDirectory, "request-*.json").Any())
            {
                return true;
            }

            await Task.Delay(TimeSpan.FromMilliseconds(50), deadline.Token).ConfigureAwait(false);
        }

        return false;
    }

    /// <summary>Repository root derived from the test output directory layout.</summary>
    public static string RepositoryRoot
        => Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", ".."));

    /// <summary>
    /// Builds the authoritative execution metadata shape used by fixture
    /// services in host tests. Identity values are explicit so the production
    /// projection path is exercised; no field is ever inferred from config.
    /// </summary>
    public static ResponsesExecutionMetadata ExecutionMetadata(
        string providerId,
        string routeId,
        string providerRouteId,
        string modelRouteId,
        string clientModelId,
        string catalogModelId,
        string? upstreamModelId = null,
        string clientId = "client.local_test")
        => new()
        {
            ConfigGeneration = "host-test-config-generation",
            ClientId = clientId,
            RouteId = routeId,
            ProviderId = providerId,
            ProviderRouteId = providerRouteId,
            ModelRouteId = modelRouteId,
            ClientModelId = clientModelId,
            CatalogModelId = catalogModelId,
            UpstreamModelId = upstreamModelId ?? catalogModelId,
            EndpointId = "endpoint." + modelRouteId.Replace("model_route.", string.Empty, StringComparison.Ordinal),
            ExecutionStartedAt = DateTimeOffset.UnixEpoch,
            CompletedAt = null,
        };
}
