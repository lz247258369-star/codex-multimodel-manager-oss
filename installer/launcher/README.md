# Codex Manager native launcher

This directory contains the Windows native splash/taskbar launcher source. The launcher is compiled locally by the installer from the checked-in C# source and embedded brand icon. It keeps a branded taskbar identity alive while the PowerShell/WPF V4 window initializes, then hands off once the WPF HWND reports the Codex AppUserModelID.
