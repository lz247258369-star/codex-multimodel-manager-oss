using System.Reflection;
using Router.Core.Lifecycle;
using Router.Observability;
using Xunit;

namespace Router.Observability.Tests;

public sealed class SafeRequestRecordTests
{
    [Fact]
    public void Request_record_has_no_content_fields_by_construction()
    {
        string[] forbidden = ["prompt", "instruction", "tool", "image", "body", "authorization", "secret", "cookie", "header", "content"];
        foreach (PropertyInfo property in typeof(SafeRequestRecord).GetProperties(BindingFlags.Public | BindingFlags.Instance))
        {
            string name = property.Name.ToLowerInvariant();
            foreach (string needle in forbidden)
            {
                Assert.DoesNotContain(needle, name);
            }
        }
    }

    [Fact]
    public void Redaction_rejects_secret_or_content_markers()
    {
        SafeRequestRecord record = CreateRecord();
        SafeRequestRecord unsafeRecord = record with { ErrorCode = "Authorization: Bearer sk-synthetic-secret" };

        Assert.Throws<RedactionFailureException>(() => RedactionBoundary.Redact(unsafeRecord));
        Assert.NotNull(RedactionBoundary.Redact(record));
    }

    [Fact]
    public async Task Redaction_failure_drops_event_and_never_writes()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "codex-mm-obs-" + Guid.NewGuid().ToString("N"));
        var options = ObservabilityOptions.Defaults(tempRoot);
        var log = new DurableRequestLog(options);
        SafeRequestRecord unsafeRecord = CreateRecord() with { ErrorCode = "C:\\Users\\victim\\project secret" };

        bool written = await log.WriteSafeAsync(unsafeRecord, CancellationToken.None);

        Assert.False(written);
        Assert.Equal(0, log.Snapshot().FileCount);
    }

    [Fact]
    public void Safe_health_record_never_contains_paths_or_content()
    {
        var health = new SafeHealthRecord
        {
            HealthyCount = 1,
            DegradedCount = 0,
            UnhealthyCount = 0,
            UnknownCount = 0,
            GeneratedAt = "2026-09-03T00:00:00Z",
        };

        Assert.Equal(1, health.HealthyCount);
        Assert.DoesNotContain("path", health.GeneratedAt, StringComparison.OrdinalIgnoreCase);
    }

    private static SafeRequestRecord CreateRecord()
        => SafeRequestRecord.Create(
            "req_test_1",
            "trc_test_1",
            DateTimeOffset.Parse("2026-09-03T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal),
            DateTimeOffset.Parse("2026-09-03T00:00:01Z", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal),
            RequestState.Completed,
            errorCode: null,
            clientId: "client.codex_cli",
            routeId: "route.test",
            providerId: "mm_openrouter",
            protocolId: "protocol.openai.responses.v1",
            modelRouteId: "model-route.test",
            httpStatus: 200,
            attemptCount: 1,
            usagePresent: true,
            stream: false);
}
