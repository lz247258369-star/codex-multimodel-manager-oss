using Router.ProtocolAdapters.Responses;
using Xunit;

namespace Router.ProtocolAdapters.Tests;

public sealed class CanonicalEventVocabularyTests
{
    [Fact]
    public void Vocabulary_inherits_existing_canonical_event_names()
    {
        Assert.Equal("response.created", CanonicalEventVocabulary.ResponseStarted);
        Assert.Equal("response.output_text.delta", CanonicalEventVocabulary.TextDelta);
        Assert.Equal("response.reasoning_summary_text.delta", CanonicalEventVocabulary.ReasoningDelta);
        Assert.Equal("response.output_item.added", CanonicalEventVocabulary.OutputItemAdded);
        Assert.Equal("response.completed", CanonicalEventVocabulary.ResponseCompleted);
        Assert.Equal("response.failed", CanonicalEventVocabulary.ResponseFailed);
        Assert.Equal("error", CanonicalEventVocabulary.Error);
    }

    [Fact]
    public void Vocabulary_is_unique_and_has_stable_order()
    {
        string[] expected =
        [
            CanonicalEventVocabulary.ResponseStarted,
            CanonicalEventVocabulary.ResponseInProgress,
            CanonicalEventVocabulary.OutputItemAdded,
            CanonicalEventVocabulary.OutputItemDone,
            CanonicalEventVocabulary.TextDelta,
            CanonicalEventVocabulary.TextDone,
            CanonicalEventVocabulary.ReasoningDelta,
            CanonicalEventVocabulary.ResponseCompleted,
            CanonicalEventVocabulary.ResponseFailed,
            CanonicalEventVocabulary.Error,
        ];

        Assert.Equal(expected, CanonicalEventVocabulary.All);
        Assert.Equal(CanonicalEventVocabulary.All.Count, CanonicalEventVocabulary.All.Distinct(StringComparer.Ordinal).Count());
    }
}
