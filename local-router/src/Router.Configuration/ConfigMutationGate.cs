using Router.Core.Support;

namespace Router.Configuration;

/// <summary>
/// Cross-process config-mutation serialization boundary. The lock identity is a
/// stable hash of the canonical user-config path, so the raw filesystem path is
/// never exposed in the lock name and two independent operator instances (or
/// two processes) that target the same config serialize through the same OS
/// mutex. The final CAS compare always happens after the gate is held and the
/// current config is re-read.
/// </summary>
public sealed class ConfigMutationGate : IDisposable
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(10);

    private const string MutexPrefix = @"Local\codex.multimodel.local-router.config.mutation.";

    private readonly Mutex _mutex;
    private bool _held;
    private bool _disposed;

    private ConfigMutationGate(Mutex mutex, bool held)
    {
        _mutex = mutex;
        _held = held;
    }

    /// <summary>
    /// Acquires the mutation gate for the canonical user-config path. Throws
    /// <see cref="ConfigMutationTimeoutException"/> when the gate is busy for
    /// longer than <paramref name="timeout"/>.
    /// </summary>
    public static ConfigMutationGate Acquire(
        string userConfigPath,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(userConfigPath);
        string canonical = Path.GetFullPath(userConfigPath);
        string lockName = MutexPrefix + SafeHasher.Sha256Hex(canonical);
        Mutex mutex = new(initiallyOwned: false, lockName);
        bool held;
        try
        {
            TimeSpan wait = timeout ?? DefaultTimeout;
            int index = WaitHandle.WaitAny(
                [mutex, cancellationToken.WaitHandle],
                wait);
            held = index == 0;
        }
        catch (AbandonedMutexException)
        {
            // The previous owner crashed inside the critical section; the
            // mutex is now owned by this caller, which is the safe recovery.
            held = true;
        }

        if (!held)
        {
            mutex.Dispose();
            cancellationToken.ThrowIfCancellationRequested();
            throw new ConfigMutationTimeoutException(canonical);
        }

        return new ConfigMutationGate(mutex, held: true);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_held)
        {
            _mutex.ReleaseMutex();
            _held = false;
        }

        _mutex.Dispose();
        GC.SuppressFinalize(this);
    }
}

/// <summary>Thrown when the config mutation gate cannot be acquired in time.</summary>
public sealed class ConfigMutationTimeoutException : Exception
{
    public ConfigMutationTimeoutException(string canonicalUserConfigPath)
        : base("The configuration mutation gate is busy.")
    {
        CanonicalUserConfigPath = canonicalUserConfigPath;
    }

    public string CanonicalUserConfigPath { get; }
}
