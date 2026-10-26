using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Codex Manager")]
[assembly: System.Reflection.AssemblyProduct("Codex Multi-Model Manager")]
[assembly: System.Reflection.AssemblyDescription("Native Windows launcher for Codex Multi-Model Manager V4")]
[assembly: System.Reflection.AssemblyCompany("Codex Manager")]
[assembly: System.Reflection.AssemblyVersion("4.0.0.0")]

namespace CodexManagerLauncher
{
    internal static class Program
    {
        private const string AppId = "Codex.MultiModelManager.V4";
        private const string WindowTitle = "Codex Multi-Model Manager V4";
        private const string LauncherMutex = "Local\\CodexManagerNativeLauncherV1";
        private const int SW_RESTORE = 9;

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

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

            public string Value
            {
                get
                {
                    if (valueType == (ushort)VarEnum.VT_EMPTY ||
                        valueType == (ushort)VarEnum.VT_NULL ||
                        ptr == IntPtr.Zero)
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

        [STAThread]
        private static void Main(string[] args)
        {
            try { SetCurrentProcessExplicitAppUserModelID(AppId); } catch { }

            IntPtr existing = FindWindow(null, WindowTitle);
            if (existing != IntPtr.Zero)
            {
                Activate(existing);
                return;
            }

            bool createdNew;
            using (Mutex mutex = new Mutex(true, LauncherMutex, out createdNew))
            {
                if (!createdNew)
                {
                    existing = FindWindow(null, WindowTitle);
                    if (existing != IntPtr.Zero) Activate(existing);
                    return;
                }

                if (args == null || args.Length < 1 || String.IsNullOrWhiteSpace(args[0]) || !File.Exists(args[0]))
                {
                    MessageBox.Show(
                        "Codex Manager 启动入口不存在。请重新运行快捷方式安装器。",
                        "Codex Manager",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
                    return;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using (StartupForm startup = new StartupForm(args[0]))
                {
                    Application.Run(startup);
                }
            }
        }

        private static void Activate(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return;
            ShowWindow(hwnd, SW_RESTORE);
            SetForegroundWindow(hwnd);
        }

        private static string GetWindowAppId(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return String.Empty;
            IPropertyStore store = null;
            Guid iid = PropertyStoreGuid;
            int hr = SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
            if (hr < 0 || store == null) return String.Empty;

            try
            {
                PropertyKey key = AppUserModelIdKey;
                using (PropVariant value = new PropVariant())
                {
                    uint result = store.GetValue(ref key, value);
                    if (unchecked((int)result) < 0) return String.Empty;
                    return value.Value;
                }
            }
            catch
            {
                return String.Empty;
            }
            finally
            {
                if (store != null && Marshal.IsComObject(store))
                {
                    Marshal.FinalReleaseComObject(store);
                }
            }
        }

        private sealed class StartupForm : Form
        {
            private readonly string launcherScript;
            private readonly System.Windows.Forms.Timer pollTimer;
            private readonly Label statusLabel;
            private readonly DateTime startedAt;
            private int brandedReadyTicks;

            public StartupForm(string launcherScript)
            {
                this.launcherScript = launcherScript;
                this.startedAt = DateTime.UtcNow;
                this.brandedReadyTicks = 0;

                Text = "Codex Manager";
                Width = 430;
                Height = 176;
                StartPosition = FormStartPosition.CenterScreen;
                FormBorderStyle = FormBorderStyle.FixedSingle;
                MaximizeBox = false;
                MinimizeBox = false;
                ShowInTaskbar = true;
                BackColor = Color.FromArgb(7, 15, 29);
                ForeColor = Color.White;

                try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

                Panel accent = new Panel();
                accent.BackColor = Color.FromArgb(92, 92, 255);
                accent.Location = new Point(0, 0);
                accent.Size = new Size(8, ClientSize.Height);
                accent.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left;
                Controls.Add(accent);

                Label title = new Label();
                title.AutoSize = true;
                title.Text = "CODEX MANAGER";
                title.Font = new Font("Segoe UI", 16F, FontStyle.Bold, GraphicsUnit.Point);
                title.ForeColor = Color.FromArgb(245, 247, 255);
                title.Location = new Point(30, 28);
                Controls.Add(title);

                Label subtitle = new Label();
                subtitle.AutoSize = true;
                subtitle.Text = "Multi-Model Manager V4";
                subtitle.Font = new Font("Segoe UI", 9.5F, FontStyle.Regular, GraphicsUnit.Point);
                subtitle.ForeColor = Color.FromArgb(151, 166, 194);
                subtitle.Location = new Point(32, 64);
                Controls.Add(subtitle);

                statusLabel = new Label();
                statusLabel.AutoSize = true;
                statusLabel.Text = "正在启动工作台…";
                statusLabel.Font = new Font("Segoe UI", 10F, FontStyle.Regular, GraphicsUnit.Point);
                statusLabel.ForeColor = Color.FromArgb(69, 211, 171);
                statusLabel.Location = new Point(32, 106);
                Controls.Add(statusLabel);

                pollTimer = new System.Windows.Forms.Timer();
                pollTimer.Interval = 100;
                pollTimer.Tick += OnPoll;

                Shown += OnShown;
                FormClosing += delegate { pollTimer.Stop(); };
            }

            private void OnShown(object sender, EventArgs e)
            {
                try
                {
                    string wscript = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "wscript.exe");
                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = wscript;
                    psi.Arguments = "\"" + launcherScript + "\"";
                    psi.WorkingDirectory = Path.GetDirectoryName(launcherScript) ?? Environment.CurrentDirectory;
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    Process.Start(psi);
                    pollTimer.Start();
                }
                catch (Exception ex)
                {
                    MessageBox.Show(
                        "Codex Manager 启动失败：\r\n" + ex.Message,
                        "Codex Manager",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
                    Close();
                }
            }

            private void OnPoll(object sender, EventArgs e)
            {
                IntPtr hwnd = FindWindow(null, WindowTitle);
                if (hwnd != IntPtr.Zero)
                {
                    statusLabel.Text = "正在连接工作台…";
                    string windowAppId = GetWindowAppId(hwnd);
                    if (String.Equals(windowAppId, AppId, StringComparison.Ordinal))
                    {
                        brandedReadyTicks++;
                        if (brandedReadyTicks >= 3)
                        {
                            pollTimer.Stop();
                            Program.Activate(hwnd);
                            Close();
                            return;
                        }
                    }
                    else
                    {
                        brandedReadyTicks = 0;
                    }

                    if ((DateTime.UtcNow - startedAt).TotalSeconds >= 8)
                    {
                        pollTimer.Stop();
                        Program.Activate(hwnd);
                        Close();
                        return;
                    }
                }

                if ((DateTime.UtcNow - startedAt).TotalSeconds >= 30)
                {
                    pollTimer.Stop();
                    MessageBox.Show(
                        "Codex Manager 启动超时。请检查 PowerShell 7 和 V4 启动脚本。",
                        "Codex Manager",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Warning);
                    Close();
                }
            }
        }
    }
}
