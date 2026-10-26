using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.ProtocolAdapters.Abstractions;
using Router.ProtocolAdapters.Responses;
using Xunit;

namespace Router.ProtocolAdapters.Tests;

/// <summary>
/// Deterministic, scrubbed, versioned golden fixtures for the LR-8 protocol
/// boundary. All values are synthetic; no key, prompt, project data, or
/// Authorization value is present. Comparisons are semantic (not byte-order
/// based) because JSON object property order is not normative.
/// </summary>
public sealed class ProtocolGoldenFixtureTests
{
    private static readonly ResponsesProtocolAdapter Adapter = new();

    private static string GoldenRoot
        => Path.Combine(AppContext.BaseDirectory, "fixtures", "local-router", "v1", "protocol", "responses", "golden");

    [Fact]
    public void Golden_fixture_set_is_present()
    {
        string[] names =
        [
            "request.text.json",
            "request.instructions.json",
            "request.reasoning.json",
            "request.tools.json",
            "request.tool-result.json",
            "request.multimodal-rejected.json",
            "request.background-rejected.json",
            "response.text.json",
            "response.usage.json",
            "stream.text.sse",
            "stream.reasoning.sse",
            "stream.tools.sse",
            "stream.error.sse",
            "error.semantic-loss.json",
        ];

        foreach (string name in names)
        {
            Assert.True(File.Exists(Path.Combine(GoldenRoot, name)), "Missing golden fixture: " + name);
        }
    }

    [Fact]
    public void Text_request_golden_maps_losslessly()
    {
        string json = File.ReadAllText(Path.Combine(GoldenRoot, "request.text.json"));
        Assert.Null(ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? request));

        Result<CanonicalResponsesRequest, RouterError> mapped = Adapter.MapRequest(request!);

        Assert.True(mapped.IsSuccess);
        Assert.Equal("synthetic-model-v1", mapped.Value!.Model);
        Assert.False(mapped.Value.Stream);
    }

    [Fact]
    public void Instructions_and_reasoning_goldens_map_losslessly()
    {
        string instructionsJson = File.ReadAllText(Path.Combine(GoldenRoot, "request.instructions.json"));
        Assert.Null(ResponsesRequestParser.TryParse(instructionsJson, out CanonicalResponsesRequest? instructions));
        Assert.Equal("Synthetic instructions fixture.", instructions!.Instructions);
        Assert.True(Adapter.MapRequest(instructions).IsSuccess);

        string reasoningJson = File.ReadAllText(Path.Combine(GoldenRoot, "request.reasoning.json"));
        Assert.Null(ResponsesRequestParser.TryParse(reasoningJson, out CanonicalResponsesRequest? reasoning));
        Assert.NotNull(reasoning!.Reasoning);
        Assert.True(Adapter.MapRequest(reasoning).IsSuccess);
    }

    [Fact]
    public void Tool_and_tool_result_goldens_map_losslessly()
    {
        string toolsJson = File.ReadAllText(Path.Combine(GoldenRoot, "request.tools.json"));
        Assert.Null(ResponsesRequestParser.TryParse(toolsJson, out CanonicalResponsesRequest? tools));
        Assert.NotEmpty(tools!.Tools);
        Assert.True(Adapter.MapRequest(tools).IsSuccess);

        string toolResultJson = File.ReadAllText(Path.Combine(GoldenRoot, "request.tool-result.json"));
        Assert.Null(ResponsesRequestParser.TryParse(toolResultJson, out CanonicalResponsesRequest? toolResult));
        Assert.Contains(toolResult!.Input, static item => item is FunctionCallOutputItem);
        Assert.True(Adapter.MapRequest(toolResult).IsSuccess);
    }

    [Fact]
    public void Unsupported_multimodal_golden_fails_closed()
    {
        string json = File.ReadAllText(Path.Combine(GoldenRoot, "request.multimodal-rejected.json"));

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
    }

    [Fact]
    public void Background_golden_fails_closed()
    {
        string json = File.ReadAllText(Path.Combine(GoldenRoot, "request.background-rejected.json"));

        RouterError? error = ResponsesRequestParser.TryParse(json, out _);

        Assert.NotNull(error);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error!.Code);
    }

    [Fact]
    public void Text_response_golden_maps_losslessly()
    {
        CanonicalResponsesResponse response = ReadResponse("response.text.json");

        Result<CanonicalResponsesResponse, RouterError> mapped = Adapter.MapResponse(response);

        Assert.True(mapped.IsSuccess);
        Assert.Equal("completed", mapped.Value!.Status);
        Assert.Contains(mapped.Value.Output, static item => item is MessageOutputItem);
    }

    [Fact]
    public void Usage_response_golden_preserves_counts()
    {
        CanonicalResponsesResponse response = ReadResponse("response.usage.json");

        Result<CanonicalResponsesResponse, RouterError> mapped = Adapter.MapResponse(response);

        Assert.True(mapped.IsSuccess);
        Assert.Equal(100, mapped.Value!.Usage!.InputTokens);
        Assert.Equal(50, mapped.Value.Usage.OutputTokens);
        Assert.Equal(150, mapped.Value.Usage.TotalTokens);
    }

    [Theory]
    [InlineData("stream.text.sse", "response.completed")]
    [InlineData("stream.reasoning.sse", "response.reasoning_summary_text.delta")]
    [InlineData("stream.tools.sse", "response.output_item.added")]
    [InlineData("stream.error.sse", "error")]
    public void Sse_goldens_preserve_event_order_and_semantics(string fileName, string requiredType)
    {
        string sse = File.ReadAllText(Path.Combine(GoldenRoot, fileName));
        List<CanonicalEvent> events = ParseSseEvents(sse);

        Assert.NotEmpty(events);
        var mapped = new List<CanonicalEvent>();
        foreach (CanonicalEvent canonicalEvent in events)
        {
            Result<CanonicalEvent, RouterError> result = Adapter.MapEvent(canonicalEvent);
            Assert.True(result.IsSuccess);
            mapped.Add(result.Value!);
        }

        Assert.Equal(events.Select(static e => e.Type), mapped.Select(static e => e.Type));
        Assert.Contains(mapped, evt => evt.Type == requiredType);
    }

    private static CanonicalResponsesResponse ReadResponse(string name)
    {
        string json = File.ReadAllText(Path.Combine(GoldenRoot, name));
        return JsonSerializer.Deserialize<CanonicalResponsesResponse>(json, ResponsesJson.Options)!;
    }

    private static List<CanonicalEvent> ParseSseEvents(string sse)
    {
        var events = new List<CanonicalEvent>();
        string[] blocks = sse.Replace("\r\n", "\n", StringComparison.Ordinal).Split("\n\n", StringSplitOptions.RemoveEmptyEntries);
        foreach (string block in blocks)
        {
            string? eventName = null;
            var dataLines = new List<string>();
            foreach (string line in block.Split('\n'))
            {
                if (line.StartsWith("event:", StringComparison.Ordinal))
                {
                    eventName = line["event:".Length..].Trim();
                }
                else if (line.StartsWith("data:", StringComparison.Ordinal))
                {
                    dataLines.Add(line["data:".Length..].TrimStart());
                }
            }

            if (eventName is null || dataLines.Count == 0)
            {
                continue;
            }

            using JsonDocument document = JsonDocument.Parse(string.Join("\n", dataLines));
            events.Add(CanonicalEvent.Create(eventName, document.RootElement.Clone()));
        }

        return events;
    }
}
