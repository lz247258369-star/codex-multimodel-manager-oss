param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

$sourcePath = Join-Path $RepositoryRoot "installer/launcher/CodexManagerLauncher.cs"
$buildPath = Join-Path $RepositoryRoot "installer/scripts/build-codex-manager-launcher.ps1"
$installerPath = Join-Path $RepositoryRoot "installer/scripts/install-visual-console-shortcuts.ps1"
$runtimePath = Join-Path $RepositoryRoot "installer/scripts/visual-combo-display-runtime.ps1"

foreach ($path in @($sourcePath,$buildPath,$installerPath,$runtimePath)) {
    if (Test-Path -LiteralPath $path) { Pass "Exists: $($path.Substring($RepositoryRoot.Length + 1))" }
    else { Fail "Missing: $($path.Substring($RepositoryRoot.Length + 1))" }
}

if (Test-Path -LiteralPath $sourcePath) {
    $source = Get-Content -Raw -LiteralPath $sourcePath
    foreach ($needle in @(
        'Codex.MultiModelManager.V4',
        'Codex Multi-Model Manager V4',
        'SetCurrentProcessExplicitAppUserModelID',
        'SHGetPropertyStoreForWindow',
        'FindWindow',
        'Application.Run',
        'StartupForm',
        'ShowInTaskbar = true',
        'GetWindowAppId',
        'wscript.exe'
    )) {
        if ($source.Contains($needle)) { Pass "Native launcher behavior present: $needle" }
        else { Fail "Native launcher behavior missing: $needle" }
    }
}

if (Test-Path -LiteralPath $buildPath) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($buildPath,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) { Pass "Native launcher build script parses" }
    else { foreach ($err in $parseErrors) { Fail "Native launcher build parse error: $($err.Message)" } }

    $build = Get-Content -Raw -LiteralPath $buildPath
    foreach ($needle in @('csc.exe','/target:winexe','/win32icon:','System.Windows.Forms.dll','System.Drawing.dll','CodexManager.exe')) {
        if ($build.Contains($needle)) { Pass "Native launcher build behavior present: $needle" }
        else { Fail "Native launcher build behavior missing: $needle" }
    }

    try {
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("codex-native-launcher-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $tempExe = Join-Path $tempDir "CodexManager.exe"
        $builtPath = & $buildPath -OutputPath $tempExe | Select-Object -Last 1
        if (-not [string]::IsNullOrWhiteSpace($builtPath) -and (Test-Path -LiteralPath $builtPath)) {
            $exe = Get-Item -LiteralPath $builtPath
            if ($exe.Length -gt 4096) { Pass "Native launcher compiles to a non-trivial Windows EXE" }
            else { Fail "Native launcher EXE is unexpectedly small: $($exe.Length) bytes" }

            $version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($builtPath)
            if ($version.ProductName -eq 'Codex Multi-Model Manager') { Pass "Native launcher product metadata is branded" }
            else { Fail "Unexpected native launcher ProductName: $($version.ProductName)" }
        }
        else {
            Fail "Native launcher build did not produce CodexManager.exe"
        }
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {
        Fail "Native launcher compile smoke test failed: $($_.Exception.Message)"
    }
}

if (Test-Path -LiteralPath $installerPath) {
    $installer = Get-Content -Raw -LiteralPath $installerPath
    foreach ($needle in @(
        'build-codex-manager-launcher.ps1',
        'CodexManager.exe',
        '$nativeLauncherPath',
        '-TargetPath $nativeLauncherPath',
        '-IconPath $nativeLauncherPath',
        'LAUNCH_VISUAL_CONSOLE.vbs'
    )) {
        if ($installer.Contains($needle)) { Pass "Shortcut/native integration present: $needle" }
        else { Fail "Shortcut/native integration missing: $needle" }
    }
}

if (Test-Path -LiteralPath $runtimePath) {
    $runtime = Get-Content -Raw -LiteralPath $runtimePath
    foreach ($needle in @(
        'managerNativeLauncher',
        'CodexManager.exe',
        'relaunchCommand',
        'Set-ManagerWindowTaskbarMetadata',
        '$window.ShowInTaskbar = $false',
        '$window.ShowInTaskbar = $true'
    )) {
        if ($runtime.Contains($needle)) { Pass "WPF/native handoff present: $needle" }
        else { Fail "WPF/native handoff missing: $needle" }
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Native Codex Manager launcher validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "Native Codex Manager launcher validation PASSED" -ForegroundColor Green
exit 0
