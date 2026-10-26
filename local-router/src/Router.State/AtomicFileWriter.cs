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
                fileSystem.ReplaceFile(tempPath, targetPath);
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
