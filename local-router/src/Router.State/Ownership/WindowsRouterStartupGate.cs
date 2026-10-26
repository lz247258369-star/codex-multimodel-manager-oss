using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Router.State.Ownership;

/// <summary>
/// PR10A runtime coordination only; this is NOT an installation or stopped lease.
/// All enabled Hosts sharing a user SID and physical runtime directory share a
/// Windows kernel mutex. Ancestor handles deny delete/rename until Host cleanup
/// completes. A dedicated thread owns the mutex across async Host continuations.
/// </summary>
public sealed class WindowsRouterStartupGate : IDisposable
{
    /// <summary>
    /// Fixed, identifiable label raised by <see cref="Dispose"/> when the runtime
    /// directory access control could not be restored. Every other resource is
    /// released before it is raised (the coordination thread has already restored
    /// what it could and released the kernel mutex, and this object's handles are
    /// closed), so a caller can turn it into a non-zero exit without leaking.
    /// </summary>
    public const string CleanupFailedMessage = "startup_gate_cleanup_failed";

    private readonly List<SafeFileHandle> _directories;
    private readonly SafeFileHandle _mutex;
    private readonly ManualResetEventSlim _release = new(false);
    private readonly Thread _ownerThread;
    private readonly string _runtimeDirectory;
    private readonly SecurityIdentifier _sid;
    // Owned by the coordination thread exclusively: installed after the mutex is
    // acquired, restored before the mutex is released, never touched by the
    // caller thread.
    private MetadataWriteGuard? _metadataWriteGuard;
    private volatile bool _metadataRestoreFailed;
    private int _disposed;

    private WindowsRouterStartupGate(List<SafeFileHandle> directories, SafeFileHandle mutex,
        string runtimeDirectory, SecurityIdentifier sid)
    {
        _directories = directories;
        _mutex = mutex;
        _runtimeDirectory = runtimeDirectory;
        _sid = sid;
        TaskCompletionSource acquired = new(TaskCreationOptions.RunContinuationsAsynchronously);
        _ownerThread = new Thread(() => OwnMutexAndGuard(acquired))
        {
            IsBackground = true,
            Name = "Router startup coordination",
        };
        _ownerThread.Start();
        try
        {
            acquired.Task.GetAwaiter().GetResult();
        }
        catch
        {
            // The owner thread reports failure only after it has released the
            // mutex, so this join is bounded by a fixed amount of work: either the
            // guard was never installed (nothing to restore) or it was installed
            // and the thread is restoring it. Releasing _release first guarantees
            // a thread that did acquire the mutex can always leave its wait.
            _release.Set();
            _ownerThread.Join();
            _release.Dispose();
            throw;
        }
    }

    /// <summary>
    /// True when the metadata-write guard could not be restored during release.
    /// The denial residue is harmless (the next acquisition removes it) but the
    /// cleanup is never reported as fully successful.
    /// </summary>
    public bool MetadataRestoreFailed => _metadataRestoreFailed;

    /// <summary>
    /// Acquire before ownership inspection, secret resolution, listener binding
    /// or READY. The directory must be absolute, local, plain and trusted. Only
    /// its final component may be created, with an explicit current-user ACL.
    /// No PID record, cached lifecycle or manifest is used as coordination.
    /// </summary>
    public static WindowsRouterStartupGate Acquire(string runtimeDirectory)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new RouterStartupGateException("startup_gate_windows_required");
        }

        List<SafeFileHandle> directories = [];
        SafeFileHandle? mutex = null;
        string failureStage = "path_validation";
        try
        {
            string root = ValidateDirectoryPath(runtimeDirectory);
            failureStage = "user_identity";
            using WindowsIdentity identity = WindowsIdentity.GetCurrent();
            SecurityIdentifier sid = identity.User ?? throw new IOException("Missing user identity.");
            using NativeDescriptor descriptor = new($"O:{sid.Value}D:P(A;;GA;;;{sid.Value})");
            PinDirectories(root, sid, descriptor, directories, ref failureStage);
            failureStage = "volume_identity";
            FileInformation info = Information(directories[^1]);
            char[] fileSystem = new char[32];
            if (!GetVolumeInformationByHandleW(directories[^1], IntPtr.Zero, 0, out uint serial,
                out _, out _, fileSystem, (uint)fileSystem.Length)
                || !string.Equals(new string(fileSystem).TrimEnd('\0'), "NTFS", StringComparison.Ordinal)
                || serial != info.VolumeSerialNumber)
            {
                throw new IOException("A verifiable local NTFS runtime identity is required.");
            }
            string material = string.Create(CultureInfo.InvariantCulture,
                $"{sid.Value}:{info.VolumeSerialNumber:x8}:{info.FileIndexHigh:x8}:{info.FileIndexLow:x8}");
            string name = "Global\\CodexManager.Router.Startup.v1."
                + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(material)));
            SecurityAttributes attributes = descriptor.Attributes;
            failureStage = "mutex_open";
            mutex = CreateMutexExW(ref attributes, name, 0, 0x00100001 | 0x00020000);
            if (mutex.IsInvalid) { throw NativeError(); }
            // A pre-created object with unknown/broad security is not adopted.
            failureStage = "mutex_security";
            AssertSecurity(mutex, 6, sid, mutexObject: true);
            // The runtime directory is the only directory whose child files are
            // published atomically, and it is the object a reparse replacement
            // would hijack. Its metadata-write class is refused for the whole
            // coordination lifetime, applied by the constructor only after this
            // process owns the kernel mutex; the parent needs no extra guard
            // because the pinned leaf can never be deleted or renamed away (no
            // share delete), which keeps the parent permanently non-empty and
            // therefore un-reparsable.
            failureStage = "metadata_write_guard";
            return new WindowsRouterStartupGate(directories, mutex, root, sid);
        }
        catch (Exception error)
        {
            mutex?.Dispose();
            for (int index = directories.Count - 1; index >= 0; index--) { directories[index].Dispose(); }
            if (error is RouterStartupGateException) { throw; }
            throw new RouterStartupGateException("startup_gate_untrusted", error, failureStage);
        }
    }

    /// <summary>
    /// Owns the kernel mutex on this dedicated thread for the whole gate
    /// lifetime, and owns the metadata-write guard inside that ownership window:
    /// the guard is installed after the mutex is acquired and restored before the
    /// mutex is released. That ordering is what forbids two Hosts from touching
    /// the runtime directory ACL at the same time, and it gives a failed guard
    /// installation a bounded exit (the thread still releases the mutex).
    /// </summary>
    private void OwnMutexAndGuard(TaskCompletionSource acquired)
    {
        bool owns = false;
        bool restored = false;
        try
        {
            uint result = WaitForSingleObject(_mutex, 0);
            if (result == 258) { throw new RouterStartupGateException("startup_gate_busy"); }
            if (result is not (0 or 128)) { throw NativeError(); }
            // WAIT_ABANDONED permits another startup, not a claim of safe stop.
            // Bootstrap still validates/archives the existing Owner Record.
            owns = true;
            if (OperatingSystem.IsWindows())
            {
                // Installed only while this thread owns the mutex: a process that
                // lost the coordination race never reaches this line, so its
                // residue cleanup can never remove the live winner's deny ACE.
                _metadataWriteGuard = MetadataWriteGuard.Apply(_runtimeDirectory, _sid);
            }
            acquired.SetResult();
            _release.Wait();
        }
        catch (Exception error)
        {
            acquired.TrySetException(error);
        }
        finally
        {
            if (owns)
            {
                // Restore the ACL before the mutex is released: releasing first
                // would let a second Host enter coordination while this one is
                // still rewriting the same access control.
                if (_metadataWriteGuard is { } guard)
                {
                    restored = guard.TryRestore();
                    _metadataWriteGuard = null;
                    _metadataRestoreFailed = !restored;
                }

                _ = ReleaseMutex(_mutex);
            }
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) { return; }
        // The coordination thread restores the metadata-write guard and only then
        // releases the mutex, so a second Host can never enter coordination while
        // this one is still rewriting the runtime directory access control. Both
        // steps complete before the mutex and pinned directory handles are closed.
        _release.Set();
        _ownerThread.Join();
        _release.Dispose();
        _mutex.Dispose();
        for (int index = _directories.Count - 1; index >= 0; index--) { _directories[index].Dispose(); }
        // Raised last, after every mutex and directory handle is released, so a
        // cleanup failure can never leak coordination or file handles. Dispose is
        // idempotent (the interlocked guard above), so this is raised at most once.
        // The inner exception is deliberately content-free: the Host prints only
        // the exception type and the Win32 code, never a path, SID or message.
        if (_metadataRestoreFailed)
        {
            throw new RouterStartupGateException(
                CleanupFailedMessage,
                new IOException("Runtime directory access control restore failed."),
                "metadata_restore");
        }
    }

    private static string ValidateDirectoryPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)
            || path.StartsWith("\\\\", StringComparison.Ordinal) || path.Contains('/'))
        {
            throw new IOException("Local absolute directory required.");
        }
        string full = Path.GetFullPath(path).TrimEnd('\\');
        string drive = Path.GetPathRoot(full) ?? throw new IOException("Missing drive.");
        if (drive.Length != 3 || full.Length <= drive.Length || GetDriveTypeW(drive) != 3
            || string.Equals(Path.GetDirectoryName(full)?.TrimEnd('\\'), drive.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
        {
            throw new IOException("Local fixed volume required.");
        }
        // Reject traversal, ADS, device names and Win32 spelling aliases rather
        // than allowing normalization to select a different coordination root.
        foreach (string part in path[drive.Length..].TrimEnd('\\').Split('\\'))
        {
            string stem = part.Split('.')[0];
            if (part.Length == 0 || part is "." or ".." || part.EndsWith('.') || part.EndsWith(' ')
                || part.IndexOfAny([':', '<', '>', '"', '|', '?', '*']) >= 0 || part.Any(char.IsControl)
                || stem.Equals("CON", StringComparison.OrdinalIgnoreCase)
                || stem.Equals("PRN", StringComparison.OrdinalIgnoreCase)
                || stem.Equals("AUX", StringComparison.OrdinalIgnoreCase)
                || stem.Equals("NUL", StringComparison.OrdinalIgnoreCase)
                || stem.Equals("CONIN$", StringComparison.OrdinalIgnoreCase)
                || stem.Equals("CONOUT$", StringComparison.OrdinalIgnoreCase)
                || (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.OrdinalIgnoreCase)
                    || stem.StartsWith("LPT", StringComparison.OrdinalIgnoreCase))
                    && (char.IsDigit(stem[3]) || stem[3] is '¹' or '²' or '³')))
            {
                throw new IOException("Unsafe directory spelling.");
            }
        }
        return full;
    }

    [SupportedOSPlatform("windows")]
    private static void PinDirectories(string root, SecurityIdentifier sid, NativeDescriptor descriptor,
        List<SafeFileHandle> handles, ref string failureStage)
    {
        string drive = Path.GetPathRoot(root)!;
        List<string> paths = [drive];
        string current = drive;
        foreach (string part in root[drive.Length..].Split('\\'))
        {
            current = Path.Combine(current, part);
            paths.Add(current);
        }
        for (int index = 0; index < paths.Count; index++)
        {
            string path = paths[index];
            // Never share delete: that alone is what refuses renaming or deleting
            // the pinned directory (verified on Windows: a share mode without
            // FILE_SHARE_DELETE refuses DELETE-class opens with ERROR_SHARING_VIOLATION).
            //
            // The data-write class MUST be shared. Windows resolves a child-file
            // rename/replace by opening its parent directory for write access, so a
            // FILE_SHARE_READ-only handle on the file's own directory makes every
            // atomic state publication fail with ERROR_SHARING_VIOLATION(32). Sharing
            // write lets the Host publish owner/READY/STOPPED while the missing
            // FILE_SHARE_DELETE keeps the directory itself unreplaceable.
            //
            // The metadata-write class (FILE_WRITE_ATTRIBUTES) is deliberately NOT
            // left to sharing: Windows does not include it in FILE_SHARE_WRITE, so a
            // reparse (junction) replacement would still succeed on the pinned
            // directory. That class is refused by the explicit metadata-write guard
            // applied below (§ MetadataWriteGuard).
            uint sharing = 3u;
            // FILE_LIST_DIRECTORY is actual read access for Windows share-access
            // accounting. READ_CONTROL / FILE_READ_ATTRIBUTES alone do not make
            // a metadata handle enforce the requested no-write/no-delete sharing.
            const uint directoryReadAccess = 0x00020081;
            failureStage = index == paths.Count - 1 ? "runtime_directory_open" : "ancestor_directory_open";
            SafeFileHandle handle = CreateFileW(path, directoryReadAccess, sharing, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid && Marshal.GetLastWin32Error() is 2 or 3 && index == paths.Count - 1)
            {
                handle.Dispose();
                failureStage = "runtime_parent_acl";
                AssertSecurity(handles[^1], 1, sid, mutexObject: false);
                SecurityAttributes attributes = descriptor.Attributes;
                failureStage = "runtime_directory_create";
                if (!CreateDirectoryW(path, ref attributes) && Marshal.GetLastWin32Error() != 183)
                {
                    throw NativeError();
                }
                failureStage = "runtime_directory_open";
                handle = CreateFileW(path, directoryReadAccess, sharing, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            }
            if (handle.IsInvalid) { handle.Dispose(); throw NativeError(); }
            handles.Add(handle);
            failureStage = "directory_physical_identity";
            FileInformation info = Information(handle);
            if ((info.Attributes & 0x400) != 0 || (info.Attributes & 0x10) == 0)
            {
                throw new IOException("Not a plain directory.");
            }
            char[] final = new char[32768];
            uint count = GetFinalPathNameByHandleW(handle, final, (uint)final.Length, 0);
            if (count == 0 || count >= final.Length
                || !string.Equals(new string(final, 0, (int)count), "\\\\?\\" + path, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("Directory identity/path mismatch.");
            }
        }
        failureStage = "runtime_directory_acl";
        AssertSecurity(handles[^1], 1, sid, mutexObject: false);
    }

    [SupportedOSPlatform("windows")]
    private static void AssertSecurity(SafeFileHandle handle, uint kind, SecurityIdentifier sid, bool mutexObject)
    {
        uint result = GetSecurityInfo(handle, kind, 5, out _, out _, out _, out _, out IntPtr descriptor);
        if (result != 0) { throw new Win32Exception((int)result); }
        try
        {
            uint size = GetSecurityDescriptorLength(descriptor);
            byte[] bytes = new byte[checked((int)size)];
            Marshal.Copy(descriptor, bytes, 0, bytes.Length);
            RawSecurityDescriptor security = new(bytes, 0);
            // Elevated Windows processes can create legacy directories owned
            // by Administrators (the token's default owner). These privileged
            // owners are already inside the directory administration boundary;
            // kernel coordination objects must still be owned by this exact SID.
            bool administrativeOwner = !mutexObject
                && security.Owner?.Value is "S-1-5-18" or "S-1-5-32-544";
            if ((security.Owner != sid && !administrativeOwner) || security.DiscretionaryAcl is null
                || (mutexObject && (security.ControlFlags & ControlFlags.DiscretionaryAclProtected) == 0))
            {
                throw new IOException("Untrusted owner or ACL.");
            }
            foreach (GenericAce ace in security.DiscretionaryAcl)
            {
                if ((ace.AceFlags & AceFlags.InheritOnly) != 0) { continue; }
                if (ace is not CommonAce rule || rule.IsCallback) { throw new IOException("Unknown ACL rule."); }
                if (rule.AceQualifier == AceQualifier.AccessDenied)
                {
                    // An effective deny against the coordination identity or one
                    // of its groups must fail closed. Only rights the runtime
                    // actually requires are inspected: the metadata-write class is
                    // deliberately denied by the guard, and delete/rename rights
                    // are refused by directory sharing, so a deny on those is not
                    // evidence of an unusable runtime directory.
                    //
                    // Measured Windows behaviour (see the startup gate document):
                    // a deny on FILE_READ_ATTRIBUTES alone does NOT block the pin
                    // open, because Windows implicitly grants FILE_READ_ATTRIBUTES
                    // whenever any other access is granted. FILE_LIST_DIRECTORY and
                    // FILE_WRITE_DATA denials do block it.
                    const int requiredRights = 0x00000001 | 0x00000002 | 0x00020000;
                    if ((rule.AccessMask & requiredRights) != 0 && AppliesToCurrentIdentity(rule.SecurityIdentifier, sid))
                    {
                        throw new IOException("Required directory access is denied.");
                    }

                    continue;
                }
                if (rule.AceQualifier != AceQualifier.AccessAllowed) { continue; }
                bool own = rule.SecurityIdentifier == sid;
                bool administrator = !mutexObject && (rule.SecurityIdentifier.Value is "S-1-5-18" or "S-1-5-32-544");
                // Other principals may read directories, but must not replace,
                // create or alter coordination state. Kernel objects are private.
                const int mutationRights = 0x500D0156; // generic write/all, write DAC/owner/delete, file writes
                if ((!own && !administrator && (mutexObject || (rule.AccessMask & mutationRights) != 0)))
                {
                    throw new IOException("Unsafe ACL grant.");
                }
            }
        }
        finally { _ = LocalFree(descriptor); }
    }

    /// <summary>
    /// True when a deny ACE applies to this process identity: either the exact
    /// user SID or one of the SIDs carried by the current token (group deny).
    /// </summary>
    [SupportedOSPlatform("windows")]
    private static bool AppliesToCurrentIdentity(SecurityIdentifier aceSid, SecurityIdentifier userSid)
    {
        if (aceSid == userSid) { return true; }
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        foreach (IdentityReference group in identity.Groups ?? [])
        {
            if (group is SecurityIdentifier groupSid && groupSid == aceSid) { return true; }
        }

        return false;
    }

    private static FileInformation Information(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out FileInformation info)) { throw NativeError(); }
        return info;
    }

    private static Win32Exception NativeError() => new(Marshal.GetLastWin32Error());

    /// <summary>
    /// Refuses the metadata-write class (FILE_WRITE_ATTRIBUTES /
    /// FILE_WRITE_EA) on the pinned runtime directory for as long as the gate is
    /// held.
    ///
    /// Why this exists: a directory handle opened with any share mode still does
    /// not refuse FILE_WRITE_ATTRIBUTES opens, because Windows keeps the
    /// metadata-write class outside FILE_SHARE_WRITE (measured on Windows: a
    /// pinned directory refuses GENERIC_WRITE with ERROR_SHARING_VIOLATION but
    /// accepts an access mask of FILE_WRITE_ATTRIBUTES, which is exactly the
    /// access FSCTL_SET_REPARSE_POINT needs). Sharing alone therefore cannot stop
    /// a same-user junction replacement. An explicit deny ACE can, and it costs
    /// nothing the Host needs: creating, renaming and replacing child files
    /// requires FILE_ADD_FILE / FILE_DELETE_CHILD / FILE_WRITE_DATA on the
    /// directory, not the metadata-write class (verified: child create + atomic
    /// move still succeed with the guard applied).
    ///
    /// The original access control is captured and restored on release; a deny
    /// ACE left behind by a crashed predecessor is recognised as this gate's own
    /// residue and removed before the clean state is captured, so the guard
    /// heals itself instead of accumulating.
    /// </summary>
    private sealed class MetadataWriteGuard : IDisposable
    {
        // FILE_WRITE_ATTRIBUTES | FILE_WRITE_EA as a raw mask: referencing the
        // Windows-only enum members from a platform-neutral field would trip the
        // platform analyzer, and the mask is the whole point of the guard.
        private const int MetadataWriteMask = 0x00000100 | 0x00000010;

        private readonly DirectoryInfo _directory;
        private readonly byte[] _restoreForm;

        private MetadataWriteGuard(DirectoryInfo directory, byte[] restoreForm)
        {
            _directory = directory;
            _restoreForm = restoreForm;
        }

        [SupportedOSPlatform("windows")]
        public static MetadataWriteGuard Apply(string runtimeDirectory, SecurityIdentifier sid)
        {
            FileSystemRights metadataWriteRights = (FileSystemRights)MetadataWriteMask;
            DirectoryInfo directory = new(runtimeDirectory);
            DirectorySecurity security = directory.GetAccessControl(AccessControlSections.Access);

            // Drop a residue of our own shape first: an earlier process that was
            // killed between apply and restore must not make this run capture a
            // guarded ACL as its "original" state.
            bool residue = false;
            foreach (FileSystemAccessRule rule in security.GetAccessRules(includeExplicit: true, includeInherited: false, typeof(SecurityIdentifier)))
            {
                if (rule.AccessControlType != AccessControlType.Deny || rule.IdentityReference != sid) { continue; }
                if ((rule.FileSystemRights & metadataWriteRights) != metadataWriteRights) { continue; }
                if ((rule.FileSystemRights & ~(metadataWriteRights | FileSystemRights.Synchronize)) != 0) { continue; }
                security.RemoveAccessRuleSpecific(rule);
                residue = true;
            }

            // Inherited grants are materialised once, so the guard survives for
            // the whole process lifetime even though the parent is shared with
            // other tooling. The captured form below is what release restores.
            security.SetAccessRuleProtection(true, true);
            if (residue) { directory.SetAccessControl(security); }

            byte[] restoreForm = security.GetSecurityDescriptorBinaryForm();
            security.AddAccessRule(new FileSystemAccessRule(sid, metadataWriteRights, AccessControlType.Deny));
            directory.SetAccessControl(security);
            return new MetadataWriteGuard(directory, restoreForm);
        }

        /// <summary>
        /// Restores the captured access control. Returns false when the restore
        /// failed: the caller must not report a fully clean shutdown then.
        /// </summary>
        /// <summary>
        /// Restores the captured access control. Returns false when the restore
        /// failed: the caller must not report a fully clean shutdown then.
        /// </summary>
        public bool TryRestore()
        {
            if (!OperatingSystem.IsWindows()) { return true; }
            return RestoreCore();
        }

        [SupportedOSPlatform("windows")]
        private bool RestoreCore()
        {
            try
            {
                DirectorySecurity restore = new();
                // Access section only: writing the SACL needs SeSecurityPrivilege,
                // which the Host deliberately does not require. The captured form
                // is applied as a DACL-only restore.
                restore.SetSecurityDescriptorBinaryForm(_restoreForm, AccessControlSections.Access);
                _directory.SetAccessControl(restore);
                return true;
            }
            catch (Exception error)
            {
                // Never silent: a residue is harmless (the next acquisition
                // removes it) but the operator must still see that cleanup failed.
                Console.Error.WriteLine($"[local-router] startup_gate_acl_restore_failed: the runtime directory access control could not be restored; the next startup removes the residue. cause={error.GetType().Name} hresult={error.HResult:x8}");
                return false;
            }
        }

        public void Dispose() => _ = TryRestore();
    }

    private sealed class NativeDescriptor : IDisposable
    {
        private readonly IntPtr _descriptor;
        public NativeDescriptor(string sddl)
        {
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, out _descriptor, out _))
            {
                throw NativeError();
            }
        }
        public SecurityAttributes Attributes => new()
        {
            Length = Marshal.SizeOf<SecurityAttributes>(), Descriptor = _descriptor,
        };
        public void Dispose() => _ = LocalFree(_descriptor);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes { public int Length; public IntPtr Descriptor; public int InheritHandle; }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, AccessTime, WriteTime;
        public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateDirectoryW(string path, ref SecurityAttributes security);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern SafeFileHandle CreateMutexExW(ref SecurityAttributes security, string name, uint flags, uint access);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern uint WaitForSingleObject(SafeFileHandle handle, uint milliseconds);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReleaseMutex(SafeFileHandle handle);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, [Out] char[] path, uint size, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint GetDriveTypeW(string root);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumeInformationByHandleW(SafeFileHandle handle, IntPtr volumeName, uint volumeNameSize,
        out uint serialNumber, out uint maxComponentLength, out uint flags, [Out] char[] fileSystem, uint fileSystemSize);
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern uint GetSecurityInfo(SafeFileHandle handle, uint kind, uint information, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
    [DllImport("advapi32.dll", ExactSpelling = true)]
    private static extern uint GetSecurityDescriptorLength(IntPtr descriptor);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, uint revision, out IntPtr descriptor, out uint size);
    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern IntPtr LocalFree(IntPtr memory);
}

/// <summary>Sanitized coordination refusal; no paths, keys or process arguments are logged.</summary>
public sealed class RouterStartupGateException : IOException
{
    public RouterStartupGateException(string message) : base(message) { }
    public RouterStartupGateException(string message, Exception innerException) : base(message, innerException) { }
    internal RouterStartupGateException(string message, Exception innerException, string failureStage)
        : base(message, innerException) { FailureStage = failureStage; }
    /// <summary>Fixed diagnostic label; never contains a path, SID or exception message.</summary>
    public string FailureStage { get; } = "coordination";
}
