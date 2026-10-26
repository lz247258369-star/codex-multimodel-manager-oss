using System.Diagnostics;
using Router.Core.Tests.Fakes;
using Router.Host;
using Xunit;

namespace Router.Core.Tests.Host;

public sealed class DisabledHostTests
{
    [Fact]
    public async Task Host_bootstrap_exits_zero_when_disabled()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            // DSR6: the shipped defaults stay disabled, but the effective config
            // is defaults + user, so this check runs against an isolated home
            // (no user config) instead of whatever the machine happens to have.
            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                new TestPathProvider(sandbox, TestPaths.DefaultsPath),
                cancellationToken: CancellationToken.None);

            Assert.Equal(0, exitCode);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Host_bootstrap_returns_cancel_code_when_token_is_already_cancelled()
    {
        using CancellationTokenSource cts = new();
        cts.Cancel();

        int exitCode = await RouterHostBootstrap.RunAsync(Array.Empty<string>(), cancellationToken: cts.Token);

        Assert.Equal(RouterHostBootstrap.CancelledExitCode, exitCode);
    }

    [Fact]
    public async Task Host_process_exits_quickly_with_code_zero_and_no_listener_startup()
    {
        string hostExecutable = Path.Combine(AppContext.BaseDirectory, "Router.Host.exe");
        Assert.True(File.Exists(hostExecutable), $"Expected host executable at {hostExecutable}");

        // DSR6: an explicit user router.config.json is the only opt-in source,
        // so the out-of-process check must run against an empty isolated home
        // (no user config) and must stay deterministic on a machine that does
        // have an enabled user config.
        string isolatedHome = TestPaths.NewSandboxDirectory();
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = hostExecutable,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            },
        };
        process.StartInfo.Environment["CODEX_HOME"] = isolatedHome;

        try
        {
            Stopwatch stopwatch = Stopwatch.StartNew();
            Assert.True(process.Start(), "Failed to start Router.Host.exe");

            string standardOutput = await process.StandardOutput.ReadToEndAsync();
            string standardError = await process.StandardError.ReadToEndAsync();
            Assert.True(process.WaitForExit(15_000), "Router.Host.exe did not exit; a listener would keep it alive.");
            stopwatch.Stop();

            Assert.Equal(0, process.ExitCode);
            Assert.Contains(RouterHostBootstrap.DisabledExitMessage, standardOutput);
            Assert.Equal(string.Empty, standardError);
            Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(10), "Host exit was unexpectedly slow.");
        }
        finally
        {
            Directory.Delete(isolatedHome, recursive: true);
        }
    }
}
