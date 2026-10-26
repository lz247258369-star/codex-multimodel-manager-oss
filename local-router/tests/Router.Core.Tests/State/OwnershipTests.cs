using Router.Core.Errors;
using Router.Core.Tests.Fakes;
using Router.State;
using Router.State.Ownership;
using Xunit;

namespace Router.Core.Tests.State;

public sealed class OwnershipTests
{
    private readonly FakeClock _clock = new(1_752_000_000_000);
    private readonly WindowsFileSystem _fileSystem = new();

    [Fact]
    public void Missing_owner_record_is_missing()
    {
        OwnershipVerifier verifier = new(new FakeProcessInspector());

        Assert.Equal(OwnershipStatus.Missing, verifier.Verify(null));
    }

    [Fact]
    public void Live_owner_is_detected()
    {
        const int pid = 4242;
        DateTimeOffset start = new(2026, 8, 1, 1, 2, 3, TimeSpan.Zero);
        FakeProcessInspector inspector = new();
        inspector.Add(pid, start);
        OwnershipVerifier verifier = new(inspector);

        Assert.Equal(OwnershipStatus.LiveOwner, verifier.Verify(CreateRecord(pid, start)));
    }

    [Fact]
    public void Stale_pid_is_detected()
    {
        const int pid = 4242;
        FakeProcessInspector inspector = new();
        OwnershipVerifier verifier = new(inspector);

        Assert.Equal(OwnershipStatus.StaleOwner, verifier.Verify(CreateRecord(pid, _clock.UtcNow)));
    }

    [Fact]
    public void Reused_pid_is_foreign()
    {
        const int pid = 4242;
        DateTimeOffset recordedStart = new(2026, 8, 1, 1, 2, 3, TimeSpan.Zero);
        DateTimeOffset reusedStart = recordedStart.AddMinutes(5);
        FakeProcessInspector inspector = new();
        inspector.Add(pid, reusedStart);
        OwnershipVerifier verifier = new(inspector);

        Assert.Equal(OwnershipStatus.ForeignProcess, verifier.Verify(CreateRecord(pid, recordedStart)));
    }

    [Fact]
    public void Fingerprint_mismatch_is_foreign()
    {
        const int pid = 4242;
        DateTimeOffset start = new(2026, 8, 1, 1, 2, 3, TimeSpan.Zero);
        FakeProcessInspector inspector = new();
        inspector.Add(pid, start);
        OwnershipVerifier verifier = new(inspector);

        OwnerRecord record = CreateRecord(pid, start) with { ProcessFingerprint = new string('f', 64) };

        Assert.Equal(OwnershipStatus.ForeignProcess, verifier.Verify(record));
    }

    [Fact]
    public void Unverifiable_process_is_foreign()
    {
        const int pid = 4242;
        FakeProcessInspector inspector = new();
        inspector.AddUnverifiable(pid);
        OwnershipVerifier verifier = new(inspector);

        Assert.Equal(OwnershipStatus.ForeignProcess, verifier.Verify(CreateRecord(pid, _clock.UtcNow)));
    }

    [Fact]
    public async Task Stale_record_is_archived_to_quarantine()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            FakeProcessInspector inspector = new();
            OwnerRecordStore store = CreateStore(inspector, out FakeFileSecurity security);
            OwnerRecord record = CreateRecord(4242, _clock.UtcNow);
            string ownerPath = Path.Combine(sandbox, "runtime", "router.pid.json");
            RouterError? writeError = await store.WriteAsync(ownerPath, record, CancellationToken.None);
            Assert.Null(writeError);

            CleanStaleOutcome outcome = await store.CleanStaleAsync(ownerPath, Path.Combine(sandbox, "quarantine"), CancellationToken.None);

            Assert.True(outcome.IsSuccess);
            Assert.NotNull(outcome.QuarantineReceipt);
            Assert.False(File.Exists(ownerPath));
            Assert.True(File.Exists(outcome.QuarantineReceipt!.QuarantinePath));
            Assert.Contains(ownerPath, security.ProtectCalls);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Live_owner_is_never_cleaned()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            const int pid = 4242;
            DateTimeOffset start = _clock.UtcNow;
            FakeProcessInspector inspector = new();
            inspector.Add(pid, start);
            OwnerRecordStore store = CreateStore(inspector, out _);
            string ownerPath = Path.Combine(sandbox, "runtime", "router.pid.json");
            await store.WriteAsync(ownerPath, CreateRecord(pid, start), CancellationToken.None);

            CleanStaleOutcome outcome = await store.CleanStaleAsync(ownerPath, Path.Combine(sandbox, "quarantine"), CancellationToken.None);

            Assert.False(outcome.IsSuccess);
            Assert.Equal(RouterErrorCode.OwnershipConflict, outcome.Error!.Code);
            Assert.True(File.Exists(ownerPath));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Foreign_owner_is_never_cleaned()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            const int pid = 4242;
            FakeProcessInspector inspector = new();
            inspector.Add(pid, _clock.UtcNow.AddMinutes(1));
            OwnerRecordStore store = CreateStore(inspector, out _);
            string ownerPath = Path.Combine(sandbox, "runtime", "router.pid.json");
            await store.WriteAsync(ownerPath, CreateRecord(pid, _clock.UtcNow), CancellationToken.None);

            CleanStaleOutcome outcome = await store.CleanStaleAsync(ownerPath, Path.Combine(sandbox, "quarantine"), CancellationToken.None);

            Assert.False(outcome.IsSuccess);
            Assert.Equal(RouterErrorCode.OwnershipForeignProcess, outcome.Error!.Code);
            Assert.True(File.Exists(ownerPath));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Owner_file_write_is_atomic_and_acl_protected()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            OwnerRecordStore store = CreateStore(new FakeProcessInspector(), out FakeFileSecurity security);
            string ownerPath = Path.Combine(sandbox, "runtime", "router.pid.json");

            RouterError? error = await store.WriteAsync(ownerPath, CreateRecord(4242, _clock.UtcNow), CancellationToken.None);

            Assert.Null(error);
            Assert.True(File.Exists(ownerPath));
            Assert.Contains(ownerPath, security.ProtectCalls);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Unknown_acl_status_fails_closed()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            OwnerRecordStore store = CreateStore(new FakeProcessInspector(), out FakeFileSecurity security);
            security.ProtectResult = FileSecurityStatus.Unknown;
            string ownerPath = Path.Combine(sandbox, "runtime", "router.pid.json");

            RouterError? error = await store.WriteAsync(ownerPath, CreateRecord(4242, _clock.UtcNow), CancellationToken.None);

            Assert.Equal(RouterErrorCode.StateWriteFailed, error!.Code);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Corrupt_owner_record_is_quarantined()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string ownerPath = Path.Combine(sandbox, "runtime", "router.pid.json");
            Directory.CreateDirectory(Path.GetDirectoryName(ownerPath)!);
            File.Copy(TestPaths.Fixture("ownership/corrupt-owner.json"), ownerPath);
            OwnerRecordStore store = CreateStore(new FakeProcessInspector(), out _);

            OwnerLoadOutcome outcome = await store.LoadAsync(ownerPath, Path.Combine(sandbox, "quarantine"), CancellationToken.None);

            Assert.False(outcome.IsSuccess);
            Assert.Equal(RouterErrorCode.StateCorrupt, outcome.Error!.Code);
            Assert.False(File.Exists(ownerPath));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public void Owner_record_validation_rejects_bad_shapes()
    {
        OwnerRecord valid = CreateRecord(4242, _clock.UtcNow);

        Assert.Null(OwnerRecordValidator.Validate(valid));
        Assert.NotNull(OwnerRecordValidator.Validate(valid with { Pid = 0 }));
        Assert.NotNull(OwnerRecordValidator.Validate(valid with { Host = "0.0.0.0" }));
        Assert.NotNull(OwnerRecordValidator.Validate(valid with { Port = 0 }));
        Assert.NotNull(OwnerRecordValidator.Validate(valid with { ProcessFingerprint = "abc" }));
        Assert.NotNull(OwnerRecordValidator.Validate(valid with { ProcessStartTicks = -1 }));
        Assert.NotNull(OwnerRecordValidator.Validate(valid with { ProcessFingerprint = new string('f', 64) }));
        Assert.NotNull(OwnerRecordValidator.Validate(valid with { SchemaVersion = 2 }));
    }

    [Fact]
    public void Windows_acl_protection_works_on_isolated_file()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string path = Path.Combine(sandbox, "owner.json");
            File.WriteAllText(path, "{}");
            WindowsFileSecurity security = new();

            FileSecurityStatus status = security.ProtectForCurrentUser(path);

            Assert.Equal(FileSecurityStatus.Protected, status);
            Assert.Equal(FileSecurityStatus.Protected, security.GetStatus(path));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    private OwnerRecordStore CreateStore(FakeProcessInspector inspector, out FakeFileSecurity security)
    {
        security = new FakeFileSecurity();
        return new OwnerRecordStore(_fileSystem, _clock, security, new OwnershipVerifier(inspector));
    }

    private OwnerRecord CreateRecord(int pid, DateTimeOffset startTimeUtc)
        => new()
        {
            SchemaVersion = OwnerRecord.CurrentSchemaVersion,
            Pid = pid,
            ProcessFingerprint = ProcessFingerprint.Compute(pid, startTimeUtc),
            ProcessStartTicks = startTimeUtc.ToUniversalTime().Ticks,
            Host = "127.0.0.1",
            Port = 47821,
            CreatedAt = _clock.UtcNow,
            Version = 1,
        };
}
