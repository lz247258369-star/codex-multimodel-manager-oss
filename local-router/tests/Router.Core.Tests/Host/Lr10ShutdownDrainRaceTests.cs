using System.Net;
using System.Net.Http.Headers;
using System.Text;
using Router.ClientAdapters.Responses;
using Router.Core.Tests.Fakes;
using Router.Host;
using Router.Ingress.Fakes;
using Router.Metering;
using Xunit;
using CanonicalUsage = Router.ClientAdapters.Responses.UsageRecord;

namespace Router.Core.Tests.Host;

public sealed class Lr10ShutdownDrainRaceTests
{
    [Fact]
    public async Task Immediate_shutdown_after_response_completion_drains_the_last_metering_completion()
    {
        int port = HostTestHarness.GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        using CancellationTokenSource cts = new();
        Task<int>? runTask = null;
        try
        {
            TestPathProvider pathProvider = new(sandbox);
            await HostTestHarness.WriteEnabledRouterDefaultsAsync(pathProvider, port);

            FakeResponsesService service = PricedService();
            HostObservabilityProbe probe = new();
            runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                clock: new PinnedTestClock(HostTestHarness.CanonicalPricingNow),
                secretResolver: HostTestHarness.SecretResolver(),
                responsesService: service,
                observabilityProbe: probe,
                cancellationToken: cts.Token);

            using HttpClient client = new();
            Assert.True(await HostTestHarness.WaitUntilReadyAsync(client, port), "Router health did not become ready within the timeout.");
            Assert.True(
                await HostTestHarness.WaitUntilReadyStateAsync(pathProvider, TimeSpan.FromSeconds(5)),
                "Router did not persist the READY runtime state before the host was cancelled.");
            Assert.NotNull(probe.Metering);
            Assert.NotNull(probe.Metering!.Pricing);
            HostTestHarness.AssertPriceFreshAt(
                probe.Metering.Pricing!, "chatgpt", "gpt-5.6-terra", HostTestHarness.CanonicalPricingNow);

            using HttpRequestMessage request = new(HttpMethod.Post, $"http://127.0.0.1:{port}/v1/responses")
            {
                Content = new StringContent("""{"model":"gpt-5.6-terra","input":"hi"}""", Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", HostTestHarness.TestToken);

            using HttpResponseMessage response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            string body = await response.Content.ReadAsStringAsync();
            Assert.Contains("\"status\":\"completed\"", body, StringComparison.Ordinal);

            // Cancel immediately: no WaitForMeteringRecord is performed before
            // shutdown. The bounded drain must carry the last completion.
            cts.Cancel();
            int exitCode = await runTask.WaitAsync(TimeSpan.FromSeconds(15));
            Assert.Equal(0, exitCode);

            Assert.True(probe.Observer!.DrainCompleted, "Bounded completion queue must drain before host exit.");
            Assert.Equal(0, probe.Observer.DroppedJobCount);
            Assert.Null(probe.Observer.LastDegradationCode);
            IReadOnlyList<RequestMeteringRecord> records = probe.Metering!.Store.Recent(20);
            RequestMeteringRecord record = Assert.Single(records);
            Assert.Equal(RequestMeteringStatus.Recorded, record.Status);
            Assert.NotNull(record.CostEstimate);
            Assert.Equal(CostEstimateStatus.Complete, record.CostEstimate!.Status);

            string logDirectory = Path.Combine(Path.GetDirectoryName(pathProvider.RuntimeStatePath)!, "logs");
            Assert.True(
                await HostTestHarness.WaitForLogFileAsync(logDirectory, TimeSpan.FromSeconds(2)),
                "Redacted request log was not drained before host exit.");
        }
        finally
        {
            await HostTestHarness.StopHostAsync(cts, runTask);
            Directory.Delete(sandbox, recursive: true);
        }
    }

    private static FakeResponsesService PricedService()
    {
        FakeResponsesService service = new();
        service.UseHandler((request, _, _) => Task.FromResult(ResponsesServiceResult.NonStream(
            new CanonicalResponsesResponse
            {
                Id = "resp_shutdown_drain",
                ObjectType = "response",
                CreatedAt = HostTestHarness.CanonicalPricingNow.ToUnixTimeSeconds(),
                Status = "completed",
                Model = request.Model,
                Usage = new CanonicalUsage
                {
                    InputTokens = 100,
                    OutputTokens = 25,
                    TotalTokens = 125,
                },
            },
            HostTestHarness.ExecutionMetadata(
                "chatgpt",
                "route.chatgpt-terra",
                "provider-route.chatgpt-terra",
                "model_route.chatgpt-terra",
                request.Model,
                "gpt-5.6-terra"))));
        return service;
    }
}
