param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) {
    $passes.Add($Message)
    Write-Host "PASS  $Message" -ForegroundColor Green
}

function Fail([string]$Message) {
    $failures.Add($Message)
    Write-Host "FAIL  $Message" -ForegroundColor Red
}

$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
Set-Location $RepositoryRoot

$shared = @(
    "sync-stealth-registry.ps1",
    "record-stealth-reveal.ps1",
    "launch-stealth-model.ps1",
    "stealth-model-center.ps1"
)

foreach ($name in $shared) {
    $installer = Join-Path $RepositoryRoot "installer/scripts/$name"
    $skill = Join-Path $RepositoryRoot "skill/codex-multimodel-manager/scripts/$name"
    if (-not (Test-Path $installer) -or -not (Test-Path $skill)) {
        Fail "Missing stealth runtime script pair: $name"
        continue
    }

    $installerHash = (Get-FileHash -Algorithm SHA256 $installer).Hash
    $skillHash = (Get-FileHash -Algorithm SHA256 $skill).Hash
    if ($installerHash -eq $skillHash) {
        Pass "Installer/Skill stealth script parity: $name"
    }
    else {
        Fail "Installer/Skill copies differ: $name"
    }
}

$syncPath = Join-Path $RepositoryRoot "installer/scripts/sync-stealth-registry.ps1"
if (Test-Path $syncPath) {
    $sync = Get-Content $syncPath -Raw
    foreach ($required in @("stealth/ox-alpha", "ACTIVE_STEALTH", "MISSING_NEEDS_REVIEW", "REVEALED_ACTIVE", "suspected_replacements", "https://openrouter.ai/api/v1/models")) {
        if ($sync.Contains($required)) { Pass "Stealth sync contains: $required" } else { Fail "Stealth sync missing: $required" }
    }
    if ($sync -match '/responses') {
        Fail "Stealth sync must not call paid inference /responses"
    } else {
        Pass "Stealth sync does not call /responses"
    }
}

$recordPath = Join-Path $RepositoryRoot "installer/scripts/record-stealth-reveal.ps1"
if (Test-Path $recordPath) {
    $record = Get-Content $recordPath -Raw
    foreach ($required in @("MIGRATE", "replacement_id", "official_name", "reveal_recorded", "https://openrouter.ai/api/v1/models")) {
        if ($record.Contains($required)) { Pass "Reveal recorder contains: $required" } else { Fail "Reveal recorder missing: $required" }
    }
}

$launchPath = Join-Path $RepositoryRoot "installer/scripts/launch-stealth-model.ps1"
if (Test-Path $launchPath) {
    $launch = Get-Content $launchPath -Raw
    foreach ($required in @("replacement_id", "current_id", "OPENROUTER_API_KEY", "collect-handoff.ps1", 'model_provider="mm_openrouter"')) {
        if ($launch.Contains($required)) { Pass "Stealth launcher contains: $required" } else { Fail "Stealth launcher missing: $required" }
    }
    foreach ($forbidden in @("git reset", "git clean", "git stash")) {
        if ($launch -match [regex]::Escape($forbidden)) { Fail "Stealth launcher contains forbidden command: $forbidden" }
    }
}

$oxPaths = @(
    "installer/scripts/launch-ox-alpha.ps1",
    "skill/codex-multimodel-manager/scripts/launch-ox-alpha.ps1"
)
foreach ($relative in $oxPaths) {
    $full = Join-Path $RepositoryRoot $relative
    if (Test-Path $full) {
        $text = Get-Content $full -Raw
        if ($text -match 'launch-stealth-model\.ps1' -and $text -match 'ConfirmationCode\s+"OX"') {
            Pass "$relative delegates to the stealth alias launcher"
        } else {
            Fail "$relative does not delegate to the stealth alias launcher"
        }
    }
}

foreach ($relative in @(
    "installer/scripts/discover-models.ps1",
    "skill/codex-multimodel-manager/scripts/discover-models.ps1"
)) {
    $full = Join-Path $RepositoryRoot $relative
    if (Test-Path $full) {
        $text = Get-Content $full -Raw
        if ($text -match 'sync-stealth-registry\.ps1' -and $text -match '-Quiet') {
            Pass "$relative performs read-only stealth lifecycle sync"
        } else {
            Fail "$relative does not integrate stealth lifecycle sync"
        }
    }
}

$cmd = Join-Path $RepositoryRoot "installer/STEALTH_MODEL_REGISTRY.cmd"
$center = Join-Path $RepositoryRoot "installer/scripts/stealth-model-center.ps1"
if ((Test-Path $cmd) -and (Test-Path $center)) {
    $cmdText = Get-Content $cmd -Raw
    if ($cmdText -match 'stealth-model-center\.ps1') {
        Pass "STEALTH_MODEL_REGISTRY.cmd targets the registry center"
    } else {
        Fail "STEALTH_MODEL_REGISTRY.cmd target is incorrect"
    }
} else {
    Fail "Stealth registry Windows entrypoint or center is missing"
}

$tracked = @(& git ls-files)
foreach ($path in $tracked) {
    if ($path -match '(?i)(^|/)stealth-models\.json$' -or $path -match '(?i)(^|/)stealth-model-history\.jsonl$') {
        Fail "Runtime stealth state must not be tracked: $path"
    }
}
if (-not ($failures | Where-Object { $_ -like "Runtime stealth state must not be tracked:*" })) {
    Pass "No runtime stealth registry state is committed"
}

Write-Host ""
Write-Host "Stealth Registry validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($passes.Count)"
Write-Host "FAIL: $($failures.Count)"

if ($failures.Count -gt 0) {
    Write-Host "Stealth Registry validation FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Stealth Registry validation PASSED" -ForegroundColor Green
exit 0
