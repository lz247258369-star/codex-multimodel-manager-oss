using System.Text;
using System.Text.Json;
using Router.Observability;
using Xunit;

namespace Router.Observability.Tests;

/// <summary>
/// DSR7-C-FIX2: the local safe failure diagnostic must name the failing
/// capability field and nothing else. These tests pin the strict path
/// allowlist, the exact five-field record, the atomic write, the bounded
/// retention and the fail-closed behaviour on unsafe input or I/O failure.
/// </summary>
public sealed class SafeFailureDiagnosticTests
{
    private const string Directory = @"C:\RouterOwned\diagnostics";
    private const string DiagnosticFileNameFragment = "capability-";

    // Decoy values that must never appear in a diagnostic file.
    private const string DecoyToolType = "web_search";
    private const string DecoyToolName = "SUPER_SECRET_TOOL_NAME";
    private const string DecoyPrompt = "PROMPT_DO_NOT_LEAK_123";
    private const string DecoyUrl = "https://secret.example/private";
    private const string DecoyPreviousResponseId = "resp_secret_123";
    private const string DecoyApiLikeText = "sk-test-DO_NOT_LEAK";

    private static readonly string[] DecoyValues =
    [
        DecoyToolType,
        DecoyToolName,
        DecoyPrompt,
        DecoyUrl,
        DecoyPreviousResponseId,
        DecoyApiLikeText,
    ];

    private static readonly string[] ExpectedRecordFields =
    [
        "completed_at",
        "error_code",
        "request_id",
        "safe_param",
        "schema_version",
    ];

    private static readonly string[] ExpectedClassifiedRecordFields =
    [
        "completed_at",
        "error_code",
        "request_id",
        "safe_class",
        "safe_param",
        "schema_version",
    ];

    private static readonly string[] ExpectedIdentifiedRecordFields =
    [
        "completed_at",
        "error_code",
        "request_id",
        "safe_class",
        "safe_identity",
        "safe_param",
        "schema_version",
    ];

    [Theory]
    [InlineData("background")]
    [InlineData("store")]
    [InlineData("modalities")]
    [InlineData("previous_response_id")]
    [InlineData("tool_choice.type")]
    [InlineData("tools[0].type")]
    [InlineData("tools[12].type")]
    [InlineData("input[1].type")]
    [InlineData("input[0].content[3].type")]
    public void Allowed_paths_pass(string candidate)
    {
        Assert.True(SafeFailureDiagnosticPath.IsSafe(candidate));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("tools[0].type=web_search")]
    [InlineData("tools[abc].type")]
    [InlineData("tools[0].name")]
    [InlineData("tool.name")]
    [InlineData("metadata.foo")]
    [InlineData("previous_response_id=resp_123")]
    [InlineData("previous_response_id=resp_secret_123")]
    [InlineData("https://secret.example/private")]
    [InlineData("SUPER_SECRET_TOOL_NAME")]
    [InlineData("PROMPT_DO_NOT_LEAK_123")]
    [InlineData("sk-test-DO_NOT_LEAK")]
    [InlineData(" tools[0].type")]
    [InlineData("tools[0].type ")]
    [InlineData("tools[0].type\nX")]
    [InlineData("input[0].content[0].type;drop")]
    [InlineData("Tools[0].type")]
    [InlineData("tools[-1].type")]
    public void Unsafe_paths_are_rejected(string? candidate)
    {
        Assert.False(SafeFailureDiagnosticPath.IsSafe(candidate));
    }

    [Fact]
    public void Overlong_path_is_rejected()
    {
        string candidate = "input[" + new string('9', 300) + "].type";
        Assert.True(candidate.Length > SafeFailureDiagnosticPath.MaxLength);
        Assert.False(SafeFailureDiagnosticPath.IsSafe(candidate));
    }

    [Fact]
    public void Record_requires_the_unsupported_capability_code_and_a_safe_path()
    {
        DateTimeOffset completedAt = new(2026, 9, 21, 3, 0, 0, TimeSpan.Zero);

        SafeFailureDiagnosticRecord? accepted = SafeFailureDiagnosticRecord.TryCreate(
            "req_safe",
            "unsupported_capability",
            "tools[0].type",
            completedAt);
        SafeFailureDiagnosticRecord? wrongCode = SafeFailureDiagnosticRecord.TryCreate(
            "req_safe",
            "unsupported_parameter",
            "tools[0].type",
            completedAt);
        SafeFailureDiagnosticRecord? unsafePath = SafeFailureDiagnosticRecord.TryCreate(
            "req_safe",
            "unsupported_capability",
            "tools[0].type=" + DecoyToolType,
            completedAt);
        SafeFailureDiagnosticRecord? missingId = SafeFailureDiagnosticRecord.TryCreate(
            null,
            "unsupported_capability",
            "tools[0].type",
            completedAt);

        Assert.NotNull(accepted);
        Assert.Null(wrongCode);
        Assert.Null(unsafePath);
        Assert.Null(missingId);
        Assert.Equal(1, accepted!.SchemaVersion);
        Assert.Equal(SafeFailureDiagnosticRecord.UnsupportedCapabilityCode, accepted.ErrorCode);
        Assert.Equal("tools[0].type", accepted.SafeParam);
    }

    [Fact]
    public void Record_json_contains_exactly_the_five_allowed_fields()
    {
        SafeFailureDiagnosticRecord record = SafeFailureDiagnosticRecord.TryCreate(
            "req_json",
            "unsupported_capability",
            "input[0].content[0].type",
            new DateTimeOffset(2026, 9, 21, 3, 0, 0, TimeSpan.Zero))!;

        using JsonDocument document = JsonDocument.Parse(record.ToJsonBytes());
        string[] fields = document.RootElement.EnumerateObject().Select(static p => p.Name).OrderBy(static n => n, StringComparer.Ordinal).ToArray();

        Assert.Equal(ExpectedRecordFields, fields);
        Assert.Equal("input[0].content[0].type", document.RootElement.GetProperty("safe_param").GetString());
    }

    // DSR7-C-FIX3: the classified (schema v2) record adds exactly one field.
    [Fact]
    public void Classified_record_json_contains_exactly_the_six_allowed_fields()
    {
        SafeFailureDiagnosticRecord record = SafeFailureDiagnosticRecord.TryCreateClassified(
            "req_v2",
            "unsupported_capability",
            "tools[6].type",
            "local_shell",
            new DateTimeOffset(2026, 9, 21, 4, 0, 0, TimeSpan.Zero))!;

        using JsonDocument document = JsonDocument.Parse(record.ToJsonBytes());
        string[] fields = document.RootElement.EnumerateObject().Select(static p => p.Name).OrderBy(static n => n, StringComparer.Ordinal).ToArray();

        Assert.Equal(ExpectedClassifiedRecordFields, fields);
        Assert.Equal(2, document.RootElement.GetProperty("schema_version").GetInt32());
        Assert.Equal("local_shell", document.RootElement.GetProperty("safe_class").GetString());
        Assert.Equal("tools[6].type", document.RootElement.GetProperty("safe_param").GetString());
    }

    [Theory]
    [InlineData("SUPER_SECRET_TOOL_TYPE")]
    [InlineData("sk-test-DO_NOT_LEAK")]
    [InlineData("https://secret.example/private")]
    [InlineData("local_shell ")]
    [InlineData("")]
    [InlineData(null)]
    public void Classified_record_rejects_any_non_allowlisted_class(string? safeClass)
    {
        SafeFailureDiagnosticRecord? record = SafeFailureDiagnosticRecord.TryCreateClassified(
            "req_bad_class",
            "unsupported_capability",
            "tools[0].type",
            safeClass,
            new DateTimeOffset(2026, 9, 21, 4, 0, 0, TimeSpan.Zero));

        Assert.Null(record);
    }

    [Theory]
    [InlineData("background")]
    [InlineData("store")]
    [InlineData("input[0].type")]
    [InlineData("input[0].content[0].type")]
    [InlineData("tool_choice.type")]
    public void Classified_record_only_accepts_the_tool_type_path(string safeParam)
    {
        SafeFailureDiagnosticRecord? record = SafeFailureDiagnosticRecord.TryCreateClassified(
            "req_wrong_path",
            "unsupported_capability",
            safeParam,
            "shell",
            new DateTimeOffset(2026, 9, 21, 4, 0, 0, TimeSpan.Zero));

        Assert.Null(record);
    }

    [Fact]
    public void Classified_log_writes_v2_and_the_legacy_writer_still_writes_v1()
    {
        var fileSystem = new FakeObservabilityFileSystem();
        var log = new SafeFailureDiagnosticLog(Directory, fileSystem, () => DurableRequestLogTests.Now);

        Assert.True(log.TryWriteClassified("req_v2", "unsupported_capability", "tools[2].type", "mcp"));
        Assert.False(log.TryWriteClassified("req_bad", "unsupported_capability", "tools[2].type", "SUPER_SECRET_TOOL_TYPE"));
        Assert.True(log.TryWrite("req_v1", "unsupported_capability", "store"));

        Assert.Equal(2, log.WrittenCount);
        string[] jsons = fileSystem.Contents.Values.Select(static v => Encoding.UTF8.GetString(v)).ToArray();
        Assert.Contains(jsons, static json => json.Contains("\"schema_version\":2", StringComparison.Ordinal) && json.Contains("\"safe_class\":\"mcp\"", StringComparison.Ordinal));
        Assert.Contains(jsons, static json => json.Contains("\"schema_version\":1", StringComparison.Ordinal) && !json.Contains("safe_class", StringComparison.Ordinal));
        Assert.DoesNotContain(string.Join("\n", jsons), "SUPER_SECRET_TOOL_TYPE", StringComparison.Ordinal);
    }

    // DSR7-C-FIX4: the identified (schema v3) record adds exactly one more field.
    [Fact]
    public void Identified_record_json_contains_exactly_the_seven_allowed_fields()
    {
        SafeFailureDiagnosticRecord record = SafeFailureDiagnosticRecord.TryCreateIdentified(
            "req_v3",
            "unsupported_capability",
            "tools[6].type",
            "custom",
            "apply_patch",
            new DateTimeOffset(2026, 9, 21, 5, 0, 0, TimeSpan.Zero))!;

        using JsonDocument document = JsonDocument.Parse(record.ToJsonBytes());
        string[] fields = document.RootElement.EnumerateObject().Select(static p => p.Name).OrderBy(static n => n, StringComparer.Ordinal).ToArray();

        Assert.Equal(ExpectedIdentifiedRecordFields, fields);
        Assert.Equal(3, document.RootElement.GetProperty("schema_version").GetInt32());
        Assert.Equal("tools[6].type", document.RootElement.GetProperty("safe_param").GetString());
        Assert.Equal("custom", document.RootElement.GetProperty("safe_class").GetString());
        Assert.Equal("apply_patch", document.RootElement.GetProperty("safe_identity").GetString());
    }

    [Fact]
    public void Identified_record_requires_the_custom_class_the_tool_path_and_a_known_identity()
    {
        DateTimeOffset now = new(2026, 9, 21, 5, 0, 0, TimeSpan.Zero);

        Assert.Null(SafeFailureDiagnosticRecord.TryCreateIdentified("req", "unsupported_capability", "tools[0].type", "shell", "apply_patch", now));
        Assert.Null(SafeFailureDiagnosticRecord.TryCreateIdentified("req", "unsupported_capability", "store", "custom", "apply_patch", now));
        Assert.Null(SafeFailureDiagnosticRecord.TryCreateIdentified("req", "unsupported_capability", "tools[0].type", "custom", "SUPER_SECRET_TOOL_NAME", now));
        Assert.Null(SafeFailureDiagnosticRecord.TryCreateIdentified("req", "unsupported_capability", "tools[0].type", "custom", "Apply_Patch", now));
        Assert.Null(SafeFailureDiagnosticRecord.TryCreateIdentified("req", "unsupported_capability", "tools[0].type", "custom", "https://secret.example/private", now));
        Assert.Null(SafeFailureDiagnosticRecord.TryCreateIdentified("req", "unsupported_parameter", "tools[0].type", "custom", "apply_patch", now));
    }

    [Fact]
    public void Identified_log_writes_v3_and_never_leaks_an_unknown_name()
    {
        var fileSystem = new FakeObservabilityFileSystem();
        var log = new SafeFailureDiagnosticLog(Directory, fileSystem, () => DurableRequestLogTests.Now);

        Assert.True(log.TryWriteIdentified("req_v3", "unsupported_capability", "tools[3].type", "custom", "apply_patch"));
        Assert.True(log.TryWriteIdentified("req_v3b", "unsupported_capability", "tools[3].type", "custom", "unknown_custom"));
        Assert.False(log.TryWriteIdentified("req_bad", "unsupported_capability", "tools[3].type", "custom", "SUPER_SECRET_TOOL_NAME"));

        Assert.Equal(2, log.WrittenCount);
        string all = string.Join("\n", fileSystem.Contents.Values.Select(static v => Encoding.UTF8.GetString(v)));
        Assert.Contains("\"schema_version\":3", all, StringComparison.Ordinal);
        Assert.Contains("\"safe_identity\":\"apply_patch\"", all, StringComparison.Ordinal);
        Assert.Contains("\"safe_identity\":\"unknown_custom\"", all, StringComparison.Ordinal);
        Assert.DoesNotContain("SUPER_SECRET_TOOL_NAME", all, StringComparison.Ordinal);
    }

    [Fact]
    public void Log_writes_one_atomic_file_with_only_safe_content()
    {
        var fileSystem = new FakeObservabilityFileSystem();
        var log = new SafeFailureDiagnosticLog(Directory, fileSystem, () => DurableRequestLogTests.Now);

        bool written = log.TryWrite("req_atomic", "unsupported_capability", "tools[0].type");

        Assert.True(written);
        Assert.Equal(1, log.WrittenCount);
        string[] files = fileSystem.Contents.Keys.Where(static k => k.EndsWith(".json", StringComparison.Ordinal)).ToArray();
        string file = Assert.Single(files);
        Assert.Contains(DiagnosticFileNameFragment, Path.GetFileName(file), StringComparison.Ordinal);
        Assert.Contains("req_atomic", Path.GetFileName(file), StringComparison.Ordinal);
        Assert.DoesNotContain(".tmp-", Path.GetFileName(file), StringComparison.Ordinal);

        string json = Encoding.UTF8.GetString(fileSystem.Contents[file]);
        Assert.Contains("\"safe_param\":\"tools[0].type\"", json, StringComparison.Ordinal);
        Assert.Contains("\"error_code\":\"unsupported_capability\"", json, StringComparison.Ordinal);
        Assert.True(fileSystem.Contents[file].Length <= SafeFailureDiagnosticLog.MaxFileBytes);
    }

    [Fact]
    public void Unsafe_param_or_wrong_code_writes_nothing()
    {
        var fileSystem = new FakeObservabilityFileSystem();
        var log = new SafeFailureDiagnosticLog(Directory, fileSystem, () => DurableRequestLogTests.Now);

        Assert.False(log.TryWrite("req_1", "unsupported_capability", "tools[0].type=" + DecoyToolType));
        Assert.False(log.TryWrite("req_2", "unsupported_capability", DecoyUrl));
        Assert.False(log.TryWrite("req_3", "unsupported_capability", DecoyToolName));
        Assert.False(log.TryWrite("req_4", "unsupported_parameter", "tools[0].type"));
        Assert.False(log.TryWrite("req_5", "invalid_request", "input[0].type"));

        Assert.Empty(fileSystem.Contents);
        Assert.Equal(5, log.DroppedCount);
    }

    [Fact]
    public void Written_files_never_contain_request_content()
    {
        var fileSystem = new FakeObservabilityFileSystem();
        var log = new SafeFailureDiagnosticLog(Directory, fileSystem, () => DurableRequestLogTests.Now);

        Assert.True(log.TryWrite("req_clean", "unsupported_capability", "input[3].type"));

        string all = string.Join("\n", fileSystem.Contents.Values.Select(static v => Encoding.UTF8.GetString(v)));
        Assert.Contains("input[3].type", all, StringComparison.Ordinal);
        foreach (string decoy in DecoyValues)
        {
            Assert.DoesNotContain(decoy, all, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void Retention_keeps_only_the_newest_64_files()
    {
        var fileSystem = new FakeObservabilityFileSystem();
        DateTimeOffset now = DurableRequestLogTests.Now;
        var log = new SafeFailureDiagnosticLog(Directory, fileSystem, () => now);

        for (int index = 0; index < 70; index++)
        {
            now = now.AddSeconds(1);
            Assert.True(log.TryWrite("req_" + index.ToString("D3", System.Globalization.CultureInfo.InvariantCulture), "unsupported_capability", "store"));
        }

        string[] files = fileSystem.Contents.Keys
            .Where(static k => k.EndsWith(".json", StringComparison.Ordinal))
            .OrderBy(static k => k, StringComparer.Ordinal)
            .ToArray();

        Assert.Equal(SafeFailureDiagnosticLog.MaxRetainedFiles, files.Length);
        Assert.DoesNotContain("req_000", string.Join("|", files), StringComparison.Ordinal);
        Assert.Contains("req_069", string.Join("|", files), StringComparison.Ordinal);
        Assert.Equal(SafeFailureDiagnosticLog.MaxRetainedFiles, log.RetainedFileCount());
    }

    [Fact]
    public void Write_failure_is_non_fatal_and_isolated()
    {
        var log = new SafeFailureDiagnosticLog(Directory, new FailingObservabilityFileSystem(), () => DurableRequestLogTests.Now);

        bool written = log.TryWrite("req_fail", "unsupported_capability", "background");

        Assert.False(written);
        Assert.True(log.Degraded);
        Assert.Equal(0, log.WrittenCount);
    }
}
