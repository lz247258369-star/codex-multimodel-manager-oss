using System.Diagnostics;

namespace Router.State.Ownership;

/// <summary>Identity of an inspected process.</summary>
public sealed record ProcessInfo
{
    public required int Pid { get; init; }

    /// <summary>Null when the process exists but its start identity cannot be verified.</summary>
    public DateTimeOffset? StartTimeUtc { get; init; }
}

/// <summary>
/// Process inspection abstraction. Returns null when the process does not
/// exist. Implementations never kill or modify processes.
/// </summary>
public interface IProcessInspector
{
    ProcessInfo? TryGetProcess(int pid);
}

/// <summary>Production inspector over the OS process table.</summary>
public sealed class SystemProcessInspector : IProcessInspector
{
    public ProcessInfo? TryGetProcess(int pid)
    {
        if (pid <= 0)
        {
            return null;
        }

        try
        {
            using Process process = Process.GetProcessById(pid);
            return new ProcessInfo
            {
                Pid = process.Id,
                StartTimeUtc = process.StartTime.ToUniversalTime(),
            };
        }
        catch (ArgumentException)
        {
            return null;
        }
        catch (InvalidOperationException)
        {
            return null;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // The process exists but its identity cannot be verified: treat as
            // an unverifiable foreign conflict, never as stale.
            return new ProcessInfo { Pid = pid, StartTimeUtc = null };
        }
    }
}
