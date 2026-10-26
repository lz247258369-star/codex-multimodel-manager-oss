param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
$runtimePath = Join-Path $RepositoryRoot "installer/scripts/visual-crash-diagnostics.ps1"
$loaderPath = Join-Path $RepositoryRoot "installer/scripts/visual-sidebar-readability.ps1"
if (-not (Test-Path -LiteralPath $runtimePath)) { throw "Missing V4 crash diagnostics runtime: $runtimePath" }
if (-not (Test-Path -LiteralPath $loaderPath)) { throw "Missing V4 sidebar loader: $loaderPath" }

$runtime = Get-Content -Raw -LiteralPath $runtimePath
$loader = Get-Content -Raw -LiteralPath $loaderPath
foreach ($marker in @(
    'v4-crash.log',
    'STARTUP diagnostics-attached',
    'Dispatcher.add_UnhandledException',
    'APPDOMAIN-UNHANDLED',
    'WINDOW-CLOSED'
)) {
    if (-not $runtime.Contains($marker)) { throw "Missing V4 crash diagnostic marker: $marker" }
}
if (-not $loader.Contains('visual-crash-diagnostics.ps1')) { throw "V4 loader does not install crash diagnostics." }

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($runtimePath,[ref]$tokens,[ref]$errors) | Out-Null
if ($errors.Count -gt 0) { throw "Crash diagnostics runtime parse failed: $($errors[0].Message)" }

$env:MM_CRASH_DIAGNOSTICS_ROOT = $RepositoryRoot
$staTest = Join-Path $env:TEMP ("mm-crash-diagnostics-{0}.ps1" -f ([Guid]::NewGuid().ToString("N")))
@'
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework

$repo = $env:MM_CRASH_DIAGNOSTICS_ROOT
$runtimePath = Join-Path $repo "installer/scripts/visual-crash-diagnostics.ps1"
$window = [System.Windows.Window]::new()
$window.Width = 320
$window.Height = 200

$logPath = Join-Path $env:LOCALAPPDATA "Codex Multi-Model Manager\logs\v4-crash.log"
Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

. $runtimePath

if (-not (Test-Path -LiteralPath $logPath)) { throw "Crash log was not created immediately when diagnostics attached." }
$text = Get-Content -Raw -LiteralPath $logPath
if ($text -notmatch 'STARTUP diagnostics-attached') { throw "Crash log is missing the startup marker." }

$window.Show()
$window.Close()
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Action]{},[System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
$text = Get-Content -Raw -LiteralPath $logPath
if ($text -notmatch 'WINDOW-CLOSED') { throw "Crash log did not record normal window close." }

Write-Host "V4 always-on crash diagnostics PASS" -ForegroundColor Green
'@ | Set-Content -LiteralPath $staTest -Encoding utf8BOM

try {
    & pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File $staTest
    if ($LASTEXITCODE -ne 0) { throw "V4 crash diagnostics STA validation failed with exit code $LASTEXITCODE." }
}
finally {
    Remove-Item -LiteralPath $staTest -Force -ErrorAction SilentlyContinue
    Remove-Item Env:MM_CRASH_DIAGNOSTICS_ROOT -ErrorAction SilentlyContinue
}

Write-Host "V4 crash diagnostics validation PASS" -ForegroundColor Green
