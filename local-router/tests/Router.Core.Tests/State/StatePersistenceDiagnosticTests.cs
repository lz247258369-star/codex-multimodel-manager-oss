using System.ComponentModel;
using Router.Core.Abstractions;
using Router.Core.Errors;
using Router.Core.Tests.Fakes;
using Router.State;
using Xunit;

namespace Router.Core.Tests.State;

public sealed class StatePersistenceDiagnosticTests
{
    [Fact]
    public void Diagnostic_reports_native_sharing_conflict_without_private_details()
    {
        const string privateDetail = "private-user-token-provider-request-content";
        string diagnostic = StatePersistenceDiagnostic.Describe(
            "C:\\Users\\" + privateDetail + "\\runtime\\router.pid.json",
            StatePersistenceOperation.MoveFile,
            new Win32Exception(32, privateDetail));

        Assert.Contains("target=owner_record", diagnostic, StringComparison.Ordinal);
        Assert.Contains("operation=MoveFile", diagnostic, StringComparison.Ordinal);
        Assert.Contains("cause=Win32Exception", diagnostic, StringComparison.Ordinal);
        Assert.Contains("native=32 category=sharing_violation", diagnostic, StringComparison.Ordinal);
        Assert.DoesNotContain(privateDetail, diagnostic, StringComparison.Ordinal);
        Assert.DoesNotContain("C:\\Users", diagnostic, StringComparison.Ordinal);
    }

    [Fact]
    public void Diagnostic_extracts_access_denied_from_failed_win32_hresult()
    {
        string diagnostic = StatePersistenceDiagnostic.Describe(
            "/private/runtime/router.state.json",
            StatePersistenceOperation.SetFileSecurity,
            new UnauthorizedAccessException("private-path-and-content"));

        Assert.Contains("target=runtime_state", diagnostic, StringComparison.Ordinal);
        Assert.Contains("operation=SetFileSecurity", diagnostic, StringComparison.Ordinal);
        Assert.Contains("hresult=80070005 native=5 category=access_denied", diagnostic, StringComparison.Ordinal);
        Assert.DoesNotContain("private", diagnostic, StringComparison.Ordinal);
    }

    [Fact]
    public void Diagnostic_extracts_sharing_conflict_from_io_hresult()
    {
        string diagnostic = StatePersistenceDiagnostic.Describe(
            "router.state.json",
            StatePersistenceOperation.ReplaceFile,
            new IOException("private-path-and-content", unchecked((int)0x80070020)));

        Assert.Contains("cause=IOException", diagnostic, StringComparison.Ordinal);
        Assert.Contains("native=32 category=sharing_violation", diagnostic, StringComparison.Ordinal);
        Assert.DoesNotContain("private", diagnostic, StringComparison.Ordinal);
    }

    [Fact]
    public void Unknown_file_exception_and_operation_use_fixed_safe_labels()
    {
        string diagnostic = StatePersistenceDiagnostic.Describe(
            "/private/request-data-and-token.json",
            (StatePersistenceOperation)999,
            new PrivateDetailException("private-request-content"));

        Assert.Contains("target=managed_file operation=Unknown cause=Exception", diagnostic, StringComparison.Ordinal);
        Assert.Contains("native=0 category=unknown", diagnostic, StringComparison.Ordinal);
        Assert.DoesNotContain("private", diagnostic, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(nameof(PrivateDetailException), diagnostic, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(StatePersistenceOperation.CreateDirectory)]
    [InlineData(StatePersistenceOperation.CreateTempPath)]
    [InlineData(StatePersistenceOperation.WriteAllBytes)]
    [InlineData(StatePersistenceOperation.FileExists)]
    [InlineData(StatePersistenceOperation.ReplaceFile)]
    public async Task Persistence_failure_preserves_previous_file_and_cleans_only_new_temp(StatePersistenceOperation operation)
    {
        const string previous = "previous-good-state";
        string target = Path.Combine("fake-sandbox", "router.state.json");
        FaultingFileSystem fileSystem = new(operation);
        fileSystem.Inner.SeedFile(target, previous);

        RouterError? error = await AtomicFileWriter.WriteAsync(target, [1, 2, 3], fileSystem, CancellationToken.None);

        Assert.Equal(RouterErrorCode.StateWriteFailed, error!.Code);
        Assert.Equal(previous, fileSystem.Inner.ReadFileText(target));
        Assert.DoesNotContain(fileSystem.Inner.Files, static path => path.Contains(".tmp-", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Failed_new_file_move_preserves_unrelated_file_and_cleans_only_temp()
    {
        string target = Path.Combine("fake-sandbox", "router.pid.json");
        string sentinel = Path.Combine("fake-sandbox", "user-sentinel.txt");
        FaultingFileSystem fileSystem = new(StatePersistenceOperation.MoveFile);
        fileSystem.Inner.SeedFile(sentinel, "unchanged-user-data");

        RouterError? error = await AtomicFileWriter.WriteAsync(target, [1, 2, 3], fileSystem, CancellationToken.None);

        Assert.Equal(RouterErrorCode.StateWriteFailed, error!.Code);
        Assert.False(fileSystem.Inner.HasFile(target));
        Assert.Equal("unchanged-user-data", fileSystem.Inner.ReadFileText(sentinel));
        Assert.DoesNotContain(fileSystem.Inner.Files, static path => path.Contains(".tmp-", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Precancelled_write_keeps_previous_file_and_does_not_create_temp()
    {
        string target = Path.Combine("fake-sandbox", "router.state.json");
        FakeFileSystem fileSystem = new();
        fileSystem.SeedFile(target, "previous-good-state");
        using CancellationTokenSource cancellation = new();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            AtomicFileWriter.WriteAsync(target, [1, 2, 3], fileSystem, cancellation.Token));

        Assert.Equal("previous-good-state", fileSystem.ReadFileText(target));
        Assert.Single(fileSystem.Files);
    }

    private sealed class PrivateDetailException(string message) : Exception(message);

    private sealed class FaultingFileSystem(StatePersistenceOperation failure) : IFileSystem
    {
        private bool _failed;
        public FakeFileSystem Inner { get; } = new();

        private void Fail(StatePersistenceOperation operation)
        {
            if (!_failed && operation == failure)
            {
                _failed = true;
                throw new IOException("private-fault-detail", unchecked((int)0x80070020));
            }
        }

        public bool FileExists(string path) { Fail(StatePersistenceOperation.FileExists); return Inner.FileExists(path); }
        public bool DirectoryExists(string path) => Inner.DirectoryExists(path);
        public void CreateDirectory(string path) { Fail(StatePersistenceOperation.CreateDirectory); Inner.CreateDirectory(path); }
        public IEnumerable<string> EnumerateFiles(string directory, string pattern) => Inner.EnumerateFiles(directory, pattern);
        public void DeleteFile(string path) => Inner.DeleteFile(path);
        public void CopyFile(string sourcePath, string destinationPath, bool overwrite) => Inner.CopyFile(sourcePath, destinationPath, overwrite);
        public void MoveFile(string sourcePath, string destinationPath, bool overwrite) { Fail(StatePersistenceOperation.MoveFile); Inner.MoveFile(sourcePath, destinationPath, overwrite); }
        public void ReplaceFile(string sourcePath, string destinationPath) { Fail(StatePersistenceOperation.ReplaceFile); Inner.ReplaceFile(sourcePath, destinationPath); }
        public Task<string> ReadAllTextAsync(string path, CancellationToken cancellationToken) => Inner.ReadAllTextAsync(path, cancellationToken);
        public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken) => Inner.ReadAllBytesAsync(path, cancellationToken);
        public Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken) { Fail(StatePersistenceOperation.WriteAllBytes); return Inner.WriteAllBytesAsync(path, content, cancellationToken); }
        public string CreateTempPath(string directory) { Fail(StatePersistenceOperation.CreateTempPath); return Inner.CreateTempPath(directory); }
    }
}
