using Router.ClientAdapters.Responses;
using Router.ProtocolAdapters.Abstractions;
using Router.Registries;
using Xunit;

namespace Router.ProtocolAdapters.Tests;

public sealed class SemanticLossDetectorTests
{
    [Fact]
    public void Streaming_without_upstream_streaming_is_loss()
    {
        CanonicalResponsesRequest request = CreateRequest(stream: true);

        SemanticLoss? loss = SemanticLossDetector.Detect(request, CapabilitySet.From(["text"]));

        Assert.NotNull(loss);
        Assert.Equal("streaming", loss!.Capability);
    }

    [Fact]
    public void Reasoning_without_upstream_reasoning_is_loss()
    {
        CanonicalResponsesRequest request = CreateRequest() with
        {
            Reasoning = new ReasoningRequest { Effort = ReasoningEffort.Medium },
        };

        SemanticLoss? loss = SemanticLossDetector.Detect(request, CapabilitySet.From(["text"]));

        Assert.NotNull(loss);
        Assert.Equal("reasoning", loss!.Capability);
    }

    [Fact]
    public void Tools_without_upstream_tools_is_loss()
    {
        CanonicalResponsesRequest request = CreateRequest() with
        {
            Tools = [new FunctionToolDefinition { Name = "get_weather" }],
        };

        SemanticLoss? loss = SemanticLossDetector.Detect(request, CapabilitySet.From(["text"]));

        Assert.NotNull(loss);
        Assert.Equal("tools", loss!.Capability);
    }

    [Fact]
    public void Multimodal_content_is_loss()
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
                        new TextContentPart { Type = "input_image", Text = "synthetic" },
                    ],
                },
            ],
        };

        SemanticLoss? loss = SemanticLossDetector.Detect(request, CapabilitySet.From(["text", "streaming"]));

        Assert.NotNull(loss);
        Assert.Equal("multimodal", loss!.Capability);
    }

    [Fact]
    public void Unknown_event_is_loss()
    {
        SemanticLoss? loss = SemanticLossDetector.DetectEvent(CanonicalEvent.Create("response.unknown_event", """{"type":"response.unknown_event"}"""));

        Assert.NotNull(loss);
        Assert.Equal("event", loss!.Capability);
    }

    [Fact]
    public void Supported_request_has_no_loss()
    {
        CanonicalResponsesRequest request = CreateRequest(stream: true) with
        {
            Reasoning = new ReasoningRequest { Effort = ReasoningEffort.High },
            Tools = [new FunctionToolDefinition { Name = "get_weather" }],
        };

        SemanticLoss? loss = SemanticLossDetector.Detect(
            request,
            CapabilitySet.From(["text", "streaming", "reasoning", "tools"]));

        Assert.Null(loss);
    }

    private static CanonicalResponsesRequest CreateRequest(bool stream = false)
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
            Stream = stream,
        };
}
