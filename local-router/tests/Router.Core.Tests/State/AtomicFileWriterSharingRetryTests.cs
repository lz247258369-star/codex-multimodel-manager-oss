using System.Text;
using Router.Core.Abstractions;
using Router.Core.Errors;
using Router.Core.Tests.Fakes;
using Router.State;
using Xunit;

namespace Router.Core.Tests.State;

/// <summary>
/// OSS-M4-2-HOTFIX2: the atomic writer retries ReplaceFile a bounded number of
/// times only for an exactly identified Windows sharing violation. Every case is
/// deterministic: faults are scripted per call, and the real-file cases hold a
/// handle without FileShare.Delete, which makes File.Replace fail with native 32
/// on Windows every time.
/// </summary>
public sealed class AtomicFileWriterSharingRetryTests
{
    private const int SharingViolation = unchecked((int)0x80070020);
    private const int MaxAttempts = 4; // first attempt + three retries
    private const string Previous = "previous-good-state";
    private const string Next = "next-state";

    [Theory]
    [InlineData(1)]
    [InlineData(3)]
    public async Task Sharing_violation_is_retried_and_the_replace_then_succeeds(int sharingFailures)
    {
        ScriptedReplaceFileSystem fileSystem = new(Enumerable.Repeat<Exception?>(SharingFault(), sharingFailures));
        string target = SeedPrevious(fileSystem);

        RouterError? error = await AtomicFileWriter.WriteAsync(target, Encoding.UTF8.GetBytes(Next), fileSystem, CancellationToken.None);

        Assert.Null(error);
        Assert.Equal(sharingFailures + 1, fileSystem.ReplaceCalls);
        Assert.Equal(Next, fileSystem.Inner.ReadFileText(target));
        AssertNoTempFile(fileSystem.Inner);
    }

    [Fact]
    public async Task Persistent_sharing_violation_exhausts_the_bounded_retries_and_reports_a_real_failure()
    {
        ScriptedReplaceFileSystem fileSystem = new(Enumerable.Repeat<Exception?>(SharingFault(), 50));
        string target = SeedPrevious(fileSystem);

        RouterError? error = await AtomicFileWriter.WriteAsync(target, Encoding.UTF8.GetBytes(Next), fileSystem, CancellationToken.None);

        Assert.Equal(RouterErrorCode.StateWriteFailed, error!.Code);
        Assert.Equal(MaxAttempts, fileSystem.ReplaceCalls);
        Assert.Equal(Previous, fileSystem.Inner.ReadFileText(target));
        AssertNoTempFile(fileSystem.Inner);
    }

    public static TheoryData<string> NonSharingFailures => new()
    {
        "access-denied",
        "lock-violation-33",
        "disk-full-112",
        "path-not-found",
        "generic-io",
        "win32-32-not-io",
    };

    [Theory]
    [MemberData(nameof(NonSharingFailures))]
    public async Task Failure_that_is_not_an_identified_sharing_violation_is_never_retried(string kind)
    {
        ScriptedReplaceFileSystem fileSystem = new([NonSharingFault(kind)]);
        string target = SeedPrevious(fileSystem);

        RouterError? error = await AtomicFileWriter.WriteAsync(target, Encoding.UTF8.GetBytes(Next), fileSystem, CancellationToken.None);

        Assert.Equal(RouterErrorCode.StateWriteFailed, error!.Code);
        Assert.Equal(1, fileSystem.ReplaceCalls);
        Assert.Equal(Previous, fileSystem.Inner.ReadFileText(target));
        AssertNoTempFile(fileSystem.Inner);
    }

    [Fact]
    public async Task Cancellation_requested_after_a_sharing_violation_stops_before_any_retry()
    {
        using CancellationTokenSource cancellation = new();
        ScriptedReplaceFileSystem fileSystem = new(Enumerable.Repeat<Exception?>(SharingFault(), 50))
        {
            OnReplaceFailure = cancellation.Cancel,
        };
        string target = SeedPrevious(fileSystem);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            AtomicFileWriter.WriteAsync(target, Encoding.UTF8.GetBytes(Next), fileSystem, cancellation.Token));

        Assert.Equal(1, fileSystem.ReplaceCalls);
        Assert.Equal(Previous, fileSystem.Inner.ReadFileText(target));
        AssertNoTempFile(fileSystem.Inner);
    }

    [Fact]
    public async Task Stopped_state_save_recovers_from_a_transient_sharing_violation()
    {
        ScriptedReplaceFileSystem fileSystem = new([SharingFault()]);
        string target = SeedPrevious(fileSystem);
        RouterStateStore store = new(fileSystem, new FakeClock());

        RouterError? error = await store.SaveAsync(target, StoppedState(), CancellationToken.None);

        Assert.Null(error);
        Assert.Equal(2, fileSystem.ReplaceCalls);
        Assert.Contains("\"lifecycle\":\"STOPPED\"", fileSystem.Inner.ReadFileText(target), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Stopped_state_save_that_keeps_conflicting_is_reported_as_failed_never_as_saved()
    {
        ScriptedReplaceFileSystem fileSystem = new(Enumerable.Repeat<Exception?>(SharingFault(), 50));
        string target = SeedPrevious(fileSystem);
        RouterStateStore store = new(fileSystem, new FakeClock());

        RouterError? error = await store.SaveAsync(target, StoppedState(), CancellationToken.None);

        Assert.Equal(RouterErrorCode.StateWriteFailed, error!.Code);
        Assert.Equal(MaxAttempts, fileSystem.ReplaceCalls);
        Assert.Equal(Previous, fileSystem.Inner.ReadFileText(target));
        AssertNoTempFile(fileSystem.Inner);
    }

    [Fact]
    public async Task Real_file_held_without_delete_sharing_recovers_once_the_reader_releases_it()
    {
        Assert.True(OperatingSystem.IsWindows(), "File.Replace sharing semantics are Windows-specific; the Router Host tests run on Windows.");
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string target = Path.Combine(sandbox, "router.state.json");
            File.WriteAllText(target, Previous);
            FileStream reader = HoldWithoutDeleteSharing(target);
            ReleasingFileSystem fileSystem = new(new WindowsFileSystem(), onFirstReplaceFailure: reader.Dispose);
            try
            {
                RouterError? error = await AtomicFileWriter.WriteAsync(target, Encoding.UTF8.GetBytes(Next), fileSystem, CancellationToken.None);

                Assert.Null(error);
                Assert.Equal(1, fileSystem.SharingViolations);
                Assert.Equal(Next, File.ReadAllText(target));
                Assert.Single(Directory.GetFiles(sandbox));
            }
            finally
            {
                reader.Dispose();
            }
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Real_file_held_for_the_whole_retry_window_keeps_the_previous_state_and_no_temp()
    {
        Assert.True(OperatingSystem.IsWindows(), "File.Replace sharing semantics are Windows-specific; the Router Host tests run on Windows.");
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string target = Path.Combine(sandbox, "router.state.json");
            File.WriteAllText(target, Previous);
            ReleasingFileSystem fileSystem = new(new WindowsFileSystem(), onFirstReplaceFailure: null);
            RouterError? error;
            using (HoldWithoutDeleteSharing(target))
            {
                error = await AtomicFileWriter.WriteAsync(target, Encoding.UTF8.GetBytes(Next), fileSystem, CancellationToken.None);
            }

            Assert.Equal(RouterErrorCode.StateWriteFailed, error!.Code);
            Assert.Equal(MaxAttempts, fileSystem.SharingViolations);
            Assert.Equal(Previous, File.ReadAllText(target));
            Assert.Equal([target], Directory.GetFiles(sandbox));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public void Reader_that_grants_delete_sharing_lets_the_atomic_replace_complete()
    {
        Assert.True(OperatingSystem.IsWindows(), "File.Replace sharing semantics are Windows-specific; the Router Host tests run on Windows.");
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string target = Path.Combine(sandbox, "router.state.json");
            string replacement = Path.Combine(sandbox, ".tmp-replacement");
            File.WriteAllText(target, Previous);
            File.WriteAllText(replacement, Next);

            using FileStream shared = new(target, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            File.Replace(replacement, target, null);

            using StreamReader previousContent = new(shared);
            Assert.Equal(Previous, previousContent.ReadToEnd());
            Assert.Equal(Next, File.ReadAllText(target));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    private static FileStream HoldWithoutDeleteSharing(string path)
        => new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);

    private static string SeedPrevious(ScriptedReplaceFileSystem fileSystem)
    {
        string target = Path.Combine("fake-sandbox", "router.state.json");
        fileSystem.Inner.SeedFile(target, Previous);
        return target;
    }

    private static void AssertNoTempFile(FakeFileSystem fileSystem)
        => Assert.DoesNotContain(fileSystem.Files, static path => path.Contains(".tmp-", StringComparison.Ordinal));

    private static IOException SharingFault() => new("private-fault-detail", SharingViolation);

    private static Exception NonSharingFault(string kind) => kind switch
    {
        "access-denied" => new UnauthorizedAccessException("private-fault-detail"),
        "lock-violation-33" => new IOException("private-fault-detail", unchecked((int)0x80070021)),
        "disk-full-112" => new IOException("private-fault-detail", unchecked((int)0x80070070)),
        "path-not-found" => new DirectoryNotFoundException("private-fault-detail"),
        "generic-io" => new IOException("private-fault-detail"),
        "win32-32-not-io" => new System.ComponentModel.Win32Exception(32, "private-fault-detail"),
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    private static RouterRuntimeState StoppedState() => new()
    {
        SchemaVersion = 1,
        Lifecycle = "STOPPED",
        Version = 2,
        ConfigGeneration = string.Empty,
        UpdatedAt = DateTimeOffset.UnixEpoch,
    };

    /// <summary>In-memory file system whose ReplaceFile follows a per-call script.</summary>
    private sealed class ScriptedReplaceFileSystem(IEnumerable<Exception?> replaceScript) : IFileSystem
    {
        private readonly Queue<Exception?> _script = new(replaceScript);
        public FakeFileSystem Inner { get; } = new();
        public int ReplaceCalls { get; private set; }
        public Action? OnReplaceFailure { get; init; }

        public void ReplaceFile(string sourcePath, string destinationPath)
        {
            ReplaceCalls++;
            if (_script.TryDequeue(out Exception? fault) && fault is not null)
            {
                OnReplaceFailure?.Invoke();
                throw fault;
            }

            Inner.ReplaceFile(sourcePath, destinationPath);
        }

        public bool FileExists(string path) => Inner.FileExists(path);
        public bool DirectoryExists(string path) => Inner.DirectoryExists(path);
        public void CreateDirectory(string path) => Inner.CreateDirectory(path);
        public IEnumerable<string> EnumerateFiles(string directory, string pattern) => Inner.EnumerateFiles(directory, pattern);
        public void DeleteFile(string path) => Inner.DeleteFile(path);
        public void CopyFile(string sourcePath, string destinationPath, bool overwrite) => Inner.CopyFile(sourcePath, destinationPath, overwrite);
        public void MoveFile(string sourcePath, string destinationPath, bool overwrite) => Inner.MoveFile(sourcePath, destinationPath, overwrite);
        public Task<string> ReadAllTextAsync(string path, CancellationToken cancellationToken) => Inner.ReadAllTextAsync(path, cancellationToken);
        public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken) => Inner.ReadAllBytesAsync(path, cancellationToken);
        public Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken) => Inner.WriteAllBytesAsync(path, content, cancellationToken);
        public string CreateTempPath(string directory) => Inner.CreateTempPath(directory);
    }

    /// <summary>Real file system that counts native sharing violations on ReplaceFile.</summary>
    private sealed class ReleasingFileSystem(IFileSystem inner, Action? onFirstReplaceFailure) : IFileSystem
    {
        public int SharingViolations { get; private set; }

        public void ReplaceFile(string sourcePath, string destinationPath)
        {
            try
            {
                inner.ReplaceFile(sourcePath, destinationPath);
            }
            catch (IOException error) when (error.HResult == SharingViolation)
            {
                SharingViolations++;
                if (SharingViolations == 1)
                {
                    onFirstReplaceFailure?.Invoke();
                }

                throw;
            }
        }

        public bool FileExists(string path) => inner.FileExists(path);
        public bool DirectoryExists(string path) => inner.DirectoryExists(path);
        public void CreateDirectory(string path) => inner.CreateDirectory(path);
        public IEnumerable<string> EnumerateFiles(string directory, string pattern) => inner.EnumerateFiles(directory, pattern);
        public void DeleteFile(string path) => inner.DeleteFile(path);
        public void CopyFile(string sourcePath, string destinationPath, bool overwrite) => inner.CopyFile(sourcePath, destinationPath, overwrite);
        public void MoveFile(string sourcePath, string destinationPath, bool overwrite) => inner.MoveFile(sourcePath, destinationPath, overwrite);
        public Task<string> ReadAllTextAsync(string path, CancellationToken cancellationToken) => inner.ReadAllTextAsync(path, cancellationToken);
        public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken) => inner.ReadAllBytesAsync(path, cancellationToken);
        public Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken) => inner.WriteAllBytesAsync(path, content, cancellationToken);
        public string CreateTempPath(string directory) => inner.CreateTempPath(directory);
    }
}

/// <summary>Captures Console.Error, so it must not run alongside other tests.</summary>
[CollectionDefinition(nameof(ConsoleErrorCaptureGroup), DisableParallelization = true)]
public sealed class ConsoleErrorCaptureGroup
{
}

[Collection(nameof(ConsoleErrorCaptureGroup))]
public sealed class AtomicFileWriterSharingDiagnosticTests
{
    [Fact]
    public async Task Exhausted_sharing_violation_reports_one_redacted_diagnostic_and_recovered_retries_report_none()
    {
        string target = Path.Combine("C:\\Users\\private-user-name\\runtime", "router.state.json");
        TextWriter original = Console.Error;
        StringWriter captured = new();
        Console.SetError(captured);
        try
        {
            AlwaysSharingFileSystem exhausted = new(failures: int.MaxValue);
            exhausted.Inner.SeedFile(target, "previous-good-state");
            RouterError? exhaustedError = await AtomicFileWriter.WriteAsync(target, [1, 2, 3], exhausted, CancellationToken.None);
            string exhaustedOutput = captured.ToString();

            captured.GetStringBuilder().Clear();
            AlwaysSharingFileSystem recovered = new(failures: 2);
            recovered.Inner.SeedFile(target, "previous-good-state");
            RouterError? recoveredError = await AtomicFileWriter.WriteAsync(target, [1, 2, 3], recovered, CancellationToken.None);
            string recoveredOutput = captured.ToString();

            Assert.Equal(RouterErrorCode.StateWriteFailed, exhaustedError!.Code);
            string line = Assert.Single(exhaustedOutput.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries),
                static l => l.Contains("state_persistence_failed", StringComparison.Ordinal));
            Assert.Equal(
                "[local-router] state_persistence_failed: target=runtime_state operation=ReplaceFile cause=IOException hresult=80070020 native=32 category=sharing_violation.",
                line);
            Assert.DoesNotContain("private", exhaustedOutput, StringComparison.OrdinalIgnoreCase);
            Assert.Null(recoveredError);
            Assert.DoesNotContain("state_persistence_failed", recoveredOutput, StringComparison.Ordinal);
        }
        finally
        {
            Console.SetError(original);
        }
    }

    private sealed class AlwaysSharingFileSystem(int failures) : IFileSystem
    {
        private int _remaining = failures;
        public FakeFileSystem Inner { get; } = new();

        public void ReplaceFile(string sourcePath, string destinationPath)
        {
            if (_remaining > 0)
            {
                _remaining--;
                throw new IOException("private-fault-detail", unchecked((int)0x80070020));
            }

            Inner.ReplaceFile(sourcePath, destinationPath);
        }

        public bool FileExists(string path) => Inner.FileExists(path);
        public bool DirectoryExists(string path) => Inner.DirectoryExists(path);
        public void CreateDirectory(string path) => Inner.CreateDirectory(path);
        public IEnumerable<string> EnumerateFiles(string directory, string pattern) => Inner.EnumerateFiles(directory, pattern);
        public void DeleteFile(string path) => Inner.DeleteFile(path);
        public void CopyFile(string sourcePath, string destinationPath, bool overwrite) => Inner.CopyFile(sourcePath, destinationPath, overwrite);
        public void MoveFile(string sourcePath, string destinationPath, bool overwrite) => Inner.MoveFile(sourcePath, destinationPath, overwrite);
        public Task<string> ReadAllTextAsync(string path, CancellationToken cancellationToken) => Inner.ReadAllTextAsync(path, cancellationToken);
        public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken) => Inner.ReadAllBytesAsync(path, cancellationToken);
        public Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken) => Inner.WriteAllBytesAsync(path, content, cancellationToken);
        public string CreateTempPath(string directory) => Inner.CreateTempPath(directory);
    }
}
