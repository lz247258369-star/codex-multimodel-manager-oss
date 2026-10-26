using ProviderContractKit;
using Router.ClientAdapters.Responses;
using Router.Core.Context;
using Router.Core.Ids;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Router.Secrets;
using Router.UpstreamHttp;

namespace Router.ProviderAdapters.DeepSeek.Tests;

/// <summary>Deterministic invocation factory for direct DeepSeek adapter tests.</summary>
public static class DeepSeekInvocationFactory
{
    private static readonly UuidV7 FixedUuid = UuidV7.Parse("018f4a9b-0000-7000-8000-000000000000");

    public static RequestContext CreateContext()
        => RequestContext.Create(
            RequestId.Create(FixedUuid),
            TraceId.Create(FixedUuid),
            ContractRouteFactory.ClientId,
            DateTimeOffset.UtcNow,
            "responses:invoke",
            configGeneration: Router.Core.Support.SafeHasher.Sha256Hex("dsr1-deepseek"),
            cancellationToken: CancellationToken.None);

    public static ProviderAdapterInvocation CreateInvocation(
        FakeProviderServer server,
        CanonicalResponsesRequest request,
        string secretValue = "test_fake_key_do_not_use",
        bool stream = false)
    {
        Result<UpstreamEndpoint, Router.Core.Errors.RouterError> endpoint = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "/"),
            tlsRequired: false,
            loopbackTestOnly: true);

        return new ProviderAdapterInvocation
        {
            AttemptId = AttemptId.Create(FixedUuid),
            RequestId = RequestId.Create(FixedUuid),
            TraceId = TraceId.Create(FixedUuid),
            Route = new DeepSeekContractHarness().CreateRoute(),
            Endpoint = endpoint.Value!,
            Request = request,
            Secret = SecretHandle.FromValue(secretValue),
            Transport = new HttpUpstreamTransport(new LoopbackOnlyHandler()),
            Boundaries = TimeoutBoundaries.Create(
                connectTimeout: TimeSpan.FromSeconds(2),
                firstByteTimeout: TimeSpan.FromSeconds(5),
                idleTimeout: TimeSpan.FromSeconds(5),
                totalTimeout: TimeSpan.FromSeconds(30)),
            Checkpoint = RetryCheckpoint.NotStarted,
            AttemptNumber = 1,
        };
    }
}
