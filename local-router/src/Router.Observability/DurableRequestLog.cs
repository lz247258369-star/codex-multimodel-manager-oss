using System.Text.Json;
using System.Text.Json.Serialization;

namespace Router.Observability;

/// <summary>
/// Thread-safe durable request log. Each request is written atomically as one
/// JSON file; rotation/pruning is deterministic and bounded. Logging failures
/// are non-fatal and never change request semantics.
/// </summary>
public sealed class DurableRequestLog
{
    public const int DefaultRecentMaxCount = 20;
    public const int HardRecentMaxCount = 100;

    /// <summary>
    /// Hard ceiling on the number of newest log files inspected per recent
    /// read, so an unexpectedly large directory can never cause an unbounded
    /// scan.
    /// </summary>
    public const int MaxRecentScanFiles = 256;

    private static readonly JsonSerializerOptions ReadOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = false,
        WriteIndented = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    };

    private readonly object _sync = new();
    private readonly ObservabilityOptions _options;
    private readonly IObservabilityFileSystem _fileSystem;
    private readonly Func<DateTimeOffset> _clock;
    private bool _degraded;
    private string? _lastErrorCode;

    public DurableRequestLog(
        ObservabilityOptions options,
        IObservabilityFileSystem? fileSystem = null,
        Func<DateTimeOffset>? clock = null)
    {
        _options = options;
        _fileSystem = fileSystem ?? new ObservabilityFileSystem();
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public async Task<bool> WriteAsync(RedactedRequestRecord record, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(record);
        try
        {
            byte[] content = JsonSerializer.SerializeToUtf8Bytes(record, ObservabilityJson.Options);
            lock (_sync)
            {
                _fileSystem.CreateDirectory(_options.LogDirectory);
                long now = _clock().ToUnixTimeMilliseconds();
                string target = Path.Combine(_options.LogDirectory, $"request-{now}-{record.RequestId}.json");
                string temp = _fileSystem.CreateTempPath(_options.LogDirectory);
                try
                {
                    _fileSystem.WriteAllBytesAsync(temp, content, cancellationToken).GetAwaiter().GetResult();
                    _fileSystem.MoveFile(temp, target, overwrite: true);
                }
                catch
                {
                    if (_fileSystem.FileExists(temp))
                    {
                        _fileSystem.DeleteFile(temp);
                    }

                    throw;
                }

                PruneLocked();
            }

            return true;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            lock (_sync)
            {
                _degraded = true;
                _lastErrorCode = "log_write_failed";
            }

            return false;
        }
    }

    /// <summary>
    /// Writes only after the redaction boundary succeeds. A redaction failure
    /// drops the event and never reaches the durable sink.
    /// </summary>
    public Task<bool> WriteSafeAsync(SafeRequestRecord record, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(record);
        try
        {
            RedactedRequestRecord redacted = RedactionBoundary.Redact(record);
            return WriteAsync(redacted, cancellationToken);
        }
        catch (RedactionFailureException)
        {
            return Task.FromResult(false);
        }
    }

    public LogStateSnapshot Snapshot()
    {
        lock (_sync)
        {
            long total = 0;
            int count = 0;
            foreach (string file in _fileSystem.EnumerateFiles(_options.LogDirectory, "request-*.json"))
            {
                total += _fileSystem.GetFileSize(file);
                count++;
            }

            return new LogStateSnapshot
            {
                FileCount = count,
                TotalBytes = total,
                Degraded = _degraded,
                LastErrorCode = _lastErrorCode,
            };
        }
    }

    public async Task<int> RecoverCorruptAsync(CancellationToken cancellationToken)
    {
        lock (_sync)
        {
            _fileSystem.CreateDirectory(_options.LogDirectory);
        }

        int recovered = 0;
        string[] files = _fileSystem.EnumerateFiles(_options.LogDirectory, "request-*.json").ToArray();
        foreach (string file in files)
        {
            try
            {
                byte[] bytes = await _fileSystem.ReadAllBytesAsync(file, cancellationToken).ConfigureAwait(false);
                using JsonDocument document = JsonDocument.Parse(bytes);
                if (document.RootElement.ValueKind != JsonValueKind.Object)
                {
                    throw new JsonException("Not an object.");
                }
            }
            catch (JsonException)
            {
                string quarantineDirectory = Path.Combine(_options.LogDirectory, "quarantine");
                lock (_sync)
                {
                    _fileSystem.CreateDirectory(quarantineDirectory);
                    string destination = Path.Combine(quarantineDirectory, Path.GetFileName(file));
                    if (!_fileSystem.FileExists(destination))
                    {
                        _fileSystem.MoveFile(file, destination, overwrite: false);
                    }
                    else
                    {
                        _fileSystem.DeleteFile(file);
                    }
                }

                recovered++;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch
            {
                // Unreadable file is quarantined best-effort without crashing the router.
            }
        }

        return recovered;
    }

    /// <summary>
    /// Reads up to <paramref name="maxCount"/> most-recent safe durable records.
    /// The read is bounded, read-only, and failure-isolated: one oversized,
    /// corrupt, partially-written, or unreadable record never throws into the
    /// caller. Degradation is reported explicitly instead of raw exception
    /// details. No arbitrary path input is accepted; only the Router-owned log
    /// directory is ever read.
    /// </summary>
    public async Task<DurableRecentReadResult> ReadRecentAsync(
        int maxCount,
        CancellationToken cancellationToken)
    {
        if (maxCount is < 1 or > HardRecentMaxCount)
        {
            throw new ArgumentOutOfRangeException(nameof(maxCount), maxCount, "Recent read count must be between 1 and 100.");
        }

        lock (_sync)
        {
            _fileSystem.CreateDirectory(_options.LogDirectory);
        }

        SortedDictionary<string, string> newestCandidates = new(DescendingPathComparer.Instance);
        long totalSeen = 0;
        try
        {
            // Bounded candidate selection: keep only the newest
            // MaxRecentScanFiles paths while enumerating, so directory size can
            // never materialize an unbounded candidate array.
            foreach (string file in _fileSystem.EnumerateFiles(_options.LogDirectory, "request-*.json"))
            {
                totalSeen++;
                if (newestCandidates.Count < MaxRecentScanFiles)
                {
                    newestCandidates.Add(file, file);
                    continue;
                }

                // Descending iteration means the smallest (oldest) candidate is
                // the last entry.
                string oldest = newestCandidates.Last().Key;
                if (string.CompareOrdinal(file, oldest) > 0)
                {
                    newestCandidates.Remove(oldest);
                    newestCandidates.Add(file, file);
                }
            }
        }
        catch (Exception)
        {
            return DurableRecentReadResult.Unavailable();
        }

        bool scanLimited = totalSeen > MaxRecentScanFiles;
        var records = new List<RedactedRequestRecord>(Math.Min(maxCount, newestCandidates.Count));
        int skippedCorrupt = 0;
        int skippedOversized = 0;
        int skippedUnreadable = 0;

        foreach (string file in newestCandidates.Keys)
        {
            if (records.Count >= maxCount)
            {
                break;
            }

            try
            {
                long size = _fileSystem.GetFileSize(file);
                if (size <= 0 || size > _options.MaxFileBytes)
                {
                    skippedOversized++;
                    continue;
                }

                byte[] bytes = await _fileSystem.ReadAllBytesAsync(file, cancellationToken).ConfigureAwait(false);
                if (bytes.LongLength > _options.MaxFileBytes)
                {
                    skippedOversized++;
                    continue;
                }

                RedactedRequestRecord? record = JsonSerializer.Deserialize<RedactedRequestRecord>(bytes, ReadOptions);
                if (record is null || !IsValid(record))
                {
                    skippedCorrupt++;
                    continue;
                }

                records.Add(record);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (JsonException)
            {
                skippedCorrupt++;
            }
            catch (Exception)
            {
                // A file may disappear between enumeration and read (rotation);
                // count it as unreadable degradation, never an exception.
                skippedUnreadable++;
            }
        }

        var codes = new List<string>();
        if (skippedCorrupt > 0)
        {
            codes.Add("recent_record_corrupt");
        }

        if (skippedOversized > 0)
        {
            codes.Add("recent_record_oversized");
        }

        if (skippedUnreadable > 0)
        {
            codes.Add("recent_record_unreadable");
        }

        if (scanLimited)
        {
            codes.Add("recent_scan_limited");
        }

        return new DurableRecentReadResult
        {
            SchemaVersionValue = DurableRecentReadResult.SchemaVersion,
            Records = records,
            Degraded = codes.Count > 0,
            SkippedCorrupt = skippedCorrupt,
            SkippedOversized = skippedOversized,
            SkippedUnreadable = skippedUnreadable,
            ScanLimited = scanLimited,
            Codes = codes,
        };
    }

    private static bool IsValid(RedactedRequestRecord record)
    {
        if (record.SchemaVersion < 1
            || !IsValidId(record.RequestId)
            || !IsValidId(record.TraceId)
            || string.IsNullOrWhiteSpace(record.TerminalState)
            || record.TerminalState.Length > 32
            || record.DurationMs < 0
            || !DateTimeOffset.TryParse(
                record.StartedAt,
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.RoundtripKind,
                out _)
            || !DateTimeOffset.TryParse(
                record.CompletedAt,
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.RoundtripKind,
                out _))
        {
            return false;
        }

        return IsOptionalId(record.ClientId)
            && IsOptionalId(record.RouteId)
            && IsOptionalId(record.ProviderId)
            && IsOptionalId(record.ProtocolId)
            && IsOptionalId(record.ModelRouteId)
            && IsOptionalId(record.ErrorCode)
            && (record.HttpStatus is null || record.HttpStatus is >= 100 and <= 599)
            && record.AttemptCount >= 0
            && record.RetryCount >= 0
            && record.FallbackCount >= 0;
    }

    private static bool IsValidId(string value)
        => !string.IsNullOrWhiteSpace(value) && value.Length <= 128;

    private static bool IsOptionalId(string? value)
        => value is null || IsValidId(value);

    private sealed class DescendingPathComparer : IComparer<string>
    {
        public static DescendingPathComparer Instance { get; } = new();

        private DescendingPathComparer()
        {
        }

        public int Compare(string? x, string? y)
            => string.Compare(y ?? string.Empty, x ?? string.Empty, StringComparison.Ordinal);
    }

    private void PruneLocked()
    {
        DateTimeOffset now = _clock();
        string[] files = _fileSystem.EnumerateFiles(_options.LogDirectory, "request-*.json")
            .OrderByDescending(static path => path, StringComparer.Ordinal)
            .ToArray();

        for (int index = 0; index < files.Length; index++)
        {
            string file = files[index];
            DateTimeOffset modified = _fileSystem.GetLastWriteTimeUtc(file);
            bool tooOld = now - modified > _options.RetentionAge;
            bool tooMany = index >= _options.MaxFiles;
            if (tooOld || tooMany)
            {
                try
                {
                    _fileSystem.DeleteFile(file);
                }
                catch
                {
                    _degraded = true;
                    _lastErrorCode = "log_prune_failed";
                }
            }
        }
    }
}
