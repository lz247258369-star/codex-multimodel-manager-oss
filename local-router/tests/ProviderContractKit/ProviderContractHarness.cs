using Router.ClientAdapters.Responses;
using Router.ProviderAdapters.Abstractions;
using Router.Routing;
using Router.Secrets;
using Router.UpstreamHttp;
using Router.FakeProvider;

namespace ProviderContractKit;

/// <summary>
/// Adapter-specific wiring for the reusable Provider Contract Kit. Future
/// adapter PRs (LR-6/7/7A/7B) implement this harness and inherit
/// <see cref="ProviderContractSuite"/>; there is exactly one contract suite for
/// every provider adapter.
/// </summary>
public abstract class ProviderContractHarness
{
    public abstract IProviderAdapter CreateAdapter();

    public virtual IUpstreamTransport CreateTransport()
        => new HttpUpstreamTransport(new LoopbackOnlyHandler());

    public virtual SecretHandle CreateSecret()
        => SecretHandle.FromValue("test_fake_key_do_not_use");

    public virtual ResolvedRoute CreateRoute()
        => ContractRouteFactory.CreateFakeRoute();

    public virtual FakeProviderServer CreateServer()
        => new();

    public virtual UpstreamEndpoint CreateEndpoint(FakeProviderServer server)
    {
        Result<UpstreamEndpoint, Router.Core.Errors.RouterError> created = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "v1/responses"),
            tlsRequired: false,
            loopbackTestOnly: true);
        if (created.Error is not null)
        {
            throw new InvalidOperationException("Test endpoint must be valid.");
        }

        return created.Value!;
    }

    public virtual CanonicalResponsesRequest CreateRequest(bool stream = false)
        => ContractRouteFactory.CreateRequest(stream);

    public virtual TimeoutBoundaries CreateBoundaries()
        => TimeoutBoundaries.Create(
            connectTimeout: TimeSpan.FromSeconds(2),
            firstByteTimeout: TimeSpan.FromSeconds(5),
            idleTimeout: TimeSpan.FromSeconds(5),
            totalTimeout: TimeSpan.FromSeconds(30));
}
