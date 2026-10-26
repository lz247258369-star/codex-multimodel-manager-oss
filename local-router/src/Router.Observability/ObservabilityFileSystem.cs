namespace Router.Observability;

/// <summary>Production file-system implementation for Router-owned log paths.</summary>
public sealed class ObservabilityFileSystem : IObservabilityFileSystem
{
    public bool FileExists(string path) => File.Exists(path);

    public bool DirectoryExists(string path) => Directory.Exists(path);

    public void CreateDirectory(string path) => Directory.CreateDirectory(path);

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

    public void MoveFile(string sourcePath, string destinationPath, bool overwrite)
        => File.Move(sourcePath, destinationPath, overwrite);

    public void DeleteFile(string path) => File.Delete(path);

    public IEnumerable<string> EnumerateFiles(string directory, string pattern)
        => Directory.Exists(directory) ? Directory.EnumerateFiles(directory, pattern) : [];

    public long GetFileSize(string path) => new FileInfo(path).Length;

    public DateTimeOffset GetLastWriteTimeUtc(string path) => File.GetLastWriteTimeUtc(path);
}
