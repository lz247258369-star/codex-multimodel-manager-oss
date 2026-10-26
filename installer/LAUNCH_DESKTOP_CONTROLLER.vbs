Option Explicit

Dim shell, fso, scriptDir, repoRoot, psScript, command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
repoRoot = fso.GetParentFolderName(scriptDir)
psScript = fso.BuildPath(scriptDir, "scripts\desktop-controller.ps1")

If Not fso.FileExists(psScript) Then
    MsgBox "Desktop Controller script not found:" & vbCrLf & psScript, vbCritical, "Codex Multi-Model Controller"
    WScript.Quit 1
End If

shell.CurrentDirectory = repoRoot
command = "pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File """ & psScript & """"

' Window style 0 hides the console host while the WPF window remains visible.
shell.Run command, 0, False

Set fso = Nothing
Set shell = Nothing
