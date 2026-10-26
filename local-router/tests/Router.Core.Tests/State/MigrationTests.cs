using System.Text.Json;
using System.Text.Json.Nodes;
using Router.Configuration;
using Router.Core.Errors;
using Router.Core.Tests.Fakes;
using Router.State;
using Xunit;

namespace Router.Core.Tests.State;

/// <summary>
/// TEST-ONLY legacy migration: schema_version 0 -> 1. The contract defines no
/// public v0 schema; this exists solely to exercise the migration machinery.
/// </summary>
public sealed class LegacyToV1Migration : IRouterMigration
{
    public int FromVersion => 0;

    public int ToVersion => 1;

    public string MigrationId => "migrate.test.legacy-to-v1";

    public string Apply(string sourceJson)
    {
        JsonObject node = JsonNode.Parse(sourceJson)!.AsObject();
        node["schema_version"] = 1;
        JsonObject local = node["local_router"]!.AsObject();
        local["client_auth"] = JsonNode.Parse("""{"mode":"bearer_env_ref","token_ref":"CODEX_LOCAL_ROUTER_TOKEN"}""");
        local["limits"] = JsonNode.Parse(
            """{"max_request_bytes":16777216,"max_header_bytes":32768,"max_connections":32,"shutdown_grace_ms":15000}""");
        node["clients"] = new JsonArray();
        node["protocol_routes"] = new JsonArray();
        node["provider_routes"] = new JsonArray();
        node["model_routes"] = new JsonArray();
        node["routes"] = new JsonArray();
        node["policies"] = new JsonArray();
        node["updated_at"] = "2026-08-27T00:00:00Z";
        return node.ToJsonString();
    }
}

/// <summary>TEST-ONLY migration that produces invalid config to exercise rollback.</summary>
public sealed class BrokenMigration : IRouterMigration
{
    public int FromVersion => 0;

    public int ToVersion => 1;

    public string MigrationId => "migrate.test.broken";

    public string Apply(string sourceJson)
    {
        JsonObject node = JsonNode.Parse(sourceJson)!.AsObject();
        node["schema_version"] = 1;
        node["mode"] = "auto";
        return node.ToJsonString();
    }
}

/// <summary>TEST-ONLY migration that throws mid-apply to exercise interruption recovery.</summary>
public sealed class ThrowingMigration : IRouterMigration
{
    public int FromVersion => 0;

    public int ToVersion => 1;

    public string MigrationId => "migrate.test.throwing";

    public string Apply(string sourceJson)
        => throw new InvalidOperationException("fault-injected migration failure");
}

public sealed class MigrationTests
{
    private readonly FakeClock _clock = new(1_752_000_000_000);
    private readonly WindowsFileSystem _fileSystem = new();

    private static readonly IReadOnlyList<IRouterMigration> LegacyMigrations =
        new IRouterMigration[] { new LegacyToV1Migration() };

    private static MigrationRunOptions CreateOptions() => new()
    {
        Validate = RouterConfigurationLoader.ValidateJson,
        CorruptSource = param => ConfigurationErrors.Corrupt(param),
        FutureVersion = param => ConfigurationErrors.SchemaUnsupported(),
    };

    [Fact]
    public async Task Legacy_predecessor_migrates_to_v1()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string targetPath = Path.Combine(sandbox, "router.config.json");
            File.Copy(TestPaths.Fixture("migration/legacy-predecessor.json"), targetPath);
            MigrationRunner runner = new(_fileSystem, _clock);

            MigrationRunOutcome outcome = await runner.RunAsync(
                targetPath,
                LegacyMigrations,
                Path.Combine(sandbox, "backups"),
                CreateOptions(),
                CancellationToken.None);

            Assert.True(outcome.IsSuccess, outcome.Error?.Code ?? "no error");
            Assert.False(outcome.IsNoOp);
            MigrationReceipt receipt = outcome.Receipts!.Single();
            Assert.Equal("completed", receipt.Status);
            Assert.Equal(0, receipt.FromVersion);
            Assert.Equal(1, receipt.ToVersion);
            Assert.Matches("^[0-9a-f]{64}$", receipt.SourceSha256);
            Assert.Matches("^[0-9a-f]{64}$", receipt.TargetSha256);
            Assert.Null(RouterConfigurationLoader.ValidateJson(await File.ReadAllTextAsync(targetPath)));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Idempotent_rerun_is_a_noop()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string targetPath = Path.Combine(sandbox, "router.config.json");
            File.Copy(TestPaths.Fixture("migration/legacy-predecessor.json"), targetPath);
            string backupRoot = Path.Combine(sandbox, "backups");
            MigrationRunner runner = new(_fileSystem, _clock);

            MigrationRunOutcome first = await runner.RunAsync(targetPath, LegacyMigrations, backupRoot, CreateOptions(), CancellationToken.None);
            string migratedText = await File.ReadAllTextAsync(targetPath);
            MigrationRunOutcome second = await runner.RunAsync(targetPath, LegacyMigrations, backupRoot, CreateOptions(), CancellationToken.None);

            Assert.True(first.IsSuccess, first.Error?.Code ?? "no error");
            Assert.True(second.IsNoOp);
            Assert.Equal(migratedText, await File.ReadAllTextAsync(targetPath));
            Assert.Single(Directory.GetDirectories(backupRoot));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Interrupted_apply_rolls_back_and_preserves_original()
    {
        FakeFileSystem fileSystem = new();
        string targetPath = Path.Combine("sandbox", "router.config.json");
        fileSystem.SeedFile(targetPath, await File.ReadAllTextAsync(TestPaths.Fixture("migration/legacy-predecessor.json")));
        MigrationRunner runner = new(fileSystem, _clock);

        MigrationRunOutcome outcome = await runner.RunAsync(
            targetPath,
            new IRouterMigration[] { new ThrowingMigration() },
            Path.Combine("sandbox", "backups"),
            CreateOptions(),
            CancellationToken.None);

        Assert.False(outcome.IsSuccess);
        Assert.Equal(RouterErrorCode.MigrationFailed, outcome.Error!.Code);
        Assert.NotNull(outcome.RollbackReceipt);
        Assert.Equal("rolled_back", outcome.RollbackReceipt!.Status);
        Assert.Equal(
            await File.ReadAllTextAsync(TestPaths.Fixture("migration/legacy-predecessor.json")),
            fileSystem.ReadFileText(targetPath));
        Assert.DoesNotContain(fileSystem.Files, static path => path.Contains(".tmp-", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Invalid_migrated_output_triggers_verified_rollback()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string targetPath = Path.Combine(sandbox, "router.config.json");
            string original = await File.ReadAllTextAsync(TestPaths.Fixture("migration/legacy-predecessor.json"));
            await File.WriteAllTextAsync(targetPath, original);
            MigrationRunner runner = new(_fileSystem, _clock);

            MigrationRunOutcome outcome = await runner.RunAsync(
                targetPath,
                new IRouterMigration[] { new BrokenMigration() },
                Path.Combine(sandbox, "backups"),
                CreateOptions(),
                CancellationToken.None);

            Assert.False(outcome.IsSuccess);
            Assert.Equal(RouterErrorCode.MigrationFailed, outcome.Error!.Code);
            Assert.NotNull(outcome.RollbackReceipt);
            Assert.Equal("rolled_back", outcome.RollbackReceipt!.Status);
            Assert.Equal(original, await File.ReadAllTextAsync(targetPath));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Corrupt_source_fails_closed_and_is_untouched()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string targetPath = Path.Combine(sandbox, "router.config.json");
            await File.WriteAllTextAsync(targetPath, "{ \"schema_version\": 1,");
            MigrationRunner runner = new(_fileSystem, _clock);

            MigrationRunOutcome outcome = await runner.RunAsync(targetPath, LegacyMigrations, Path.Combine(sandbox, "backups"), CreateOptions(), CancellationToken.None);

            Assert.False(outcome.IsSuccess);
            Assert.Equal(RouterErrorCode.ConfigCorrupt, outcome.Error!.Code);
            Assert.Equal("{ \"schema_version\": 1,", await File.ReadAllTextAsync(targetPath));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Future_version_fails_closed()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string targetPath = Path.Combine(sandbox, "router.config.json");
            string future = await File.ReadAllTextAsync(TestPaths.Fixture("config/invalid/future-schema.json"));
            await File.WriteAllTextAsync(targetPath, future);
            MigrationRunner runner = new(_fileSystem, _clock);

            MigrationRunOutcome outcome = await runner.RunAsync(targetPath, LegacyMigrations, Path.Combine(sandbox, "backups"), CreateOptions(), CancellationToken.None);

            Assert.False(outcome.IsSuccess);
            Assert.Equal(RouterErrorCode.ConfigSchemaUnsupported, outcome.Error!.Code);
            Assert.Equal(future, await File.ReadAllTextAsync(targetPath));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Missing_target_is_a_noop()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            MigrationRunner runner = new(_fileSystem, _clock);

            MigrationRunOutcome outcome = await runner.RunAsync(
                Path.Combine(sandbox, "missing.json"),
                LegacyMigrations,
                Path.Combine(sandbox, "backups"),
                CreateOptions(),
                CancellationToken.None);

            Assert.True(outcome.IsNoOp);
            Assert.True(outcome.IsSuccess);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Invalid_rollback_backup_reports_rollback_failed()
    {
        FakeFileSystem fileSystem = new();
        string targetPath = Path.Combine("sandbox", "router.config.json");
        fileSystem.SeedFile(targetPath, await File.ReadAllTextAsync(TestPaths.Fixture("migration/legacy-predecessor.json")));
        fileSystem.FailReadAllBytesOnCall = 2; // backup read succeeds; restore read fails
        MigrationRunner runner = new(fileSystem, _clock);

        MigrationRunOutcome outcome = await runner.RunAsync(
            targetPath,
            new IRouterMigration[] { new ThrowingMigration() },
            Path.Combine("sandbox", "backups"),
            CreateOptions(),
            CancellationToken.None);

        Assert.False(outcome.IsSuccess);
        Assert.Equal(RouterErrorCode.MigrationRollbackFailed, outcome.Error!.Code);
        Assert.Null(outcome.RollbackReceipt);
    }

    [Fact]
    public void Receipt_golden_serialization_is_stable()
    {
        MigrationReceipt receipt = new()
        {
            SchemaVersion = 1,
            MigrationId = "migrate.test.legacy-to-v1",
            FromVersion = 0,
            ToVersion = 1,
            SourceSha256 = new string('a', 64),
            TargetSha256 = new string('b', 64),
            Status = "completed",
            BackupReceiptId = "bkp_1",
            CompletedAt = new DateTimeOffset(2026, 8, 27, 0, 0, 0, TimeSpan.Zero),
        };

        string json = JsonSerializer.Serialize(receipt, StateJson.Options);

        Assert.Equal(
            "{\"schema_version\":1,\"migration_id\":\"migrate.test.legacy-to-v1\",\"from_version\":0,"
            + "\"to_version\":1,\"source_sha256\":\"" + new string('a', 64) + "\","
            + "\"target_sha256\":\"" + new string('b', 64) + "\","
            + "\"status\":\"completed\",\"backup_receipt_id\":\"bkp_1\","
            + "\"completed_at\":\"2026-08-27T00:00:00+00:00\"}",
            json);
    }

    [Fact]
    public void Planner_rejects_future_versions_and_gaps()
    {
        Assert.Throws<MigrationPlanException>(() => MigrationPlanner.Plan(5, LegacyMigrations));
        Assert.Throws<MigrationPlanException>(() => MigrationPlanner.Plan(0, Array.Empty<IRouterMigration>()));
        Assert.Empty(MigrationPlanner.Plan(MigrationPlanner.TargetSchemaVersion, LegacyMigrations));
    }
}
