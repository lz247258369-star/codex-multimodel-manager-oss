param(
    [switch]$Desktop = $true,
    [switch]$StartMenu = $true
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$hiddenLauncher = (Resolve-Path (Join-Path $repoRoot "installer\LAUNCH_VISUAL_CONSOLE.vbs")).Path
# Compatibility note: the native CodexManager.exe owns the first-frame taskbar identity,
# then LAUNCH_VISUAL_CONSOLE.vbs still delegates through wscript.exe to the existing pwsh/WPF runtime.
$brandingHelper = (Resolve-Path (Join-Path $repoRoot "installer\scripts\branding-assets.ps1")).Path
$appIdentityHelper = (Resolve-Path (Join-Path $repoRoot "installer\scripts\windows-app-identity.ps1")).Path
$nativeLauncherBuilder = (Resolve-Path (Join-Path $repoRoot "installer\scripts\build-codex-manager-launcher.ps1")).Path
$workingDirectory = $repoRoot
$nativeLauncherPath = Join-Path $env:LOCALAPPDATA "Codex Multi-Model Manager\CodexManager.exe"

foreach ($required in @($hiddenLauncher,$brandingHelper,$appIdentityHelper,$nativeLauncherBuilder)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required installer component not found: $required"
    }
}

. $brandingHelper
. $appIdentityHelper
$brandIconPath = Get-ManagerBrandIconPath
$appUserModelId = Get-ManagerAppUserModelId
$nativeLauncherPath = & $nativeLauncherBuilder -OutputPath $nativeLauncherPath | Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace($nativeLauncherPath) -or -not (Test-Path -LiteralPath $nativeLauncherPath)) {
    throw "Native Codex Manager launcher was not created."
}
$nativeLauncherPath = (Resolve-Path -LiteralPath $nativeLauncherPath).Path

function Remove-ShortcutIfExists([string]$Path) {
    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function New-VisualConsoleShortcut([string]$Path, [string]$Description) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    Remove-ShortcutIfExists $Path
    New-ManagerShortcut `
        -Path $Path `
        -TargetPath $nativeLauncherPath `
        -Arguments ('"{0}"' -f $hiddenLauncher) `
        -WorkingDirectory $workingDirectory `
        -Description $Description `
        -IconPath $nativeLauncherPath `
        -IconIndex 0 `
        -ShowCommand 1
}

$created = @()

if ($Desktop) {
    $desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    if (-not [string]::IsNullOrWhiteSpace($desktopPath)) {
        foreach ($legacyName in @(
            "Codex Multi-Model Visual Console.lnk",
            "Codex Multi-Model Manager.lnk"
        )) {
            Remove-ShortcutIfExists (Join-Path $desktopPath $legacyName)
        }

        $desktopShortcut = Join-Path $desktopPath "Codex Manager.lnk"
        New-VisualConsoleShortcut $desktopShortcut "Open Codex Multi-Model Manager V4"
        $created += $desktopShortcut
    }
}

if ($StartMenu) {
    $programsPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    if (-not [string]::IsNullOrWhiteSpace($programsPath)) {
        $startFolder = Join-Path $programsPath "Codex Multi-Model Manager"
        Remove-ShortcutIfExists (Join-Path $startFolder "Codex Multi-Model Visual Console.lnk")

        $startShortcut = Join-Path $startFolder "Codex Multi-Model Manager.lnk"
        New-VisualConsoleShortcut $startShortcut "Open Codex Multi-Model Manager V4"
        $created += $startShortcut
    }
}

Write-Host ""
if ($created.Count -eq 0) {
    Write-Host "未创建快捷方式：Windows Desktop/Start Menu 路径不可用。" -ForegroundColor Yellow
    exit 1
}

Write-Host "V4 快捷方式已创建/刷新：" -ForegroundColor Green
foreach ($item in $created) {
    Write-Host " - $item" -ForegroundColor DarkGray
}
Write-Host "原生启动器：$nativeLauncherPath" -ForegroundColor DarkGray
Write-Host "品牌图标：$brandIconPath" -ForegroundColor DarkGray
Write-Host "Windows AppUserModelID：$appUserModelId" -ForegroundColor DarkGray
Write-Host "桌面名称：Codex Manager" -ForegroundColor Cyan
Write-Host "开始菜单名称：Codex Multi-Model Manager" -ForegroundColor Cyan
Write-Host "快捷方式现在直接启动 CodexManager.exe；它会立即提供品牌任务栏身份，再无缝接管现有 V4。" -ForegroundColor Cyan
Write-Host "桌面快捷方式遵循 Windows 的单击/双击打开设置。" -ForegroundColor DarkGray
