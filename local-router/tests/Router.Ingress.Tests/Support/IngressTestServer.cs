using System.Net.Http.Headers;
using Router.Configuration;
using Router.Core.Abstractions;
using Router.Core.Ids;
using Router.Ingress.Fakes;
using Router.Secrets;
using Xunit;

namespace Router.Ingress.Tests.Support;

/// <summary>
/// Starts a real loopback ingress (127.0.0.1, ephemeral port) with a fake
/// secret resolver and the synthetic response service. Never touches a real
/// provider, key, auth.json, or .env.
/// </summary>
public sealed class IngressTestServer : IAsyncDisposable
{
    public const string TestToken = "lr3-test-token-0001";

    private readonly ResponsesIngress _ingress;
    private readonly HttpClient _client;

    private IngressTestServer(ResponsesIngress ingress, HttpClient client, CollectingObserver observer, FakeSecretResolver secretResolver)
    {
        _ingress = ingress;
        _client = client;
        Observer = observer;
        SecretResolver = secretResolver;
    }

    public static IReadOnlyList<ClientConfig> DefaultClients { get; } =
    [
        new ClientConfig
        {
            ClientId = "client.local_test",
            AdapterId = "adapter.client.local_test.responses.v1",
            Enabled = true,
            AuthScope = "responses:invoke",
            Version = 1,
        },
        new ClientConfig
        {
            ClientId = "client.local_status",
            AdapterId = "adapter.client.local_status.responses.v1",
            Enabled = true,
            AuthScope = "router:status",
            Version = 1,
        },
    ];

    public CollectingObserver Observer { get; }

    public FakeSecretResolver SecretResolver { get; }

    public ResponsesIngress Ingress => _ingress;

    public Uri BaseUri => _ingress.ListenAddress!;

    public HttpClient Client => _client;

    /// <summary>Creates a client without any default Authorization header.</summary>
    public HttpClient CreateAnonymousClient() => new() { BaseAddress = _ingress.ListenAddress };

    public static async Task<IngressTestServer> StartAsync(Action<IngressTestServerOptions>? configure = null)
    {
        IngressTestServerOptions options = new();
        configure?.Invoke(options);

        FakeSecretResolver secretResolver = new();
        secretResolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", options.Token);

        CollectingObserver observer = options.Observer as CollectingObserver ?? new CollectingObserver();
        IngressRequestObserver effectiveObserver = options.Observer ?? observer;
        SystemClock clock = new();
        UuidV7IdGenerator idGenerator = new(clock);

        IngressRuntimeOptions ingressOptions = new()
        {
            Host = "127.0.0.1",
            Port = 0,
            Limits = options.Limits,
            ConfigGeneration = options.ConfigGeneration,
            TokenReferenceName = "CODEX_LOCAL_ROUTER_TOKEN",
            Clients = options.Clients,
            AllowedOrigins = options.AllowedOrigins,
            RequestTimeout = options.RequestTimeout,
        };

        IngressStartResult result = await ResponsesIngress.StartAsync(
            ingressOptions,
            options.Service,
            secretResolver,
            clock,
            idGenerator,
            effectiveObserver,
            options.ControlPlane,
            deferReadyPublication: options.DeferReadyPublication).ConfigureAwait(false);

        Assert.True(result.IsSuccess, $"Ingress failed to start: {result.Error?.Code}");
        Assert.NotNull(result.Ingress!.ListenAddress);
        Assert.StartsWith("http://127.0.0.1:", result.Ingress.ListenAddress!.ToString(), StringComparison.Ordinal);

        HttpClient client = new() { BaseAddress = result.Ingress.ListenAddress };
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", options.Token);
        return new IngressTestServer(result.Ingress, client, observer, secretResolver);
    }

    /// <summary>
    /// Host-ready publication for a deferred ingress: only STARTING -> READY is
    /// attempted, and the caller learns whether it actually happened.
    /// </summary>
    public bool PublishReady() => _ingress.TryPublishReady();

    [System.Diagnostics.CodeAnalysis.SuppressMessage("Performance", "CA1822:Mark members as static", Justification = "Instance helper keeps test call sites uniform.")]
    public HttpRequestMessage CreateRequest(HttpMethod method, string pathAndQuery, string? jsonBody = null)
    {
        HttpRequestMessage request = new(method, pathAndQuery);
        if (jsonBody is not null)
        {
            request.Content = new StringContent(jsonBody, System.Text.Encoding.UTF8, "application/json");
        }

        return request;
    }

    public Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken = default)
        => _client.SendAsync(request, cancellationToken);

    public Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, HttpCompletionOption completionOption, CancellationToken cancellationToken = default)
        => _client.SendAsync(request, completionOption, cancellationToken);

    [System.Diagnostics.CodeAnalysis.SuppressMessage("Performance", "CA1822:Mark members as static", Justification = "Instance helper keeps test call sites uniform.")]
    public async Task<string> GetBodyAsync(HttpResponseMessage response)
        => await response.Content.ReadAsStringAsync().ConfigureAwait(false);

    public async ValueTask DisposeAsync()
    {
        await _ingress.DisposeAsync().ConfigureAwait(false);
        _client.Dispose();
    }
}
