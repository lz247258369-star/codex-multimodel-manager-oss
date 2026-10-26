using Router.Configuration;
using Router.Ingress.Fakes;

namespace Router.Ingress.Tests.Support;

/// <summary>Mutable options for building a test ingress server.</summary>
public sealed class IngressTestServerOptions
{
    public string Token { get; set; } = IngressTestServer.TestToken;

    public LimitsConfig Limits { get; set; } = new()
    {
        MaxRequestBytes = 16_777_216,
        MaxHeaderBytes = 32_768,
        MaxConnections = 32,
        ShutdownGraceMs = 15_000,
    };

    public IReadOnlyList<ClientConfig> Clients { get; set; } = IngressTestServer.DefaultClients;

    public IReadOnlyList<string> AllowedOrigins { get; set; } = [];

    public TimeSpan? RequestTimeout { get; set; }

    public FakeResponsesService Service { get; set; } = new();

    public IngressRequestObserver? Observer { get; set; }

    public ControlPlaneRuntimeServices? ControlPlane { get; set; }

    public string ConfigGeneration { get; set; } = new string('a', 64);

    /// <summary>
    /// When true the listener binds but READY is not published until the test
    /// calls <see cref="IngressTestServer.PublishReady"/> - the production Host
    /// shape, where readiness follows the durable owner/state commit.
    /// </summary>
    public bool DeferReadyPublication { get; set; }
}
