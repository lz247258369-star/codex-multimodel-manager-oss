using System.Runtime.ExceptionServices;
using Router.Host;

namespace Router.Core.Tests.Host;

/// <summary>How a test-owned Host ended when the test stopped it.</summary>
internal enum HostStopOutcome
{
    /// <summary>The test never started a Host.</summary>
    NotStarted,

    /// <summary>The Host returned exit code 0.</summary>
    Exited,

    /// <summary>
    /// The Host returned a non-zero exit code other than the cancellation code.
    /// RunAsync reports real failures this way (for example a failed shutdown
    /// cleanup), so this is never a clean stop.
    /// </summary>
    ExitedWithError,

    /// <summary>
    /// The Host ended by the cancellation the test requested: the cancellation
    /// exit code, or a cancelled task carrying exactly the test's own token.
    /// </summary>
    Cancelled,

    /// <summary>The Host did not end within the stop timeout; it may still be running.</summary>
    TimedOut,

    /// <summary>The Host task ended with an exception other than the requested cancellation.</summary>
    Faulted,
}

/// <summary>Result of <see cref="HostTestCleanup.StopHostAsync"/>.</summary>
internal sealed record HostStopResult(
    HostStopOutcome Outcome,
    int? ExitCode = null,
    Exception? Fault = null,
    Exception? StopRequestFailure = null)
{
    /// <summary>
    /// True only when the Host is known to have ended, so its listener, state
    /// files and logs are released and the sandbox may be deleted.
    /// </summary>
    public bool HostEnded => Outcome is not HostStopOutcome.TimedOut;
}

/// <summary>A cleanup failure of a test-owned Host or its sandbox.</summary>
internal sealed class HostCleanupException : Exception
{
    public HostCleanupException(string message, Exception? innerException = null)
        : base(message, innerException)
    {
    }
}

/// <summary>
/// Stops a Host started by a test and removes its sandbox without hiding
/// anything: a Host that has not been confirmed to end keeps its sandbox, a
/// Host fault or a failed delete is reported, and an original test failure is
/// always the first failure the test reports.
/// </summary>
internal static class HostTestCleanup
{
    public static readonly TimeSpan DefaultStopTimeout = TimeSpan.FromSeconds(15);

    /// <summary>
    /// Requests cancellation (once) and waits up to <paramref name="stopTimeout"/>
    /// for the Host task. Never throws for a Host outcome; the outcome is returned.
    /// </summary>
    public static async Task<HostStopResult> StopHostAsync(
        CancellationTokenSource cts,
        Task<int>? runTask,
        TimeSpan? stopTimeout = null)
    {
        ArgumentNullException.ThrowIfNull(cts);
        Exception? stopRequestFailure = null;
        if (!cts.IsCancellationRequested)
        {
            try
            {
                cts.Cancel();
            }
            catch (Exception error)
            {
                // Recorded, never swallowed: a throwing cancellation callback
                // must not replace the original test failure or skip the wait.
                stopRequestFailure = error;
            }
        }

        HostStopResult result = await ObserveHostEndAsync(cts, runTask, stopTimeout ?? DefaultStopTimeout).ConfigureAwait(false);
        return result with { StopRequestFailure = stopRequestFailure };
    }

    private static async Task<HostStopResult> ObserveHostEndAsync(
        CancellationTokenSource cts,
        Task<int>? runTask,
        TimeSpan stopTimeout)
    {
        if (runTask is null)
        {
            return new HostStopResult(HostStopOutcome.NotStarted);
        }

        Task finished = await Task.WhenAny(runTask, Task.Delay(stopTimeout)).ConfigureAwait(false);
        if (!ReferenceEquals(finished, runTask))
        {
            return new HostStopResult(HostStopOutcome.TimedOut);
        }

        try
        {
            int exitCode = await runTask.ConfigureAwait(false);
            HostStopOutcome outcome = exitCode switch
            {
                0 => HostStopOutcome.Exited,
                RouterHostBootstrap.CancelledExitCode => HostStopOutcome.Cancelled,
                _ => HostStopOutcome.ExitedWithError,
            };
            return new HostStopResult(outcome, ExitCode: exitCode);
        }
        catch (OperationCanceledException cancelled) when (cancelled.CancellationToken == cts.Token)
        {
            return new HostStopResult(HostStopOutcome.Cancelled);
        }
        catch (Exception fault)
        {
            // Includes a cancellation that is not the test's own (for example an
            // HTTP timeout): only the requested stop is an expected cancellation.
            return new HostStopResult(HostStopOutcome.Faulted, Fault: fault);
        }
    }

    /// <summary>
    /// Ends a Host test: stops the Host, deletes the sandbox only when the Host
    /// is known to have ended, then reports. With no failures it returns. With
    /// only the original test failure it rethrows that exception unchanged.
    /// Otherwise it throws: a single cleanup failure as itself, or an
    /// <see cref="AggregateException"/> whose first inner exception is the
    /// original test failure (when there is one) followed by every cleanup
    /// failure.
    /// </summary>
    public static async Task FinishHostTestAsync(
        ExceptionDispatchInfo? testFailure,
        CancellationTokenSource cts,
        Task<int>? runTask,
        string sandbox,
        TimeSpan? stopTimeout = null)
    {
        HostStopResult stop = await StopHostAsync(cts, runTask, stopTimeout).ConfigureAwait(false);
        List<Exception> cleanupFailures = [];

        if (stop.StopRequestFailure is not null)
        {
            cleanupFailures.Add(new HostCleanupException("Requesting the Host stop failed.", stop.StopRequestFailure));
        }

        if (stop.Outcome == HostStopOutcome.ExitedWithError)
        {
            cleanupFailures.Add(new HostCleanupException($"The Host ended with exit code {stop.ExitCode}."));
        }

        if (stop.Outcome == HostStopOutcome.Faulted
            && !ReferenceEquals(stop.Fault, testFailure?.SourceException))
        {
            cleanupFailures.Add(new HostCleanupException("The Host task faulted.", stop.Fault));
        }

        if (!stop.HostEnded)
        {
            cleanupFailures.Add(new HostCleanupException(
                $"The Host did not end within {(stopTimeout ?? DefaultStopTimeout).TotalSeconds:0.###} s after cancellation; "
                + $"the sandbox '{Path.GetFileName(sandbox)}' was left in place because the Host may still be using it."));
        }
        else if (Directory.Exists(sandbox))
        {
            try
            {
                Directory.Delete(sandbox, recursive: true);
            }
            catch (Exception error)
            {
                cleanupFailures.Add(new HostCleanupException(
                    $"The Host ended ({stop.Outcome}) but the sandbox '{Path.GetFileName(sandbox)}' could not be deleted.", error));
            }
        }

        if (cleanupFailures.Count == 0)
        {
            testFailure?.Throw();
            return;
        }

        if (testFailure is null && cleanupFailures.Count == 1)
        {
            throw cleanupFailures[0];
        }

        List<Exception> all = testFailure is null ? [] : [testFailure.SourceException];
        all.AddRange(cleanupFailures);
        throw new AggregateException(
            testFailure is null
                ? "Host test cleanup failed."
                : "The test failed and Host test cleanup also failed; the first inner exception is the original test failure.",
            all);
    }
}
