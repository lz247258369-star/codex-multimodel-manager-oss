param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) {
    Write-Host "PASS  $Message" -ForegroundColor Green
}

function Fail([string]$Message) {
    $failures.Add($Message)
    Write-Host "FAIL  $Message" -ForegroundColor Red
}

$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$cmdPath = Join-Path $RepositoryRoot "installer/INSTALL_DESKTOP_SHORTCUTS.cmd"
$scriptPath = Join-Path $RepositoryRoot "installer/scripts/install-desktop-shortcuts.ps1"
$hiddenLauncherPath = Join-Path $RepositoryRoot "installer/LAUNCH_DESKTOP_CONTROLLER.vbs"
$setupPath = Join-Path $RepositoryRoot "installer/setup.ps1"

foreach ($path in @($cmdPath, $scriptPath, $hiddenLauncherPath, $setupPath)) {
    if (Test-Path $path) { Pass "Exists: $($path.Substring($RepositoryRoot.Length + 1))" }
    else { Fail "Missing: $($path.Substring($RepositoryRoot.Length + 1))" }
}

if (Test-Path $scriptPath) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -eq 0) { Pass "PowerShell parses: installer/scripts/install-desktop-shortcuts.ps1" }
    else {
        foreach ($err in $errors) { Fail "Shortcut installer parse error: $($err.Message)" }
    }

    $script = Get-Content $scriptPath -Raw
    foreach ($needle in @(
        'DesktopDirectory',
        'SpecialFolder\]::Programs',
        'LAUNCH_DESKTOP_CONTROLLER\.vbs',
        'System32\\wscript\.exe',
        'WScript\.Shell',
        'CreateShortcut',
        '\.Arguments',
        'WorkingDirectory'
    )) {
        if ($script -match $needle) { Pass "Shortcut installer contains expected behavior: $needle" }
        else { Fail "Shortcut installer missing expected behavior: $needle" }
    }

    if ($script -match 'TargetPath\s*=\s*\$launcher' -or $script -match 'CODEX_DESKTOP_CONTROLLER\.cmd') {
        Fail "Desktop shortcut still targets the visible CMD launcher"
    }
    else { Pass "Desktop shortcut no longer targets the visible CMD launcher" }

    if ($script -match '(?im)\bgit\s+(reset|clean|stash)\b') {
        Fail "Shortcut installer contains a forbidden destructive Git command"
    }
    else { Pass "Shortcut installer does not reset/clean/stash Git worktrees" }
}

if (Test-Path $hiddenLauncherPath) {
    $hidden = Get-Content $hiddenLauncherPath -Raw
    foreach ($needle in @(
        'WScript\.Shell',
        'desktop-controller\.ps1',
        'pwsh\.exe -NoProfile -STA',
        'shell\.Run command, 0, False'
    )) {
        if ($hidden -match $needle) { Pass "Hidden launcher contains expected behavior: $needle" }
        else { Fail "Hidden launcher missing expected behavior: $needle" }
    }
}

if (Test-Path $cmdPath) {
    $cmd = Get-Content $cmdPath -Raw
    if ($cmd -match '(?i)pwsh\.exe' -and $cmd -match 'install-desktop-shortcuts\.ps1') {
        Pass "Shortcut entrypoint uses PowerShell 7 and targets shortcut installer"
    }
    else { Fail "Shortcut entrypoint is missing pwsh or shortcut installer target" }
}

if (Test-Path $setupPath) {
    $setup = Get-Content $setupPath -Raw
    foreach ($needle in @(
        'Install-DesktopEntrypoints',
        '11\. 安装 Desktop Controller 桌面/开始菜单入口',
        '是否创建/刷新 Desktop Controller 桌面与开始菜单快捷方式'
    )) {
        if ($setup -match $needle) { Pass "Setup contains expected shortcut integration: $needle" }
        else { Fail "Setup missing shortcut integration: $needle" }
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Desktop shortcut validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "Desktop shortcut validation PASSED" -ForegroundColor Green
exit 0
