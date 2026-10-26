namespace Router.ProtocolAdapters.Responses;

/// <summary>
/// Frozen, versioned canonical Responses event vocabulary. Names strictly
/// inherit the existing canonical event stream; no second event vocabulary is
/// created. Event ordering and payload semantics are preserved exactly.
/// </summary>
public static class CanonicalEventVocabulary
{
    public const string ResponseStarted = "response.created";
    public const string ResponseInProgress = "response.in_progress";
    public const string OutputItemAdded = "response.output_item.added";
    public const string OutputItemDone = "response.output_item.done";
    public const string TextDelta = "response.output_text.delta";
    public const string TextDone = "response.output_text.done";
    public const string ReasoningDelta = "response.reasoning_summary_text.delta";
    public const string ResponseCompleted = "response.completed";
    public const string ResponseFailed = "response.failed";
    public const string Error = "error";

    /// <summary>Canonical event names the Responses protocol adapter accepts.</summary>
    public static IReadOnlyList<string> All { get; } =
    [
        ResponseStarted,
        ResponseInProgress,
        OutputItemAdded,
        OutputItemDone,
        TextDelta,
        TextDone,
        ReasoningDelta,
        ResponseCompleted,
        ResponseFailed,
        Error,
    ];
}
