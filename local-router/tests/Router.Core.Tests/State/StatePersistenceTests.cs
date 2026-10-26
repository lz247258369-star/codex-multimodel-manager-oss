using System.Text.Json;
using Router.Core.Errors;
using Router.Core.Tests.Fakes;
using Router.State;
using Xunit;

namespace Router.Core.Tests.State;

public sealed class StatePersistenceTests
{
    private readonly FakeClock _clock = new(1_752_000_000_000);
    private readonly WindowsFileSystem _fileSystem = new();

    [Fact]
    public async Task Atomic_write_success_persists_state()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string statePath = Path.Combine(sandbox, "runtime", "router.state.json");
            RouterStateStore store = new(_fileSystem, _clock);

            RouterError? error = await store.SaveAsync(statePath, RouterRuntimeState.CreateDefault(_clock.UtcNow), CancellationToken.None);

            Assert.Null(error);
            Assert.True(File.Exists(statePath));
            string text = await File.ReadAllTextAsync(statePath);
            Assert.Contains("\"lifecycle\":\"STOPPED\"", text);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Interrupted_temp_write_preserves_previous_good_state()
    {
        FakeFileSystem fileSystem = new();
        string statePath = Path.Combine("sandbox", "router.state.json");
        string goodJson = JsonSerializer.Serialize(RouterRuntimeState.CreateDefault(_clock.UtcNow), StateJson.Options);
        fileSystem.SeedFile(statePath, goodJson);
        RouterStateStore store = new(fileSystem, _clock);
        fileSystem.FailNextWrite = true;

        RouterError? error = await store.SaveAsync(statePath, RouterRuntimeState.CreateDefault(_clock.UtcNow), CancellationToken.None);

        Assert.Equal(RouterErrorCode.StateWriteFailed, error!.Code);
        Assert.Equal(goodJson, fileSystem.ReadFileText(statePath));
        Assert.DoesNotContain(fileSystem.Files, static path => path.Contains(".tmp-", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Replace_failure_preserves_previous_good_state()
    {
        FakeFileSystem fileSystem = new();
        string statePath = Path.Combine("sandbox", "router.state.json");
        string goodJson = JsonSerializer.Serialize(RouterRuntimeState.CreateDefault(_clock.UtcNow), StateJson.Options);
        fileSystem.SeedFile(statePath, goodJson);
        RouterStateStore store = new(fileSystem, _clock);
        fileSystem.FailNextReplace = true;

        RouterError? error = await store.SaveAsync(statePath, RouterRuntimeState.CreateDefault(_clock.UtcNow), CancellationToken.None);

        Assert.Equal(RouterErrorCode.StateWriteFailed, error!.Code);
        Assert.Equal(goodJson, fileSystem.ReadFileText(statePath));
        Assert.DoesNotContain(fileSystem.Files, static path => path.Contains(".tmp-", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Corrupt_state_is_quarantined_and_fails_closed()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string statePath = Path.Combine(sandbox, "runtime", "router.state.json");
            Directory.CreateDirectory(Path.GetDirectoryName(statePath)!);
            File.Copy(TestPaths.Fixture("state/corrupt-state.json"), statePath);
            string quarantineRoot = Path.Combine(sandbox, "quarantine");
            RouterStateStore store = new(_fileSystem, _clock);

            StateLoadOutcome outcome = await store.LoadAsync(statePath, quarantineRoot, CancellationToken.None);

            Assert.False(outcome.IsSuccess);
            Assert.Equal(RouterErrorCode.StateCorrupt, outcome.Error!.Code);
            Assert.NotNull(outcome.QuarantineReceipt);
            Assert.False(File.Exists(statePath));
            Assert.True(File.Exists(outcome.QuarantineReceipt!.QuarantinePath));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Invalid_lifecycle_and_future_schema_are_quarantined()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            RouterStateStore store = new(_fileSystem, _clock);

            string lifecyclePath = Path.Combine(sandbox, "lifecycle.json");
            File.Copy(TestPaths.Fixture("state/invalid-lifecycle.json"), lifecyclePath);
            StateLoadOutcome lifecycle = await store.LoadAsync(lifecyclePath, Path.Combine(sandbox, "q1"), CancellationToken.None);
            Assert.Equal(RouterErrorCode.StateCorrupt, lifecycle.Error!.Code);
            Assert.False(File.Exists(lifecyclePath));

            string futurePath = Path.Combine(sandbox, "future.json");
            File.Copy(TestPaths.Fixture("state/future-state-schema.json"), futurePath);
            StateLoadOutcome future = await store.LoadAsync(futurePath, Path.Combine(sandbox, "q2"), CancellationToken.None);
            Assert.Equal(RouterErrorCode.StateCorrupt, future.Error!.Code);
            Assert.False(File.Exists(futurePath));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Backup_then_restore_recovers_exact_content()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string statePath = Path.Combine(sandbox, "router.state.json");
            RouterStateStore store = new(_fileSystem, _clock);
            RouterRuntimeState original = RouterRuntimeState.CreateDefault(_clock.UtcNow) with
            {
                Lifecycle = "STARTING",
                ConfigGeneration = new string('a', 64),
            };
            await store.SaveAsync(statePath, original, CancellationToken.None);

            BackupReceipt? receipt = await store.BackupAsync(statePath, Path.Combine(sandbox, "backups"), "test", CancellationToken.None);
            Assert.NotNull(receipt);
            await store.SaveAsync(statePath, RouterRuntimeState.CreateDefault(_clock.UtcNow), CancellationToken.None);

            RestoreOutcome restore = await store.RestoreAsync(receipt!, statePath, CancellationToken.None);

            Assert.True(restore.IsSuccess);
            StateLoadOutcome reloaded = await store.LoadAsync(statePath, Path.Combine(sandbox, "q"), CancellationToken.None);
            Assert.True(reloaded.IsSuccess);
            Assert.Equal("STARTING", reloaded.State!.Lifecycle);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Invalid_backup_is_rejected()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string statePath = Path.Combine(sandbox, "router.state.json");
            RouterStateStore store = new(_fileSystem, _clock);
            await store.SaveAsync(statePath, RouterRuntimeState.CreateDefault(_clock.UtcNow), CancellationToken.None);
            BackupReceipt? receipt = await store.BackupAsync(statePath, Path.Combine(sandbox, "backups"), "test", CancellationToken.None);

            RestoreOutcome missing = await store.RestoreAsync(
                receipt! with { BackupPath = Path.Combine(sandbox, "missing.json") },
                statePath,
                CancellationToken.None);
            Assert.Equal(RouterErrorCode.StateRecoveryFailed, missing.Error!.Code);

            RestoreOutcome tampered = await store.RestoreAsync(
                receipt with { SourceSha256 = new string('f', 64) },
                statePath,
                CancellationToken.None);
            Assert.Equal(RouterErrorCode.StateRecoveryFailed, tampered.Error!.Code);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Save_serializes_canonical_snake_case_without_request_content()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string statePath = Path.Combine(sandbox, "router.state.json");
            RouterStateStore store = new(_fileSystem, _clock);
            RouterRuntimeState state = RouterRuntimeState.CreateDefault(_clock.UtcNow) with
            {
                Lifecycle = "STARTING",
                ConfigGeneration = new string('b', 64),
                LastFailure = new FailureRecord { Code = "config_invalid", Message = "safe", OccurredAt = _clock.UtcNow },
            };

            await store.SaveAsync(statePath, state, CancellationToken.None);
            string text = await File.ReadAllTextAsync(statePath);

            Assert.Contains("\"schema_version\":1", text);
            Assert.Contains("\"lifecycle\":\"STARTING\"", text);
            Assert.Contains("\"config_generation\":\"" + new string('b', 64) + "\"", text);
            Assert.Contains("\"last_failure\":{\"code\":\"config_invalid\"", text);
            Assert.DoesNotContain("prompt", text, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("api_key", text, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("authorization", text, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Append_migration_receipt_persists_into_state()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string statePath = Path.Combine(sandbox, "router.state.json");
            RouterStateStore store = new(_fileSystem, _clock);
            MigrationReceipt receipt = new()
            {
                SchemaVersion = 1,
                MigrationId = "migrate.test.legacy-to-v1",
                FromVersion = 0,
                ToVersion = 1,
                SourceSha256 = new string('a', 64),
                TargetSha256 = new string('b', 64),
                Status = "completed",
                CompletedAt = _clock.UtcNow,
            };

            RouterError? error = await store.AppendMigrationReceiptAsync(statePath, Path.Combine(sandbox, "q"), receipt, CancellationToken.None);

            Assert.Null(error);
            StateLoadOutcome outcome = await store.LoadAsync(statePath, Path.Combine(sandbox, "q2"), CancellationToken.None);
            Assert.True(outcome.IsSuccess);
            Assert.Single(outcome.State!.MigrationReceipts);
            Assert.Equal("migrate.test.legacy-to-v1", outcome.State.MigrationReceipts[0].MigrationId);
            Assert.Equal(2, outcome.State.Version);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }
}
