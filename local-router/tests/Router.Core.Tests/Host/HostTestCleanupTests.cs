using System.Runtime.ExceptionServices;
using Router.Core.Tests.Fakes;
using Xunit;

namespace Router.Core.Tests.Host;

/// <summary>
/// Deterministic coverage of <see cref="HostTestCleanup"/> with synthetic Host
/// tasks: no listener, no wall-clock race. A timeout case uses a Host task that
/// never ends, so its outcome does not depend on timing.
/// </summary>
public sealed class HostTestCleanupTests
{
    private static readonly TimeSpan ShortStopTimeout = TimeSpan.FromMilliseconds(50);

    [Fact]
    public async Task Exited_host_is_reported_with_its_exit_code_and_the_sandbox_is_deleted()
    {
        string sandbox = NewSandboxWithFile();
        using CancellationTokenSource cts = new();

        HostStopResult stop = await HostTestCleanup.StopHostAsync(cts, Task.FromResult(3));
        await HostTestCleanup.FinishHostTestAsync(null, cts, Task.FromResult(3), sandbox);

        Assert.Equal(HostStopOutcome.Exited, stop.Outcome);
        Assert.Equal(3, stop.ExitCode);
        Assert.True(stop.HostEnded);
        Assert.True(cts.IsCancellationRequested);
        Assert.False(Directory.Exists(sandbox));
    }

    [Fact]
    public async Task Requested_cancellation_of_the_host_task_is_expected_and_not_a_failure()
    {
        string sandbox = NewSandboxWithFile();
        using CancellationTokenSource cts = new();
        TaskCompletionSource<int> host = new(TaskCreationOptions.RunContinuationsAsynchronously);
        using CancellationTokenRegistration registration = cts.Token.Register(() => host.TrySetCanceled(cts.Token));

        await HostTestCleanup.FinishHostTestAsync(null, cts, host.Task, sandbox);

        Assert.True(host.Task.IsCanceled);
        Assert.Equal(HostStopOutcome.Cancelled, (await HostTestCleanup.StopHostAsync(cts, host.Task)).Outcome);
        Assert.False(Directory.Exists(sandbox));
    }

    [Fact]
    public async Task Host_that_throws_operation_canceled_after_the_requested_stop_is_cancelled_not_faulted()
    {
        using CancellationTokenSource cts = new();
        Task<int> host = WaitForCancellationThenThrowAsync(cts.Token);

        HostStopResult stop = await HostTestCleanup.StopHostAsync(cts, host);

        Assert.Equal(HostStopOutcome.Cancelled, stop.Outcome);
        Assert.Null(stop.Fault);
    }

    [Fact]
    public async Task Host_that_does_not_end_keeps_its_sandbox_and_reports_the_stop_timeout()
    {
        string sandbox = NewSandboxWithFile();
        using CancellationTokenSource cts = new();
        TaskCompletionSource<int> neverEnds = new(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            HostStopResult stop = await HostTestCleanup.StopHostAsync(cts, neverEnds.Task, ShortStopTimeout);
            HostCleanupException error = await Assert.ThrowsAsync<HostCleanupException>(
                () => HostTestCleanup.FinishHostTestAsync(null, cts, neverEnds.Task, sandbox, ShortStopTimeout));

            Assert.Equal(HostStopOutcome.TimedOut, stop.Outcome);
            Assert.False(stop.HostEnded);
            Assert.Contains("did not end", error.Message, StringComparison.Ordinal);
            Assert.Contains("left in place", error.Message, StringComparison.Ordinal);
            Assert.True(Directory.Exists(sandbox), "A sandbox must not be deleted while the Host may still be using it.");
            Assert.True(File.Exists(Path.Combine(sandbox, "in-use.txt")));
        }
        finally
        {
            neverEnds.TrySetResult(0);
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Host_fault_is_reported_with_the_original_exception_after_the_sandbox_is_removed()
    {
        string sandbox = NewSandboxWithFile();
        using CancellationTokenSource cts = new();
        InvalidOperationException hostFault = new("synthetic host fault");
        Task<int> host = Task.FromException<int>(hostFault);

        HostStopResult stop = await HostTestCleanup.StopHostAsync(cts, host);
        HostCleanupException error = await Assert.ThrowsAsync<HostCleanupException>(
            () => HostTestCleanup.FinishHostTestAsync(null, cts, host, sandbox));

        Assert.Equal(HostStopOutcome.Faulted, stop.Outcome);
        Assert.Same(hostFault, stop.Fault);
        Assert.True(stop.HostEnded);
        Assert.Same(hostFault, error.InnerException);
        Assert.False(Directory.Exists(sandbox), "A faulted Host has ended, so its sandbox is removed.");
    }

    [Fact]
    public async Task Original_test_failure_is_rethrown_unchanged_when_cleanup_succeeds()
    {
        string sandbox = NewSandboxWithFile();
        using CancellationTokenSource cts = new();
        InvalidOperationException original = new("original assertion");

        InvalidOperationException thrown = await Assert.ThrowsAsync<InvalidOperationException>(
            () => HostTestCleanup.FinishHostTestAsync(Capture(original), cts, Task.FromResult(0), sandbox));

        Assert.Same(original, thrown);
        Assert.False(Directory.Exists(sandbox));
    }

    [Fact]
    public async Task Original_test_failure_stays_first_when_the_host_also_does_not_end()
    {
        string sandbox = NewSandboxWithFile();
        using CancellationTokenSource cts = new();
        TaskCompletionSource<int> neverEnds = new(TaskCreationOptions.RunContinuationsAsynchronously);
        InvalidOperationException original = new("original assertion");
        try
        {
            AggregateException error = await Assert.ThrowsAsync<AggregateException>(
                () => HostTestCleanup.FinishHostTestAsync(Capture(original), cts, neverEnds.Task, sandbox, ShortStopTimeout));

            Assert.Equal(2, error.InnerExceptions.Count);
            Assert.Same(original, error.InnerExceptions[0]);
            Assert.IsType<HostCleanupException>(error.InnerExceptions[1]);
            Assert.Contains("original test failure", error.Message, StringComparison.Ordinal);
            Assert.True(Directory.Exists(sandbox));
        }
        finally
        {
            neverEnds.TrySetResult(0);
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Original_test_failure_stays_first_when_the_host_faults_with_a_different_exception()
    {
        string sandbox = NewSandboxWithFile();
        using CancellationTokenSource cts = new();
        InvalidOperationException original = new("original assertion");
        InvalidOperationException hostFault = new("synthetic host fault");

        AggregateException error = await Assert.ThrowsAsync<AggregateException>(
            () => HostTestCleanup.FinishHostTestAsync(Capture(original), cts, Task.FromException<int>(hostFault), sandbox));

        Assert.Equal(2, error.InnerExceptions.Count);
        Assert.Same(original, error.InnerExceptions[0]);
        HostCleanupException cleanup = Assert.IsType<HostCleanupException>(error.InnerExceptions[1]);
        Assert.Same(hostFault, cleanup.InnerException);
        Assert.False(Directory.Exists(sandbox));
    }

    [Fact]
    public async Task Host_fault_that_the_test_already_reported_is_not_reported_twice()
    {
        string sandbox = NewSandboxWithFile();
        using CancellationTokenSource cts = new();
        InvalidOperationException hostFault = new("synthetic host fault");

        InvalidOperationException thrown = await Assert.ThrowsAsync<InvalidOperationException>(
            () => HostTestCleanup.FinishHostTestAsync(Capture(hostFault), cts, Task.FromException<int>(hostFault), sandbox));

        Assert.Same(hostFault, thrown);
        Assert.False(Directory.Exists(sandbox));
    }

    [Fact]
    public async Task Test_that_never_started_a_host_still_removes_its_sandbox()
    {
        string sandbox = NewSandboxWithFile();
        using CancellationTokenSource cts = new();

        HostStopResult stop = await HostTestCleanup.StopHostAsync(cts, null);
        await HostTestCleanup.FinishHostTestAsync(null, cts, null, sandbox);

        Assert.Equal(HostStopOutcome.NotStarted, stop.Outcome);
        Assert.False(Directory.Exists(sandbox));
    }

    private static string NewSandboxWithFile()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        File.WriteAllText(Path.Combine(sandbox, "in-use.txt"), "sandbox content");
        return sandbox;
    }

    private static ExceptionDispatchInfo Capture(Exception error)
    {
        try
        {
            throw error;
        }
        catch (Exception thrown)
        {
            return ExceptionDispatchInfo.Capture(thrown);
        }
    }

    private static async Task<int> WaitForCancellationThenThrowAsync(CancellationToken token)
    {
        await Task.Delay(Timeout.InfiniteTimeSpan, token);
        return 0;
    }
}
