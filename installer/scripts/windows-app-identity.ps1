$ErrorActionPreference = "Stop"

$script:ManagerAppUserModelId = "Codex.MultiModelManager.V4"

if (-not ("CodexManager.Windows.AppIdentity" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using ComTypes = System.Runtime.InteropServices.ComTypes;

namespace CodexManager.Windows
{
    public static class AppIdentity
    {
        private const int STGM_READ = 0x00000000;

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        [DllImport("shell32.dll", PreserveSig = true)]
        private static extern int SHGetPropertyStoreForWindow(
            IntPtr hwnd,
            ref Guid riid,
            [MarshalAs(UnmanagedType.Interface)] out IPropertyStore propertyStore);

        [DllImport("Ole32.dll", PreserveSig = false)]
        private static extern void PropVariantClear([In, Out] PropVariant pvar);

        [ComImport]
        [ClassInterface(ClassInterfaceType.None)]
        [Guid("00021401-0000-0000-C000-000000000046")]
        private class ShellLinkClass
        {
        }

        [ComImport]
        [Guid("000214F9-0000-0000-C000-000000000046")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellLinkW
        {
            [PreserveSig] uint GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
            [PreserveSig] uint GetIDList(out IntPtr ppidl);
            [PreserveSig] uint SetIDList(IntPtr pidl);
            [PreserveSig] uint GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
            [PreserveSig] uint SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
            [PreserveSig] uint GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
            [PreserveSig] uint SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
            [PreserveSig] uint GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
            [PreserveSig] uint SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
            [PreserveSig] uint GetHotKey(out ushort pwHotkey);
            [PreserveSig] uint SetHotKey(ushort wHotKey);
            [PreserveSig] uint GetShowCmd(out int piShowCmd);
            [PreserveSig] uint SetShowCmd(int iShowCmd);
            [PreserveSig] uint GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
            [PreserveSig] uint SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
            [PreserveSig] uint SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
            [PreserveSig] uint Resolve(IntPtr hwnd, uint fFlags);
            [PreserveSig] uint SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
        }

        [ComImport]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
        private interface IPropertyStore
        {
            [PreserveSig] uint GetCount([Out] out uint cProps);
            [PreserveSig] uint GetAt([In] uint iProp, out PropertyKey pkey);
            [PreserveSig] uint GetValue([In] ref PropertyKey key, [Out] PropVariant pv);
            [PreserveSig] uint SetValue([In] ref PropertyKey key, [In] PropVariant pv);
            [PreserveSig] uint Commit();
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct PropertyKey
        {
            private Guid formatId;
            private Int32 propertyId;

            public PropertyKey(Guid formatId, Int32 propertyId)
            {
                this.formatId = formatId;
                this.propertyId = propertyId;
            }
        }

        [StructLayout(LayoutKind.Explicit)]
        private sealed class PropVariant : IDisposable
        {
            [FieldOffset(0)] private ushort valueType;
            [FieldOffset(8)] private IntPtr ptr;

            public PropVariant()
            {
            }

            public PropVariant(string value)
            {
                if (value == null) throw new ArgumentNullException("value");
                valueType = (ushort)VarEnum.VT_LPWSTR;
                ptr = Marshal.StringToCoTaskMemUni(value);
            }

            public string Value
            {
                get
                {
                    if (valueType == (ushort)VarEnum.VT_EMPTY || valueType == (ushort)VarEnum.VT_NULL || ptr == IntPtr.Zero)
                    {
                        return String.Empty;
                    }
                    return Marshal.PtrToStringUni(ptr) ?? String.Empty;
                }
            }

            public void Dispose()
            {
                PropVariantClear(this);
                GC.SuppressFinalize(this);
            }

            ~PropVariant()
            {
                Dispose();
            }
        }

        private static readonly PropertyKey AppUserModelIdKey =
            new PropertyKey(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);

        private static readonly Guid PropertyStoreGuid =
            new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");

        private static void VerifySucceeded(uint hr)
        {
            int signed = unchecked((int)hr);
            if (signed < 0)
            {
                Marshal.ThrowExceptionForHR(signed);
            }
        }

        private static void VerifySucceeded(int hr)
        {
            if (hr < 0)
            {
                Marshal.ThrowExceptionForHR(hr);
            }
        }

        public static void SetCurrentProcessAppId(string appId)
        {
            if (String.IsNullOrWhiteSpace(appId))
            {
                throw new ArgumentException("AppUserModelID must not be empty.", "appId");
            }

            VerifySucceeded(SetCurrentProcessExplicitAppUserModelID(appId));
        }

        public static void SetWindowAppId(IntPtr hwnd, string appId)
        {
            if (hwnd == IntPtr.Zero) throw new ArgumentException("Window handle must not be zero.", "hwnd");
            if (String.IsNullOrWhiteSpace(appId)) throw new ArgumentException("AppUserModelID must not be empty.", "appId");

            IPropertyStore propertyStore = null;
            Guid iid = PropertyStoreGuid;
            VerifySucceeded(SHGetPropertyStoreForWindow(hwnd, ref iid, out propertyStore));
            try
            {
                PropertyKey key = AppUserModelIdKey;
                using (PropVariant value = new PropVariant(appId))
                {
                    VerifySucceeded(propertyStore.SetValue(ref key, value));
                    VerifySucceeded(propertyStore.Commit());
                }
            }
            finally
            {
                if (propertyStore != null && Marshal.IsComObject(propertyStore))
                {
                    Marshal.FinalReleaseComObject(propertyStore);
                }
            }
        }

        public static string GetWindowAppId(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return String.Empty;

            IPropertyStore propertyStore = null;
            Guid iid = PropertyStoreGuid;
            VerifySucceeded(SHGetPropertyStoreForWindow(hwnd, ref iid, out propertyStore));
            try
            {
                PropertyKey key = AppUserModelIdKey;
                using (PropVariant value = new PropVariant())
                {
                    VerifySucceeded(propertyStore.GetValue(ref key, value));
                    return value.Value;
                }
            }
            finally
            {
                if (propertyStore != null && Marshal.IsComObject(propertyStore))
                {
                    Marshal.FinalReleaseComObject(propertyStore);
                }
            }
        }

        public static void CreateShortcut(
            string shortcutPath,
            string targetPath,
            string arguments,
            string workingDirectory,
            string description,
            string iconPath,
            int iconIndex,
            int showCommand,
            string appId)
        {
            if (String.IsNullOrWhiteSpace(shortcutPath)) throw new ArgumentException("Shortcut path must not be empty.", "shortcutPath");
            if (String.IsNullOrWhiteSpace(targetPath)) throw new ArgumentException("Target path must not be empty.", "targetPath");
            if (String.IsNullOrWhiteSpace(appId)) throw new ArgumentException("AppUserModelID must not be empty.", "appId");

            IShellLinkW shellLink = null;
            try
            {
                shellLink = (IShellLinkW)new ShellLinkClass();
                VerifySucceeded(shellLink.SetPath(targetPath));
                VerifySucceeded(shellLink.SetArguments(arguments ?? String.Empty));
                VerifySucceeded(shellLink.SetWorkingDirectory(workingDirectory ?? String.Empty));
                VerifySucceeded(shellLink.SetDescription(description ?? String.Empty));
                if (!String.IsNullOrWhiteSpace(iconPath))
                {
                    VerifySucceeded(shellLink.SetIconLocation(iconPath, iconIndex));
                }
                VerifySucceeded(shellLink.SetShowCmd(showCommand));

                IPropertyStore propertyStore = (IPropertyStore)shellLink;
                PropertyKey key = AppUserModelIdKey;
                using (PropVariant value = new PropVariant(appId))
                {
                    VerifySucceeded(propertyStore.SetValue(ref key, value));
                    VerifySucceeded(propertyStore.Commit());
                }

                ComTypes.IPersistFile persistFile = (ComTypes.IPersistFile)shellLink;
                persistFile.Save(shortcutPath, true);
            }
            finally
            {
                if (shellLink != null && Marshal.IsComObject(shellLink))
                {
                    Marshal.FinalReleaseComObject(shellLink);
                }
            }
        }

        public static string GetShortcutAppId(string shortcutPath)
        {
            if (!File.Exists(shortcutPath)) return String.Empty;

            IShellLinkW shellLink = null;
            try
            {
                shellLink = (IShellLinkW)new ShellLinkClass();
                ComTypes.IPersistFile persistFile = (ComTypes.IPersistFile)shellLink;
                persistFile.Load(shortcutPath, STGM_READ);

                IPropertyStore propertyStore = (IPropertyStore)shellLink;
                PropertyKey key = AppUserModelIdKey;
                using (PropVariant value = new PropVariant())
                {
                    VerifySucceeded(propertyStore.GetValue(ref key, value));
                    return value.Value;
                }
            }
            finally
            {
                if (shellLink != null && Marshal.IsComObject(shellLink))
                {
                    Marshal.FinalReleaseComObject(shellLink);
                }
            }
        }
    }
}
'@ -Language CSharp
}

function Get-ManagerAppUserModelId {
    return $script:ManagerAppUserModelId
}

function Set-ManagerCurrentProcessAppIdentity {
    [CodexManager.Windows.AppIdentity]::SetCurrentProcessAppId($script:ManagerAppUserModelId)
}

function Set-ManagerWindowAppIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$WindowHandle
    )

    [CodexManager.Windows.AppIdentity]::SetWindowAppId($WindowHandle, $script:ManagerAppUserModelId)
}

function Get-ManagerWindowAppIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$WindowHandle
    )

    return [CodexManager.Windows.AppIdentity]::GetWindowAppId($WindowHandle)
}

function New-ManagerShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $false)][string]$Arguments = "",
        [Parameter(Mandatory = $false)][string]$WorkingDirectory = "",
        [Parameter(Mandatory = $false)][string]$Description = "",
        [Parameter(Mandatory = $false)][string]$IconPath = "",
        [Parameter(Mandatory = $false)][int]$IconIndex = 0,
        [Parameter(Mandatory = $false)][int]$ShowCommand = 7
    )

    [CodexManager.Windows.AppIdentity]::CreateShortcut(
        $Path,
        $TargetPath,
        $Arguments,
        $WorkingDirectory,
        $Description,
        $IconPath,
        $IconIndex,
        $ShowCommand,
        $script:ManagerAppUserModelId
    )
}

function Get-ManagerShortcutAppIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [CodexManager.Windows.AppIdentity]::GetShortcutAppId($Path)
}
