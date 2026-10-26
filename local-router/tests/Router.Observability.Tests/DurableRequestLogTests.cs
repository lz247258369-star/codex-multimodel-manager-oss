using Router.Observability;
using Xunit;

namespace Router.Observability.Tests;

public sealed class DurableRequestLogTests
{
    internal static DateTimeOffset Now = DateTimeOffset.Parse("2026-09-03T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal);

    [Fact]
    public async Task Write_and_snapshot_are_safe()
    {
        var fs = new FakeObservabilityFileSystem();
        var options = ObservabilityOptions.Create(@"C:\RouterOwned\logs", 1024 * 1024, 8, TimeSpan.FromDays(7), 64);
        var log = new DurableRequestLog(options, fs, () => Now);

        bool ok = await log.WriteSafeAsync(SafeRequestRecordTestsHelpers.Record("req_1"), CancellationToken.None);

        Assert.True(ok);
        LogStateSnapshot snapshot = log.Snapshot();
        Assert.Equal(1, snapshot.FileCount);
        Assert.True(snapshot.TotalBytes > 0);
    }

    [Fact]
    public async Task Rotation_keeps_file_count_bounded()
    {
        var fs = new FakeObservabilityFileSystem();
        var options = ObservabilityOptions.Create(@"C:\RouterOwned\logs", 1024 * 1024, 2, TimeSpan.FromDays(7), 64);
        var log = new DurableRequestLog(options, fs, () => Now);

        for (int index = 1; index <= 4; index++)
        {
            Now = Now.AddSeconds(1);
            await log.WriteSafeAsync(SafeRequestRecordTestsHelpers.Record("req_" + index), CancellationToken.None);
        }

        Assert.Equal(2, log.Snapshot().FileCount);
    }

    [Fact]
    public async Task Retention_removes_old_records()
    {
        var fs = new FakeObservabilityFileSystem();
        var options = ObservabilityOptions.Create(@"C:\RouterOwned\logs", 1024 * 1024, 8, TimeSpan.FromMinutes(5), 64);
        var log = new DurableRequestLog(options, fs, () => Now);
        await log.WriteSafeAsync(SafeRequestRecordTestsHelpers.Record("req_old"), CancellationToken.None);

        Now = Now.AddMinutes(6);
        await log.WriteSafeAsync(SafeRequestRecordTestsHelpers.Record("req_new"), CancellationToken.None);

        Assert.Equal(1, log.Snapshot().FileCount);
    }

    [Fact]
    public async Task Corrupt_record_is_quarantined()
    {
        var fs = new FakeObservabilityFileSystem();
        var options = ObservabilityOptions.Create(@"C:\RouterOwned\logs", 1024 * 1024, 8, TimeSpan.FromDays(7), 64);
        fs.Contents[@"C:\RouterOwned\logs\request-1-req_corrupt.json"] = "{ nope"u8.ToArray();

        var log = new DurableRequestLog(options, fs, () => Now);
        int recovered = await log.RecoverCorruptAsync(CancellationToken.None);

        Assert.Equal(1, recovered);
        Assert.True(fs.Contents.ContainsKey(@"C:\RouterOwned\logs\quarantine\request-1-req_corrupt.json"));
    }

    [Fact]
    public async Task Logging_failure_is_non_fatal()
    {
        var fs = new FailingObservabilityFileSystem();
        var options = ObservabilityOptions.Create(@"C:\RouterOwned\logs", 1024 * 1024, 8, TimeSpan.FromDays(7), 64);
        var log = new DurableRequestLog(options, fs, () => Now);

        bool written = await log.WriteSafeAsync(SafeRequestRecordTestsHelpers.Record("req_fail"), CancellationToken.None);

        Assert.False(written);
        Assert.True(log.Snapshot().Degraded);
    }

    [Fact]
    public async Task Concurrent_writes_never_corrupt_or_lose_records()
    {
        var fs = new FakeObservabilityFileSystem();
        var options = ObservabilityOptions.Create(@"C:\RouterOwned\logs", 1024 * 1024, 200, TimeSpan.FromDays(7), 64);
        var log = new DurableRequestLog(options, fs, () => Now);

        Task<bool>[] writes = Enumerable.Range(1, 50)
            .Select(index => log.WriteSafeAsync(SafeRequestRecordTestsHelpers.Record("req_" + index), CancellationToken.None))
            .ToArray();

        bool[] results = await Task.WhenAll(writes);
        Assert.All(results, Assert.True);
        Assert.Equal(50, log.Snapshot().FileCount);
    }
}

internal static class SafeRequestRecordTestsHelpers
{
    public static SafeRequestRecord Record(string requestId)
        => SafeRequestRecord.Create(
            requestId,
            "trc_" + requestId,
            DateTimeOffset.Parse("2026-09-03T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal),
            DateTimeOffset.Parse("2026-09-03T00:00:01Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal),
            Router.Core.Lifecycle.RequestState.Completed,
            errorCode: null,
            routeId: "route.test",
            providerId: "mm_openrouter",
            protocolId: "protocol.openai.responses.v1",
            httpStatus: 200);
}

internal sealed class FakeObservabilityFileSystem : IObservabilityFileSystem
{
    public Dictionary<string, byte[]> Contents { get; } = new(StringComparer.Ordinal);
    public int ReadAllBytesCalls { get; private set; }
    private readonly Dictionary<string, DateTimeOffset> _modifiedTimes = new(StringComparer.Ordinal);

    public bool FileExists(string path) => Contents.ContainsKey(path);

    public bool DirectoryExists(string path) => Contents.Keys.Any(key => key.StartsWith(path.TrimEnd('\\') + "\\", StringComparison.Ordinal));

    public void CreateDirectory(string path)
    {
    }

    public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken)
    {
        ReadAllBytesCalls++;
        return Task.FromResult(Contents[path]);
    }

    public Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken)
    {
        Contents[path] = content;
        _modifiedTimes[path] = DurableRequestLogTests.Now;
        return Task.CompletedTask;
    }

    public string CreateTempPath(string directory) => Path.Combine(directory, ".tmp-" + Guid.NewGuid().ToString("N"));

    public void MoveFile(string sourcePath, string destinationPath, bool overwrite)
    {
        if (Contents.Remove(sourcePath, out byte[]? content))
        {
            Contents[destinationPath] = content;
            if (_modifiedTimes.Remove(sourcePath, out DateTimeOffset modified))
            {
                _modifiedTimes[destinationPath] = modified;
            }
        }
    }

    public void DeleteFile(string path)
    {
        Contents.Remove(path);
        _modifiedTimes.Remove(path);
    }

    public IEnumerable<string> EnumerateFiles(string directory, string pattern)
        => Contents.Keys.Where(key => key.StartsWith(directory.TrimEnd('\\') + "\\", StringComparison.Ordinal) && key.EndsWith(".json", StringComparison.Ordinal));

    public long GetFileSize(string path) => Contents.TryGetValue(path, out byte[]? content) ? content.LongLength : 0;

    public DateTimeOffset GetLastWriteTimeUtc(string path)
        => _modifiedTimes.TryGetValue(path, out DateTimeOffset modified) ? modified : DurableRequestLogTests.Now;
}

internal sealed class FailingObservabilityFileSystem : IObservabilityFileSystem
{
    public bool FileExists(string path) => false;

    public bool DirectoryExists(string path) => true;

    public void CreateDirectory(string path)
    {
    }

    public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken) => throw new InvalidOperationException();

    public Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken) => throw new IOException("disk full");

    public string CreateTempPath(string directory) => Path.Combine(directory, ".tmp");

    public void MoveFile(string sourcePath, string destinationPath, bool overwrite) => throw new IOException();

    public void DeleteFile(string path)
    {
    }

    public IEnumerable<string> EnumerateFiles(string directory, string pattern) => [];

    public long GetFileSize(string path) => 0;

    public DateTimeOffset GetLastWriteTimeUtc(string path) => DateTimeOffset.UtcNow;
}
