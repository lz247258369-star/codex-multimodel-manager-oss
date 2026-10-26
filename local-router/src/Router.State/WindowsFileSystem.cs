using Router.Core.Abstractions;

namespace Router.State;

/// <summary>
/// Real file-system implementation. Writes use a unique temp file with
/// write-through semantics; replaces use <see cref="File.Replace"/> when the
/// destination exists for atomic swap on Windows.
/// </summary>
public sealed class WindowsFileSystem : IFileSystem
{
    public bool FileExists(string path) => File.Exists(path);

    public bool DirectoryExists(string path) => Directory.Exists(path);

    public void CreateDirectory(string path) => Directory.CreateDirectory(path);

    public IEnumerable<string> EnumerateFiles(string directory, string pattern)
        => Directory.EnumerateFiles(directory, pattern);

    public void DeleteFile(string path) => File.Delete(path);

    public void CopyFile(string sourcePath, string destinationPath, bool overwrite)
        => File.Copy(sourcePath, destinationPath, overwrite);

    public void MoveFile(string sourcePath, string destinationPath, bool overwrite)
        => File.Move(sourcePath, destinationPath, overwrite);

    public void ReplaceFile(string sourcePath, string destinationPath)
        => File.Replace(sourcePath, destinationPath, null);

    public Task<string> ReadAllTextAsync(string path, CancellationToken cancellationToken)
        => File.ReadAllTextAsync(path, cancellationToken);

    public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken)
        => File.ReadAllBytesAsync(path, cancellationToken);

    public async Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            bufferSize: 4096,
            FileOptions.Asynchronous | FileOptions.WriteThrough);
        await stream.WriteAsync(content, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public string CreateTempPath(string directory)
        => Path.Combine(directory, $".tmp-{Guid.NewGuid():N}");
}
