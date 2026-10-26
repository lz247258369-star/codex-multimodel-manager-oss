namespace Router.Observability;

/// <summary>
/// Durable, bounded, Router-owned local log for safe capability failure
/// diagnostics. It is deliberately separate from <see cref="DurableRequestLog"/>:
/// the redacted request-log schema is unchanged, and diagnostics never enter the
/// control-plane request surface.
///
/// Guarantees:
/// <list type="bullet">
///   <item>one JSON file per diagnostic, written atomically (temp + move);</item>
///   <item>best effort: a write failure returns false and never changes request
///   semantics, never throws into the caller, and never crashes the router;</item>
///   <item>bounded retention: at most <see cref="MaxRetainedFiles"/> files, with
///   the oldest pruned first;</item>
///   <item>strictly capped file size, and only the Router-owned diagnostics
///   directory is ever touched.</item>
/// </list>
/// </summary>
public sealed class SafeFailureDiagnosticLog
{
    /// <summary>Bounded retention: the newest 64 diagnostics are kept.</summary>
    public const int MaxRetainedFiles = 64;

    /// <summary>Hard per-file ceiling; a diagnostic is a handful of short fields.</summary>
    public const int MaxFileBytes = 4096;

    /// <summary>File-name prefix; only this prefix is ever enumerated or pruned.</summary>
    public const string FilePrefix = "capability-";

    private readonly object _sync = new();
    private readonly string _directory;
    private readonly IObservabilityFileSystem _fileSystem;
    private readonly Func<DateTimeOffset> _clock;
    private long _writtenCount;
    private long _droppedCount;
    private bool _degraded;

    public SafeFailureDiagnosticLog(
        string directory,
        IObservabilityFileSystem? fileSystem = null,
        Func<DateTimeOffset>? clock = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(directory);
        _directory = Path.GetFullPath(directory);
        _fileSystem = fileSystem ?? new ObservabilityFileSystem();
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public string Directory => _directory;

    public long WrittenCount => Interlocked.Read(ref _writtenCount);

    public long DroppedCount => Interlocked.Read(ref _droppedCount);

    public bool Degraded
    {
        get
        {
            lock (_sync)
            {
                return _degraded;
            }
        }
    }

    /// <summary>
    /// Records one safe diagnostic. The caller has already applied the
    /// diagnostic contract; this method re-validates, writes atomically, prunes,
    /// and reports success. It never throws for I/O problems.
    /// </summary>
    public bool TryWrite(string? requestId, string? errorCode, string? safeParam)
    {
        SafeFailureDiagnosticRecord? record = SafeFailureDiagnosticRecord.TryCreate(
            requestId,
            errorCode,
            safeParam,
            _clock());
        return WriteRecord(record);
    }

    /// <summary>
    /// DSR7-C-FIX3: records a schema-v2 diagnostic for a rejected tool type. The
    /// class must be a fixed taxonomy label and the path must be the tool-type
    /// shape; otherwise the diagnostic is dropped.
    /// </summary>
    public bool TryWriteClassified(string? requestId, string? errorCode, string? safeParam, string? safeClass)
    {
        SafeFailureDiagnosticRecord? record = SafeFailureDiagnosticRecord.TryCreateClassified(
            requestId,
            errorCode,
            safeParam,
            safeClass,
            _clock());
        return WriteRecord(record);
    }

    /// <summary>
    /// DSR7-C-FIX4: records a schema-v3 diagnostic for a rejected custom tool.
    /// The class must be <c>custom</c>, the path must be the tool-type shape, and
    /// the identity must be a fixed known label; otherwise nothing is written.
    /// </summary>
    public bool TryWriteIdentified(string? requestId, string? errorCode, string? safeParam, string? safeClass, string? safeIdentity)
    {
        SafeFailureDiagnosticRecord? record = SafeFailureDiagnosticRecord.TryCreateIdentified(
            requestId,
            errorCode,
            safeParam,
            safeClass,
            safeIdentity,
            _clock());
        return WriteRecord(record);
    }

    private bool WriteRecord(SafeFailureDiagnosticRecord? record)
    {
        if (record is null)
        {
            Interlocked.Increment(ref _droppedCount);
            return false;
        }

        byte[] content = record.ToJsonBytes();
        if (content.Length > MaxFileBytes)
        {
            // Defensive: the record is a handful of short fields, so an oversized
            // payload can only mean an unexpected input shape -> drop it.
            Interlocked.Increment(ref _droppedCount);
            return false;
        }

        try
        {
            lock (_sync)
            {
                _fileSystem.CreateDirectory(_directory);
                string stamp = _clock().ToUnixTimeMilliseconds().ToString(System.Globalization.CultureInfo.InvariantCulture);
                string target = Path.Combine(
                    _directory,
                    $"{FilePrefix}{stamp}-{Sanitize(record.RequestId)}.json");
                string temp = _fileSystem.CreateTempPath(_directory);
                try
                {
                    _fileSystem.WriteAllBytesAsync(temp, content, CancellationToken.None).GetAwaiter().GetResult();
                    _fileSystem.MoveFile(temp, target, overwrite: true);
                }
                catch
                {
                    if (_fileSystem.FileExists(temp))
                    {
                        try
                        {
                            _fileSystem.DeleteFile(temp);
                        }
                        catch
                        {
                            // Best effort cleanup only.
                        }
                    }

                    throw;
                }

                PruneLocked();
            }

            Interlocked.Increment(ref _writtenCount);
            return true;
        }
        catch (Exception)
        {
            lock (_sync)
            {
                _degraded = true;
            }

            Interlocked.Increment(ref _droppedCount);
            return false;
        }
    }

    /// <summary>Number of retained diagnostic files (bounded by MaxRetainedFiles).</summary>
    public int RetainedFileCount()
    {
        try
        {
            lock (_sync)
            {
                return _fileSystem.EnumerateFiles(_directory, FilePrefix + "*.json").Count();
            }
        }
        catch (Exception)
        {
            return 0;
        }
    }

    private void PruneLocked()
    {
        // Deterministic pruning: newest names kept, oldest removed first.
        string[] files = _fileSystem
            .EnumerateFiles(_directory, FilePrefix + "*.json")
            .OrderByDescending(static path => path, StringComparer.Ordinal)
            .ToArray();

        for (int index = 0; index < files.Length; index++)
        {
            if (index < MaxRetainedFiles)
            {
                continue;
            }

            try
            {
                _fileSystem.DeleteFile(files[index]);
            }
            catch
            {
                _degraded = true;
            }
        }
    }

    /// <summary>
    /// Request ids are already validated as short router-generated ids; this
    /// keeps the file name defensively inert by removing any path characters.
    /// </summary>
    private static string Sanitize(string value)
    {
        Span<char> buffer = stackalloc char[value.Length];
        int length = 0;
        foreach (char c in value)
        {
            buffer[length++] = c is (>= 'a' and <= 'z') or (>= 'A' and <= 'Z') or (>= '0' and <= '9') or '.' or '_' or '-'
                ? c
                : '_';
        }

        return new string(buffer[..length]);
    }
}
