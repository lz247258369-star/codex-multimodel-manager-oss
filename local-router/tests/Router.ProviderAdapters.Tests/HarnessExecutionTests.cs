using ProviderContractKit;
using Router.Core.Context;
using Router.Core.Errors;
using Router.Core.Ids;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.Responses;
using Router.Secrets;
using Router.UpstreamHttp;
using Xunit;

namespace Router.ProviderAdapters.Tests;

public sealed class HarnessExecutionTests
{
    private static readonly UuidV7 FixedUuid = UuidV7.Parse("018f4a9b-0000-7000-8000-000000000000");

    [Fact]
    public async Task Successful_attempt_produces_result_and_safe_record()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson()));

        (AttemptExecutionResult execution, RequestContext context) = await ExecuteAsync(server);

        execution.Result.Validate();
        Assert.NotNull(execution.Result.Response);
        Assert.Equal(AttemptOutcome.Succeeded, execution.Record.Outcome);
        Assert.Equal(context.RequestId.Value, execution.Record.RequestId);
        Assert.Equal(ContractRouteFactory.RouteId, execution.Record.RouteId);
        Assert.Equal(FakeResponsesProviderAdapter.AdapterId, execution.Record.AdapterId);
        Assert.Equal("endpoint.fake", execution.Record.EndpointId);
        Assert.Null(execution.Record.NormalizedError);
    }

    [Fact]
    public async Task Failed_attempt_normalizes_error_in_record()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(503, "{}"));

        (AttemptExecutionResult execution, _) = await ExecuteAsync(server);

        execution.Result.Validate();
        Assert.Equal(AttemptOutcome.Failed, execution.Record.Outcome);
        Assert.Equal(RouterErrorCode.Provider5xx, execution.Record.NormalizedError!.Code);
        Assert.Equal(RouterErrorCode.Provider5xx, execution.Result.Error!.Code);
    }

    [Fact]
    public async Task Cancellation_marks_attempt_cancelled_and_never_creates_extra_attempts()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(new FakeProviderScenario
        {
            StatusCode = 200,
            ContentType = "application/json",
            Body = "{}"u8.ToArray(),
            DelayBeforeFirstByte = TimeSpan.FromSeconds(5),
        });

        using var cts = new CancellationTokenSource();
        Task<(AttemptExecutionResult, RequestContext)> pending = ExecuteAsync(server, cancellationToken: cts.Token);
        await Task.Delay(100);
        cts.Cancel();

        (AttemptExecutionResult execution, _) = await pending;
        execution.Result.Validate();
        Assert.Equal(AttemptOutcome.Cancelled, execution.Record.Outcome);
        Assert.Equal(RouterErrorCode.Cancelled, execution.Record.NormalizedError!.Code);
        Assert.Equal(1, execution.Record.AttemptNumber);
    }

    [Fact]
    public async Task Harness_never_switches_route_between_attempts()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson()));

        (AttemptExecutionResult first, _) = await ExecuteAsync(server, attemptNumber: 1);
        (AttemptExecutionResult second, _) = await ExecuteAsync(server, attemptNumber: 2);

        Assert.Equal(first.Record.RouteId, second.Record.RouteId);
        Assert.Equal(first.Record.EndpointId, second.Record.EndpointId);
        Assert.Equal(1, first.Record.AttemptNumber);
        Assert.Equal(2, second.Record.AttemptNumber);
    }

    private static async Task<(AttemptExecutionResult Execution, RequestContext Context)> ExecuteAsync(
        FakeProviderServer server,
        int attemptNumber = 1,
        CancellationToken cancellationToken = default)
    {
        var harness = new ProviderAdapterHarness();
        RequestContext context = RequestContext.Create(
            RequestId.Create(FixedUuid),
            TraceId.Create(FixedUuid),
            ContractRouteFactory.ClientId,
            DateTimeOffset.UtcNow,
            "responses:invoke",
            configGeneration: Router.Core.Support.SafeHasher.Sha256Hex("lr5-harness"),
            cancellationToken: cancellationToken);

        Result<UpstreamEndpoint, Router.Core.Errors.RouterError> endpoint = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "v1/responses"),
            tlsRequired: false,
            loopbackTestOnly: true);

        using var transport = new HttpUpstreamTransport();
        using SecretHandle secret = SecretHandle.FromValue("test_fake_key_do_not_use");

        AttemptExecutionResult execution = await harness.ExecuteOnceAsync(
            new FakeResponsesProviderAdapter(),
            ContractRouteFactory.CreateFakeRoute(),
            endpoint.Value!,
            ContractRouteFactory.CreateRequest(),
            secret,
            transport,
            TimeoutBoundaries.Create(
                connectTimeout: TimeSpan.FromSeconds(1),
                firstByteTimeout: TimeSpan.FromSeconds(2),
                idleTimeout: TimeSpan.FromSeconds(3),
                totalTimeout: TimeSpan.FromSeconds(10)),
            context,
            attemptNumber,
            cancellationToken);

        return (execution, context);
    }
}
