// LR15-PR8: Windows handle-based deletion. No process termination or directory deletion.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexManager.Installation
{
    // The caller supplies its trusted lifecycle coordinator, not a boolean or
    // cached status. Its lease must inhibit Host starts until disposed, and each
    // assertion must verify a stopped Host for this exact installation.
    public interface IStoppedRouterLease : IDisposable { void AssertStopped(); }
    public interface IRouterLifecycleGuard
    {
        IStoppedRouterLease AcquireStopped(string installRoot, Guid installationId);
    }

    public static class WindowsOwnedFile
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInfo
        {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Disposition { [MarshalAs(UnmanagedType.Bool)] public bool Delete; }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access,
            uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInfo info);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint length, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle file,
            int infoClass, ref Disposition info, uint size);

        private static void CheckAncestors(string path)
        {
            for (string current = Path.GetFullPath(path); current != null;
                current = Path.GetDirectoryName(current))
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Linked path refused");
            }
        }
        private static SafeFileHandle Open(string path, bool deleting)
        {
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                throw new PlatformNotSupportedException("Production uninstall requires Windows handle semantics");
            string full = Path.GetFullPath(path);
            if (full.StartsWith(@"\\", StringComparison.Ordinal))
                throw new IOException("Network/device path refused");
            CheckAncestors(full);
            // No sharing: competing writers/renames/deleters fail while verified.
            // OPEN_REPARSE_POINT opens the link itself, never follows the leaf.
            SafeFileHandle handle = CreateFileW(full, 0x80000000u | (deleting ? 0x10000u : 0u),
                0, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
            if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
            return handle;
        }
        private static string CheckHandle(SafeFileHandle handle, string path)
        {
            FileInfo info;
            if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if ((info.Attributes & (0x400u | 0x10u)) != 0 || info.Links != 1)
                throw new IOException("Reparse point, directory or hard link refused");
            StringBuilder final = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandleW(handle, final, (uint)final.Capacity, 0);
            if (length == 0 || length >= final.Capacity) throw new IOException("Cannot confirm final file path");
            string resolved = final.ToString();
            if (resolved.StartsWith(@"\\?\", StringComparison.Ordinal)) resolved = resolved.Substring(4);
            if (!string.Equals(resolved, Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase))
                throw new IOException("File path replaced or aliased");
            CheckAncestors(path);
            return info.Volume.ToString("x8") + ":" + info.IndexHigh.ToString("x8") + info.IndexLow.ToString("x8");
        }
        private static void CheckContent(FileStream stream, long size, string sha256)
        {
            if (stream.Length != size) throw new IOException("Owned file size changed");
            using (SHA256 hash = SHA256.Create())
            {
                string actual = BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
                if (!string.Equals(actual, sha256, StringComparison.Ordinal)) throw new IOException("Owned file hash changed");
            }
        }
        public static string Snapshot(string path, long size, string sha256)
        {
            using (SafeFileHandle handle = Open(path, false))
            using (FileStream stream = new FileStream(handle, FileAccess.Read))
            {
                string id = CheckHandle(handle, path);
                CheckContent(stream, size, sha256);
                if (CheckHandle(handle, path) != id) throw new IOException("File identity changed");
                return id;
            }
        }
        public static void Delete(string path, long size, string sha256, string expectedIdentity, IStoppedRouterLease lease)
        {
            using (SafeFileHandle handle = Open(path, true))
            using (FileStream stream = new FileStream(handle, FileAccess.Read))
            {
                if (CheckHandle(handle, path) != expectedIdentity) throw new IOException("Owned file replaced");
                CheckContent(stream, size, sha256);
                if (CheckHandle(handle, path) != expectedIdentity) throw new IOException("Owned file replaced");
                if (lease == null) throw new IOException("Stopped lease missing");
                lease.AssertStopped();
                Disposition disposition = new Disposition { Delete = true };
                // FileDispositionInfo: delete the verified open object, never
                // resolve its pathname again. Dispose completes deletion.
                if (!SetFileInformationByHandle(handle, 4, ref disposition, (uint)Marshal.SizeOf(typeof(Disposition))))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }
}
