namespace Router.Observability;

/// <summary>
/// Minimal file-system boundary for observability storage. Production uses
/// user-scoped Router-owned paths; tests inject deterministic fakes.
/// </summary>
public interface IObservabilityFileSystem
{
    bool FileExists(string path);

    bool DirectoryExists(string path);

    void CreateDirectory(string path);

    Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken);

    Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken);

    string CreateTempPath(string directory);

    void MoveFile(string sourcePath, string destinationPath, bool overwrite);

    void DeleteFile(string path);

    IEnumerable<string> EnumerateFiles(string directory, string pattern);

    long GetFileSize(string path);

    DateTimeOffset GetLastWriteTimeUtc(string path);
}
