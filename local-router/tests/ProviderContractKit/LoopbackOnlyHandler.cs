using System.Net;
using Router.ProviderAdapters.Abstractions;

namespace ProviderContractKit;

/// <summary>
/// Test network guard: any request whose target is not a loopback host fails
/// immediately. This guarantees LR-5 tests never touch a real provider.
/// </summary>
public sealed class LoopbackOnlyHandler : DelegatingHandler
{
    public LoopbackOnlyHandler()
        : base(new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            ConnectTimeout = TimeSpan.FromSeconds(2),
        })
    {
    }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.RequestUri is not { } uri
            || !UpstreamEndpoint.IsLoopbackHost(uri.Host))
        {
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadGateway)
            {
                ReasonPhrase = "network-guard: non-loopback target rejected",
            });
        }

        return base.SendAsync(request, cancellationToken);
    }
}
