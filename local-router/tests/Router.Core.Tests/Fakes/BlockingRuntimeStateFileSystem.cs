using System.Collections.Concurrent;
using System.Text;
using Router.Core.Abstractions;
using Router.State;

namespace Router.Core.Tests.Fakes;

/// <summary>
/// Deterministic startup-window seam for the Host readiness tests. Every byte
/// of real I/O still goes to the production Windows file system (so the sandbox
/// on disk stays authoritative), but the durable runtime READY commit can be
/// held open: the moment that JSON is about to be written the fake signals a
/// completion source and then blocks on the caller's cancellation token.
///
/// Only cancellation can release the held write, which is exactly the race the
/// production Host must survive. No sleep, no delay-based guessing, no
/// probability: the test decides when the window is open.
/// </summary>
public sealed class BlockingRuntimeStateFileSystem : IFileSystem
{
    private readonly WindowsFileSystem _inner = new();
    private readonly ConcurrentQueue<string> _writtenContents = new();

    /// <summary>Completes once the durable runtime READY write has been entered.</summary>
    public TaskCompletionSource ReadyStateWriteStarted { get; } =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    /// <summary>Number of write attempts whose content matched <paramref name="needle"/>.</summary>
    public int CountWritesContaining(string needle)
        => _writtenContents.Count(content => content.Contains(needle, StringComparison.Ordinal));

    public bool FileExists(string path) => _inner.FileExists(path);

    public bool DirectoryExists(string path) => _inner.DirectoryExists(path);

    public void CreateDirectory(string path) => _inner.CreateDirectory(path);

    public IEnumerable<string> EnumerateFiles(string directory, string pattern)
        => _inner.EnumerateFiles(directory, pattern);

    public void DeleteFile(string path) => _inner.DeleteFile(path);

    public void CopyFile(string sourcePath, string destinationPath, bool overwrite)
        => _inner.CopyFile(sourcePath, destinationPath, overwrite);

    public void MoveFile(string sourcePath, string destinationPath, bool overwrite)
        => _inner.MoveFile(sourcePath, destinationPath, overwrite);

    public void ReplaceFile(string sourcePath, string destinationPath)
        => _inner.ReplaceFile(sourcePath, destinationPath);

    public Task<string> ReadAllTextAsync(string path, CancellationToken cancellationToken)
        => _inner.ReadAllTextAsync(path, cancellationToken);

    public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken)
        => _inner.ReadAllBytesAsync(path, cancellationToken);

    public async Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken)
    {
        string text = Encoding.UTF8.GetString(content);
        _writtenContents.Enqueue(text);

        if (text.Contains("\"lifecycle\":\"READY\"", StringComparison.Ordinal))
        {
            ReadyStateWriteStarted.TrySetResult();

            // Hold the durable READY commit open for as long as the caller wants
            // the startup window to last; the token is the only release path, so
            // AtomicFileWriter observes a real cancellation and cleans its temp.
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
        }

        await _inner.WriteAllBytesAsync(path, content, cancellationToken).ConfigureAwait(false);
    }

    public string CreateTempPath(string directory) => _inner.CreateTempPath(directory);
}
