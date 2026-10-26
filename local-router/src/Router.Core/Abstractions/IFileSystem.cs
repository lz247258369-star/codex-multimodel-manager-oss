namespace Router.Core.Abstractions;

/// <summary>
/// Minimal file-system abstraction used by configuration/state persistence so
/// tests can inject in-memory or fault-injecting implementations. Paths are
/// always caller-provided; the abstraction never resolves user home paths.
/// </summary>
public interface IFileSystem
{
    bool FileExists(string path);

    bool DirectoryExists(string path);

    void CreateDirectory(string path);

    IEnumerable<string> EnumerateFiles(string directory, string pattern);

    void DeleteFile(string path);

    void CopyFile(string sourcePath, string destinationPath, bool overwrite);

    void MoveFile(string sourcePath, string destinationPath, bool overwrite);

    /// <summary>Atomically replaces an existing destination (File.Replace semantics).</summary>
    void ReplaceFile(string sourcePath, string destinationPath);

    Task<string> ReadAllTextAsync(string path, CancellationToken cancellationToken);

    Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken);

    Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken);

    /// <summary>Creates a unique temp path inside the same directory as the target file.</summary>
    string CreateTempPath(string directory);
}
