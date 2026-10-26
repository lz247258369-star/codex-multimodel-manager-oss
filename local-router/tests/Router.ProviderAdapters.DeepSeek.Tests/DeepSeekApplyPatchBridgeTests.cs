using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Router.Registries;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

/// <summary>
/// DSR7-C-FIX5-A: DeepSeek is the only provider that declares the apply_patch
/// compatibility bridge. FIX5-A pinned the pre-bridge contract: a canonical
/// custom tool was never forwarded and never silently dropped, and the shared
/// provider base failed closed for every provider.
///
/// DSR7-C-FIX5-B1b-1 promotes the eligible DeepSeek path (the request transform
/// and replay bridge - see <c>DeepSeekApplyPatchRequestBridgeTests</c>). This file
/// keeps pinning the other half of the contract: a route that does not declare
/// every capability the bridge needs is still never bridged, and nothing - not
/// even the synthetic function - reaches the transport.
/// </summary>
public sealed class DeepSeekApplyPatchBridgeTests
{
    private const string ApplyPatchToolJson = """
        {"model":"deepseek-flash","input":"hi","tools":[{"type":"custom","name":"apply_patch","description":"freeform","format":{"type":"grammar","syntax":"lark","definition":"start: /.+/"}}]}
        """;

    [Fact]
    public void DeepSeek_declares_the_apply_patch_compatibility_bridge()
    {
        Assert.Equal("apply_patch_compat_bridge", DeepSeekCapabilities.ApplyPatchCompatBridge);
        Assert.True(DeepSeekCapabilities.SupportedCompatibilityBridges.Contains(DeepSeekCapabilities.ApplyPatchCompatBridge));
    }

    [Fact]
    public async Task Canonical_apply_patch_tool_is_not_forwarded_upstream_yet()
    {
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.NonStreamJson());
        CanonicalResponsesRequest request = ParseRequest(ApplyPatchToolJson);
        Assert.NotNull(request.ApplyPatchTool);

        // The bridge requires the route's tools capability. Without it the request
        // is never transformed upstream, so the transport stays untouched.
        ProviderAdapterInvocation invocation = DeepSeekInvocationFactory.CreateInvocation(server, request);
        invocation = invocation with
        {
            Route = invocation.Route with
            {
                EffectiveCapabilities = CapabilitySet.From(
                    ["text", "streaming", "reasoning", "usage", "cancellation"]),
            },
        };

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            invocation,
            CancellationToken.None);

        Assert.NotNull(result.Error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, result.Error!.Code);
        Assert.Null(result.Response);

        // Nothing reached the upstream: a custom definition must never be sent.
        Assert.Null(server.LastRequestBody);
    }

    [Fact]
    public async Task Eligible_route_bridges_the_freeform_tool_and_never_sends_the_custom_definition()
    {
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.NonStreamJson());
        CanonicalResponsesRequest request = ParseRequest(ApplyPatchToolJson);

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, request),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);

        using JsonDocument sent = JsonDocument.Parse(server.LastRequestBody!);
        JsonElement tool = sent.RootElement.GetProperty("tools")[0];
        Assert.Equal("function", tool.GetProperty("type").GetString());
        Assert.Equal(ApplyPatchBridgeContract.SyntheticFunctionName, tool.GetProperty("name").GetString());

        // The freeform definition itself never crosses the boundary.
        string body = System.Text.Encoding.UTF8.GetString(server.LastRequestBody!);
        Assert.DoesNotContain("custom", body, StringComparison.Ordinal);
        Assert.DoesNotContain("start: /.+/", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Ordinary_function_tools_still_reach_the_upstream_unchanged()
    {
        await using FakeProviderServer server = await StartServerAsync(DeepSeekFixtures.NonStreamJson());
        CanonicalResponsesRequest request = ParseRequest(
            """{"model":"deepseek-flash","input":"hi","tools":[{"type":"function","name":"f","parameters":{"type":"object","properties":{}}}]}""");

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
            DeepSeekInvocationFactory.CreateInvocation(server, request),
            CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        using JsonDocument sent = JsonDocument.Parse(server.LastRequestBody!);
        JsonElement tool = sent.RootElement.GetProperty("tools")[0];
        Assert.Equal("f", tool.GetProperty("name").GetString());
    }

    private static CanonicalResponsesRequest ParseRequest(string json)
    {
        RouterError? error = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request);
        Assert.Null(error);
        return request!;
    }

    private static async Task<FakeProviderServer> StartServerAsync(string body)
    {
        var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(new FakeProviderScenario
        {
            StatusCode = 200,
            Body = System.Text.Encoding.UTF8.GetBytes(body),
            ContentType = "application/json",
        });
        return server;
    }
}
