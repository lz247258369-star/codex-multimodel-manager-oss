using ProviderContractKit;
using Router.Core.Context;
using Router.Core.Ids;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.OpenAI;
using Router.Secrets;
using Router.UpstreamHttp;
using Xunit;

namespace Router.ProviderAdapters.OpenAI.Tests;

public sealed class OpenAIPassiveOutcomeTests
{
    [Fact]
    public async Task Success_outcome_is_recorded_for_passive_health_input()
    {
        AttemptOutcome outcome = await RunOutcomeAsync(200, OpenAIFixtures.NonStreamJson());

        Assert.Equal(AttemptOutcome.Succeeded, outcome);
    }

    [Fact]
    public async Task Provider_5xx_outcome_is_recorded_for_passive_health_input()
    {
        AttemptOutcome outcome = await RunOutcomeAsync(503, "{}");

        Assert.Equal(AttemptOutcome.Failed, outcome);
    }

    [Fact]
    public async Task Rate_limited_outcome_is_recorded_for_passive_health_input()
    {
        AttemptOutcome outcome = await RunOutcomeAsync(429, "{}");

        Assert.Equal(AttemptOutcome.Failed, outcome);
    }

    private static async Task<AttemptOutcome> RunOutcomeAsync(int statusCode, string body)
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(statusCode, body));

        Result<UpstreamEndpoint, Router.Core.Errors.RouterError> endpoint = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "v1"),
            tlsRequired: false,
            loopbackTestOnly: true);

        RequestContext context = OpenAIInvocationFactory.CreateContext();
        using SecretHandle secret = SecretHandle.FromValue("test_fake_key_do_not_use");
        using var transport = new HttpUpstreamTransport(new LoopbackOnlyHandler());

        AttemptExecutionResult execution = await new ProviderAdapterHarness().ExecuteOnceAsync(
            new OpenAIProviderAdapter(),
            new OpenAIContractHarness().CreateRoute(),
            endpoint.Value!,
            ContractRouteFactory.CreateRequest(),
            secret,
            transport,
            TimeoutBoundaries.Default,
            context,
            attemptNumber: 1,
            CancellationToken.None);

        return execution.Record.Outcome;
    }
}
