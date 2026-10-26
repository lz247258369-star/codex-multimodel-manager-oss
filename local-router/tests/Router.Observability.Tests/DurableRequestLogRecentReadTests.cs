using System.Text.Json;
using Xunit;

namespace Router.Observability.Tests;

/// <summary>
/// LR-14P safe bounded recent durable-log reader tests. Corrupt, oversized,
/// unreadable, and rotated records never crash or fail the read; degradation
/// is explicit and no arbitrary path input exists.
/// </summary>
public sealed class DurableRequestLogRecentReadTests
{
    private const string LogDirectory = @"C:\RouterOwned\logs";

    [Fact]
    public async Task Recent_read_returns_newest_records_in_bounded_order()
    {
        FakeObservabilityFileSystem fileSystem = new();
        for (int index = 1; index <= 5; index++)
        {
            SeedValid(fileSystem, index);
        }

        DurableRequestLog log = CreateLog(fileSystem);
        DurableRecentReadResult result = await log.ReadRecentAsync(3, CancellationToken.None);

        Assert.False(result.Degraded);
        Assert.Equal(3, result.Records.Count);
        Assert.Equal("req_5", result.Records[0].RequestId);
        Assert.Equal("req_4", result.Records[1].RequestId);
        Assert.Equal("req_3", result.Records[2].RequestId);
    }

    [Fact]
    public async Task Corrupt_newest_record_is_isolated_and_older_valid_records_return()
    {
        FakeObservabilityFileSystem fileSystem = new();
        SeedValid(fileSystem, 1);
        SeedValid(fileSystem, 2);
        fileSystem.Contents[PathFor("request-9-bad.json")] = "{ nope"u8.ToArray();

        DurableRequestLog log = CreateLog(fileSystem);
        DurableRecentReadResult result = await log.ReadRecentAsync(5, CancellationToken.None);

        Assert.True(result.Degraded);
        Assert.Equal(1, result.SkippedCorrupt);
        Assert.Contains("recent_record_corrupt", result.Codes, StringComparer.Ordinal);
        Assert.Equal(2, result.Records.Count);
        Assert.Equal("req_2", result.Records[0].RequestId);
        Assert.Equal("req_1", result.Records[1].RequestId);
    }

    [Fact]
    public async Task Oversized_record_is_skipped_without_failing_the_read()
    {
        FakeObservabilityFileSystem fileSystem = new();
        SeedValid(fileSystem, 1);
        fileSystem.Contents[PathFor("request-9-oversized.json")] = new byte[1024 * 1024 + 1];

        DurableRequestLog log = CreateLog(
            fileSystem,
            maxFileBytes: 1024 * 1024);
        DurableRecentReadResult result = await log.ReadRecentAsync(5, CancellationToken.None);

        Assert.True(result.Degraded);
        Assert.Equal(1, result.SkippedOversized);
        Assert.Contains("recent_record_oversized", result.Codes, StringComparer.Ordinal);
        Assert.Equal("req_1", Assert.Single(result.Records).RequestId);
    }

    [Fact]
    public async Task Recent_read_hard_bounds_are_enforced()
    {
        FakeObservabilityFileSystem fileSystem = new();
        DurableRequestLog log = CreateLog(fileSystem);

        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(
            () => log.ReadRecentAsync(0, CancellationToken.None));
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(
            () => log.ReadRecentAsync(DurableRequestLog.HardRecentMaxCount + 1, CancellationToken.None));
    }

    [Fact]
    public async Task Excessively_large_log_directory_is_scan_limited_not_infinite()
    {
        FakeObservabilityFileSystem fileSystem = new();
        for (int index = 1; index <= DurableRequestLog.MaxRecentScanFiles + 20; index++)
        {
            SeedValid(fileSystem, index);
        }

        DurableRequestLog log = CreateLog(fileSystem);
        DurableRecentReadResult result = await log.ReadRecentAsync(DurableRequestLog.DefaultRecentMaxCount, CancellationToken.None);

        Assert.True(result.Degraded);
        Assert.True(result.ScanLimited);
        Assert.Contains("recent_scan_limited", result.Codes, StringComparer.Ordinal);
        Assert.Equal(DurableRequestLog.DefaultRecentMaxCount, result.Records.Count);
    }

    [Fact]
    public async Task Partial_json_record_is_isolated_as_corrupt()
    {
        FakeObservabilityFileSystem fileSystem = new();
        SeedValid(fileSystem, 1);
        fileSystem.Contents[PathFor("request-9-partial.json")] =
            """{"schema_version":1,"request_id":"req_partial","trace_id":"""u8.ToArray();

        DurableRequestLog log = CreateLog(fileSystem);
        DurableRecentReadResult result = await log.ReadRecentAsync(5, CancellationToken.None);

        Assert.True(result.Degraded);
        Assert.Equal(1, result.SkippedCorrupt);
        Assert.Contains("recent_record_corrupt", result.Codes, StringComparer.Ordinal);
        Assert.Equal("req_1", Assert.Single(result.Records).RequestId);
    }

    [Fact]
    public async Task Many_files_never_materialize_an_unbounded_candidate_array()
    {
        FakeObservabilityFileSystem fileSystem = new();
        int total = DurableRequestLog.MaxRecentScanFiles + 1000;
        for (int index = 1; index <= total; index++)
        {
            SeedValid(fileSystem, index);
        }

        DurableRequestLog log = CreateLog(fileSystem);
        DurableRecentReadResult result = await log.ReadRecentAsync(DurableRequestLog.DefaultRecentMaxCount, CancellationToken.None);

        Assert.True(result.Degraded);
        Assert.True(result.ScanLimited);
        Assert.Equal(DurableRequestLog.DefaultRecentMaxCount, result.Records.Count);
        Assert.Equal("req_" + total, result.Records[0].RequestId);
        Assert.True(
            fileSystem.ReadAllBytesCalls <= DurableRequestLog.MaxRecentScanFiles,
            $"Reader read {fileSystem.ReadAllBytesCalls} files; bound is {DurableRequestLog.MaxRecentScanFiles}");
    }

    private static DurableRequestLog CreateLog(
        FakeObservabilityFileSystem fileSystem,
        long maxFileBytes = 256 * 1024)
        => new(
            ObservabilityOptions.Create(
                LogDirectory,
                maxFileBytes,
                maxFiles: 8,
                TimeSpan.FromDays(7),
                maxTraceEventsPerRequest: 64),
            fileSystem,
            () => DurableRequestLogTests.Now);

    private static void SeedValid(FakeObservabilityFileSystem fileSystem, int index)
    {
        SafeRequestRecord safe = SafeRequestRecordTestsHelpers.Record("req_" + index);
        RedactedRequestRecord redacted = RedactedRequestRecord.From(safe);
        fileSystem.Contents[PathFor($"request-{index:0000}-req_{index}.json")] =
            JsonSerializer.SerializeToUtf8Bytes(redacted, ObservabilityJson.Options);
    }

    private static string PathFor(string fileName)
        => Path.Combine(LogDirectory, fileName);
}
