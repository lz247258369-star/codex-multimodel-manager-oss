param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

$metadataPath = Join-Path $RepositoryRoot "installer/scripts/windows-taskbar-metadata.ps1"
$comboRuntimePath = Join-Path $RepositoryRoot "installer/scripts/visual-combo-display-runtime.ps1"

foreach ($path in @($metadataPath, $comboRuntimePath)) {
    if (Test-Path -LiteralPath $path) { Pass "Exists: $($path.Substring($RepositoryRoot.Length + 1))" }
    else { Fail "Missing: $($path.Substring($RepositoryRoot.Length + 1))" }
}

if (Test-Path -LiteralPath $metadataPath) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($metadataPath,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) { Pass "Taskbar metadata helper parses" }
    else { foreach ($err in $parseErrors) { Fail "Taskbar metadata parse error: $($err.Message)" } }

    $metadataText = Get-Content -Raw -LiteralPath $metadataPath
    foreach ($needle in @(
        'SHGetPropertyStoreForWindow',
        'Codex.MultiModelManager.V4',
        'RelaunchCommandKey',
        'RelaunchIconResourceKey',
        'RelaunchDisplayNameResourceKey',
        'AppUserModelIdKey',
        'Set-ManagerWindowTaskbarMetadata',
        'Get-ManagerWindowTaskbarMetadata'
    )) {
        if ($metadataText.Contains($needle)) { Pass "Taskbar metadata behavior present: $needle" }
        else { Fail "Taskbar metadata behavior missing: $needle" }
    }

    try {
        . $metadataPath
        Add-Type -AssemblyName System.Windows.Forms

        $form = New-Object System.Windows.Forms.Form
        try {
            $form.Text = "Codex Manager taskbar smoke test"
            $handle = $form.Handle
            if ($handle -eq [IntPtr]::Zero) { throw "WinForms smoke-test HWND was zero" }

            $expectedCommand = 'notepad.exe'
            $expectedDisplay = 'Codex Manager'
            $expectedIconPath = Join-Path $env:WINDIR 'System32\shell32.dll'

            Set-ManagerWindowTaskbarMetadata `
                -WindowHandle $handle `
                -RelaunchCommand $expectedCommand `
                -DisplayName $expectedDisplay `
                -IconPath $expectedIconPath

            $roundTrip = Get-ManagerWindowTaskbarMetadata -WindowHandle $handle
            if ($roundTrip.AppUserModelId -eq 'Codex.MultiModelManager.V4') { Pass "Window AppUserModelID round-trips" }
            else { Fail "Unexpected window AppUserModelID: $($roundTrip.AppUserModelId)" }

            if ($roundTrip.RelaunchCommand -eq $expectedCommand) { Pass "Window RelaunchCommand round-trips" }
            else { Fail "Unexpected RelaunchCommand: $($roundTrip.RelaunchCommand)" }

            if ($roundTrip.DisplayName -eq $expectedDisplay) { Pass "Window display name round-trips" }
            else { Fail "Unexpected display name: $($roundTrip.DisplayName)" }

            if ($roundTrip.IconResource -eq "$expectedIconPath,0") { Pass "Window icon resource round-trips" }
            else { Fail "Unexpected icon resource: $($roundTrip.IconResource)" }
        }
        finally {
            if ($null -ne $form) { $form.Dispose() }
        }
    }
    catch {
        Fail "Hosted-window taskbar metadata smoke test failed: $($_.Exception.Message)"
    }
}

if (Test-Path -LiteralPath $comboRuntimePath) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($comboRuntimePath,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) { Pass "V4 taskbar integration runtime parses" }
    else { foreach ($err in $parseErrors) { Fail "V4 taskbar integration parse error: $($err.Message)" } }

    $comboText = Get-Content -Raw -LiteralPath $comboRuntimePath
    foreach ($needle in @(
        'windows-taskbar-metadata.ps1',
        'Add_SourceInitialized',
        'LAUNCH_VISUAL_CONSOLE.vbs',
        'wscript.exe',
        'Set-ManagerWindowTaskbarMetadata',
        'Codex Manager',
        '$window.ShowInTaskbar = $false',
        '$window.ShowInTaskbar = $true'
    )) {
        if ($comboText.Contains($needle)) { Pass "V4 taskbar integration present: $needle" }
        else { Fail "V4 taskbar integration missing: $needle" }
    }

    $hideIndex = $comboText.IndexOf('$window.ShowInTaskbar = $false', [System.StringComparison]::Ordinal)
    $sourceInitIndex = $comboText.IndexOf('$window.Add_SourceInitialized({', [System.StringComparison]::Ordinal)
    $metadataIndex = $comboText.IndexOf('Set-ManagerWindowTaskbarMetadata', [System.StringComparison]::Ordinal)
    $revealIndex = $comboText.IndexOf('$window.ShowInTaskbar = $true', $metadataIndex, [System.StringComparison]::Ordinal)

    if ($hideIndex -ge 0 -and $sourceInitIndex -gt $hideIndex) {
        Pass "Taskbar button is hidden before HWND SourceInitialized handling"
    }
    else {
        Fail "Taskbar button must be hidden before SourceInitialized taskbar identity work"
    }

    if ($metadataIndex -gt $sourceInitIndex -and $revealIndex -gt $metadataIndex) {
        Pass "Codex taskbar metadata is applied before the taskbar button is revealed"
    }
    else {
        Fail "Taskbar button must be revealed only after Codex metadata is applied"
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Windows taskbar metadata validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "Windows taskbar metadata validation PASSED" -ForegroundColor Green
exit 0