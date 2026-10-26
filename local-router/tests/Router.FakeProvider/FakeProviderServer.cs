using System.Net;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace Router.FakeProvider;

/// <summary>
/// Loopback-only fake upstream HTTP server used exclusively by LR-5 tests. It
/// binds 127.0.0.1 on an ephemeral port and serves deterministic scenarios.
/// </summary>
public sealed class FakeProviderServer : IAsyncDisposable
{
    private readonly object _sync = new();
    private WebApplication? _app;
    private FakeProviderScenario _scenario = FakeProviderScenario.Json(200, "{}");
    private byte[]? _lastRequestBody;
    private string? _lastRequestPath;
    private Dictionary<string, string> _lastRequestHeaders = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Base URL of the running server, for example <c>http://127.0.0.1:PORT</c>.</summary>
    public Uri BaseUri { get; private set; } = new("http://127.0.0.1:0");

    public async Task StartAsync()
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.WebHost.ConfigureKestrel(options =>
        {
            options.Listen(IPAddress.Loopback, 0);
        });
        builder.Services.AddRouting();

        WebApplication app = builder.Build();
        app.MapPost("/v1/responses", HandleResponsesAsync);
        app.MapPost("/compatible-mode/v1/responses", HandleResponsesAsync);
        app.MapPost("/api/v1/responses", HandleResponsesAsync);
        // DSR1: the direct DeepSeek official Responses API is served at the
        // provider root (/responses) rather than under a gateway prefix.
        app.MapPost("/responses", HandleResponsesAsync);
        app.Map("/redirect-same", HandleRedirectSameAsync);
        app.Map("/redirect-cross", HandleRedirectCrossAsync);
        app.MapGet("/health", () => Results.Text("ok"));

        await app.StartAsync().ConfigureAwait(false);
        _app = app;
        BaseUri = new Uri(app.Urls.First().TrimEnd('/') + "/");
    }

    public void SetScenario(FakeProviderScenario scenario)
    {
        ArgumentNullException.ThrowIfNull(scenario);
        lock (_sync)
        {
            _scenario = scenario;
        }
    }

    /// <summary>Most recent request body received by the fake upstream (test assertion only).</summary>
    public byte[]? LastRequestBody
    {
        get
        {
            lock (_sync)
            {
                return _lastRequestBody;
            }
        }
    }

    /// <summary>Most recent request path received by the fake upstream (test assertion only).</summary>
    public string? LastRequestPath
    {
        get
        {
            lock (_sync)
            {
                return _lastRequestPath;
            }
        }
    }

    /// <summary>Most recent request headers received by the fake upstream (test assertion only).</summary>
    public IReadOnlyDictionary<string, string> LastRequestHeaders
    {
        get
        {
            lock (_sync)
            {
                return new Dictionary<string, string>(_lastRequestHeaders, StringComparer.OrdinalIgnoreCase);
            }
        }
    }

    private async Task HandleResponsesAsync(HttpContext context)
    {
        byte[]? requestBody = null;
        if (context.Request.ContentLength is > 0)
        {
            using var buffer = new MemoryStream();
            await context.Request.Body.CopyToAsync(buffer, context.RequestAborted).ConfigureAwait(false);
            requestBody = buffer.ToArray();
        }

        var requestHeaders = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (KeyValuePair<string, Microsoft.Extensions.Primitives.StringValues> header in context.Request.Headers)
        {
            requestHeaders[header.Key] = header.Value.ToString();
        }

        lock (_sync)
        {
            _lastRequestBody = requestBody;
            _lastRequestPath = context.Request.Path.Value;
            _lastRequestHeaders = requestHeaders;
        }

        FakeProviderScenario scenario;
        lock (_sync)
        {
            scenario = _scenario;
        }

        if (scenario.DelayBeforeFirstByte > TimeSpan.Zero)
        {
            await Task.Delay(scenario.DelayBeforeFirstByte, context.RequestAborted).ConfigureAwait(false);
        }

        if (scenario.AbortConnection)
        {
            context.Abort();
            return;
        }

        context.Response.StatusCode = scenario.StatusCode;
        foreach (KeyValuePair<string, string> header in scenario.ExtraHeaders)
        {
            context.Response.Headers[header.Key] = header.Value;
        }

        if (scenario.ContentType is not null)
        {
            context.Response.ContentType = scenario.ContentType;
        }

        await context.Response.StartAsync(context.RequestAborted).ConfigureAwait(false);

        if (scenario.Body is null || scenario.Body.Length == 0)
        {
            return;
        }

        int chunkSize = scenario.ChunkSize <= 0 ? int.MaxValue : scenario.ChunkSize;
        for (int offset = 0; offset < scenario.Body.Length; offset += chunkSize)
        {
            if (offset > 0 && scenario.DelayBetweenChunks > TimeSpan.Zero)
            {
                await Task.Delay(scenario.DelayBetweenChunks, context.RequestAborted).ConfigureAwait(false);
            }

            int count = Math.Min(chunkSize, scenario.Body.Length - offset);
            await context.Response.Body.WriteAsync(scenario.Body.AsMemory(offset, count), context.RequestAborted).ConfigureAwait(false);
            await context.Response.Body.FlushAsync(context.RequestAborted).ConfigureAwait(false);
        }
    }

    private static Task HandleRedirectSameAsync(HttpContext context)
    {
        context.Response.StatusCode = 302;
        context.Response.Headers.Location = new Uri(context.Request.Scheme + "://" + context.Request.Host + "/v1/responses").ToString();
        return Task.CompletedTask;
    }

    private static Task HandleRedirectCrossAsync(HttpContext context)
    {
        context.Response.StatusCode = 302;
        context.Response.Headers.Location = new Uri("https://provider.example.invalid/v1/responses").ToString();
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        if (_app is { } app)
        {
            await app.DisposeAsync().ConfigureAwait(false);
        }
    }
}
