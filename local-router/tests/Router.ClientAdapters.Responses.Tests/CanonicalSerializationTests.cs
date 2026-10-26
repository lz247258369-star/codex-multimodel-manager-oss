using System.Text.Json;
using Xunit;

namespace Router.ClientAdapters.Responses.Tests;

public sealed class CanonicalSerializationTests
{
    [Fact]
    public void Response_serializes_to_canonical_snake_case_shape()
    {
        CanonicalResponsesResponse response = new()
        {
            Id = "resp_00000000-0000-7000-8000-000000000001",
            ObjectType = "response",
            CreatedAt = 1_700_000_000,
            Status = "completed",
            Model = "gpt-test",
            Output =
            [
                new MessageOutputItem
                {
                    Type = "message",
                    Id = "msg_00000000-0000-7000-8000-000000000002",
                    Role = "assistant",
                    Content =
                    [
                        new OutputTextPart { Type = "output_text", Text = "hello", Annotations = [] },
                    ],
                },
            ],
            Usage = new UsageRecord { InputTokens = 7, OutputTokens = 5, TotalTokens = 12 },
        };

        string json = JsonSerializer.Serialize(response, ResponsesJson.Options);

        Assert.Contains("\"object\":\"response\"", json, StringComparison.Ordinal);
        Assert.Contains("\"created_at\":1700000000", json, StringComparison.Ordinal);
        Assert.Contains("\"input_tokens\":7", json, StringComparison.Ordinal);
        Assert.Contains("\"total_tokens\":12", json, StringComparison.Ordinal);
        Assert.Contains("\"role\":\"assistant\"", json, StringComparison.Ordinal);
        Assert.Contains("\"content\":[{\"type\":\"output_text\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Null_usage_fields_are_omitted()
    {
        CanonicalResponsesResponse response = new()
        {
            Id = "resp_00000000-0000-7000-8000-000000000001",
            ObjectType = "response",
            CreatedAt = 1,
            Status = "completed",
            Model = "gpt-test",
            Output = [],
            Usage = new UsageRecord { InputTokens = 1, OutputTokens = 1, TotalTokens = 2 },
        };

        string json = JsonSerializer.Serialize(response, ResponsesJson.Options);

        Assert.DoesNotContain("cached_tokens", json, StringComparison.Ordinal);
        Assert.DoesNotContain("reasoning_tokens", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Event_data_is_serialized_without_raw_newlines()
    {
        CanonicalEvent evt = CanonicalEvent.Create("response.output_text.delta", new { delta = "line1\nline2" });

        string json = JsonSerializer.Serialize(evt.Data, ResponsesJson.Options);

        Assert.DoesNotContain('\n', json);
        Assert.Contains("line1\\nline2", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Event_name_validation_rejects_injection_shapes()
    {
        Assert.Throws<ArgumentException>(() => CanonicalEvent.Create("response.completed\r\nevent: x", new { }));
        Assert.Throws<ArgumentException>(() => CanonicalEvent.Create("response.completed\n", new { }));
        Assert.Throws<ArgumentException>(() => CanonicalEvent.Create(new string('a', 65), new { }));
    }

    [Fact]
    public void ResponseId_accepts_only_canonical_shape()
    {
        Assert.True(ResponseId.TryParse("resp_00000000-0000-7000-8000-000000000001", out ResponseId parsed));
        Assert.Equal("resp_00000000-0000-7000-8000-000000000001", parsed.Value);
        Assert.False(ResponseId.TryParse("resp_00000000-0000-7000-8000-00000000001", out _));
        Assert.False(ResponseId.TryParse("resp_00000000-0000-7000-8000-00000000001x", out _));
        Assert.False(ResponseId.TryParse("other_00000000-0000-7000-8000-000000000001", out _));
    }

    [Fact]
    public void Request_max_output_tokens_round_trips_as_an_integer()
    {
        CanonicalResponsesRequest request = new()
        {
            Model = "gpt-test",
            Input = [new MessageInputItem { Type = "message", Role = "user", Content = [new TextContentPart { Type = "input_text", Text = "hi" }] }],
            MaxOutputTokens = 16,
        };

        string json = JsonSerializer.Serialize(request, ResponsesJson.Options);

        Assert.Contains("\"max_output_tokens\":16", json, StringComparison.Ordinal);
        Assert.DoesNotContain("max_output_tokens\":\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Absent_max_output_tokens_is_not_invented()
    {
        CanonicalResponsesRequest request = new()
        {
            Model = "gpt-test",
            Input = [new MessageInputItem { Type = "message", Role = "user", Content = [new TextContentPart { Type = "input_text", Text = "hi" }] }],
        };

        string json = JsonSerializer.Serialize(request, ResponsesJson.Options);

        Assert.DoesNotContain("max_output_tokens", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Reasoning_effort_max_round_trips_unchanged()
    {
        CanonicalResponsesRequest request = new()
        {
            Model = "gpt-test",
            Input = [new MessageInputItem { Type = "message", Role = "user", Content = [new TextContentPart { Type = "input_text", Text = "hi" }] }],
            Reasoning = new ReasoningRequest { Effort = ReasoningEffort.Max },
        };

        string json = JsonSerializer.Serialize(request, ResponsesJson.Options);

        Assert.Contains("\"effort\":\"max\"", json, StringComparison.Ordinal);
        Assert.DoesNotContain("\"effort\":\"high\"", json, StringComparison.Ordinal);
        Assert.DoesNotContain("xhigh", json, StringComparison.Ordinal);
    }
}
