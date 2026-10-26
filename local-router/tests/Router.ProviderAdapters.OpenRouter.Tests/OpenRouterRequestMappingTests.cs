using System.Text.Json;
using ProviderContractKit;
using Router.ClientAdapters.Responses;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.OpenRouter;
using Xunit;

namespace Router.ProviderAdapters.OpenRouter.Tests;

public sealed class OpenRouterRequestMappingTests
{
    [Fact]
    public async Task Upstream_model_id_comes_only_from_the_resolved_route()
    {
        await using FakeProviderServer server = await StartServerAsync(SseFixtureBuilder.NonStreamJson());
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest(text: "hello");

        ProviderAdapterResult result = await new OpenRouterProviderAdapter().InvokeAsync(
            OpenRouterInvocationFactory.CreateInvocation(server, request),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        byte[]? sentBody = server.LastRequestBody;
        Assert.NotNull(sentBody);
        using JsonDocument document = JsonDocument.Parse(sentBody!);
        Assert.Equal("z-ai/glm-5.3", document.RootElement.GetProperty("model").GetString());
        Assert.Equal("hello", document.RootElement.GetProperty("input")[0].GetProperty("content")[0].GetProperty("text").GetString());
    }

    [Fact]
    public async Task Headers_are_explicit_allowlist_only()
    {
        await using FakeProviderServer server = await StartServerAsync(SseFixtureBuilder.NonStreamJson());
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest();

        ProviderAdapterResult result = await new OpenRouterProviderAdapter().InvokeAsync(
            OpenRouterInvocationFactory.CreateInvocation(server, request),
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
    public async Task Instructions_reasoning_and_tools_are_preserved_in_the_body()
    {
        await using FakeProviderServer server = await StartServerAsync(SseFixtureBuilder.NonStreamJson());
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
                    Parameters = System.Text.Json.JsonDocument.Parse("""{"type":"object"}""").RootElement.Clone(),
                },
            ],
        };

        ProviderAdapterResult result = await new OpenRouterProviderAdapter().InvokeAsync(
            OpenRouterInvocationFactory.CreateInvocation(server, request),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        byte[]? sentBody = server.LastRequestBody;
        Assert.NotNull(sentBody);
        string body = System.Text.Encoding.UTF8.GetString(sentBody!);
        Assert.Contains("be concise", body);
        Assert.Contains("reasoning", body);
        Assert.Contains("get_weather", body);
    }

    [Fact]
    public async Task Stream_request_accepts_event_stream()
    {
        await using FakeProviderServer server = await StartServerAsync(SseFixtureBuilder.BasicStream(), stream: true);
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest(stream: true);

        ProviderAdapterResult result = await new OpenRouterProviderAdapter().InvokeAsync(
            OpenRouterInvocationFactory.CreateInvocation(server, request, stream: true),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.EventStream);
        Assert.Equal("text/event-stream", server.LastRequestHeaders["Accept"]);
        await DrainAsync(result.EventStream!);
    }

    [Fact]
    public async Task Secret_rotation_uses_the_current_handle_each_attempt()
    {
        await using FakeProviderServer server = await StartServerAsync(SseFixtureBuilder.NonStreamJson());
        CanonicalResponsesRequest request = ContractRouteFactory.CreateRequest();

        ProviderAdapterResult first = await new OpenRouterProviderAdapter().InvokeAsync(
            OpenRouterInvocationFactory.CreateInvocation(server, request, secretValue: "test_fake_key_do_not_use"),
            CancellationToken.None);
        first.Validate();
        Assert.Equal("Bearer test_fake_key_do_not_use", server.LastRequestHeaders["Authorization"]);

        ProviderAdapterResult second = await new OpenRouterProviderAdapter().InvokeAsync(
            OpenRouterInvocationFactory.CreateInvocation(server, request, secretValue: "rotated_fake_key_do_not_use"),
            CancellationToken.None);
        second.Validate();
        Assert.Equal("Bearer rotated_fake_key_do_not_use", server.LastRequestHeaders["Authorization"]);
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
