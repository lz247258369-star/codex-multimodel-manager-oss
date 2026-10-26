using System.Text;
using Router.Core.Abstractions;

namespace Router.Core.Tests.Fakes;

/// <summary>
/// In-memory file system with fault injection for atomic-write and migration
/// failure paths. Never touches a real directory.
/// </summary>
public sealed class FakeFileSystem : IFileSystem
{
    private readonly object _sync = new();
    private readonly Dictionary<string, byte[]> _files = new(StringComparer.OrdinalIgnoreCase);

    public bool FailNextWrite { get; set; }

    public bool FailNextReplace { get; set; }

    public bool FailNextMove { get; set; }

    public bool FailNextCopy { get; set; }

    /// <summary>Invoked immediately after a successful atomic replace (post-commit hook for tests).</summary>
    public Action? OnAfterReplace { get; set; }

    /// <summary>When set, the Nth ReadAllBytesAsync call throws IOException.</summary>
    public int FailReadAllBytesOnCall { get; set; } = -1;

    private int _readAllBytesCalls;

    public void SeedFile(string path, string content)
    {
        lock (_sync)
        {
            _files[path] = Encoding.UTF8.GetBytes(content);
        }
    }

    public bool HasFile(string path)
    {
        lock (_sync)
        {
            return _files.ContainsKey(path);
        }
    }

    public string? ReadFileText(string path)
    {
        lock (_sync)
        {
            return _files.TryGetValue(path, out byte[]? bytes) ? Encoding.UTF8.GetString(bytes) : null;
        }
    }

    public IReadOnlyList<string> Files
    {
        get
        {
            lock (_sync)
            {
                return _files.Keys.ToArray();
            }
        }
    }

    public bool FileExists(string path)
    {
        lock (_sync)
        {
            return _files.ContainsKey(path);
        }
    }

    public bool DirectoryExists(string path)
        => Files.Any(file => file.StartsWith(path.TrimEnd('\\', '/') + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));

    public void CreateDirectory(string path)
    {
        // Directories are implicit in this in-memory model.
    }

    public IEnumerable<string> EnumerateFiles(string directory, string pattern)
        => Files.Where(file => file.StartsWith(directory, StringComparison.OrdinalIgnoreCase)
            && Path.GetFileName(file).StartsWith(pattern.Trim('*'), StringComparison.OrdinalIgnoreCase));

    public void DeleteFile(string path)
    {
        lock (_sync)
        {
            _files.Remove(path);
        }
    }

    public void CopyFile(string sourcePath, string destinationPath, bool overwrite)
    {
        if (FailNextCopy)
        {
            FailNextCopy = false;
            throw new IOException("Fault-injected copy failure.");
        }

        lock (_sync)
        {
            if (!_files.TryGetValue(sourcePath, out byte[]? content))
            {
                throw new FileNotFoundException("Source not found.", sourcePath);
            }

            if (!overwrite && _files.ContainsKey(destinationPath))
            {
                throw new IOException("Destination exists.");
            }

            _files[destinationPath] = content.ToArray();
        }
    }

    public void MoveFile(string sourcePath, string destinationPath, bool overwrite)
    {
        if (FailNextMove)
        {
            FailNextMove = false;
            throw new IOException("Fault-injected move failure.");
        }

        lock (_sync)
        {
            if (!_files.TryGetValue(sourcePath, out byte[]? content))
            {
                throw new FileNotFoundException("Source not found.", sourcePath);
            }

            if (!overwrite && _files.ContainsKey(destinationPath))
            {
                throw new IOException("Destination exists.");
            }

            _files.Remove(sourcePath);
            _files[destinationPath] = content;
            OnAfterReplace?.Invoke();
        }
    }

    public void ReplaceFile(string sourcePath, string destinationPath)
    {
        if (FailNextReplace)
        {
            FailNextReplace = false;
            throw new IOException("Fault-injected replace failure.");
        }

        lock (_sync)
        {
            if (!_files.TryGetValue(sourcePath, out byte[]? content))
            {
                throw new FileNotFoundException("Source not found.", sourcePath);
            }

            _files.Remove(sourcePath);
            _files[destinationPath] = content;
            OnAfterReplace?.Invoke();
        }
    }

    public Task<string> ReadAllTextAsync(string path, CancellationToken cancellationToken)
        => Task.FromResult(ReadFileText(path) ?? throw new FileNotFoundException("File not found.", path));

    public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken)
    {
        _readAllBytesCalls++;
        if (FailReadAllBytesOnCall > 0 && _readAllBytesCalls == FailReadAllBytesOnCall)
        {
            throw new IOException("Fault-injected read failure.");
        }

        lock (_sync)
        {
            if (!_files.TryGetValue(path, out byte[]? content))
            {
                throw new FileNotFoundException("File not found.", path);
            }

            return Task.FromResult(content.ToArray());
        }
    }

    public Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken)
    {
        if (FailNextWrite)
        {
            FailNextWrite = false;
            throw new IOException("Fault-injected write failure.");
        }

        lock (_sync)
        {
            if (_files.ContainsKey(path))
            {
                throw new IOException("Temp file already exists.");
            }

            _files[path] = content.ToArray();
        }

        return Task.CompletedTask;
    }

    public string CreateTempPath(string directory)
        => Path.Combine(directory, $".tmp-{Guid.NewGuid():N}");
}
