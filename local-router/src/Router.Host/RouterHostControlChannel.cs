using System.Globalization;
using System.IO.Pipes;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Router.Core.Abstractions;
using Router.State;
using Router.State.Ownership;

namespace Router.Host;

/// <summary>
/// LR-15 PR10B: the host-local, single-shot lifecycle control endpoint a READY
/// Router Host publishes for a same-user lifecycle controller.
///
/// The endpoint is a capability, not an authority: it carries the owner
/// identity (PID, start ticks, fingerprint), the durable config generation, a
/// random per-process token and the random name of a current-user-only named
/// pipe. Nothing here grants installation identity, stopped-lease authority or
/// uninstall permission, and no PID alone is ever sufficient to address it.
/// </summary>
public sealed record RouterHostControlEndpoint
{
    /// <summary>Schema version of the published control endpoint file.</summary>
    public const int CurrentSchemaVersion = 1;

    public required int SchemaVersion { get; init; }

    public required int Version { get; init; }

    public required string PipeName { get; init; }

    public required string Token { get; init; }

    public required int Pid { get; init; }

    public required string ProcessFingerprint { get; init; }

    public required long ProcessStartTicks { get; init; }

    public required string ConfigGeneration { get; init; }

    public required DateTimeOffset CreatedAt { get; init; }
}

/// <summary>
/// LR-15 PR10B lifecycle control listener. It accepts exactly one connection,
/// authorizes exactly one fixed-shape request with a constant-time token
/// comparison, answers it, and never accepts a second one. Every failure path
/// keeps the Host serving and simply leaves the stop capability unavailable;
/// the listener never terminates a process and never executes a command.
/// </summary>
public sealed class RouterHostControlListener : IDisposable
{
    /// <summary>Endpoint file name inside the pinned runtime directory.</summary>
    public const string EndpointFileName = "router.control.json";

    /// <summary>The only accepted action.</summary>
    public const string StopAction = "stop";

    /// <summary>Request size bound; a larger request is malformed, never parsed.</summary>
    public const int MaxRequestBytes = 1024;

    /// <summary>Bounded wait for a complete request after the connection is accepted.</summary>
    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(10);

    private static readonly TimeSpan DisposeJoinTimeout = TimeSpan.FromSeconds(5);

    /// <summary>
    /// Bounded wait for the peer to close after it consumed the answer.
    /// Disconnecting a named pipe discards data the peer has not read yet, so
    /// the channel is never torn down before the answer was consumed.
    /// </summary>
    private static readonly TimeSpan PeerCloseTimeout = TimeSpan.FromSeconds(5);

    private static readonly string[] RequiredRequestProperties = ["schema_version", "action", "token"];

    private readonly NamedPipeServerStream _pipe;
    private readonly CancellationTokenSource _channelCancellation;
    private readonly IFileSystem _fileSystem;
    private readonly string _endpointPath;
    private readonly string _token;
    private readonly Action _requestStop;
    private readonly Task _acceptTask;
    private int _disposed;
    private int _stopAccepted;

    private RouterHostControlListener(
        NamedPipeServerStream pipe,
        CancellationTokenSource channelCancellation,
        IFileSystem fileSystem,
        string endpointPath,
        string token,
        Action requestStop)
    {
        _pipe = pipe;
        _channelCancellation = channelCancellation;
        _fileSystem = fileSystem;
        _endpointPath = endpointPath;
        _token = token;
        _requestStop = requestStop;
        // The single accept loop is started directly, not through a thread-pool
        // task: its synchronous prefix is only the non-blocking asynchronous pipe
        // wait, and the Host composition creates no background task of its own.
        _acceptTask = AcceptLoopAsync();
    }

    /// <summary>True once an authenticated stop request was answered.</summary>
    public bool StopAccepted => Volatile.Read(ref _stopAccepted) == 1;

    /// <summary>Published endpoint path (never printed by the Host).</summary>
    public string EndpointPath => _endpointPath;

    /// <summary>
    /// Publishes the control endpoint and starts listening. Returns null when the
    /// channel cannot be created, protected and published with a fail-closed
    /// result: nothing is published at all, and the caller must not report a stop
    /// capability it does not have.
    ///
    /// Publication order is a security contract: the capability is created as an
    /// empty private temporary file, its access control is restricted to the
    /// current user and verified, and only then are the token bytes written and
    /// the file published by an atomic rename inside the same pinned directory.
    /// The token is therefore never readable by another principal at any moment,
    /// and a partial publication leaves no readable capability behind.
    /// </summary>
    public static async Task<RouterHostControlListener?> TryStartAsync(
        string runtimeDirectory,
        OwnerRecord owner,
        string configGeneration,
        IFileSystem fileSystem,
        IFileSecurity fileSecurity,
        IClock clock,
        Action requestStop,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(fileSystem);
        ArgumentNullException.ThrowIfNull(fileSecurity);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(requestStop);
        if (string.IsNullOrWhiteSpace(runtimeDirectory)) { return null; }

        NamedPipeServerStream? pipe = null;
        CancellationTokenSource? channelCancellation = null;
        bool published = false;
        string endpointPath = Path.Combine(runtimeDirectory, EndpointFileName);
        try
        {
            string pipeName = "codex-router-host-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
            string token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
            // CurrentUserOnly is the platform-enforced identity boundary: no other
            // user can open this pipe even if the endpoint file leaked.
            pipe = new NamedPipeServerStream(
                pipeName,
                PipeDirection.InOut,
                maxNumberOfServerInstances: 1,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly,
                inBufferSize: 1024,
                outBufferSize: 1024);

            RouterHostControlEndpoint endpoint = new()
            {
                SchemaVersion = RouterHostControlEndpoint.CurrentSchemaVersion,
                Version = 1,
                PipeName = pipeName,
                Token = token,
                Pid = owner.Pid,
                ProcessFingerprint = owner.ProcessFingerprint,
                ProcessStartTicks = owner.ProcessStartTicks,
                ConfigGeneration = configGeneration,
                CreatedAt = clock.UtcNow,
            };

            byte[] payload = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(endpoint, StateJson.Options));
            // The capability is written into a private randomly named temporary
            // file in the same pinned directory, protected for the current user,
            // VERIFIED, and only then published by an atomic rename. The final
            // capability path therefore never exists with inherited access rules.
            string tempPath = fileSystem.CreateTempPath(runtimeDirectory);
            try
            {
                // The capability file is created with the current-user-only
                // security descriptor AT CREATION, in one step: the token never
                // exists in a file another principal could open, not even for an
                // instant, and the published path is only ever produced by an
                // atomic rename of that already protected file.
                if (!TryWriteProtectedCapability(tempPath, payload))
                {
                    throw new IOException("control_endpoint_unprotected");
                }

                if (fileSecurity.GetStatus(tempPath) != FileSecurityStatus.Protected)
                {
                    throw new IOException("control_endpoint_protection_unverified");
                }

                // A stale capability of a previous instance is replaced only when
                // it is a plain file; anything else fails closed and nothing is
                // published by this process.
                if (fileSystem.FileExists(endpointPath))
                {
                    fileSystem.DeleteFile(endpointPath);
                }

                fileSystem.MoveFile(tempPath, endpointPath, overwrite: false);
                published = true;
            }
            finally
            {
                TryDelete(fileSystem, tempPath);
            }

            channelCancellation = new CancellationTokenSource();
            return new RouterHostControlListener(pipe, channelCancellation, fileSystem, endpointPath, token, requestStop);
        }
        catch (Exception)
        {
            channelCancellation?.Dispose();
            pipe?.Dispose();
            if (published)
            {
                TryDelete(fileSystem, endpointPath);
            }

            return null;
        }
    }

    /// <summary>
    /// Releases the stop capability idempotently: the listener stops accepting,
    /// the pipe is closed and the published endpoint is removed, so a controller
    /// can never address a Host that is already stopping or gone.
    /// </summary>
    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) { return; }

        try { _channelCancellation.Cancel(); } catch (Exception) { }
        try { _pipe.Dispose(); } catch (Exception) { }
        try { _acceptTask.Wait(DisposeJoinTimeout); } catch (Exception) { }
        try { _channelCancellation.Dispose(); } catch (Exception) { }
        TryDelete(_fileSystem, _endpointPath);
    }

    private async Task AcceptLoopAsync()
    {
        try
        {
            await _pipe.WaitForConnectionAsync(_channelCancellation.Token).ConfigureAwait(false);
        }
        catch (Exception)
        {
            return;
        }

        bool accepted = false;
        string? rejectionReason = null;
        try
        {
            string? action = await ReadRequestAsync().ConfigureAwait(false);
            if (action is null)
            {
                rejectionReason = "request_rejected";
            }
            else
            {
                accepted = true;
            }

            await WriteResponseAsync(accepted, rejectionReason).ConfigureAwait(false);
            await WaitForPeerCloseAsync().ConfigureAwait(false);
        }
        catch (Exception)
        {
            return;
        }

        if (accepted)
        {
            Volatile.Write(ref _stopAccepted, 1);
            _requestStop();
        }
    }

    /// <summary>
    /// Waits until the peer closed its handle (the answer was consumed) or the
    /// bounded deadline elapsed. Nothing here can extend the Host's lifetime:
    /// the listener is disposed by the same shutdown the request triggered.
    /// </summary>
    private async Task WaitForPeerCloseAsync()
    {
        using CancellationTokenSource deadline = CancellationTokenSource.CreateLinkedTokenSource(_channelCancellation.Token);
        deadline.CancelAfter(PeerCloseTimeout);
        try
        {
            byte[] scratch = new byte[64];
            while (true)
            {
                int read = await _pipe.ReadAsync(scratch, deadline.Token).ConfigureAwait(false);
                if (read <= 0) { return; }
            }
        }
        catch (Exception)
        {
            // A deadline or a broken pipe both mean there is nothing left to
            // deliver; the decision above is already final.
        }
    }

    /// <summary>
    /// Reads one newline-terminated fixed-shape request. Returns the action name
    /// when the request is well formed AND the token matches; any other outcome
    /// (oversized, truncated, unknown field, wrong token, timeout) returns null
    /// so the caller answers a generic rejection and stops accepting.
    /// </summary>
    private async Task<string?> ReadRequestAsync()
    {
        using CancellationTokenSource deadline = CancellationTokenSource.CreateLinkedTokenSource(_channelCancellation.Token);
        deadline.CancelAfter(RequestTimeout);

        byte[] buffer = new byte[MaxRequestBytes];
        int length = 0;
        while (length < buffer.Length)
        {
            int read = await _pipe.ReadAsync(buffer.AsMemory(length, 1), deadline.Token).ConfigureAwait(false);
            if (read <= 0) { return null; }
            if (buffer[length] == (byte)'\n') { break; }
            length++;
        }

        if (length == 0 || length >= buffer.Length) { return null; }

        try
        {
            using JsonDocument document = JsonDocument.Parse(Encoding.UTF8.GetString(buffer, 0, length));
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) { return null; }

            int propertyCount = 0;
            foreach (JsonProperty property in root.EnumerateObject())
            {
                propertyCount++;
                if (!RequiredRequestProperties.Contains(property.Name, StringComparer.Ordinal)) { return null; }
            }

            if (propertyCount != RequiredRequestProperties.Length) { return null; }
            if (!root.TryGetProperty("schema_version", out JsonElement schema)
                || schema.ValueKind != JsonValueKind.Number
                || !schema.TryGetInt32(out int schemaVersion)
                || schemaVersion != RouterHostControlEndpoint.CurrentSchemaVersion)
            {
                return null;
            }

            if (!root.TryGetProperty("action", out JsonElement action)
                || action.ValueKind != JsonValueKind.String)
            {
                return null;
            }

            string? actionName = action.GetString();
            if (!string.Equals(actionName, StopAction, StringComparison.Ordinal)) { return null; }

            if (!root.TryGetProperty("token", out JsonElement token)
                || token.ValueKind != JsonValueKind.String)
            {
                return null;
            }

            string? provided = token.GetString();
            if (provided is null || !TokenMatches(provided)) { return null; }

            return actionName;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private bool TokenMatches(string provided)
    {
        byte[] expected = Encoding.UTF8.GetBytes(_token);
        byte[] actual = Encoding.UTF8.GetBytes(provided);
        try
        {
            return CryptographicOperations.FixedTimeEquals(actual, expected);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(actual);
            CryptographicOperations.ZeroMemory(expected);
        }
    }

    private async Task WriteResponseAsync(bool accepted, string? rejectionReason)
    {
        string json = accepted
            ? string.Create(CultureInfo.InvariantCulture, $"{{\"schema_version\":{RouterHostControlEndpoint.CurrentSchemaVersion},\"accepted\":true}}")
            : string.Create(CultureInfo.InvariantCulture, $"{{\"schema_version\":{RouterHostControlEndpoint.CurrentSchemaVersion},\"accepted\":false,\"reason\":\"{rejectionReason ?? "request_rejected"}\"}}");
        byte[] payload = Encoding.UTF8.GetBytes(json + "\n");
        try
        {
            await _pipe.WriteAsync(payload, _channelCancellation.Token).ConfigureAwait(false);
            await _pipe.FlushAsync(_channelCancellation.Token).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // A response the client never reads cannot change the decision made
            // above; the caller still learns the outcome from the Host's exit.
        }
    }

    private static void TryDelete(IFileSystem fileSystem, string path)
    {
        try
        {
            if (fileSystem.FileExists(path)) { fileSystem.DeleteFile(path); }
        }
        catch (Exception)
        {
            // The endpoint file is best-effort on shutdown only; the token is
            // bound to this process identity and dies with it.
        }
    }

    /// <summary>
    /// Writes the capability into a file whose access control is restricted to
    /// the current user from the instant the file exists. Returns false on a
    /// platform without the Windows lifecycle capability or when the private
    /// descriptor cannot be applied; the caller must then publish nothing.
    /// </summary>
    private static bool TryWriteProtectedCapability(string path, byte[] payload)
    {
        if (!OperatingSystem.IsWindows()) { return false; }
        try
        {
            WriteProtectedCapabilityWindows(path, payload);
            return true;
        }
        catch (Exception)
        {
            // Never a private message, path or value in the diagnostic.
            return false;
        }
    }

    [SupportedOSPlatform("windows")]
    private static void WriteProtectedCapabilityWindows(string path, byte[] payload)
    {
        SecurityIdentifier user = WindowsIdentity.GetCurrent().User
            ?? throw new IOException("control_endpoint_no_current_user");
        FileSecurity security = new();
        security.SetOwner(user);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            user, FileSystemRights.FullControl, AccessControlType.Allow));

        using FileStream stream = FileSystemAclExtensions.Create(
            new FileInfo(path),
            FileMode.CreateNew,
            FileSystemRights.FullControl,
            FileShare.None,
            bufferSize: 4096,
            FileOptions.WriteThrough,
            security);
        stream.Write(payload, 0, payload.Length);
        stream.Flush(flushToDisk: true);
    }
}
