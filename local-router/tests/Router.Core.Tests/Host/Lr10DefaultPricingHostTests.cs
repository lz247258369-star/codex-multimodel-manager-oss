using System.Net;
using System.Net.Http.Headers;
using System.Runtime.ExceptionServices;
using System.Text;
using Router.ClientAdapters.Responses;
using Router.Core.Tests.Fakes;
using Router.Host;
using Router.Ingress.Fakes;
using Router.Metering;
using Xunit;
using CanonicalUsage = Router.ClientAdapters.Responses.UsageRecord;

namespace Router.Core.Tests.Host;

public sealed class Lr10DefaultPricingHostTests
{
    [Fact]
    public async Task Default_host_loads_canonical_pricing_and_produces_complete_cost_estimate()
    {
        int port = HostTestHarness.GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        using CancellationTokenSource cts = new();
        Task<int>? runTask = null;
        ExceptionDispatchInfo? failure = null;
        try
        {
            TestPathProvider pathProvider = new(sandbox);
            await HostTestHarness.WriteEnabledRouterDefaultsAsync(pathProvider, port);

            FakeResponsesService service = CanonicalPricedService(
                usage: new CanonicalUsage
                {
                    InputTokens = 100,
                    OutputTokens = 25,
                    TotalTokens = 125,
                });
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
            Assert.NotNull(probe.Observer);
            Assert.NotNull(probe.Metering!.Pricing);
            HostTestHarness.AssertPriceFreshAt(
                probe.Metering.Pricing!, "chatgpt", "gpt-5.6-terra", HostTestHarness.CanonicalPricingNow);

            using HttpResponseMessage response = await PostAsync(client, port, "gpt-5.6-terra");
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);

            RequestMeteringRecord record = await HostTestHarness.WaitForMeteringRecordAsync(probe.Metering, TimeSpan.FromSeconds(5));
            Assert.Equal(RequestMeteringStatus.Recorded, record.Status);
            Assert.Equal(100, record.Usage!.InputTokens);
            Assert.Equal(25, record.Usage.OutputTokens);
            Assert.Equal(125, record.Usage.TotalTokens);
            Assert.Equal("chatgpt", record.ProviderId);
            Assert.Equal("gpt-5.6-terra", record.ModelId);
            Assert.NotNull(record.CostEstimate);
            Assert.Equal(0.0002m, record.CostEstimate!.InputCost);
            Assert.Equal(0.0003m, record.CostEstimate.OutputCost);
            Assert.Equal(0.0005m, record.CostEstimate.TotalCost);
            Assert.Equal(CostEstimateStatus.Complete, record.CostEstimate.Status);

            // The output catalog must be the canonical linked content, never a
            // test-authored temporary copy.
            string outputCatalog = Path.Combine(AppContext.BaseDirectory, "model-catalog.json");
            string canonicalCatalog = Path.Combine(HostTestHarness.RepositoryRoot, "installer", "model-catalog.json");
            Assert.True(File.Exists(outputCatalog), "model-catalog.json was not copied into the host output.");
            byte[] outputBytes = await File.ReadAllBytesAsync(outputCatalog);
            byte[] canonicalBytes = await File.ReadAllBytesAsync(canonicalCatalog);
            Assert.True(
                outputBytes.SequenceEqual(canonicalBytes),
                "model-catalog.json in the test output must be byte-identical to the canonical installer/model-catalog.json.");

            cts.Cancel();
            int exitCode = await runTask.WaitAsync(TimeSpan.FromSeconds(15));
            Assert.Equal(0, exitCode);
            Assert.True(probe.Observer!.DrainCompleted, "Bounded completion queue must drain before host exit.");
            Assert.Single(probe.Metering.Store.Recent(20));
        }
        catch (Exception error)
        {
            // Captured, never swallowed: FinishHostTestAsync rethrows it as the
            // first reported failure after the Host is stopped.
            failure = ExceptionDispatchInfo.Capture(error);
        }

        await HostTestCleanup.FinishHostTestAsync(failure, cts, runTask, sandbox);
    }

    [Fact]
    public async Task Default_host_without_execution_identity_never_guesses_identity()
    {
        int port = HostTestHarness.GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        using CancellationTokenSource cts = new();
        Task<int>? runTask = null;
        ExceptionDispatchInfo? failure = null;
        try
        {
            TestPathProvider pathProvider = new(sandbox);
            await HostTestHarness.WriteEnabledRouterDefaultsAsync(pathProvider, port);

            HostObservabilityProbe probe = new();
            runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: HostTestHarness.SecretResolver(),
                responsesService: ServiceWithoutExecutionIdentity(),
                observabilityProbe: probe,
                cancellationToken: cts.Token);

            using HttpClient client = new();
            Assert.True(await HostTestHarness.WaitUntilReadyAsync(client, port), "Router health did not become ready within the timeout.");
            Assert.True(
                await HostTestHarness.WaitUntilReadyStateAsync(pathProvider, TimeSpan.FromSeconds(5)),
                "Router did not persist the READY runtime state before the host was cancelled.");
            Assert.NotNull(probe.Metering);

            using HttpResponseMessage response = await PostAsync(client, port, "gpt-5.6-terra");
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);

            RequestMeteringRecord record = await HostTestHarness.WaitForMeteringRecordAsync(probe.Metering!, TimeSpan.FromSeconds(5));
            Assert.Equal(RequestMeteringStatus.IdentityUnavailable, record.Status);
            Assert.Null(record.ProviderId);
            Assert.Null(record.RouteId);
            Assert.Null(record.ModelRouteId);
            Assert.Null(record.ModelId);
            Assert.Null(record.UpstreamModelId);
            Assert.Null(record.Usage);
            Assert.Null(record.CostEstimate);

            cts.Cancel();
            int exitCode = await runTask.WaitAsync(TimeSpan.FromSeconds(15));
            Assert.Equal(0, exitCode);
        }
        catch (Exception error)
        {
            // Captured, never swallowed: FinishHostTestAsync rethrows it as the
            // first reported failure after the Host is stopped.
            failure = ExceptionDispatchInfo.Capture(error);
        }

        await HostTestCleanup.FinishHostTestAsync(failure, cts, runTask, sandbox);
    }

    private static FakeResponsesService CanonicalPricedService(CanonicalUsage usage)
    {
        FakeResponsesService service = new();
        service.UseHandler((request, _, _) => Task.FromResult(ResponsesServiceResult.NonStream(
            new CanonicalResponsesResponse
            {
                Id = "resp_canonical_pricing",
                ObjectType = "response",
                CreatedAt = HostTestHarness.CanonicalPricingNow.ToUnixTimeSeconds(),
                Status = "completed",
                Model = request.Model,
                Usage = usage,
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

    private static FakeResponsesService ServiceWithoutExecutionIdentity()
    {
        FakeResponsesService service = new();
        service.UseHandler((request, _, _) => Task.FromResult(ResponsesServiceResult.NonStream(
            new CanonicalResponsesResponse
            {
                Id = "resp_no_execution_identity",
                ObjectType = "response",
                CreatedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                Status = "completed",
                Model = request.Model,
                Usage = new CanonicalUsage
                {
                    InputTokens = 100,
                    OutputTokens = 25,
                    TotalTokens = 125,
                },
            })));
        return service;
    }

    private static async Task<HttpResponseMessage> PostAsync(HttpClient client, int port, string model)
    {
        using HttpRequestMessage request = new(HttpMethod.Post, $"http://127.0.0.1:{port}/v1/responses")
        {
            Content = new StringContent($$"""{"model":"{{model}}","input":"hi"}""", Encoding.UTF8, "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", HostTestHarness.TestToken);
        return await client.SendAsync(request);
    }
}
