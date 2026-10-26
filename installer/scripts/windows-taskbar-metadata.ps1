$ErrorActionPreference = "Stop"

$script:ManagerTaskbarAppUserModelId = "Codex.MultiModelManager.V4"

if (-not ("CodexManager.Windows.TaskbarMetadata" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexManager.Windows
{
    public static class TaskbarMetadata
    {
        [DllImport("shell32.dll", PreserveSig = true)]
        private static extern int SHGetPropertyStoreForWindow(
            IntPtr hwnd,
            ref Guid riid,
            [MarshalAs(UnmanagedType.Interface)] out IPropertyStore propertyStore);

        [DllImport("Ole32.dll", PreserveSig = false)]
        private static extern void PropVariantClear([In, Out] PropVariant pvar);

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

        private static readonly Guid AppUserModelFormatId =
            new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

        private static readonly Guid PropertyStoreGuid =
            new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");

        private static readonly PropertyKey RelaunchCommandKey =
            new PropertyKey(AppUserModelFormatId, 2);
        private static readonly PropertyKey RelaunchIconResourceKey =
            new PropertyKey(AppUserModelFormatId, 3);
        private static readonly PropertyKey RelaunchDisplayNameResourceKey =
            new PropertyKey(AppUserModelFormatId, 4);
        private static readonly PropertyKey AppUserModelIdKey =
            new PropertyKey(AppUserModelFormatId, 5);

        private static void VerifySucceeded(uint hr)
        {
            int signed = unchecked((int)hr);
            if (signed < 0) Marshal.ThrowExceptionForHR(signed);
        }

        private static void VerifySucceeded(int hr)
        {
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        }

        private static void SetString(IPropertyStore store, PropertyKey key, string value)
        {
            using (PropVariant variant = new PropVariant(value ?? String.Empty))
            {
                VerifySucceeded(store.SetValue(ref key, variant));
            }
        }

        private static string GetString(IPropertyStore store, PropertyKey key)
        {
            using (PropVariant variant = new PropVariant())
            {
                VerifySucceeded(store.GetValue(ref key, variant));
                return variant.Value;
            }
        }

        public static void SetWindowMetadata(
            IntPtr hwnd,
            string appId,
            string relaunchCommand,
            string displayName,
            string iconResource)
        {
            if (hwnd == IntPtr.Zero) throw new ArgumentException("Window handle must not be zero.", "hwnd");
            if (String.IsNullOrWhiteSpace(appId)) throw new ArgumentException("AppUserModelID must not be empty.", "appId");
            if (String.IsNullOrWhiteSpace(relaunchCommand)) throw new ArgumentException("Relaunch command must not be empty.", "relaunchCommand");
            if (String.IsNullOrWhiteSpace(displayName)) throw new ArgumentException("Display name must not be empty.", "displayName");
            if (String.IsNullOrWhiteSpace(iconResource)) throw new ArgumentException("Icon resource must not be empty.", "iconResource");

            IPropertyStore propertyStore = null;
            Guid iid = PropertyStoreGuid;
            VerifySucceeded(SHGetPropertyStoreForWindow(hwnd, ref iid, out propertyStore));
            try
            {
                SetString(propertyStore, AppUserModelIdKey, appId);
                SetString(propertyStore, RelaunchCommandKey, relaunchCommand);
                SetString(propertyStore, RelaunchDisplayNameResourceKey, displayName);
                SetString(propertyStore, RelaunchIconResourceKey, iconResource);
                VerifySucceeded(propertyStore.Commit());
            }
            finally
            {
                if (propertyStore != null && Marshal.IsComObject(propertyStore))
                {
                    Marshal.FinalReleaseComObject(propertyStore);
                }
            }
        }

        public static string[] GetWindowMetadata(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) throw new ArgumentException("Window handle must not be zero.", "hwnd");

            IPropertyStore propertyStore = null;
            Guid iid = PropertyStoreGuid;
            VerifySucceeded(SHGetPropertyStoreForWindow(hwnd, ref iid, out propertyStore));
            try
            {
                return new string[]
                {
                    GetString(propertyStore, AppUserModelIdKey),
                    GetString(propertyStore, RelaunchCommandKey),
                    GetString(propertyStore, RelaunchDisplayNameResourceKey),
                    GetString(propertyStore, RelaunchIconResourceKey)
                };
            }
            finally
            {
                if (propertyStore != null && Marshal.IsComObject(propertyStore))
                {
                    Marshal.FinalReleaseComObject(propertyStore);
                }
            }
        }
    }
}
'@ -Language CSharp
}

function Set-ManagerWindowTaskbarMetadata {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$WindowHandle,
        [Parameter(Mandatory = $true)][string]$RelaunchCommand,
        [Parameter(Mandatory = $false)][string]$DisplayName = "Codex Manager",
        [Parameter(Mandatory = $true)][string]$IconPath
    )

    $iconResource = "$IconPath,0"
    [CodexManager.Windows.TaskbarMetadata]::SetWindowMetadata(
        $WindowHandle,
        $script:ManagerTaskbarAppUserModelId,
        $RelaunchCommand,
        $DisplayName,
        $iconResource
    )
}

function Get-ManagerWindowTaskbarMetadata {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$WindowHandle
    )

    $values = [CodexManager.Windows.TaskbarMetadata]::GetWindowMetadata($WindowHandle)
    return [pscustomobject]@{
        AppUserModelId = [string]$values[0]
        RelaunchCommand = [string]$values[1]
        DisplayName = [string]$values[2]
        IconResource = [string]$values[3]
    }
}
