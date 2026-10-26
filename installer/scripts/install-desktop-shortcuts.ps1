param(
    [switch]$Desktop = $true,
    [switch]$StartMenu = $true
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$hiddenLauncher = (Resolve-Path (Join-Path $repoRoot "installer\LAUNCH_DESKTOP_CONTROLLER.vbs")).Path
$workingDirectory = $repoRoot
$wscript = Join-Path $env:WINDIR "System32\wscript.exe"

if (-not (Test-Path -LiteralPath $wscript)) {
    throw "Windows Script Host not found: $wscript"
}

function New-ControllerShortcut([string]$Path, [string]$Description) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $wscript
    $shortcut.Arguments = ('"{0}"' -f $hiddenLauncher)
    $shortcut.WorkingDirectory = $workingDirectory
    $shortcut.Description = $Description
    $shortcut.WindowStyle = 7
    $shortcut.Save()
}

$created = @()

if ($Desktop) {
    $desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    if (-not [string]::IsNullOrWhiteSpace($desktopPath)) {
        $desktopShortcut = Join-Path $desktopPath "Codex Multi-Model Controller.lnk"
        New-ControllerShortcut $desktopShortcut "Open Codex Multi-Model Desktop Controller without a console window"
        $created += $desktopShortcut
    }
}

if ($StartMenu) {
    $programsPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    if (-not [string]::IsNullOrWhiteSpace($programsPath)) {
        $startFolder = Join-Path $programsPath "Codex Multi-Model Manager"
        $startShortcut = Join-Path $startFolder "Codex Multi-Model Controller.lnk"
        New-ControllerShortcut $startShortcut "Open Codex Multi-Model Desktop Controller without a console window"
        $created += $startShortcut
    }
}

Write-Host ""
if ($created.Count -eq 0) {
    Write-Host "未创建快捷方式：Windows Desktop/Start Menu 路径不可用。" -ForegroundColor Yellow
    exit 1
}

Write-Host "快捷方式已创建/刷新（静默 GUI 启动）：" -ForegroundColor Green
foreach ($item in $created) {
    Write-Host " - $item" -ForegroundColor DarkGray
}
Write-Host "以后从桌面或开始菜单打开 Controller 时，不再弹出 PowerShell/Windows Terminal 窗口。" -ForegroundColor Cyan
