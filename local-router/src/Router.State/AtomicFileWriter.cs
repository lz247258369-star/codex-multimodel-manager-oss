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
    // transiently. One budget for every retryable failure: three retries, 175 ms
    // in total, shared by ERROR_SHARING_VIOLATION and ERROR_UNABLE_TO_REMOVE_REPLACED.
    private static readonly TimeSpan[] SharingViolationRetryDelays =
        [TimeSpan.FromMilliseconds(25), TimeSpan.FromMilliseconds(50), TimeSpan.FromMilliseconds(100)];

    // ERROR_SHARING_VIOLATION (32) as the HRESULT File.Replace reports it.
    private const int SharingViolationHResult = unchecked((int)0x80070020);

    // OSS-M4-2-HOTFIX2-FIX1: ERROR_UNABLE_TO_REMOVE_REPLACED (1175). ReplaceFile
    // could not move the replaced file aside; Windows documents that the replaced
    // and the replacement file then both keep their original names. The related
    // 1176 and 1177 leave the replaced file missing or renamed and are never retried.
    private const int UnableToRemoveReplacedHResult = unchecked((int)0x80070497);

    /// <summary>
    /// Replaces the target with the fully written temp file. Only an
    /// <see cref="IOException"/> carrying exactly ERROR_SHARING_VIOLATION or
    /// ERROR_UNABLE_TO_REMOVE_REPLACED is retried, within one shared budget: on
    /// those failures File.Replace has left both files under their names, so the
    /// same replace is attempted again. A 1175 is retried only while the target
    /// and the temp file are both still present; that presence check guards
    /// against an undocumented outcome and is not a proof that either file is
    /// unchanged. Every other failure, and the last retryable failure once the
    /// budget is exhausted, propagates unchanged. The target is never deleted or
    /// written in place.
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
            catch (IOException error) when (retry < SharingViolationRetryDelays.Length
                && (error.HResult == SharingViolationHResult || error.HResult == UnableToRemoveReplacedHResult))
            {
                if (error.HResult == UnableToRemoveReplacedHResult
                    && !BothReplaceFilesPresent(fileSystem, tempPath, targetPath))
                {
                    throw;
                }

                cancellationToken.ThrowIfCancellationRequested();
                await Task.Delay(SharingViolationRetryDelays[retry], cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
            }
        }
    }

    // Any failure of the check itself counts as "not present": the original
    // replace failure is then reported through the existing failure path.
    private static bool BothReplaceFilesPresent(IFileSystem fileSystem, string tempPath, string targetPath)
    {
        try
        {
            return fileSystem.FileExists(targetPath) && fileSystem.FileExists(tempPath);
        }
        catch (Exception)
        {
            return false;
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
