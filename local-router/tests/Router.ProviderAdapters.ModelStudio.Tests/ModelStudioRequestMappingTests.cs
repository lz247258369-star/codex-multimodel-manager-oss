using System.Text.Json;
using ProviderContractKit;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.ModelStudio;
using Router.Routing;
using Xunit;

namespace Router.ProviderAdapters.ModelStudio.Tests;

public sealed class ModelStudioRequestMappingTests
{
    [Fact]
    public async Task Upstream_model_id_comes_only_from_the_resolved_route()
    {
        // Qwen-style model hosted through Model Studio.
        await using FakeProviderServer qwenServer = await StartServerAsync(ModelStudioFixtures.NonStreamJson());
        CanonicalResponsesRequest qwenRequest = ContractRouteFactory.CreateRequest(text: "hello");

        ProviderAdapterResult qwenResult = await new ModelStudioProviderAdapter().InvokeAsync(
            ModelStudioInvocationFactory.CreateInvocation(qwenServer, qwenRequest),
            CancellationToken.None);

        qwenResult.Validate();
        Assert.NotNull(qwenResult.Response);
        Assert.Equal("qwen3.8-max", ReadSentModel(qwenServer));

        // DeepSeek-hosted model through the same provider: brand never picks
        // the provider or rewrites the model; the route's explicit mapping does.
        ResolvedRoute deepSeekRoute = new ModelStudioContractHarness().CreateRoute() with
        {
            ModelRoute = new ModelStudioContractHarness().CreateRoute().ModelRoute with
            {
                ClientModelId = "deepseek-v4-pro",
                ModelId = "deepseek-v4-pro",
                UpstreamModelId = "deepseek-v4-pro",
            },
        };

        await using FakeProviderServer deepSeekServer = await StartServerAsync(ModelStudioFixtures.NonStreamJson());
        CanonicalResponsesRequest deepSeekRequest = ContractRouteFactory.CreateRequest(text: "hello");
        ProviderAdapterInvocation deepSeekInvocation = ModelStudioInvocationFactory.CreateInvocation(deepSeekServer, deepSeekRequest) with
        {
            Route = deepSeekRoute,
        };

        ProviderAdapterResult deepSeekResult = await new ModelStudioProviderAdapter().InvokeAsync(
            deepSeekInvocation,
            CancellationToken.None);

        deepSeekResult.Validate();
        Assert.NotNull(deepSeekResult.Response);
        Assert.Equal("deepseek-v4-pro", ReadSentModel(deepSeekServer));
    }

    [Fact]
    public async Task Headers_are_explicit_allowlist_only()
    {
        await using FakeProviderServer server = await StartServerAsync(ModelStudioFixtures.NonStreamJson());
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest();

        ProviderAdapterResult result = await new ModelStudioProviderAdapter().InvokeAsync(
            ModelStudioInvocationFactory.CreateInvocation(server, request),
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
        await using FakeProviderServer server = await StartServerAsync(ModelStudioFixtures.NonStreamJson());
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

        ProviderAdapterResult result = await new ModelStudioProviderAdapter().InvokeAsync(
            ModelStudioInvocationFactory.CreateInvocation(server, request),
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
        await using FakeProviderServer server = await StartServerAsync(ModelStudioFixtures.DeepSeekStream(), stream: true);
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest(stream: true);

        ProviderAdapterResult result = await new ModelStudioProviderAdapter().InvokeAsync(
            ModelStudioInvocationFactory.CreateInvocation(server, request, stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        Assert.Equal("text/event-stream", server.LastRequestHeaders["Accept"]);
        await DrainAsync(result.EventStream!);
    }

    [Fact]
    public async Task Adapter_posts_only_to_the_responses_compatible_path()
    {
        await using FakeProviderServer server = await StartServerAsync(ModelStudioFixtures.NonStreamJson());

        ProviderAdapterResult result = await new ModelStudioProviderAdapter().InvokeAsync(
            ModelStudioInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.Equal("/compatible-mode/v1/responses", server.LastRequestPath);
    }

    [Fact]
    public async Task Non_workspace_endpoint_fails_closed_before_any_request()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, ModelStudioFixtures.NonStreamJson()));

        Result<UpstreamEndpoint, RouterError> wrongPath = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "v1/responses"),
            tlsRequired: false,
            loopbackTestOnly: true);

        ProviderAdapterResult result = await new ModelStudioProviderAdapter().InvokeAsync(
            ModelStudioInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()) with
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
        await using FakeProviderServer server = await StartServerAsync(ModelStudioFixtures.NonStreamJson());
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest();

        ProviderAdapterResult first = await new ModelStudioProviderAdapter().InvokeAsync(
            ModelStudioInvocationFactory.CreateInvocation(server, request, secretValue: "test_fake_key_do_not_use"),
            CancellationToken.None);
        first.Validate();
        Assert.Equal("Bearer test_fake_key_do_not_use", server.LastRequestHeaders["Authorization"]);

        ProviderAdapterResult second = await new ModelStudioProviderAdapter().InvokeAsync(
            ModelStudioInvocationFactory.CreateInvocation(server, request, secretValue: "rotated_fake_key_do_not_use"),
            CancellationToken.None);
        second.Validate();
        Assert.Equal("Bearer rotated_fake_key_do_not_use", server.LastRequestHeaders["Authorization"]);
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
}
