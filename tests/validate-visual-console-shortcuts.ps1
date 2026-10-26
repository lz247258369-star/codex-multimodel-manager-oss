param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

$cmdPath = Join-Path $RepositoryRoot "installer/INSTALL_VISUAL_CONSOLE_SHORTCUTS.cmd"
$scriptPath = Join-Path $RepositoryRoot "installer/scripts/install-visual-console-shortcuts.ps1"
$vbsPath = Join-Path $RepositoryRoot "installer/LAUNCH_VISUAL_CONSOLE.vbs"
$singleInstancePath = Join-Path $RepositoryRoot "installer/scripts/visual-console-single-instance.ps1"
$identityPath = Join-Path $RepositoryRoot "installer/scripts/windows-app-identity.ps1"
$brandingPath = Join-Path $RepositoryRoot "installer/scripts/branding-assets.ps1"
$iconPayloadPath = Join-Path $RepositoryRoot "installer/assets/codex-manager.ico.b64"
$comboRuntimePath = Join-Path $RepositoryRoot "installer/scripts/visual-combo-display-runtime.ps1"

foreach ($path in @($cmdPath,$scriptPath,$vbsPath,$singleInstancePath,$identityPath,$brandingPath,$iconPayloadPath,$comboRuntimePath)) {
    if (Test-Path -LiteralPath $path) { Pass "Exists: $($path.Substring($RepositoryRoot.Length + 1))" }
    else { Fail "Missing: $($path.Substring($RepositoryRoot.Length + 1))" }
}

if (Test-Path -LiteralPath $scriptPath) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) { Pass "Shortcut installer PowerShell parses" }
    else { foreach ($err in $parseErrors) { Fail "Shortcut installer parse error: $($err.Message)" } }

    $text = Get-Content -Raw -LiteralPath $scriptPath
    foreach ($needle in @(
        'LAUNCH_VISUAL_CONSOLE\.vbs','Codex Manager\.lnk','Codex Multi-Model Manager\.lnk','wscript\.exe',
        'SpecialFolder\]::DesktopDirectory','SpecialFolder\]::Programs','Codex Multi-Model Manager',
        'branding-assets\.ps1','Get-ManagerBrandIconPath','IconPath',
        'windows-app-identity\.ps1','Get-ManagerAppUserModelId','New-ManagerShortcut',
        'Remove-ShortcutIfExists','Codex Multi-Model Visual Console\.lnk'
    )) {
        if ($text -match $needle) { Pass "Shortcut behavior present: $needle" }
        else { Fail "Shortcut behavior missing: $needle" }
    }

    if ($text -match '(?im)\bgit\s+(reset|clean|stash)\b') { Fail "Shortcut installer contains destructive Git command" }
    else { Pass "Shortcut installer contains no destructive Git command" }

    if ($text -match '(?i)API[_ ]?KEY|OPENROUTER_API_KEY|MIMO_API_KEY|DASHSCOPE') { Fail "Shortcut installer should not read or mention provider secrets" }
    else { Pass "Shortcut installer is secret-independent" }
}

if (Test-Path -LiteralPath $identityPath) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($identityPath,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) { Pass "Windows app identity helper PowerShell parses" }
    else { foreach ($err in $parseErrors) { Fail "Windows app identity helper parse error: $($err.Message)" } }

    $identityText = Get-Content -Raw -LiteralPath $identityPath
    foreach ($needle in @(
        'Codex.MultiModelManager.V4',
        'SetCurrentProcessExplicitAppUserModelID',
        'SHGetPropertyStoreForWindow',
        '9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3',
        'IShellLinkW',
        'CreateShortcut',
        'GetShortcutAppId',
        'SetWindowAppId',
        'GetWindowAppId',
        'Set-ManagerCurrentProcessAppIdentity',
        'Set-ManagerWindowAppIdentity',
        'Get-ManagerWindowAppIdentity',
        'New-ManagerShortcut'
    )) {
        if ($identityText.Contains($needle)) { Pass "Windows app identity behavior present: $needle" }
        else { Fail "Windows app identity behavior missing: $needle" }
    }

    try {
        . $identityPath
        $expectedAppId = Get-ManagerAppUserModelId
        if ($expectedAppId -eq 'Codex.MultiModelManager.V4') { Pass "Stable AppUserModelID is exposed" }
        else { Fail "Unexpected AppUserModelID: $expectedAppId" }

        # Exercise the same native ShellLink creation path used by production.
        # Target, metadata and PKEY_AppUserModel_ID are committed before the .lnk
        # is first saved, matching Microsoft's documented shortcut pattern.
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("codex-mm-appid-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $tempShortcut = Join-Path $tempDir 'Codex Manager.lnk'
        $notepad = Join-Path $env:WINDIR 'System32\notepad.exe'

        New-ManagerShortcut `
            -Path $tempShortcut `
            -TargetPath $notepad `
            -WorkingDirectory $tempDir `
            -Description 'Codex Manager AppID smoke test' `
            -ShowCommand 1

        if (Test-Path -LiteralPath $tempShortcut) { Pass "Native ShellLink shortcut was created" }
        else { Fail "Native ShellLink shortcut was not created" }

        $roundTripAppId = Get-ManagerShortcutAppIdentity -Path $tempShortcut
        if ($roundTripAppId -eq $expectedAppId) { Pass "Shortcut AppUserModelID round-trips through Windows property store" }
        else { Fail "Shortcut AppUserModelID mismatch: $roundTripAppId" }

        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {
        Fail "Windows AppUserModelID runtime smoke test failed: $($_.Exception.Message)"
    }
}

if (Test-Path -LiteralPath $brandingPath) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($brandingPath,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) { Pass "Branding helper PowerShell parses" }
    else { foreach ($err in $parseErrors) { Fail "Branding helper parse error: $($err.Message)" } }

    $branding = Get-Content -Raw -LiteralPath $brandingPath
    foreach ($needle in @('codex-manager.ico.b64','FromBase64String','WriteAllBytes','09ff6e48d0efe2af7621c9ccaa8e386251ae53cfe81a4254ff84a229af4fd471')) {
        if ($branding.Contains($needle)) { Pass "Branding helper behavior present: $needle" }
        else { Fail "Branding helper behavior missing: $needle" }
    }
}

if (Test-Path -LiteralPath $iconPayloadPath) {
    try {
        $encoded = (Get-Content -Raw -LiteralPath $iconPayloadPath).Trim()
        $bytes = [Convert]::FromBase64String($encoded)
        if ($bytes.Length -gt 1024) { Pass "Brand icon payload decodes to non-trivial ICO bytes" }
        else { Fail "Brand icon payload is unexpectedly small" }

        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $actualHash = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) }
        finally { $sha.Dispose() }
        if ($actualHash -eq '09ff6e48d0efe2af7621c9ccaa8e386251ae53cfe81a4254ff84a229af4fd471') { Pass "Brand icon payload hash matches" }
        else { Fail "Brand icon payload hash mismatch: $actualHash" }
    }
    catch { Fail "Brand icon payload decode failed: $($_.Exception.Message)" }
}

if (Test-Path -LiteralPath $comboRuntimePath) {
    $comboRuntime = Get-Content -Raw -LiteralPath $comboRuntimePath
    foreach ($needle in @('branding-assets.ps1','Get-ManagerBrandIconPath','$window.Icon','BitmapFrame')) {
        if ($comboRuntime.Contains($needle)) { Pass "Window/taskbar branding present: $needle" }
        else { Fail "Window/taskbar branding missing: $needle" }
    }
}

if (Test-Path -LiteralPath $singleInstancePath) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($singleInstancePath,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) { Pass "Single-instance guard PowerShell parses" }
    else { foreach ($err in $parseErrors) { Fail "Single-instance guard parse error: $($err.Message)" } }

    $guard = Get-Content -Raw -LiteralPath $singleInstancePath
    foreach ($needle in @(
        'windows-app-identity.ps1',
        'Set-ManagerCurrentProcessAppIdentity',
        'Local\CodexMultiModelManagerV4',
        '[System.Threading.Mutex]::new',
        'AppActivate("Codex Multi-Model Manager V4")',
        'visual-console-entry.ps1',
        'ReleaseMutex()',
        'exit 0'
    )) {
        if ($guard.Contains($needle)) { Pass "Process single-instance/identity behavior present: $needle" }
        else { Fail "Process single-instance/identity behavior missing: $needle" }
    }

    if ($guard -match '(?im)\bgit\s+(reset|clean|stash)\b') { Fail "Single-instance guard contains destructive Git command" }
    else { Pass "Single-instance guard contains no destructive Git command" }
}

if (Test-Path -LiteralPath $vbsPath) {
    $vbs = Get-Content -Raw -LiteralPath $vbsPath
    foreach ($needle in @(
        'shell.AppActivate("Codex Multi-Model Manager V4")',
        'WScript.Quit 0',
        'visual-console-single-instance.ps1',
        'pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File'
    )) {
        if ($vbs.Contains($needle)) { Pass "Hidden launcher single-instance behavior present: $needle" }
        else { Fail "Hidden launcher single-instance behavior missing: $needle" }
    }

    $activateIndex = $vbs.IndexOf('shell.AppActivate("Codex Multi-Model Manager V4")', [System.StringComparison]::Ordinal)
    $runIndex = $vbs.IndexOf('shell.Run command, 0, False', [System.StringComparison]::Ordinal)
    if ($activateIndex -ge 0 -and $runIndex -gt $activateIndex) {
        Pass "Existing-window activation happens before launching the mutex guard"
    }
    else {
        Fail "Launcher must activate an existing V4 window before spawning the mutex guard"
    }
}

if (Test-Path -LiteralPath $cmdPath) {
    $cmd = Get-Content -Raw -LiteralPath $cmdPath
    if ($cmd -match '(?i)pwsh\.exe' -and $cmd -match 'install-visual-console-shortcuts\.ps1') { Pass "Shortcut CMD uses PowerShell 7" }
    else { Fail "Shortcut CMD runtime/target invalid" }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "V4 Visual Console shortcut validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "V4 Visual Console shortcut validation PASSED" -ForegroundColor Green
exit 0
