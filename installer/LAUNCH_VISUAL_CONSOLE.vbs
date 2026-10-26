Option Explicit

Dim shell, fso, scriptDir, repoRoot, psScript, command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Fast path: if the V4 window is already visible, bring it to the foreground.
If shell.AppActivate("Codex Multi-Model Manager V4") Then
    WScript.Quit 0
End If

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
repoRoot = fso.GetParentFolderName(scriptDir)
psScript = fso.BuildPath(scriptDir, "scripts\visual-console-single-instance.ps1")

If Not fso.FileExists(psScript) Then
    MsgBox "Visual Console single-instance launcher not found:" & vbCrLf & psScript, vbCritical, "Codex Multi-Model Manager V4"
    WScript.Quit 1
End If

shell.CurrentDirectory = repoRoot
command = "pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File """ & psScript & """"
shell.Run command, 0, False

Set fso = Nothing
Set shell = Nothing
