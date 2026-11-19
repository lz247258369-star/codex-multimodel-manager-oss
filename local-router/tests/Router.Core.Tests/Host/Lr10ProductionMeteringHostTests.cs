using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using Router.CatalogProjection;
using Router.ClientAdapters.Responses;
using Router.Core.Tests.Fakes;
using Router.Host;
using Router.Ingress;
using Router.Ingress.Fakes;
using Router.Metering;
using Router.Secrets;
using Xunit;
using CanonicalUsage = Router.ClientAdapters.Responses.UsageRecord;

namespace Router.Core.Tests.Host;

public sealed class Lr10ProductionMeteringHostTests
{
    private const string ClientsJson = """
        "clients": [
          {"client_id":"client.local_test","adapter_id":"adapter.client.local_test.responses.v1","enabled":true,"auth_scope":"responses:invoke","capabilities":["text","streaming","responses"],"version":1},
          {"client_id":"client.local_status","adapter_id":"adapter.client.local_status.responses.v1","enabled":true,"auth_scope":"router:status","capabilities":["responses"],"version":1}
        ],
        """;

    // The metering fixture prices are dated 2026-08-01 and production treats a
    // price as stale 90 days later. The Host runs on a test clock pinned inside
    // that window instead of the wall clock, so the expected Complete estimate
    // does not change with the calendar. The production rule is unchanged.
    private static readonly DateTimeOffset PinnedNow = new(2026, 8, 15, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public async Task Enabled_host_wires_production_metering_and_redacted_log()
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

            PricingSnapshot pricing = LoadPricingSnapshot();
            RequestMeteringService metering = new(pricing: pricing);

            FakeResponsesService service = ServiceWithUsageAndExecution(
                "mm_openrouter",
                "route.lr10r",
                "model_route.lr10r",
                "z-ai/glm-5.3",
                usage: new CanonicalUsage
                {
                    InputTokens = 7,
                    OutputTokens = 5,
                    TotalTokens = 12,
                });

            using CancellationTokenSource cts = new();
            Task<int> runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: resolver,
                responsesService: service,
                clock: new PinnedTestClock(PinnedNow),
                meteringService: metering,
                pricingSnapshot: pricing,
                cancellationToken: cts.Token);

            using HttpClient client = new();
            Assert.True(await WaitUntilReadyAsync(client, port), "Router health did not become ready within the timeout.");
            Assert.True(
                await HostTestHarness.WaitUntilReadyStateAsync(pathProvider, TimeSpan.FromSeconds(5)),
                "Router did not persist the READY runtime state before the host was cancelled.");

            using HttpRequestMessage request = new(HttpMethod.Post, $"http://127.0.0.1:{port}/v1/responses")
            {
                Content = new StringContent("""{"model":"glm-test","input":"hi"}""", Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "host-test-token");
            using HttpResponseMessage response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);

            RequestMeteringRecord record = await WaitForMeteringRecordAsync(metering, TimeSpan.FromSeconds(5));
            Assert.Equal(7, record.Usage!.InputTokens);
            Assert.Equal(5, record.Usage.OutputTokens);
            Assert.Equal(12, record.Usage.TotalTokens);
            Assert.Equal(RequestMeteringStatus.Recorded, record.Status);
            Assert.NotNull(record.CostEstimate);
            Assert.Equal(0.000035m, record.CostEstimate!.InputCost);
            Assert.Equal(0.00015m, record.CostEstimate.OutputCost);
            Assert.Equal(0.000185m, record.CostEstimate.TotalCost);
            Assert.Equal(CostEstimateStatus.Complete, record.CostEstimate.Status);

            string logDirectory = Path.Combine(Path.GetDirectoryName(pathProvider.RuntimeStatePath)!, "logs");
            Assert.True(await WaitForLogFileAsync(logDirectory, TimeSpan.FromSeconds(5)), "Redacted request log was not written.");

            cts.Cancel();
            int exitCode = await runTask.WaitAsync(TimeSpan.FromSeconds(15));
            Assert.Equal(0, exitCode);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    private static FakeResponsesService ServiceWithUsageAndExecution(
        string providerId,
        string routeId,
        string modelRouteId,
        string catalogModelId,
        CanonicalUsage usage)
    {
        FakeResponsesService service = new();
        service.UseHandler((request, _, _) => Task.FromResult(ResponsesServiceResult.NonStream(
            new CanonicalResponsesResponse
            {
                Id = "resp_lr10r_" + request.Model,
                ObjectType = "response",
                CreatedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                Status = "completed",
                Model = request.Model,
                Usage = usage,
            },
            HostTestHarness.ExecutionMetadata(
                providerId,
                routeId,
                "provider-route.lr10r",
                modelRouteId,
                request.Model,
                catalogModelId))));
        return service;
    }

    private static PricingSnapshot LoadPricingSnapshot()
    {
        string fixture = Path.Combine(
            AppContext.BaseDirectory,
            "fixtures",
            "local-router",
            "v1",
            "metering",
            "catalog.v3.metering.json");
        byte[] bytes = File.ReadAllBytes(fixture);
        CatalogProjectionResult projection = ModelCatalogProjector.Project(bytes, "catalog.v3.metering.json", "test-sha");
        projection.Validate();
        PricingProjectionResult pricing = PricingProjector.Project(projection.Projection!, PinnedNow);
        Assert.True(pricing.IsSuccess);
        return pricing.Snapshot!;
    }

    /// <summary>
    /// Starts at a pinned instant and then advances with real elapsed time, so
    /// Host timing behaves normally while dates stay deterministic.
    /// </summary>
    private sealed class PinnedTestClock : Router.Core.Abstractions.IClock
    {
        private readonly DateTimeOffset _start;
        private readonly System.Diagnostics.Stopwatch _elapsed = System.Diagnostics.Stopwatch.StartNew();

        public PinnedTestClock(DateTimeOffset start)
        {
            _start = start;
        }

        public DateTimeOffset UtcNow => _start + _elapsed.Elapsed;
    }

    private static int GetFreePort()
    {
        TcpListener listener = new(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static async Task<bool> WaitUntilReadyAsync(HttpClient client, int port)
    {
        using CancellationTokenSource timeout = new(TimeSpan.FromSeconds(10));
        while (!timeout.IsCancellationRequested)
        {
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

    private static async Task<RequestMeteringRecord> WaitForMeteringRecordAsync(
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

    private static async Task<bool> WaitForLogFileAsync(string logDirectory, TimeSpan timeout)
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
}
