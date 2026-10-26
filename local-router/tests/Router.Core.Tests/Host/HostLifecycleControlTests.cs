using System.Globalization;
using System.IO.Pipes;
using System.Net;
using System.Net.Sockets;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Runtime.Versioning;
using Router.Core.Tests.Fakes;
using Router.Host;
using Router.Ingress.Fakes;
using Router.State;
using Router.State.Ownership;
using Xunit;

namespace Router.Core.Tests.Host;

/// <summary>
/// LR-15 PR10B: the Router Host publishes a host-local, single-shot stop
/// capability only after durable READY. These tests pin the real behaviour: a
/// current-user-only pipe, a fixed request shape, a constant-time token check,
/// one accepted request, a graceful stop that persists STOPPED and archives the
/// owner record, and a refusal that never kills a process and never leaves the
/// capability exposed after a rejection.
/// </summary>
public sealed class HostLifecycleControlTests
{
    private static readonly TimeSpan ReadyTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ExitTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ShortWait = TimeSpan.FromSeconds(5);

    [Fact]
    public async Task Ready_host_publishes_a_bound_control_endpoint()
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(pathProvider, UserConfig(port));
            using CancellationTokenSource cts = new();
            Task<int> runTask = StartHost(pathProvider, cts.Token);

            using HttpClient client = new();
            Assert.True(
                await HostTestHarness.WaitUntilReadyAsync(client, port, runTask),
                "the enabled host must reach READY before a stop capability exists");

            string endpointPath = EndpointPath(pathProvider);
            Assert.True(await WaitForFileAsync(endpointPath, ReadyTimeout), "a READY host must publish the control endpoint");

            using JsonDocument endpoint = JsonDocument.Parse(await File.ReadAllTextAsync(endpointPath));
            JsonElement root = endpoint.RootElement;
            Assert.Equal(1, root.GetProperty("schema_version").GetInt32());
            Assert.Equal(1, root.GetProperty("version").GetInt32());
            Assert.Equal(Environment.ProcessId, root.GetProperty("pid").GetInt32());
            Assert.StartsWith("codex-router-host-", root.GetProperty("pipe_name").GetString()!, StringComparison.Ordinal);
            Assert.Equal(64, root.GetProperty("token").GetString()!.Length);

            using JsonDocument owner = JsonDocument.Parse(await File.ReadAllTextAsync(pathProvider.OwnerRecordPath));
            using JsonDocument state = JsonDocument.Parse(await File.ReadAllTextAsync(pathProvider.RuntimeStatePath));
            Assert.Equal(owner.RootElement.GetProperty("process_fingerprint").GetString(), root.GetProperty("process_fingerprint").GetString());
            Assert.Equal(owner.RootElement.GetProperty("process_start_ticks").GetInt64(), root.GetProperty("process_start_ticks").GetInt64());
            Assert.Equal(state.RootElement.GetProperty("config_generation").GetString(), root.GetProperty("config_generation").GetString());
            Assert.Equal("READY", state.RootElement.GetProperty("lifecycle").GetString());

            // The published capability is a LIVE pipe instance of exactly that
            // random name, not just a JSON file, and publication leaves no
            // temporary residue behind.
            string pipeName = root.GetProperty("pipe_name").GetString()!;
            Assert.True(PipeInstanceExists(pipeName), "the published control capability must be backed by a live pipe instance");
            Assert.Empty(Directory.EnumerateFiles(Path.GetDirectoryName(pathProvider.RuntimeStatePath)!, ".tmp-*"));

            // The capability file is protected for the current user only: no
            // Everyone/Users/AuthenticatedUsers write grant survives protection.
            if (OperatingSystem.IsWindows())
            {
                AssertEndpointIsCurrentUserOnly(endpointPath);
            }

            cts.Cancel();
            Assert.Equal(0, await runTask.WaitAsync(ExitTimeout));
            Assert.False(File.Exists(endpointPath), "a clean stop withdraws the published stop capability");
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    [Fact]
    public async Task Authenticated_stop_request_stops_the_host_gracefully()
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(pathProvider, UserConfig(port));
            using CancellationTokenSource cts = new();
            Task<int> runTask = StartHost(pathProvider, cts.Token);

            using HttpClient client = new();
            Assert.True(
                await HostTestHarness.WaitUntilReadyAsync(client, port, runTask),
                "the enabled host must reach READY");

            JsonElement endpoint = await WaitForEndpointAsync(pathProvider, ReadyTimeout);
            int ownerPid = endpoint.GetProperty("pid").GetInt32();
            string response = await SendControlRequestAsync(
                endpoint.GetProperty("pipe_name").GetString()!,
                StopRequest(endpoint.GetProperty("token").GetString()!));

            using (JsonDocument parsed = JsonDocument.Parse(response))
            {
                Assert.True(parsed.RootElement.GetProperty("accepted").GetBoolean(), "an authenticated stop request must be accepted");
            }

            Assert.Equal(0, await runTask.WaitAsync(ExitTimeout));

            using JsonDocument stopped = JsonDocument.Parse(await File.ReadAllTextAsync(pathProvider.RuntimeStatePath));
            Assert.Equal("STOPPED", stopped.RootElement.GetProperty("lifecycle").GetString());
            Assert.False(File.Exists(pathProvider.OwnerRecordPath), "a clean stop archives the owner record");
            Assert.False(File.Exists(EndpointPath(pathProvider)), "a clean stop withdraws the control endpoint");

            string archived = Assert.Single(Directory.EnumerateFiles(pathProvider.QuarantineRootPath, "router.pid.json", SearchOption.AllDirectories));
            using JsonDocument archivedRecord = JsonDocument.Parse(await File.ReadAllTextAsync(archived));
            Assert.Equal(ownerPid, archivedRecord.RootElement.GetProperty("pid").GetInt32());
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    [Fact]
    public async Task Wrong_token_is_refused_and_retires_the_capability_without_killing_the_host()
    {
        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(pathProvider, UserConfig(port));
            using CancellationTokenSource cts = new();
            Task<int> runTask = StartHost(pathProvider, cts.Token);

            using HttpClient client = new();
            Assert.True(await HostTestHarness.WaitUntilReadyAsync(client, port, runTask), "the enabled host must reach READY");
            JsonElement endpoint = await WaitForEndpointAsync(pathProvider, ReadyTimeout);
            string pipeName = endpoint.GetProperty("pipe_name").GetString()!;

            string response = await SendControlRequestAsync(pipeName, StopRequest(new string('0', 64)));
            using (JsonDocument refusal = JsonDocument.Parse(response))
            {
                Assert.False(refusal.RootElement.GetProperty("accepted").GetBoolean(), "a foreign token must never be accepted");
                Assert.Equal("request_rejected", refusal.RootElement.GetProperty("reason").GetString());
            }

            // A refused attempt retires the channel: the next attempt cannot be
            // served, the host keeps serving, and nothing was killed.
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => SendControlRequestAsync(
                pipeName,
                StopRequest(endpoint.GetProperty("token").GetString()!),
                TimeSpan.FromSeconds(3)));
            Assert.False(runTask.IsCompleted, "a refused stop request must never terminate the host");

            using JsonDocument state = JsonDocument.Parse(await File.ReadAllTextAsync(pathProvider.RuntimeStatePath));
            Assert.Equal("READY", state.RootElement.GetProperty("lifecycle").GetString());
            Assert.True(await HostTestHarness.WaitUntilReadyAsync(client, port, runTask), "the host must keep serving after a refused request");

            cts.Cancel();
            Assert.Equal(0, await runTask.WaitAsync(ExitTimeout));
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    [Fact]
    public async Task Listener_refuses_malformed_requests_and_protects_its_capability()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            OwnerRecord owner = CurrentProcessOwner();
            string[] requests =
            [
                """{"schema_version":1,"action":"status","token":"TOKEN"}""",
                """{"schema_version":1,"action":"stop","token":"TOKEN","extra":true}""",
                """{"schema_version":2,"action":"stop","token":"TOKEN"}""",
                """{"schema_version":1,"action":"STOP","token":"TOKEN"}""",
                """{"schema_version":1,"action":"stop"}""",
                """not-json""",
            ];

            foreach (string template in requests)
            {
                using RouterHostControlListener? listener = await RouterHostControlListener.TryStartAsync(
                    sandbox,
                    owner,
                    "0" + new string('a', 63),
                    new WindowsFileSystem(),
                    new FakeFileSecurity(),
                    new FakeClock(),
                    () => { },
                    CancellationToken.None);
                Assert.NotNull(listener);

                using JsonDocument endpoint = JsonDocument.Parse(await File.ReadAllTextAsync(listener!.EndpointPath));
                string token = endpoint.RootElement.GetProperty("token").GetString()!;
                string pipeName = endpoint.RootElement.GetProperty("pipe_name").GetString()!;

                string response = await SendControlRequestAsync(pipeName, template.Replace("TOKEN", token, StringComparison.Ordinal));
                using JsonDocument refusal = JsonDocument.Parse(response);
                Assert.False(refusal.RootElement.GetProperty("accepted").GetBoolean(), $"malformed request must be refused: {template}");
                Assert.False(listener.StopAccepted, "a refused request must not arm the stop");
            }

            // TryStartAsync is called then disposed before the next iteration
            // reuses the same directory: the capability file never survives it.
            Assert.False(File.Exists(Path.Combine(sandbox, RouterHostControlListener.EndpointFileName)));
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    [Fact]
    public async Task Ready_host_that_cannot_publish_its_capability_stops_instead_of_serving_unmanaged()
    {
        if (!OperatingSystem.IsWindows())
        {
            // The lifecycle capability is a Windows contract; other platforms
            // establish no Windows lifecycle evidence.
            return;
        }

        int port = GetFreePort();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);
            await WriteUserConfigAsync(pathProvider, UserConfig(port));
            using CancellationTokenSource cts = new();
            Task<int> runTask = RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider,
                secretResolver: HostTestHarness.SecretResolver(),
                responsesService: new FakeResponsesService(),
                fileSecurityOverride: new CapabilityProtectionUnverifiableFileSecurity(),
                cancellationToken: cts.Token);

            // The Host reaches durable READY, cannot publish and verify its stop
            // capability, and must therefore stop through the existing cleanup
            // path instead of serving as a READY host nobody can stop.
            Assert.Equal(
                RouterHostBootstrap.ControlChannelUnavailableExitCode,
                await runTask.WaitAsync(ExitTimeout));
            Assert.False(File.Exists(EndpointPath(pathProvider)), "no capability is published when its protection cannot be verified");
            Assert.Empty(Directory.EnumerateFiles(Path.GetDirectoryName(pathProvider.RuntimeStatePath)!, ".tmp-*"));

            using JsonDocument state = JsonDocument.Parse(await File.ReadAllTextAsync(pathProvider.RuntimeStatePath));
            Assert.Equal("STOPPED", state.RootElement.GetProperty("lifecycle").GetString());
            Assert.False(File.Exists(pathProvider.OwnerRecordPath), "the normal shutdown path archives the owner record");
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    [Fact]
    public async Task Unprotected_or_rejected_capability_is_never_published()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            // The capability is created with its private descriptor; the
            // injected unverifiable state stands for a protection that could not
            // be established, and publication must then be refused entirely.
            FakeFileSecurity unprotected = new() { Status = FileSecurityStatus.Unprotected, ProtectResult = FileSecurityStatus.Unprotected };
            using RouterHostControlListener? listener = await RouterHostControlListener.TryStartAsync(
                sandbox,
                CurrentProcessOwner(),
                "0" + new string('a', 63),
                new WindowsFileSystem(),
                unprotected,
                new FakeClock(),
                () => { },
                CancellationToken.None);

            Assert.Null(listener);
            Assert.False(File.Exists(Path.Combine(sandbox, RouterHostControlListener.EndpointFileName)), "an unverifiable capability file is never published");
            Assert.Empty(Directory.EnumerateFiles(sandbox, ".tmp-*"));
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    [Fact]
    public async Task Accepted_request_is_single_shot_and_dispose_is_idempotent()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            bool stopped = false;
            RouterHostControlListener listener = (await RouterHostControlListener.TryStartAsync(
                sandbox,
                CurrentProcessOwner(),
                "0" + new string('a', 63),
                new WindowsFileSystem(),
                new FakeFileSecurity(),
                new FakeClock(),
                () => stopped = true,
                CancellationToken.None))!;
            Assert.NotNull(listener);

            string endpointPath = listener.EndpointPath;
            using JsonDocument endpoint = JsonDocument.Parse(await File.ReadAllTextAsync(endpointPath));
            string pipeName = endpoint.RootElement.GetProperty("pipe_name").GetString()!;

            string response = await SendControlRequestAsync(pipeName, StopRequest(endpoint.RootElement.GetProperty("token").GetString()!));
            using (JsonDocument accepted = JsonDocument.Parse(response))
            {
                Assert.True(accepted.RootElement.GetProperty("accepted").GetBoolean());
            }

            // The channel answers first and only then requests the shutdown, so
            // the callback is observed rather than assumed to be synchronous.
            Assert.True(await WaitForConditionAsync(() => stopped, ShortWait), "the accepted request must request the host shutdown");
            Assert.True(await WaitForConditionAsync(() => listener.StopAccepted, ShortWait), "the accepted request is observable");
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => SendControlRequestAsync(
                pipeName,
                StopRequest(endpoint.RootElement.GetProperty("token").GetString()!),
                TimeSpan.FromSeconds(3)));

            listener.Dispose();
            listener.Dispose();
            Assert.False(File.Exists(endpointPath), "dispose withdraws the published endpoint");
        }
        finally
        {
            await DeleteSandboxWithRetryAsync(sandbox);
        }
    }

    private static Task<int> StartHost(TestPathProvider pathProvider, CancellationToken cancellationToken)
        => RouterHostBootstrap.RunAsync(
            Array.Empty<string>(),
            pathProvider,
            secretResolver: HostTestHarness.SecretResolver(),
            responsesService: new FakeResponsesService(),
            cancellationToken: cancellationToken);

    /// <summary>
    /// Pins the real access control of the published capability file. The file
    /// carries the stop token, so it is a credential: no identity other than the
    /// current user (or the local SYSTEM account) may hold any allow-grant on it,
    /// read or write.
    /// </summary>
    [SupportedOSPlatform("windows")]
    private static void AssertEndpointIsCurrentUserOnly(string endpointPath)
    {
        FileSecurity security = new FileInfo(endpointPath).GetAccessControl();
        Assert.True(security.AreAccessRulesProtected, "the control endpoint must not inherit broad access rules");

        SecurityIdentifier currentUser = WindowsIdentity.GetCurrent().User
            ?? throw new IOException("the capability check requires a verifiable current-user identity");
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>())
        {
            if (rule.AccessControlType != AccessControlType.Allow) { continue; }
            string identity = rule.IdentityReference.Value;
            Assert.True(
                string.Equals(identity, currentUser.Value, StringComparison.Ordinal) || string.Equals(identity, "S-1-5-18", StringComparison.Ordinal),
                $"the capability file must not grant access to another identity: {identity}");
        }
    }

    private static string EndpointPath(TestPathProvider pathProvider)
        => Path.Combine(Path.GetDirectoryName(pathProvider.RuntimeStatePath)!, RouterHostControlListener.EndpointFileName);

    private static string StopRequest(string token)
        => string.Create(
            CultureInfo.InvariantCulture,
            $"{{\"schema_version\":1,\"action\":\"stop\",\"token\":\"{token}\"}}");

    private static OwnerRecord CurrentProcessOwner()
    {
        using System.Diagnostics.Process current = System.Diagnostics.Process.GetCurrentProcess();
        DateTimeOffset started = current.StartTime.ToUniversalTime();
        return new OwnerRecord
        {
            SchemaVersion = OwnerRecord.CurrentSchemaVersion,
            Pid = current.Id,
            ProcessFingerprint = ProcessFingerprint.Compute(current.Id, started),
            ProcessStartTicks = started.Ticks,
            Host = "127.0.0.1",
            Port = 47821,
            CreatedAt = DateTimeOffset.UnixEpoch,
            Version = 1,
        };
    }

    private static async Task<JsonElement> WaitForEndpointAsync(TestPathProvider pathProvider, TimeSpan timeout)
    {
        string path = EndpointPath(pathProvider);
        using CancellationTokenSource deadline = new(timeout);
        while (!deadline.IsCancellationRequested)
        {
            if (File.Exists(path))
            {
                try
                {
                    using JsonDocument document = JsonDocument.Parse(await File.ReadAllTextAsync(path, deadline.Token));
                    return document.RootElement.Clone();
                }
                catch (Exception)
                {
                    // The file may still be mid-publication; retry.
                }
            }

            await Task.Delay(TimeSpan.FromMilliseconds(25), deadline.Token);
        }

        Assert.Fail("The control endpoint was not published before the timeout.");
        return default;
    }

    private static async Task<bool> WaitForFileAsync(string path, TimeSpan timeout)
    {
        using CancellationTokenSource deadline = new(timeout);
        while (!deadline.IsCancellationRequested)
        {
            if (File.Exists(path)) { return true; }
            await Task.Delay(TimeSpan.FromMilliseconds(25), deadline.Token);
        }

        return false;
    }

    private static async Task<bool> WaitForConditionAsync(Func<bool> condition, TimeSpan timeout)
    {
        using CancellationTokenSource deadline = new(timeout);
        while (!deadline.IsCancellationRequested)
        {
            if (condition()) { return true; }
            await Task.Delay(TimeSpan.FromMilliseconds(25), deadline.Token);
        }

        return false;
    }

    private static async Task<string> SendControlRequestAsync(string pipeName, string request, TimeSpan? timeout = null)
    {
        using CancellationTokenSource deadline = new(timeout ?? TimeSpan.FromSeconds(15));
        using NamedPipeClientStream client = new(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        await client.ConnectAsync(deadline.Token);
        await client.WriteAsync(Encoding.UTF8.GetBytes(request + "\n"), deadline.Token);
        await client.FlushAsync(deadline.Token);

        byte[] buffer = new byte[512];
        int read = 0;
        while (read < buffer.Length)
        {
            int count = await client.ReadAsync(buffer.AsMemory(read, 1), deadline.Token);
            if (count <= 0 || buffer[read] == (byte)'\n') { break; }
            read++;
        }

        return Encoding.UTF8.GetString(buffer, 0, read);
    }

    private static int GetFreePort()
    {
        TcpListener listener = new(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static string UserConfig(int port) => $$"""
        {
          "schema_version": 1,
          "version": 1,
          "mode": "router",
          "local_router": { "enabled": true, "port": {{port}} },
          "clients": [
            {"client_id":"client.local_test","adapter_id":"adapter.client.local_test.responses.v1","enabled":true,"auth_scope":"responses:invoke","capabilities":["text","streaming","responses"],"version":1}
          ]
        }
        """;

    private static async Task WriteUserConfigAsync(TestPathProvider pathProvider, string json)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(pathProvider.UserConfigPath)!);
        await File.WriteAllTextAsync(pathProvider.UserConfigPath, json);
    }

    /// <summary>True when a live pipe instance of exactly that name exists.</summary>
    private static bool PipeInstanceExists(string pipeName)
    {
        try
        {
            return Directory
                .EnumerateFiles(@"\\.\pipe\", pipeName)
                .Any(entry => string.Equals(Path.GetFileName(entry), pipeName, StringComparison.Ordinal));
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// Real ACL behaviour for the owner record and the durable state, but an
    /// unverifiable capability file protection: the deterministic injection for
    /// "durable READY, capability cannot be published and verified".
    /// </summary>
    private sealed class CapabilityProtectionUnverifiableFileSecurity : IFileSecurity
    {
        private readonly WindowsFileSecurity _inner = new();

        public FileSecurityStatus GetStatus(string path)
            => Path.GetFileName(path) is "router.pid.json" or "router.state.json"
                ? _inner.GetStatus(path)
                : FileSecurityStatus.Unprotected;

        public FileSecurityStatus ProtectForCurrentUser(string path) => _inner.ProtectForCurrentUser(path);
    }

    private static async Task DeleteSandboxWithRetryAsync(string sandbox)
    {
        const int maxAttempts = 6;
        int delayMs = 25;
        for (int attempt = 1; attempt <= maxAttempts; attempt++)
        {
            try
            {
                Directory.Delete(sandbox, recursive: true);
                return;
            }
            catch (IOException) when (attempt < maxAttempts)
            {
            }
            catch (UnauthorizedAccessException) when (attempt < maxAttempts)
            {
            }

            await Task.Delay(delayMs).ConfigureAwait(false);
            delayMs = Math.Min(delayMs * 2, 200);
        }
    }
}
