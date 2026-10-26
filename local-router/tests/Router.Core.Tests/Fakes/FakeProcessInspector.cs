using Router.State.Ownership;

namespace Router.Core.Tests.Fakes;

/// <summary>Configurable process-table fake; never inspects or touches real processes.</summary>
public sealed class FakeProcessInspector : IProcessInspector
{
    private readonly Dictionary<int, ProcessInfo?> _processes = new();

    public void Add(int pid, DateTimeOffset startTimeUtc)
        => _processes[pid] = new ProcessInfo { Pid = pid, StartTimeUtc = startTimeUtc };

    public void AddUnverifiable(int pid)
        => _processes[pid] = new ProcessInfo { Pid = pid, StartTimeUtc = null };

    public void Remove(int pid)
        => _processes.Remove(pid);

    public ProcessInfo? TryGetProcess(int pid)
        => _processes.TryGetValue(pid, out ProcessInfo? info) ? info : null;
}
