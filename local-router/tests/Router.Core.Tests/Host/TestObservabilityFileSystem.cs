using Router.Observability;

namespace Router.Core.Tests.Host;

/// <summary>
/// Deterministic in-memory observability file system for completion-observer
/// failure-isolation tests. Optional gates and failure switches exercise the
/// bounded consumer without touching real disks.
/// </summary>
internal sealed class TestObservabilityFileSystem : IObservabilityFileSystem
{
    private readonly Dictionary<string, byte[]> _files = new(StringComparer.Ordinal);
    private int _attemptedWrites;
    private int _writeCount;

    public TaskCompletionSource? WriteGate { get; set; }

    public bool ThrowOnWrite { get; set; }

    public int WriteCount => Volatile.Read(ref _writeCount);

    public int AttemptedWriteCount => Volatile.Read(ref _attemptedWrites);

    public bool FileExists(string path) => _files.ContainsKey(path);

    public bool DirectoryExists(string path) => true;

    public void CreateDirectory(string path)
    {
        // In-memory only.
    }

    public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken)
        => _files.TryGetValue(path, out byte[]? content)
            ? Task.FromResult(content)
            : throw new FileNotFoundException(path);

    public async Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref _attemptedWrites);
        if (ThrowOnWrite)
        {
            throw new IOException("injected durable log write failure");
        }

        if (WriteGate is { } gate)
        {
            await gate.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        }

        _files[path] = content;
        Interlocked.Increment(ref _writeCount);
    }

    public string CreateTempPath(string directory)
        => Path.Combine(directory, ".tmp-" + Guid.NewGuid().ToString("N"));

    public void MoveFile(string sourcePath, string destinationPath, bool overwrite)
    {
        if (_files.Remove(sourcePath, out byte[]? content))
        {
            _files[destinationPath] = content;
        }
    }

    public void DeleteFile(string path) => _files.Remove(path);

    public IEnumerable<string> EnumerateFiles(string directory, string pattern)
        => _files.Keys.Where(path => path.StartsWith(directory, StringComparison.OrdinalIgnoreCase));

    public long GetFileSize(string path)
        => _files.TryGetValue(path, out byte[]? content) ? content.LongLength : 0;

    public DateTimeOffset GetLastWriteTimeUtc(string path) => DateTimeOffset.UtcNow;
}
