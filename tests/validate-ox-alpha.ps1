param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Fail([string]$Message) {
    $failures.Add($Message)
    Write-Host "FAIL  $Message" -ForegroundColor Red
}

function Pass([string]$Message) {
    Write-Host "PASS  $Message" -ForegroundColor Green
}

$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$installerLauncher = Join-Path $RepositoryRoot "installer/scripts/launch-ox-alpha.ps1"
$skillLauncher = Join-Path $RepositoryRoot "skill/codex-multimodel-manager/scripts/launch-ox-alpha.ps1"
$installerGeneric = Join-Path $RepositoryRoot "installer/scripts/launch-stealth-model.ps1"
$skillGeneric = Join-Path $RepositoryRoot "skill/codex-multimodel-manager/scripts/launch-stealth-model.ps1"
$installerSync = Join-Path $RepositoryRoot "installer/scripts/sync-stealth-registry.ps1"
$skillSync = Join-Path $RepositoryRoot "skill/codex-multimodel-manager/scripts/sync-stealth-registry.ps1"
$installerSwitcher = Join-Path $RepositoryRoot "installer/scripts/switch-model.ps1"
$skillSwitcher = Join-Path $RepositoryRoot "skill/codex-multimodel-manager/scripts/switch-model.ps1"
$cmd = Join-Path $RepositoryRoot "installer/LAUNCH_OX_ALPHA_EXPERIMENTAL.cmd"
$doc = Join-Path $RepositoryRoot "docs/OX_ALPHA.md"

foreach ($path in @($installerLauncher, $skillLauncher, $installerGeneric, $skillGeneric, $installerSync, $skillSync, $installerSwitcher, $skillSwitcher, $cmd, $doc)) {
    if (Test-Path $path) { Pass "Exists: $($path.Substring($RepositoryRoot.Length + 1))" }
    else { Fail "Missing: $($path.Substring($RepositoryRoot.Length + 1))" }
}

foreach ($path in @($installerLauncher, $skillLauncher)) {
    if (-not (Test-Path $path)) { continue }
    $text = Get-Content -Raw $path

    if ($text -match 'launch-stealth-model\.ps1') { Pass "Ox Alpha delegates to alias launcher in $($path.Substring($RepositoryRoot.Length + 1))" }
    else { Fail "Ox Alpha does not delegate to alias launcher in $($path.Substring($RepositoryRoot.Length + 1))" }

    if ($text -match '-Alias\s+"Ox Alpha"' -and $text -match '-ConfirmationCode\s+"OX"') {
        Pass "Ox Alpha alias + explicit OX confirmation are preserved in $($path.Substring($RepositoryRoot.Length + 1))"
    }
    else {
        Fail "Ox Alpha alias/confirmation missing in $($path.Substring($RepositoryRoot.Length + 1))"
    }
}

foreach ($path in @($installerSync, $skillSync)) {
    if (-not (Test-Path $path)) { continue }
    $text = Get-Content -Raw $path
    if ($text -match 'stealth/ox-alpha') { Pass "Ox Alpha original model ID is seeded in $($path.Substring($RepositoryRoot.Length + 1))" }
    else { Fail "Ox Alpha original model ID missing from registry seed in $($path.Substring($RepositoryRoot.Length + 1))" }
}

foreach ($path in @($installerGeneric, $skillGeneric)) {
    if (-not (Test-Path $path)) { continue }
    $text = Get-Content -Raw $path
    if ($text -match 'mm_openrouter' -and $text -match 'OPENROUTER_API_KEY') {
        Pass "Generic alias launcher uses guarded OpenRouter provider in $($path.Substring($RepositoryRoot.Length + 1))"
    }
    else {
        Fail "Generic alias launcher OpenRouter guard missing in $($path.Substring($RepositoryRoot.Length + 1))"
    }

    if ($text -match 'collect-handoff\.ps1') { Pass "Git handoff remains in $($path.Substring($RepositoryRoot.Length + 1))" }
    else { Fail "Git handoff missing in $($path.Substring($RepositoryRoot.Length + 1))" }

    foreach ($pattern in @('\bgit\s+reset\b','\bgit\s+clean\b','\bgit\s+stash\b')) {
        if ($text -match $pattern) { Fail "Destructive Git command detected in $($path.Substring($RepositoryRoot.Length + 1))" }
    }
}

foreach ($path in @($installerSwitcher, $skillSwitcher)) {
    if (-not (Test-Path $path)) { continue }
    $text = Get-Content -Raw $path
    if ($text -match 'launch-ox-alpha\.ps1') { Pass "Switcher exposes guarded Ox Alpha alias launcher: $($path.Substring($RepositoryRoot.Length + 1))" }
    else { Fail "Switcher does not expose Ox Alpha launcher: $($path.Substring($RepositoryRoot.Length + 1))" }
}

if ($failures.Count -gt 0) {
    Write-Host "Ox Alpha validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "Ox Alpha validation PASSED" -ForegroundColor Green
exit 0
