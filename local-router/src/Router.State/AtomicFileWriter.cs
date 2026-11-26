using Router.Core.Abstractions;
using Router.Core.Errors;

namespace Router.State;

/// <summary>
/// Temp + flush + atomic replace writer. On failure the previous good file is
/// preserved and the temp file is removed.
/// </summary>
public sealed class AtomicFileWriter
{
    public static async Task<RouterError?> WriteAsync(
        string targetPath,
        byte[] content,
        IFileSystem fileSystem,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(targetPath);
        ArgumentNullException.ThrowIfNull(content);
        ArgumentNullException.ThrowIfNull(fileSystem);

        string directory = Path.GetDirectoryName(targetPath)
            ?? throw new ArgumentException("Target path has no directory.", nameof(targetPath));
        string? tempPath = null;
        StatePersistenceOperation operation = StatePersistenceOperation.CreateDirectory;

        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            fileSystem.CreateDirectory(directory);
            operation = StatePersistenceOperation.CreateTempPath;
            tempPath = fileSystem.CreateTempPath(directory);
            operation = StatePersistenceOperation.WriteAllBytes;
            await fileSystem.WriteAllBytesAsync(tempPath, content, cancellationToken).ConfigureAwait(false);
            operation = StatePersistenceOperation.FileExists;
            if (fileSystem.FileExists(targetPath))
            {
                operation = StatePersistenceOperation.ReplaceFile;
                await ReplaceWithBoundedSharingRetryAsync(fileSystem, tempPath, targetPath, cancellationToken).ConfigureAwait(false);
            }
            else
            {
                operation = StatePersistenceOperation.MoveFile;
                fileSystem.MoveFile(tempPath, targetPath, overwrite: false);
            }

            return null;
        }
        catch (OperationCanceledException)
        {
            TryDeleteTemp(fileSystem, tempPath);
            throw;
        }
        catch (Exception error)
        {
            StatePersistenceDiagnostic.Report(targetPath, operation, error);
            TryDeleteTemp(fileSystem, tempPath);
            return StateErrors.StateWriteFailed(Path.GetFileName(targetPath));
        }
    }

    // OSS-M4-2-HOTFIX2: delays before each retry of an atomic replace that failed
    // with a Windows sharing violation (another process briefly held the target
    // open without FileShare.Delete). Three retries, 175 ms in total.
    private static readonly TimeSpan[] SharingViolationRetryDelays =
        [TimeSpan.FromMilliseconds(25), TimeSpan.FromMilliseconds(50), TimeSpan.FromMilliseconds(100)];

    // ERROR_SHARING_VIOLATION (32) as the HRESULT File.Replace reports it.
    private const int SharingViolationHResult = unchecked((int)0x80070020);

    /// <summary>
    /// Replaces the target with the fully written temp file. Only an
    /// <see cref="IOException"/> carrying exactly ERROR_SHARING_VIOLATION is
    /// retried: on that failure File.Replace has changed neither file, so the
    /// same replace is attempted again. Every other failure, and the last
    /// sharing violation once the retries are exhausted, propagates unchanged.
    /// The target is never deleted or written in place.
    /// </summary>
    private static async Task ReplaceWithBoundedSharingRetryAsync(
        IFileSystem fileSystem,
        string tempPath,
        string targetPath,
        CancellationToken cancellationToken)
    {
        for (int retry = 0; ; retry++)
        {
            try
            {
                fileSystem.ReplaceFile(tempPath, targetPath);
                return;
            }
            catch (IOException error) when (error.HResult == SharingViolationHResult
                && retry < SharingViolationRetryDelays.Length)
            {
                cancellationToken.ThrowIfCancellationRequested();
                await Task.Delay(SharingViolationRetryDelays[retry], cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
            }
        }
    }

    private static void TryDeleteTemp(IFileSystem fileSystem, string? tempPath)
    {
        if (tempPath is null) { return; }
        try
        {
            if (fileSystem.FileExists(tempPath))
            {
                fileSystem.DeleteFile(tempPath);
            }
        }
        catch
        {
            // Best-effort cleanup; the target file is never touched.
        }
    }
}
