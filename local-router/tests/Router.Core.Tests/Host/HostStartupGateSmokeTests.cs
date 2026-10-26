using Xunit;

namespace Router.Core.Tests.Host;

/// <summary>FIX2 focused Windows CI reproduction; the full repeated tests remain mandatory.</summary>
public sealed class HostStartupGateSmokeTests
{
    // Reuse original tests and their assertions; run one deterministic window
    // per case before the complete suite, without another build or publish.
    [Fact]
    public Task Enabled_host_commits_READY()
        => new HostReadinessLifecycleTests().Health_200_implies_durable_ready(1);

    [Fact]
    public Task STARTING_cancellation_archives_owner()
        => new HostReadinessLifecycleTests().Startup_tail_cancellation_stops_safely(1);

    [Fact]
    public Task Normal_shutdown_commits_STOPPED()
        => new HostReadinessLifecycleTests().Steady_state_shutdown_remains_clean(1);

    [Fact]
    public async Task Early_exit_is_reported_instead_of_barrier_timeout()
    {
        TaskCompletionSource barrier = new();
        Exception error = await Assert.ThrowsAnyAsync<Xunit.Sdk.XunitException>(() =>
            HostTestHarness.WaitForStartupBarrierAsync(barrier.Task, Task.FromResult(2), TimeSpan.FromSeconds(15)));
        Assert.Contains("exit_code=2", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Fault_diagnostic_does_not_include_private_exception_message()
    {
        TaskCompletionSource barrier = new();
        const string privateDetail = "fixture-private-path-and-request-content";
        Exception error = await Assert.ThrowsAnyAsync<Xunit.Sdk.XunitException>(() =>
            HostTestHarness.WaitForStartupBarrierAsync(barrier.Task, Task.FromException<int>(new IOException(privateDetail)), TimeSpan.FromSeconds(15)));
        Assert.Contains("exception=IOException", error.Message, StringComparison.Ordinal);
        Assert.DoesNotContain(privateDetail, error.Message, StringComparison.Ordinal);
    }
}
