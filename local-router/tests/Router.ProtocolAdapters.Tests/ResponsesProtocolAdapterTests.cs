using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.ProtocolAdapters.Abstractions;
using Router.ProtocolAdapters.Responses;
using Xunit;

namespace Router.ProtocolAdapters.Tests;

public sealed class ResponsesProtocolAdapterTests
{
    private static readonly ResponsesProtocolAdapter Adapter = new();

    [Fact]
    public void Text_request_maps_exactly()
    {
        CanonicalResponsesRequest request = CreateRequest();

        Result<CanonicalResponsesRequest, RouterError> mapped = Adapter.MapRequest(request);

        Assert.True(mapped.IsSuccess);
        Assert.Same(request, mapped.Value);
        Assert.Equal("synthetic-model", mapped.Value!.Model);
        Assert.Equal("be concise", mapped.Value.Instructions);
    }

    [Fact]
    public void Reasoning_tools_and_tool_choice_are_preserved()
    {
        CanonicalResponsesRequest request = CreateRequest() with
        {
            Reasoning = new ReasoningRequest { Effort = ReasoningEffort.High },
            Tools =
            [
                new FunctionToolDefinition { Name = "get_weather", Description = "weather" },
            ],
            ToolChoice = new ToolChoice { Kind = ToolChoiceKind.Function, FunctionName = "get_weather" },
        };

        Result<CanonicalResponsesRequest, RouterError> mapped = Adapter.MapRequest(request);

        Assert.True(mapped.IsSuccess);
        Assert.NotNull(mapped.Value!.Reasoning);
        Assert.Single(mapped.Value.Tools);
        Assert.Equal(ToolChoiceKind.Function, mapped.Value.ToolChoice!.Kind);
    }

    [Fact]
    public void Non_stream_response_maps_exactly()
    {
        var response = new CanonicalResponsesResponse
        {
            Id = "resp_1",
            ObjectType = "response",
            CreatedAt = 1,
            Status = "completed",
            Model = "synthetic-model",
            Output =
            [
                new MessageOutputItem
                {
                    Type = "message",
                    Id = "msg_1",
                    Role = "assistant",
                    Content = [new OutputTextPart { Type = "output_text", Text = "hello" }],
                },
            ],
            Usage = new UsageRecord { InputTokens = 7, OutputTokens = 5, TotalTokens = 12 },
        };

        Result<CanonicalResponsesResponse, RouterError> mapped = Adapter.MapResponse(response);

        Assert.True(mapped.IsSuccess);
        Assert.Same(response, mapped.Value);
        Assert.Equal(7, mapped.Value!.Usage!.InputTokens);
    }

    [Fact]
    public void Canonical_event_maps_exactly_and_preserves_order()
    {
        var events = new[]
        {
            CreateEvent(CanonicalEventVocabulary.ResponseStarted),
            CreateEvent(CanonicalEventVocabulary.TextDelta),
            CreateEvent(CanonicalEventVocabulary.ResponseCompleted),
        };

        var mapped = new List<CanonicalEvent>();
        foreach (CanonicalEvent canonicalEvent in events)
        {
            Result<CanonicalEvent, RouterError> result = Adapter.MapEvent(canonicalEvent);
            Assert.True(result.IsSuccess);
            mapped.Add(result.Value!);
        }

        Assert.Equal(events.Select(static e => e.Type), mapped.Select(static e => e.Type));
    }

    [Fact]
    public void Unknown_event_fails_closed()
    {
        CanonicalEvent unknown = CreateEvent("response.some_unknown_event");

        Result<CanonicalEvent, RouterError> mapped = Adapter.MapEvent(unknown);

        Assert.False(mapped.IsSuccess);
        Assert.Equal(RouterErrorCode.SemanticLoss, mapped.Error!.Code);
    }

    [Fact]
    public void Multimodal_semantics_fail_closed()
    {
        CanonicalResponsesRequest request = CreateRequest() with
        {
            Input =
            [
                new MessageInputItem
                {
                    Type = "message",
                    Role = "user",
                    Content =
                    [
                        new TextContentPart { Type = "input_image", Text = "data:image/png;base64,synthetic" },
                    ],
                },
            ],
        };

        Result<CanonicalResponsesRequest, RouterError> mapped = Adapter.MapRequest(request);

        Assert.False(mapped.IsSuccess);
        Assert.Equal(RouterErrorCode.SemanticLoss, mapped.Error!.Code);
    }

    [Fact]
    public void Unsupported_response_status_fails_closed()
    {
        var response = new CanonicalResponsesResponse
        {
            Id = "resp_1",
            ObjectType = "response",
            CreatedAt = 1,
            Status = "in_progress",
            Model = "synthetic-model",
        };

        Result<CanonicalResponsesResponse, RouterError> mapped = Adapter.MapResponse(response);

        Assert.False(mapped.IsSuccess);
        Assert.Equal(RouterErrorCode.SemanticLoss, mapped.Error!.Code);
    }

    private static CanonicalResponsesRequest CreateRequest()
        => new()
        {
            Model = "synthetic-model",
            Input =
            [
                new MessageInputItem
                {
                    Type = "message",
                    Role = "user",
                    Content = [new TextContentPart { Type = "input_text", Text = "hello" }],
                },
            ],
            Instructions = "be concise",
        };

    private static CanonicalEvent CreateEvent(string eventName)
    {
        string payload = eventName switch
        {
            CanonicalEventVocabulary.ResponseStarted => """{"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}""",
            CanonicalEventVocabulary.TextDelta => """{"type":"response.output_text.delta","item_id":"msg_1","delta":"hello"}""",
            CanonicalEventVocabulary.ResponseCompleted => """{"type":"response.completed","response":{"id":"resp_1","status":"completed"}}""",
            _ => $$"""{"type":"{{eventName}}"}""",
        };

        using JsonDocument document = System.Text.Json.JsonDocument.Parse(payload);
        return CanonicalEvent.Create(eventName, document.RootElement.Clone());
    }
}
