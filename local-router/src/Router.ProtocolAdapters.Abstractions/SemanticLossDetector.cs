using Router.ClientAdapters.Responses;
using Router.Registries;

namespace Router.ProtocolAdapters.Abstractions;

/// <summary>
/// Pure semantic-loss detector for Responses-family mappings. It compares the
/// semantics actually present in a canonical request/event against the
/// upstream protocol capability set. Any gap is a typed loss; the router never
/// guesses, drops, downgrades, or coerces semantics.
/// </summary>
public static class SemanticLossDetector
{
    private static readonly HashSet<string> AllowedInputPartTypes = new(StringComparer.Ordinal)
    {
        "input_text",
        "output_text",
    };

    private static readonly HashSet<string> CanonicalEventNames = new(StringComparer.Ordinal)
    {
        "response.created",
        "response.in_progress",
        "response.output_item.added",
        "response.output_item.done",
        "response.output_text.delta",
        "response.output_text.done",
        "response.reasoning_summary_text.delta",
        "response.completed",
        "response.failed",
        "error",
    };

    public static SemanticLoss? Detect(CanonicalResponsesRequest request, CapabilitySet upstreamCapabilities)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(upstreamCapabilities);

        if (request.Stream && !upstreamCapabilities.Contains("streaming"))
        {
            return SemanticLoss.Create("streaming", SemanticLossReason.StreamingUnsupported);
        }

        if (request.Reasoning is not null && !upstreamCapabilities.Contains("reasoning"))
        {
            return SemanticLoss.Create("reasoning", SemanticLossReason.ReasoningUnsupported);
        }

        if ((request.Tools.Count > 0 || request.ToolChoice is not null) && !upstreamCapabilities.Contains("tools"))
        {
            return SemanticLoss.Create("tools", SemanticLossReason.ToolUnsupported);
        }

        foreach (ResponsesInputItem item in request.Input)
        {
            if (item is MessageInputItem message)
            {
                foreach (TextContentPart part in message.Content)
                {
                    if (!AllowedInputPartTypes.Contains(part.Type))
                    {
                        return SemanticLoss.Create("multimodal", SemanticLossReason.MultimodalUnsupported);
                    }
                }
            }
        }

        return null;
    }

    public static SemanticLoss? DetectEvent(CanonicalEvent canonicalEvent)
    {
        ArgumentNullException.ThrowIfNull(canonicalEvent);
        return CanonicalEventNames.Contains(canonicalEvent.Type)
            ? null
            : SemanticLoss.Create("event", SemanticLossReason.UnknownEvent);
    }
}
