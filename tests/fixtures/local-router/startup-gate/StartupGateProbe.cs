// PR10A isolated child-process fixture. Never shipped, never a production CLI.
global using System;
global using System.Collections.Generic;
global using System.IO;
global using System.Linq;
global using System.Threading;
global using System.Threading.Tasks;
using Router.Configuration;
using Router.Core.Abstractions;
using Router.Core.Errors;
using Router.Core.Tests.Fakes;
using Router.Host;
using Router.Ingress.Fakes;
using Router.Secrets;
using Router.State;
using Router.State.Ownership;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

internal static class StartupGateProbe
{
    public static async Task<int> Main(string[] args)
    {
        // Mode may carry ':'-separated parameters (for example
        // "acl-deny:ListDirectory"); the first segment is the mode name.
        string[] modeParts = args[0].Split(':');
        string mode = modeParts[0];
        // Rejoin the remainder: a Windows path carries its own ':' separator.
        string modeArg = modeParts.Length > 1 ? string.Join(':', modeParts.Skip(1)) : string.Empty;
        string modeArg2 = modeParts.Length > 2 ? modeParts[2] : string.Empty;
        string root = args[1];
        string phase = "dispatch";
        try
        {
            if (mode is "default-gate" or "default-state-io")
            {
                phase = "default_layout";
                Environment.SetEnvironmentVariable("CODEX_HOME", root);
                DefaultRouterPathProvider defaults = new();
                string localRouter = Path.Combine(root, "multimodel-manager", "local-router");
                if (!string.Equals(defaults.OwnerRecordPath, Path.Combine(localRouter, "runtime", "router.pid.json"), StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(defaults.RuntimeStatePath, Path.Combine(localRouter, "runtime", "router.state.json"), StringComparison.OrdinalIgnoreCase))
                { throw new IOException("Isolated default layout differs."); }
                Console.WriteLine("DEFAULT_LAYOUT_PATHS PASS");
                root = localRouter;
                mode = mode == "default-gate" ? "gate" : "state-io";
            }
            if (mode == "host-race" && OperatingSystem.IsWindows()) { ReportDirectoryAcl(root); }
            if (mode == "state-io") { phase = "state_io"; return await StateIoAsync(root); }
            if (mode == "directory-attacks") { return DirectoryAttacks(root); }
            if (mode is "directory-write" or "gate-open" or "acl-deny" or "acl-clear" or "acl-snapshot" or "acl-restore" or "acl-allow-everyone")
            {
                // ACL fixtures live here because PowerShell cannot call the
                // Managed ACL writers used by the gate (they are extension
                // methods) and Set-Acl round-trips the SACL, which needs
                // SeSecurityPrivilege in a non-elevated session. These modes only
                // ever touch the DACL of the test's own sandbox directory.
                if (mode is "acl-deny" or "acl-clear" or "acl-snapshot" or "acl-restore" or "acl-allow-everyone")
                {
                    string runtimePath = Path.Combine(root, "runtime");
                    string target = runtimePath;
                    if (mode == "acl-allow-everyone")
                    {
                        DirectoryInfo everyoneDir = new(target);
                        System.Security.AccessControl.DirectorySecurity everyoneSecurity =
                            everyoneDir.GetAccessControl(System.Security.AccessControl.AccessControlSections.Access);
                        everyoneSecurity.SetAccessRuleProtection(true, true);
                        everyoneSecurity.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(
                            new System.Security.Principal.SecurityIdentifier("S-1-1-0"),
                            System.Security.AccessControl.FileSystemRights.Write,
                            System.Security.AccessControl.AccessControlType.Allow));
                        everyoneDir.SetAccessControl(everyoneSecurity);
                        Console.Error.WriteLine("ACL_ALLOW_EVERYONE applied=True");
                        return 0;
                    }
                    if (mode == "acl-snapshot")
                    {
                        System.Security.AccessControl.DirectorySecurity snapshot =
                            new DirectoryInfo(target).GetAccessControl(System.Security.AccessControl.AccessControlSections.Access);
                        File.WriteAllBytes(modeArg, snapshot.GetSecurityDescriptorBinaryForm());
                        Console.Error.WriteLine($"ACL_SNAPSHOT bytes={new FileInfo(modeArg).Length}");
                        return 0;
                    }
                    if (mode == "acl-restore")
                    {
                        System.Security.AccessControl.DirectorySecurity restore = new();
                        restore.SetSecurityDescriptorBinaryForm(File.ReadAllBytes(modeArg),
                            System.Security.AccessControl.AccessControlSections.Access);
                        new DirectoryInfo(target).SetAccessControl(restore);
                        Console.Error.WriteLine("ACL_RESTORE applied=True");
                        return 0;
                    }

                    var rights = (System.Security.AccessControl.FileSystemRights)Enum.Parse(
                        typeof(System.Security.AccessControl.FileSystemRights), modeArg, ignoreCase: true);
                    var sid = System.Security.Principal.WindowsIdentity.GetCurrent().User!;
                    DirectoryInfo directory = new(target);
                    System.Security.AccessControl.DirectorySecurity security =
                        directory.GetAccessControl(System.Security.AccessControl.AccessControlSections.Access);
                    security.SetAccessRuleProtection(true, true);
                    if (mode == "acl-deny")
                    {
                        security.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(
                            sid, rights, System.Security.AccessControl.AccessControlType.Deny));
                    }
                    else
                    {
                        foreach (System.Security.AccessControl.FileSystemAccessRule rule in
                            security.GetAccessRules(true, false, typeof(System.Security.Principal.SecurityIdentifier)))
                        {
                            if (rule.AccessControlType == System.Security.AccessControl.AccessControlType.Deny
                                && rule.IdentityReference == sid
                                && (rule.FileSystemRights & rights) == rights)
                            {
                                security.RemoveAccessRuleSpecific(rule);
                            }
                        }
                    }
                    directory.SetAccessControl(security);
                    Console.Error.WriteLine($"ACL_{mode.ToUpperInvariant()} rights={rights}");
                    return 0;
                }

                // FIX5 evidence mode: proves whether the access mask the gate
                // itself requests is actually refused by the directory's ACL.
                // Exit 0 means the ACL is effective (refused), 29 means an
                // effective grant remains, so a "denied" fixture must never
                // assume refusal without this check.
                if (mode == "gate-open")
                {
                    using SafeFileHandle probe = CreateFileW(Path.Combine(root, "runtime"), 0x00020081, 3,
                        IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
                    int probeNative = probe.IsInvalid ? Marshal.GetLastWin32Error() : 0;
                    Console.Error.WriteLine($"GATE_OPEN checked refused={probe.IsInvalid} native={probeNative}");
                    return probe.IsInvalid && probeNative == 5 ? 0 : 29;
                }

                // Both classes a reparse replacement needs must be refused while
                // the Host holds coordination: the data-write class (GENERIC_WRITE,
                // refused by directory sharing without FILE_SHARE_DELETE) and the
                // metadata-write class (FILE_WRITE_ATTRIBUTES, the access
                // FSCTL_SET_REPARSE_POINT actually requires, refused by the
                // explicit metadata-write guard because Windows does not include
                // that class in FILE_SHARE_WRITE). The exact provider of the
                // refusal is reported per class; a successful open on either class
                // is a failure.
                string runtime = Path.Combine(root, "runtime");
                using SafeFileHandle generic = CreateFileW(runtime, 0x40000000, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
                int genericNative = generic.IsInvalid ? Marshal.GetLastWin32Error() : 0;
                bool genericRefused = generic.IsInvalid;
                using SafeFileHandle metadata = CreateFileW(runtime, 0x00000100, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
                int metadataNative = metadata.IsInvalid ? Marshal.GetLastWin32Error() : 0;
                bool metadataRefused = metadata.IsInvalid;
                if (!genericRefused || !metadataRefused) { return 29; }
                Console.Error.WriteLine($"DIRECTORY_WRITE_REFUSED generic={genericNative} metadata={metadataNative}");
                return 30;
            }
            if (mode is "gate" or "race" or "once" or "hold-dir-readonly" or "double-dispose")
            {
                // FIX5 cleanup semantics: a second Dispose must be a no-op and must
                // not release the same coordination twice.
                if (mode == "double-dispose")
                {
                    using (WindowsRouterStartupGate doubled = WindowsRouterStartupGate.Acquire(Path.Combine(root, "runtime")))
                    {
                        doubled.Dispose();
                        doubled.Dispose();
                        Console.WriteLine("DOUBLE_DISPOSE_OK");
                    }

                    return 0;
                }

                // FIX5 fault injection: hold the runtime directory with a
                // read-only share mode so an ACL rewrite (WRITE_DAC) is refused.
                // The pin itself only needs read access, so the gate still opens
                // it - which isolates guard-install and guard-restore failures.
                if (mode == "hold-dir-readonly")
                {
                    using SafeFileHandle held = CreateFileW(Path.Combine(root, "runtime"), 0x00020081, 1,
                        IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
                    if (held.IsInvalid)
                    {
                        Console.Error.WriteLine($"HOLD_DIR_FAILED native={Marshal.GetLastWin32Error()}");
                        return 25;
                    }

                    Console.WriteLine("HOLDING");
                    if (await Console.In.ReadLineAsync() != "RELEASE") { return 24; }
                    Console.WriteLine("HOLD_RELEASED");
                    return 0;
                }

                if (mode == "race")
                {
                    Console.WriteLine("WAITING");
                    if (await Console.In.ReadLineAsync() != "GO") { return 24; }
                }
                using (WindowsRouterStartupGate gate = WindowsRouterStartupGate.Acquire(Path.Combine(root, "runtime")))
                {
                    Console.WriteLine("ACQUIRED");
                    if (mode != "once" && await Console.In.ReadLineAsync() != "RELEASE") { return 24; }
                }
                Console.WriteLine("RELEASED");
                return 0;
            }

            if (mode == "host-race")
            {
                Console.WriteLine("WAITING");
                if (await Console.In.ReadLineAsync() != "GO") { return 24; }
            }
            ProbePaths paths = new(root, mode);
            FakeSecretResolver resolver = new();
            resolver.Configure("local_router", "CODEX_LOCAL_ROUTER_TOKEN", "pr10a-isolated-local-token");
            FakeResponsesService responses = new();
            using CancellationTokenSource stop = new();
            BlockingRuntimeStateFileSystem? blocking = mode is "starting" or "host-race" ? new() : null;
            StoppedWriteFailureFileSystem? stoppedFailure = mode == "stop-write-failure"
                ? new(Path.Combine(root, "runtime", "router.state.json")) : null;
            byte[]? originalOwner = null;
            byte[]? originalReady = null;
            byte[]? originalOwnerHash = null;
            byte[]? originalReadyHash = null;
            HashSet<string>? originalArchives = null;
            int ownedPort = 0;
            TextWriter originalError = Console.Error;
            using GateDiagnosticWriter diagnostic = new(originalError);
            Console.SetError(diagnostic);
            try
            {
                phase = "host_startup";
                Task<int> run = RouterHostBootstrap.RunAsync(Array.Empty<string>(), paths,
                    secretResolver: resolver, responsesService: responses,
                    fileSystemOverride: (IFileSystem?)stoppedFailure ?? blocking, cancellationToken: stop.Token);
                if (blocking is not null)
                {
                    Task first = await Task.WhenAny(run, blocking.ReadyStateWriteStarted.Task);
                    if (first == blocking.ReadyStateWriteStarted.Task) { Console.WriteLine("STARTING_WINDOW"); }
                }
                // Console's synchronized reader can block synchronously even for
                // ReadLineAsync. It must never hold up the completed disabled path.
                Task<string?> command = Task.Run(Console.ReadLine);
                if (await Task.WhenAny(run, command) == command)
                {
                    if (await command != "STOP") { return 24; }
                    if (stoppedFailure is not null)
                    {
                        originalOwner = await File.ReadAllBytesAsync(Path.Combine(root, "runtime", "router.pid.json"));
                        originalReady = await File.ReadAllBytesAsync(Path.Combine(root, "runtime", "router.state.json"));
                        originalOwnerHash = System.Security.Cryptography.SHA256.HashData(originalOwner);
                        originalReadyHash = System.Security.Cryptography.SHA256.HashData(originalReady);
                        using System.Text.Json.JsonDocument owner = System.Text.Json.JsonDocument.Parse(originalOwner);
                        using System.Text.Json.JsonDocument state = System.Text.Json.JsonDocument.Parse(originalReady);
                        if (state.RootElement.GetProperty("lifecycle").GetString() != "READY"
                            || owner.RootElement.GetProperty("pid").GetInt32() != Environment.ProcessId
                            || owner.RootElement.GetProperty("host").GetString() != "127.0.0.1") { return 38; }
                        ownedPort = owner.RootElement.GetProperty("port").GetInt32();
                        if (ownedPort is < 1 or > 65535) { return 38; }
                        originalArchives = ArchiveFiles(root);
                    }
                    stop.Cancel();
                }
                int code = await run;
                // Publish the real Host outcome before fixture assertions. A
                // state-write refusal happens after local secret resolution;
                // treating every exit 2 as an early gate refusal hid that error.
                Console.WriteLine($"PROBE_EXIT={code} PROVIDER_CALLS={responses.Calls.Count}");
                if (responses.Calls.Count != 0) { return 25; }
                if (mode == "disabled" && resolver.Calls.Count != 0) { return 26; }
                if (code == RouterHostBootstrap.ConfigErrorExitCode && diagnostic.GateRefused && resolver.Calls.Count != 0) { return 27; }
                if (paths.OwnerReads != 1) { return 28; }
                if (stoppedFailure is not null)
                {
                    // OSS-M4-2-HOTFIX2: the injected conflict is persistent, so the
                    // writer makes exactly its bounded attempts (first + 3 retries)
                    // and still reports the real failure.
                    bool valid = code == RouterHostBootstrap.ConfigErrorExitCode && stoppedFailure.FailureCount == 4
                        && originalOwner is not null && originalReady is not null && originalArchives is not null
                        && originalOwnerHash is not null && originalReadyHash is not null
                        && File.Exists(Path.Combine(root, "runtime", "router.pid.json"))
                        && File.Exists(Path.Combine(root, "runtime", "router.state.json"))
                        && File.ReadAllBytes(Path.Combine(root, "runtime", "router.pid.json")).SequenceEqual(originalOwner)
                        && File.ReadAllBytes(Path.Combine(root, "runtime", "router.state.json")).SequenceEqual(originalReady)
                        && System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(Path.Combine(root, "runtime", "router.pid.json"))).SequenceEqual(originalOwnerHash)
                        && System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(Path.Combine(root, "runtime", "router.state.json"))).SequenceEqual(originalReadyHash)
                        && ArchiveFiles(root).SetEquals(originalArchives)
                        && stoppedFailure.StoppedTempPaths.All(path => !File.Exists(path));
                    if (!valid) { Console.Error.WriteLine("STOP_WRITE_FAILURE FAIL"); return 38; }
                    // The parent allocated this random loopback test port and
                    // the fixture owner record identifies this process. Rebind
                    // only that port to prove the stopped ingress was released.
                    System.Net.Sockets.TcpListener releasedPort = new(System.Net.IPAddress.Loopback, ownedPort);
                    try { releasedPort.Start(); }
                    finally { releasedPort.Stop(); }
                    // Reacquiring kernel startup coordination proves release,
                    // not an installation identity or a stopped uninstall lease.
                    using (WindowsRouterStartupGate gate = WindowsRouterStartupGate.Acquire(Path.Combine(root, "runtime"))) { }
                    Console.Error.WriteLine("STOP_WRITE_FAILURE PASS");
                }
                return code;
            }
            finally
            {
                Console.SetError(originalError);
            }
        }
        catch (RouterStartupGateException error)
        {
            Console.Error.WriteLine(error.Message);
            Console.Error.WriteLine($"GATE_REFUSAL stage={error.FailureStage} kind={error.InnerException?.GetType().FullName} hresult={error.InnerException?.HResult}");
            return 23;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"PROBE_FAILURE phase={phase} cause={error.GetType().Name} native={NativeCode(error)} hresult={error.HResult:x8}");
            return 37;
        }
    }

    // FIX3: production file-system calls under another process's live startup
    // gate. Unique scratch names avoid adopting or overwriting any existing
    // state, and all evidence is retained inside the caller's GUID sandbox.
    private static async Task<int> StateIoAsync(string root)
    {
        if (!OperatingSystem.IsWindows()) { throw new PlatformNotSupportedException(); }
        string runtime = Path.Combine(root, "runtime");
        WindowsFileSystem files = new();
        WindowsFileSecurity security = new();
        string suffix = Guid.NewGuid().ToString("N");
        string moved = Path.Combine(runtime, $"fix3-{suffix}-atomic.json");
        string temp = Path.Combine(runtime, $"fix3-{suffix}-temp.json");
        string replacement = Path.Combine(runtime, $"fix3-{suffix}-replacement.json");
        bool ok = true;
        async Task<bool> Step(string operation, Func<Task> action)
        {
            try
            {
                await action();
                Console.Error.WriteLine($"STATE_IO stage={operation} PASS");
                return true;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine($"STATE_IO stage={operation} FAIL cause={error.GetType().Name} native={NativeCode(error)} hresult={error.HResult:x8}");
                return false;
            }
        }
        ok &= await Step("create_directory", () => { files.CreateDirectory(runtime); return Task.CompletedTask; });
        ok &= await Step("create_temp_path", () => { temp = files.CreateTempPath(runtime); return Task.CompletedTask; });
        ok &= await Step("write_all_bytes", () => files.WriteAllBytesAsync(temp, [1, 2, 3], CancellationToken.None));
        ok &= await Step("file_exists", () =>
        {
            if (!files.FileExists(temp)) { throw new IOException("Synthetic temp file is missing."); }
            return Task.CompletedTask;
        });
        ok &= await Step("move_file", () => { files.MoveFile(temp, moved, overwrite: false); return Task.CompletedTask; });
        ok &= await Step("write_replacement", () => files.WriteAllBytesAsync(replacement, [4, 5, 6], CancellationToken.None));
        ok &= await Step("replace_file", () =>
        {
            files.ReplaceFile(replacement, moved);
            if (!File.ReadAllBytes(moved).SequenceEqual(new byte[] { 4, 5, 6 })) { throw new IOException("Synthetic replacement differs."); }
            return Task.CompletedTask;
        });
        ok &= await Step("get_file_security", () =>
        {
            if (security.GetStatus(moved) == FileSecurityStatus.Unknown) { throw new IOException("Synthetic file security is unknown."); }
            return Task.CompletedTask;
        });
        ok &= await Step("protect_file_security", () =>
        {
            if (security.ProtectForCurrentUser(moved) != FileSecurityStatus.Protected) { throw new IOException("Synthetic file security is not protected."); }
            return Task.CompletedTask;
        });

        SystemClock clock = new();
        RouterStateStore states = new(files, clock);
        string ownerPath = Path.Combine(runtime, $"fix3-{suffix}-owner.json");
        string statePath = Path.Combine(runtime, $"fix3-{suffix}-state.json");
        using System.Diagnostics.Process process = System.Diagnostics.Process.GetCurrentProcess();
        DateTimeOffset started = new(process.StartTime.ToUniversalTime());
        OwnerRecord record = new()
        {
            SchemaVersion = 1, Pid = process.Id, ProcessStartTicks = started.Ticks,
            ProcessFingerprint = ProcessFingerprint.Compute(process.Id, started),
            Host = "127.0.0.1", Port = 47821, CreatedAt = clock.UtcNow, Version = 1,
        };
        OwnerRecordStore owners = new(files, clock, security, new OwnershipVerifier(new SystemProcessInspector()));
        bool ownerWritten = false;
        ok &= await Step("owner_record_write", async () =>
        {
            RouterError? error = await owners.WriteAsync(ownerPath, record, CancellationToken.None);
            if (error is not null)
            {
                Console.Error.WriteLine($"STATE_IO_ERROR role=owner code={error.Code} reason={(error.Param == "file_security" ? "file_security" : "atomic_write")}");
                throw new IOException("Synthetic owner write refused.");
            }
            ownerWritten = true;
        });
        RouterRuntimeState ready = RouterRuntimeState.CreateDefault(clock.UtcNow) with { Lifecycle = "READY", StartedAt = clock.UtcNow };
        ok &= await Step("ready_state_save", async () =>
        {
            RouterError? error = await states.SaveAsync(statePath, ready, CancellationToken.None);
            if (error is not null) { throw new IOException("Synthetic READY write refused."); }
            StateLoadOutcome loaded = await states.LoadAsync(statePath, Path.Combine(root, "quarantine"), CancellationToken.None);
            if (!loaded.IsSuccess || loaded.State?.Lifecycle != "READY") { throw new IOException("Synthetic READY persistence differs."); }
        });
        ok &= await Step("stopped_state_save", async () =>
        {
            RouterError? error = await states.SaveAsync(statePath, ready with { Lifecycle = "STOPPED", Version = 2 }, CancellationToken.None);
            if (error is not null) { throw new IOException("Synthetic STOPPED write refused."); }
            StateLoadOutcome loaded = await states.LoadAsync(statePath, Path.Combine(root, "quarantine"), CancellationToken.None);
            if (!loaded.IsSuccess || loaded.State?.Lifecycle != "STOPPED" || loaded.State.Version != 2)
            { throw new IOException("Synthetic STOPPED persistence differs."); }
        });
        ok &= await Step("owner_record_archive", async () =>
        {
            // Refuse to archive a failed/unknown write or any other file. This
            // is the fixture-created record, never the gate holder's ownership.
            if (!ownerWritten) { throw new IOException("Synthetic owner was not committed."); }
            OwnerLoadOutcome loaded = await owners.LoadAsync(ownerPath, Path.Combine(root, "quarantine"), CancellationToken.None);
            if (!loaded.IsSuccess || loaded.Record?.ProcessFingerprint != record.ProcessFingerprint) { throw new IOException("Synthetic ownership differs."); }
            byte[] original = await files.ReadAllBytesAsync(ownerPath, CancellationToken.None);
            QuarantineReceipt archived = await states.QuarantineAsync(ownerPath, Path.Combine(root, "quarantine"), "fix3_probe", CancellationToken.None);
            if (files.FileExists(ownerPath) || !files.FileExists(archived.QuarantinePath)) { throw new IOException("Synthetic owner archive differs."); }
            byte[] copy = await files.ReadAllBytesAsync(archived.QuarantinePath, CancellationToken.None);
            if (!copy.SequenceEqual(original)
                || !string.Equals(Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(original)), archived.Sha256, StringComparison.OrdinalIgnoreCase))
            { throw new IOException("Synthetic owner archive content differs."); }
        });
        return ok ? 0 : 36;
    }

    private static int NativeCode(Exception error)
        => error is System.ComponentModel.Win32Exception native ? native.NativeErrorCode
            : ((uint)error.HResult & 0xffff0000u) == 0x80070000u ? error.HResult & 0xffff : 0;

    private static HashSet<string> ArchiveFiles(string root)
    {
        string quarantine = Path.Combine(root, "quarantine");
        return Directory.Exists(quarantine)
            ? Directory.EnumerateFiles(quarantine, "*", SearchOption.AllDirectories).ToHashSet(StringComparer.OrdinalIgnoreCase)
            : new(StringComparer.OrdinalIgnoreCase);
    }

    // Fault injection affects only the STOPPED atomic replacement. Every other
    // operation and the full Host/native gate run against the real file system.
    private sealed class StoppedWriteFailureFileSystem(string statePath) : IFileSystem
    {
        private readonly WindowsFileSystem _inner = new();
        private readonly List<string> _stoppedTemps = [];
        public int FailureCount { get; private set; }
        public IReadOnlyList<string> StoppedTempPaths => _stoppedTemps;
        public bool FileExists(string path) => _inner.FileExists(path);
        public bool DirectoryExists(string path) => _inner.DirectoryExists(path);
        public void CreateDirectory(string path) => _inner.CreateDirectory(path);
        public IEnumerable<string> EnumerateFiles(string directory, string pattern) => _inner.EnumerateFiles(directory, pattern);
        public void DeleteFile(string path) => _inner.DeleteFile(path);
        public void CopyFile(string sourcePath, string destinationPath, bool overwrite) => _inner.CopyFile(sourcePath, destinationPath, overwrite);
        public void MoveFile(string sourcePath, string destinationPath, bool overwrite) => _inner.MoveFile(sourcePath, destinationPath, overwrite);
        public void ReplaceFile(string sourcePath, string destinationPath)
        {
            if (string.Equals(destinationPath, statePath, StringComparison.OrdinalIgnoreCase) && _stoppedTemps.Contains(sourcePath))
            {
                FailureCount++;
                throw new IOException("Synthetic STOPPED replacement sharing conflict.", unchecked((int)0x80070020));
            }
            _inner.ReplaceFile(sourcePath, destinationPath);
        }
        public Task<string> ReadAllTextAsync(string path, CancellationToken cancellationToken) => _inner.ReadAllTextAsync(path, cancellationToken);
        public Task<byte[]> ReadAllBytesAsync(string path, CancellationToken cancellationToken) => _inner.ReadAllBytesAsync(path, cancellationToken);
        public async Task WriteAllBytesAsync(string path, byte[] content, CancellationToken cancellationToken)
        {
            if (string.Equals(Path.GetDirectoryName(path), Path.GetDirectoryName(statePath), StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    using System.Text.Json.JsonDocument document = System.Text.Json.JsonDocument.Parse(content);
                    if (document.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object
                        && document.RootElement.TryGetProperty("lifecycle", out System.Text.Json.JsonElement lifecycle)
                        && lifecycle.ValueKind == System.Text.Json.JsonValueKind.String
                        && lifecycle.GetString() == "STOPPED") { _stoppedTemps.Add(path); }
                }
                catch (System.Text.Json.JsonException) { /* Other real writes pass through unchanged. */ }
            }
            await _inner.WriteAllBytesAsync(path, content, cancellationToken);
        }
        public string CreateTempPath(string directory) => _inner.CreateTempPath(directory);
    }

    private sealed class GateDiagnosticWriter(TextWriter inner) : TextWriter
    {
        private int _gateRefused;
        public bool GateRefused => Volatile.Read(ref _gateRefused) != 0;
        public override System.Text.Encoding Encoding => inner.Encoding;
        public override Task WriteLineAsync(string? value)
        {
            if (value?.StartsWith("[local-router] startup_gate_", StringComparison.Ordinal) == true)
            { Interlocked.Exchange(ref _gateRefused, 1); }
            return inner.WriteLineAsync(value);
        }
        public override void Write(char value) => inner.Write(value);
        public override void Write(string? value) => inner.Write(value);
        public override void WriteLine(string? value)
        {
            if (value?.StartsWith("[local-router] startup_gate_", StringComparison.Ordinal) == true)
            { Interlocked.Exchange(ref _gateRefused, 1); }
            inner.WriteLine(value);
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
        uint disposition, uint flags, IntPtr template);

    // FIX2 diagnostic contains roles/counts only, never SID, SDDL or a path.
    private static void ReportDirectoryAcl(string root)
    {
        using System.Security.Principal.WindowsIdentity identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        System.Security.Principal.SecurityIdentifier user = identity.User ?? throw new IOException("Unverifiable test identity.");
        System.Security.AccessControl.DirectorySecurity acl = new DirectoryInfo(root).GetAccessControl();
        System.Security.Principal.IdentityReference? owner = acl.GetOwner(typeof(System.Security.Principal.SecurityIdentifier));
        bool trustedOwner = owner == user || owner?.Value is "S-1-5-18" or "S-1-5-32-544";
        int otherMutation = 0;
        foreach (System.Security.AccessControl.FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(System.Security.Principal.SecurityIdentifier)))
        {
            if (rule.AccessControlType != System.Security.AccessControl.AccessControlType.Allow
                || (rule.PropagationFlags & System.Security.AccessControl.PropagationFlags.InheritOnly) != 0) { continue; }
            bool trusted = rule.IdentityReference == user || rule.IdentityReference.Value is "S-1-5-18" or "S-1-5-32-544";
            if (!trusted && ((int)rule.FileSystemRights & 0x500D0156) != 0) { otherMutation++; }
        }
        Console.Error.WriteLine($"FIX2_ACL owner_trusted={trustedOwner} protected={acl.AreAccessRulesProtected} other_mutation_aces={otherMutation}");
    }

    // FIX1: real NTFS attacks, not an inference from opening a write handle.
    // Every path is within the test's GUID case or its unique sibling. Never
    // remove/restore a failed attack's evidence or recursively delete anything.
    private static int DirectoryAttacks(string root)
    {
        string runtime = Path.Combine(root, "runtime");
        string target = root + "-attack-target";
        string control = root + "-junction-control";
        Directory.CreateDirectory(target);
        string sentinel = Path.Combine(target, "user-sentinel.txt");
        File.WriteAllText(sentinel, "FIX1 untouched original user bytes");
        Directory.CreateDirectory(control);
        bool valid = SetJunction(control, target, 0x40000000, out string diagnostic);
        bool ok = Report("JUNCTION_CONTROL", valid && File.ReadAllText(Path.Combine(control, "user-sentinel.txt")) == File.ReadAllText(sentinel), diagnostic);

        string legacy = root + "-metadata-control";
        Directory.CreateDirectory(legacy);
        using (SafeFileHandle metadata = CreateFileW(legacy, 0x00020080, 1, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero))
        using (SafeFileHandle write = CreateFileW(legacy, 0x40000000, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero))
        {
            ok &= Report("LEGACY_METADATA_WRITE_OPEN", !metadata.IsInvalid && !write.IsInvalid,
                $"metadataValid={!metadata.IsInvalid} writeValid={!write.IsInvalid} native={Marshal.GetLastWin32Error()}");
        }
        string originalRoot = DirectoryIdentity(root);
        string originalRuntime = DirectoryIdentity(runtime);
        bool Unchanged() => DirectoryIdentity(root) == originalRoot && DirectoryIdentity(runtime) == originalRuntime
            && File.ReadAllText(sentinel) == "FIX1 untouched original user bytes";
        foreach ((string name, string path) in new[] { ("REPARSE_RUNTIME", runtime), ("REPARSE_PARENT", root) })
        {
            bool refused = true;
            foreach (uint access in new uint[] { 0x40000000, 0x100, 0 })
            {
                bool changed = SetJunction(path, target, access, out diagnostic);
                Console.Error.WriteLine($"{name} ATTEMPT access={access:x8} changed={changed} {diagnostic}");
                refused &= !changed;
            }
            ok &= Report(name, refused && Unchanged(), $"root={DirectoryIdentity(root)} runtime={DirectoryIdentity(runtime)}");
        }
        foreach ((string name, string path) in new[] { ("REPLACE_RUNTIME", runtime), ("REPLACE_PARENT", root) })
        {
            bool moved = false;
            diagnostic = "";
            try
            {
                // Directory.Move is a native rename, unlike Move-Item's possible
                // copy/delete fallback. If it succeeds, attempt real Junction
                // replacement and fail even if subsequent replacement fails.
                Directory.Move(path, path + "-displaced");
                moved = true;
                Directory.CreateDirectory(path);
                bool replaced = SetJunction(path, target, 0x40000000, out diagnostic);
                diagnostic = $"moved=True replaced={replaced} {diagnostic}";
            }
            catch (Exception error) { diagnostic = $"moved={moved} kind={error.GetType().FullName} hresult={error.HResult:x8}"; }
            ok &= Report(name, !moved && Unchanged(), diagnostic);
        }
        return ok ? 31 : 32;
    }

    private static bool Report(string name, bool valid, string diagnostic)
    {
        Console.Error.WriteLine($"{name} {(valid ? "PASS" : "FAIL")} {diagnostic}");
        return valid;
    }

    private static bool SetJunction(string path, string target, uint access, out string diagnostic)
    {
        using SafeFileHandle handle = CreateFileW(path, access, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            diagnostic = $"open=False native={Marshal.GetLastWin32Error()}";
            return false;
        }
        byte[] substitute = System.Text.Encoding.Unicode.GetBytes(@"\??\" + target);
        byte[] print = System.Text.Encoding.Unicode.GetBytes(target);
        using MemoryStream stream = new();
        using (BinaryWriter writer = new(stream, System.Text.Encoding.Unicode, leaveOpen: true))
        {
            writer.Write(0xa0000003u); // IO_REPARSE_TAG_MOUNT_POINT
            writer.Write(checked((ushort)(8 + substitute.Length + 2 + print.Length + 2)));
            writer.Write((ushort)0);
            writer.Write((ushort)0); writer.Write(checked((ushort)substitute.Length));
            writer.Write(checked((ushort)(substitute.Length + 2))); writer.Write(checked((ushort)print.Length));
            writer.Write(substitute); writer.Write((ushort)0); writer.Write(print); writer.Write((ushort)0);
        }
        byte[] buffer = stream.ToArray();
        bool changed = DeviceIoControl(handle, 0x000900a4, buffer, (uint)buffer.Length, IntPtr.Zero, 0, out _, IntPtr.Zero);
        int error = changed ? 0 : Marshal.GetLastWin32Error();
        diagnostic = $"open=True ioctl={changed} native={error}";
        return changed;
    }

    private static string DirectoryIdentity(string path)
    {
        using SafeFileHandle handle = CreateFileW(path, 0x00020080, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid || !GetFileInformationByHandle(handle, out DirectoryInformation info))
        { throw new IOException($"Directory identity unverifiable: native={Marshal.GetLastWin32Error()}"); }
        return $"{info.Attributes:x8}:{info.Volume:x8}:{info.IndexHigh:x8}:{info.IndexLow:x8}";
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DirectoryInformation
    {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh,
            Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out DirectoryInformation information);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] buffer, uint size,
        IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);

    private sealed class ProbePaths : IRouterPathProvider
    {
        private readonly string _root;
        private readonly string _mode;
        public ProbePaths(string root, string mode) { _root = root; _mode = mode; }
        public int OwnerReads { get; private set; }
        public string DefaultsPath => Path.Combine(AppContext.BaseDirectory, "config", "router.defaults.json");
        public string UserConfigPath => Path.Combine(_root, "user", "router.config.json");
        public string RuntimeStatePath => Path.Combine(_root, _mode == "mismatch" ? "other-runtime" : "runtime", "router.state.json");
        public string OwnerRecordPath
        {
            get
            {
                OwnerReads++;
                return Path.Combine(_root, _mode == "mutating" && OwnerReads > 1 ? "other-runtime" : "runtime", "router.pid.json");
            }
        }
        public string BackupRootPath => Path.Combine(_root, "backups");
        public string QuarantineRootPath => Path.Combine(_root, "quarantine");
        public string MigrationReceiptDirectory => Path.Combine(_root, "runtime");
    }
}
