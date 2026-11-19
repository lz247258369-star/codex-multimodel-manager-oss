using System.Text.Json;
using ProviderContractKit;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Router.Registries;
using Router.Routing;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

public sealed class DeepSeekRequestMappingTests
{
    [Fact]
    public async Task Upstream_model_id_comes_only_from_the_resolved_route()
    {
        await using FakeProviderServer proServer = await StartServerAsync(DeepSeekFixtures.NonStreamJson());
        ProviderAdapterResult proResult = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(proServer, ContractRouteFactory.CreateRequest(text: "hello")),
            CancellationToken.None);

        proResult.Validate();
        Assert.NotNull(proResult.Response);
        Assert.Equal("deepseek-v4-pro", ReadSentModel(proServer));

        await using FakeProviderServer flashServer = await StartServerAsync(DeepSeekFixtures.NonStreamJson());
        ProviderAdapterResult flashResult = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(flashServer, ContractRouteFactory.CreateRequest(text: "hello")) with
            {
                Route = WithUpstreamModel(DeepSeekContractHarness.UpstreamFlashModel),
            },
            CancellationToken.None);

        flashResult.Validate();
        Assert.NotNull(flashResult.Response);
        Assert.Equal("deepseek-flash", ReadSentModel(flashServer));
    }

    [Fact]
    public async Task Adapter_posts_only_to_the_official_responses_path()
    {
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.NonStreamJson());

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.Equal("/responses", server.LastRequestPath);
    }

    [Fact]
    public async Task Headers_are_explicit_allowlist_only()
    {
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.NonStreamJson());

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        IReadOnlyDictionary<string, string> headers = server.LastRequestHeaders;
        Assert.Equal("Bearer test_fake_key_do_not_use", headers["Authorization"]);
        Assert.Equal("application/json", headers["Content-Type"]);
        Assert.Equal("application/json", headers["Accept"]);
        Assert.False(headers.ContainsKey("Cookie"));
        Assert.False(headers.ContainsKey("Proxy-Authorization"));
        Assert.False(headers.ContainsKey("x-api-key"));
        Assert.False(headers.ContainsKey("X-Client-Token"));
    }

    [Fact]
    public async Task Instructions_reasoning_tools_and_tool_choice_are_preserved_in_the_body()
    {
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.NonStreamJson());
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
            ToolChoice = new ToolChoice { Kind = ToolChoiceKind.Auto },
        };

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, request),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        byte[]? sentBody = server.LastRequestBody;
        Assert.NotNull(sentBody);
        string body = System.Text.Encoding.UTF8.GetString(sentBody!);
        Assert.Contains("be concise", body, StringComparison.Ordinal);
        Assert.Contains("reasoning", body, StringComparison.Ordinal);
        Assert.Contains("get_weather", body, StringComparison.Ordinal);
        Assert.Contains("tool_choice", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Stream_request_accepts_event_stream()
    {
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.StandardStream(), stream: true);

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        Assert.Equal("text/event-stream", server.LastRequestHeaders["Accept"]);
        await DrainAsync(result.EventStream!);
    }

    [Theory]
    [InlineData("deepseek-v4-pro")]
    [InlineData("deepseek-flash")]
    public async Task Max_output_tokens_is_passed_through_unchanged(string upstreamModelId)
    {
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.NonStreamJson());
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest() with
        {
            MaxOutputTokens = 16,
        };

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, request) with
            {
                Route = WithUpstreamModel(upstreamModelId),
            },
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        byte[]? sentBody = server.LastRequestBody;
        Assert.NotNull(sentBody);
        string body = System.Text.Encoding.UTF8.GetString(sentBody!);
        Assert.Contains("\"max_output_tokens\":16", body, StringComparison.Ordinal);
        Assert.Equal(upstreamModelId, ReadSentModel(server));
    }

    [Theory]
    [InlineData("deepseek-v4-pro")]
    [InlineData("deepseek-flash")]
    public async Task Reasoning_effort_max_is_passed_through_unchanged(string upstreamModelId)
    {
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.NonStreamJson());
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest() with
        {
            Reasoning = new ReasoningRequest { Effort = ReasoningEffort.Max },
        };

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, request) with
            {
                Route = WithUpstreamModel(upstreamModelId),
            },
            CancellationToken.None);

        result.Validate();
        byte[]? sentBody = server.LastRequestBody;
        Assert.NotNull(sentBody);
        string body = System.Text.Encoding.UTF8.GetString(sentBody!);
        Assert.Contains("\"effort\":\"max\"", body, StringComparison.Ordinal);
        Assert.DoesNotContain("\"effort\":\"high\"", body, StringComparison.Ordinal);
        Assert.Equal(upstreamModelId, ReadSentModel(server));
    }

    [Fact]
    public async Task Absent_max_output_tokens_is_not_added_upstream()
    {
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.NonStreamJson());

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        byte[]? sentBody = server.LastRequestBody;
        Assert.NotNull(sentBody);
        string body = System.Text.Encoding.UTF8.GetString(sentBody!);
        Assert.DoesNotContain("max_output_tokens", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Non_approved_endpoint_fails_closed_before_any_request()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, DeepSeekFixtures.NonStreamJson()));

        Result<UpstreamEndpoint, RouterError> wrongPath = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "v1"),
            tlsRequired: false,
            loopbackTestOnly: true);

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()) with
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
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.NonStreamJson());
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest();

        ProviderAdapterResult first = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, request, secretValue: "test_fake_key_do_not_use"),
            CancellationToken.None);
        first.Validate();
        Assert.Equal("Bearer test_fake_key_do_not_use", server.LastRequestHeaders["Authorization"]);

        ProviderAdapterResult second = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, request, secretValue: "rotated_fake_key_do_not_use"),
            CancellationToken.None);
        second.Validate();
        Assert.Equal("Bearer rotated_fake_key_do_not_use", server.LastRequestHeaders["Authorization"]);
    }

    [Fact]
    public async Task Stream_without_route_streaming_capability_fails_closed()
    {
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.StandardStream(), stream: true);

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(
                server,
                ContractRouteFactory.CreateRequest(stream: true),
                stream: true) with
            {
                Route = WithCapabilities("text"),
            },
            CancellationToken.None);

        result.Validate();
        Assert.Equal(RouterErrorCode.UnsupportedCapability, result.Error!.Code);
        Assert.Null(server.LastRequestBody);
    }

    [Fact]
    public async Task Reasoning_without_route_reasoning_capability_fails_closed()
    {
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.NonStreamJson());
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest() with
        {
            Reasoning = new ReasoningRequest { Effort = ReasoningEffort.High },
        };

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, request) with
            {
                Route = WithCapabilities("text"),
            },
            CancellationToken.None);

        result.Validate();
        Assert.Equal(RouterErrorCode.UnsupportedCapability, result.Error!.Code);
        Assert.Null(server.LastRequestBody);
    }

    [Fact]
    public async Task Tools_without_route_tools_capability_fails_closed()
    {
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.NonStreamJson());
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

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, request) with
            {
                Route = WithCapabilities("text"),
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

    private static ResolvedRoute WithUpstreamModel(string upstreamModelId)
    {
        ResolvedRoute route = new DeepSeekContractHarness().CreateRoute();
        return route with
        {
            ModelRoute = route.ModelRoute with
            {
                ClientModelId = upstreamModelId,
                ModelId = upstreamModelId,
                UpstreamModelId = upstreamModelId,
            },
        };
    }

    private static ResolvedRoute WithCapabilities(params string[] capabilities)
        => new DeepSeekContractHarness().CreateRoute() with
        {
            EffectiveCapabilities = CapabilitySet.From(capabilities),
        };
}
