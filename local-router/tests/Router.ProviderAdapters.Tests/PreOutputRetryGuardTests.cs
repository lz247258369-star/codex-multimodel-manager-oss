using Router.ProviderAdapters.Abstractions;
using Xunit;

namespace Router.ProviderAdapters.Tests;

public sealed class PreOutputRetryGuardTests
{
    [Fact]
    public void Retry_is_allowed_before_first_output()
    {
        foreach (RetryCheckpointState state in new[]
                 {
                     RetryCheckpointState.NotStarted,
                     RetryCheckpointState.RequestSent,
                     RetryCheckpointState.WaitingFirstByte,
                     RetryCheckpointState.FirstByteReceived,
                 })
        {
            Assert.True(PreOutputRetryGuard.CanRetry(new RetryCheckpoint { State = state }), state.ToString());
        }
    }

    [Fact]
    public void Retry_is_forbidden_after_first_output()
    {
        Assert.False(PreOutputRetryGuard.CanRetry(new RetryCheckpoint { State = RetryCheckpointState.FirstOutputEmitted }));
        Assert.False(PreOutputRetryGuard.CanRetry(new RetryCheckpoint { State = RetryCheckpointState.Terminal }));
    }
}
