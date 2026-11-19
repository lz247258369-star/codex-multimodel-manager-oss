using System.Text.Json;
using ProviderContractKit;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.MiMo;
using Router.Registries;
using Router.Routing;
using Xunit;

namespace Router.ProviderAdapters.MiMo.Tests;

public sealed class MiMoRequestMappingTests
{
    [Fact]
    public async Task Upstream_model_id_comes_only_from_the_resolved_route()
    {
        await using FakeProviderServer proServer = await StartServerAsync(MiMoFixtures.NonStreamJson());
        CanonicalResponsesRequest proRequest = ContractRouteFactory.CreateRequest(text: "hello");

        ProviderAdapterResult proResult = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(proServer, proRequest),
            CancellationToken.None);

        proResult.Validate();
        Assert.NotNull(proResult.Response);
        Assert.Equal("mimo-v2.5-pro", ReadSentModel(proServer));

        ResolvedRoute standardRoute = new MiMoContractHarness().CreateRoute() with
        {
            ModelRoute = new MiMoContractHarness().CreateRoute().ModelRoute with
            {
                ClientModelId = "mimo-v2.5",
                ModelId = "mimo-v2.5",
                UpstreamModelId = "mimo-v2.5",
            },
        };

        await using FakeProviderServer standardServer = await StartServerAsync(MiMoFixtures.NonStreamJson());
        CanonicalResponsesRequest standardRequest = ContractRouteFactory.CreateRequest(text: "hello");
        ProviderAdapterInvocation standardInvocation = MiMoInvocationFactory.CreateInvocation(standardServer, standardRequest) with
        {
            Route = standardRoute,
        };

        ProviderAdapterResult standardResult = await new MiMoProviderAdapter().InvokeAsync(
            standardInvocation,
            CancellationToken.None);

        standardResult.Validate();
        Assert.NotNull(standardResult.Response);
        Assert.Equal("mimo-v2.5", ReadSentModel(standardServer));
    }

    [Fact]
    public async Task Headers_are_explicit_allowlist_only()
    {
        await using FakeProviderServer server = await StartServerAsync(MiMoFixtures.NonStreamJson());
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest();

        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(server, request),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        IReadOnlyDictionary<string, string> headers = server.LastRequestHeaders;
        Assert.Equal("Bearer test_fake_key_do_not_use", headers["Authorization"]);
        Assert.Equal("application/json", headers["Content-Type"]);
        Assert.Equal("application/json", headers["Accept"]);
        Assert.False(headers.ContainsKey("Cookie"));
        Assert.False(headers.ContainsKey("Set-Cookie"));
        Assert.False(headers.ContainsKey("Proxy-Authorization"));
        Assert.False(headers.ContainsKey("x-api-key"));
        Assert.False(headers.ContainsKey("X-Client-Token"));
    }

    [Fact]
    public async Task Instructions_reasoning_and_tools_are_preserved_in_the_body()
    {
        await using FakeProviderServer server = await StartServerAsync(MiMoFixtures.NonStreamJson());
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest() with
        {
            Instructions = "be concise",
            Reasoning = new ReasoningRequest { Effort = ReasoningEffort.High },
            Tools =
            [
                new FunctionToolDefinition
                {
                    Name = "get_weather",
                    Description = "weather",
                    Parameters = JsonElement.Parse("""{"type":"object"}"""),
                },
            ],
        };

        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(server, request),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        byte[]? sentBody = server.LastRequestBody;
        Assert.NotNull(sentBody);
        string body = System.Text.Encoding.UTF8.GetString(sentBody!);
        Assert.Contains("be concise", body, StringComparison.Ordinal);
        Assert.Contains("reasoning", body, StringComparison.Ordinal);
        Assert.Contains("get_weather", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Stream_request_accepts_event_stream()
    {
        await using FakeProviderServer server = await StartServerAsync(MiMoFixtures.StandardStream(), stream: true);
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest(stream: true);

        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(server, request, stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        Assert.Equal("text/event-stream", server.LastRequestHeaders["Accept"]);
        await DrainAsync(result.EventStream!);
    }

    [Fact]
    public async Task Adapter_posts_only_to_the_v1_responses_path()
    {
        await using FakeProviderServer server = await StartServerAsync(MiMoFixtures.NonStreamJson());

        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.Equal("/v1/responses", server.LastRequestPath);
    }

    [Fact]
    public async Task Non_approved_endpoint_fails_closed_before_any_request()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, MiMoFixtures.NonStreamJson()));

        Result<UpstreamEndpoint, RouterError> wrongPath = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "v1/chat/completions"),
            tlsRequired: false,
            loopbackTestOnly: true);

        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()) with
            {
                Endpoint = wrongPath.Value!,
            },
            CancellationToken.None);

        result.Validate();
        Assert.Equal(RouterErrorCode.InvalidEndpointReference, result.Error!.Code);
        Assert.Null(server.LastRequestBody);
    }

    [Fact]
    public async Task Secret_rotation_uses_the_current_handle_each_attempt()
    {
        await using FakeProviderServer server = await StartServerAsync(MiMoFixtures.NonStreamJson());
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest();

        ProviderAdapterResult first = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(server, request, secretValue: "test_fake_key_do_not_use"),
            CancellationToken.None);
        first.Validate();
        Assert.Equal("Bearer test_fake_key_do_not_use", server.LastRequestHeaders["Authorization"]);

        ProviderAdapterResult second = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(server, request, secretValue: "rotated_fake_key_do_not_use"),
            CancellationToken.None);
        second.Validate();
        Assert.Equal("Bearer rotated_fake_key_do_not_use", server.LastRequestHeaders["Authorization"]);
    }

    [Fact]
    public async Task Stream_without_route_streaming_capability_fails_closed()
    {
        await using FakeProviderServer server = await StartServerAsync(MiMoFixtures.StandardStream(), stream: true);
        ResolvedRoute restricted = WithCapabilities("text");

        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true) with
            {
                Route = restricted,
            },
            CancellationToken.None);

        result.Validate();
        Assert.Equal(RouterErrorCode.UnsupportedCapability, result.Error!.Code);
        Assert.Null(server.LastRequestBody);
    }

    [Fact]
    public async Task Reasoning_without_route_reasoning_capability_fails_closed()
    {
        await using FakeProviderServer server = await StartServerAsync(MiMoFixtures.NonStreamJson());
        ResolvedRoute restricted = WithCapabilities("text");
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest() with
        {
            Reasoning = new ReasoningRequest { Effort = ReasoningEffort.High },
        };

        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(server, request) with
            {
                Route = restricted,
            },
            CancellationToken.None);

        result.Validate();
        Assert.Equal(RouterErrorCode.UnsupportedCapability, result.Error!.Code);
        Assert.Null(server.LastRequestBody);
    }

    [Fact]
    public async Task Tools_without_route_tools_capability_fails_closed()
    {
        await using FakeProviderServer server = await StartServerAsync(MiMoFixtures.NonStreamJson());
        ResolvedRoute restricted = WithCapabilities("text");
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest() with
        {
            Tools =
            [
                new FunctionToolDefinition
                {
                    Name = "get_weather",
                    Description = "weather",
                    Parameters = JsonElement.Parse("""{"type":"object"}"""),
                },
            ],
        };

        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(
            MiMoInvocationFactory.CreateInvocation(server, request) with
            {
                Route = restricted,
            },
            CancellationToken.None);

        result.Validate();
        Assert.Equal(RouterErrorCode.UnsupportedCapability, result.Error!.Code);
        Assert.Null(server.LastRequestBody);
    }

    private static string? ReadSentModel(FakeProviderServer server)
    {
        byte[]? sentBody = server.LastRequestBody;
        Assert.NotNull(sentBody);
        using JsonDocument document = JsonDocument.Parse(sentBody!);
        return document.RootElement.GetProperty("model").GetString();
    }

    private static async Task<FakeProviderServer> StartServerAsync(string body, bool stream = false)
    {
        var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(new FakeProviderScenario
        {
            StatusCode = 200,
            Body = System.Text.Encoding.UTF8.GetBytes(body),
            ContentType = stream ? "text/event-stream" : "application/json",
        });
        return server;
    }

    private static async Task DrainAsync(IAsyncEnumerable<CanonicalEvent> events)
    {
        await foreach (CanonicalEvent _ in events)
        {
        }
    }

    private static ResolvedRoute WithCapabilities(params string[] capabilities)
        => new MiMoContractHarness().CreateRoute() with
        {
            EffectiveCapabilities = CapabilitySet.From(capabilities),
        };
}
