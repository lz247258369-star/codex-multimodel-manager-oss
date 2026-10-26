param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Passes = New-Object System.Collections.Generic.List[string]

function Add-Pass([string]$Message) {
    $script:Passes.Add($Message)
    Write-Host "PASS  $Message" -ForegroundColor Green
}

function Add-Fail([string]$Message) {
    $script:Failures.Add($Message)
    Write-Host "FAIL  $Message" -ForegroundColor Red
}

function Require-Path([string]$RelativePath) {
    $full = Join-Path $RepositoryRoot $RelativePath
    if (Test-Path $full) {
        Add-Pass "Required path exists: $RelativePath"
    }
    else {
        Add-Fail "Missing required path: $RelativePath"
    }
}

$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
Set-Location $RepositoryRoot
Write-Host "Repository: $RepositoryRoot" -ForegroundColor Cyan

# 1. Required repository / Skill / installer structure.
$requiredPaths = @(
    "AGENTS.md",
    "README.md",
    "CHANGELOG.md",
    "manifest.json",
    "skill/codex-multimodel-manager/SKILL.md",
    "skill/codex-multimodel-manager/scripts",
    "skill/codex-multimodel-manager/references",
    "skill/codex-multimodel-manager/scripts/health-check.ps1",
    "installer/ONE_CLICK_SETUP.cmd",
    "installer/CODEX_MODEL_SWITCHER.cmd",
    "installer/HEALTH_CHECK.cmd",
    "installer/MODEL_UPDATE_CENTER.cmd",
    "installer/CHECK_NEW_MODELS.cmd",
    "installer/STEALTH_MODEL_REGISTRY.cmd",
    "installer/INSTALL_SKILL_ONLY.cmd",
    "installer/LAUNCH_OX_ALPHA_EXPERIMENTAL.cmd",
    "installer/setup.ps1",
    "installer/install-skill.ps1",
    "installer/scripts",
    "installer/scripts/health-check.ps1",
    "docs/HEALTH_CHECK.md",
    "docs/OX_ALPHA.md",
    "docs/STEALTH_MODEL_REGISTRY.md",
    "tests/validate-health-check.ps1",
    "tests/validate-stealth-registry.ps1"
)
foreach ($path in $requiredPaths) { Require-Path $path }

# 2. Manifest must be valid JSON and contain the expected identity/version.
try {
    $manifest = Get-Content (Join-Path $RepositoryRoot "manifest.json") -Raw | ConvertFrom-Json
    if ($manifest.name -ne "Codex Multi-Model Manager") {
        Add-Fail "manifest.json has unexpected name: $($manifest.name)"
    }
    else {
        Add-Pass "manifest.json identity is valid"
    }

    if ([string]::IsNullOrWhiteSpace([string]$manifest.version)) {
        Add-Fail "manifest.json version is missing"
    }
    else {
        Add-Pass "manifest.json version is $($manifest.version)"
    }
}
catch {
    Add-Fail "manifest.json is not valid JSON: $($_.Exception.Message)"
}

# 3. Parse every tracked PowerShell file. This catches syntax errors without executing scripts.
$psFiles = @(Get-ChildItem -Path $RepositoryRoot -Recurse -File -Filter "*.ps1")
foreach ($file in $psFiles) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -gt 0) {
        foreach ($parseError in $parseErrors) {
            Add-Fail "PowerShell syntax: $($file.FullName.Substring($RepositoryRoot.Length + 1)) :: $($parseError.Message)"
        }
    }
}
if (-not ($script:Failures | Where-Object { $_ -like "PowerShell syntax:*" })) {
    Add-Pass "All PowerShell files parse successfully ($($psFiles.Count) files)"
}

# 4. Skill metadata must remain discoverable by Codex.
$skillPath = Join-Path $RepositoryRoot "skill/codex-multimodel-manager/SKILL.md"
if (Test-Path $skillPath) {
    $skill = Get-Content $skillPath -Raw
    if ($skill -match '(?ms)^---\s*.*?^name:\s*codex-multimodel-manager\s*$.*?^description:\s*.+?^---\s*$') {
        Add-Pass "SKILL.md frontmatter contains name and description"
    }
    else {
        Add-Fail "SKILL.md frontmatter is missing/invalid"
    }
}

# 5. Critical runtime scripts must exist in both installer runtime and Skill payload.
$sharedRuntimeScripts = @(
    "collect-handoff.ps1",
    "resume-handoff.ps1",
    "discover-models.ps1",
    "probe-model.ps1",
    "approve-model.ps1",
    "model-update-center.ps1",
    "switch-model.ps1",
    "health-check.ps1",
    "launch-ox-alpha.ps1",
    "sync-stealth-registry.ps1",
    "record-stealth-reveal.ps1",
    "launch-stealth-model.ps1",
    "stealth-model-center.ps1"
)
foreach ($name in $sharedRuntimeScripts) {
    $installerCopy = Join-Path $RepositoryRoot "installer/scripts/$name"
    $skillCopy = Join-Path $RepositoryRoot "skill/codex-multimodel-manager/scripts/$name"
    if ((Test-Path $installerCopy) -and (Test-Path $skillCopy)) {
        Add-Pass "Shared runtime script present in installer and Skill: $name"
    }
    else {
        Add-Fail "Shared runtime script missing from installer or Skill: $name"
    }
}

# 6. The reorganized installer must install from skill/codex-multimodel-manager.
foreach ($setupFile in @("installer/setup.ps1", "installer/install-skill.ps1")) {
    $full = Join-Path $RepositoryRoot $setupFile
    if (Test-Path $full) {
        $text = Get-Content $full -Raw
        if ($text -match 'skill\\codex-multimodel-manager') {
            Add-Pass "$setupFile points at the organized Skill payload"
        }
        else {
            Add-Fail "$setupFile does not reference skill\\codex-multimodel-manager"
        }
    }
}

# 7. Active executable scripts must not reintroduce destructive Git switching or legacy Chat wire mode.
$activeFiles = @(
    Get-ChildItem (Join-Path $RepositoryRoot "installer") -Recurse -File | Where-Object { $_.Extension -in @(".ps1", ".cmd") }
    Get-ChildItem (Join-Path $RepositoryRoot "skill/codex-multimodel-manager/scripts") -Recurse -File -Filter "*.ps1"
)
$forbiddenPatterns = [ordered]@{
    "automatic git reset" = '(?im)\bgit\s+reset\b'
    "automatic git clean" = '(?im)\bgit\s+clean\b'
    "automatic git stash" = '(?im)\bgit\s+stash\b'
    "force push" = '(?im)\bgit\s+push\s+(?:[^\r\n]*\s)?(?:--force(?:-with-lease)?|-f)\b'
    "legacy wire_api chat" = '(?im)wire_api\s*=\s*["'']chat["'']'
}
foreach ($file in $activeFiles) {
    $text = Get-Content $file.FullName -Raw
    foreach ($entry in $forbiddenPatterns.GetEnumerator()) {
        if ($text -match $entry.Value) {
            Add-Fail "$($entry.Key) found in executable script: $($file.FullName.Substring($RepositoryRoot.Length + 1))"
        }
    }
}
if (-not ($script:Failures | Where-Object { $_ -match 'found in executable script:' })) {
    Add-Pass "No forbidden destructive Git commands or legacy Chat wire mode in executable scripts"
}

# 8. Detect common credential formats in tracked text files.
$textExtensions = @(".ps1", ".cmd", ".md", ".txt", ".json", ".yml", ".yaml", ".toml")
$textFiles = @(Get-ChildItem -Path $RepositoryRoot -Recurse -File | Where-Object {
    $_.Extension -in $textExtensions -and $_.FullName -notmatch '[\\/]\.git[\\/]'
})
$secretPatterns = [ordered]@{
    "OpenAI-style key" = '\bsk-[A-Za-z0-9_-]{20,}\b'
    "GitHub classic token" = '\bghp_[A-Za-z0-9]{30,}\b'
    "GitHub fine-grained token" = '\bgithub_pat_[A-Za-z0-9_]{30,}\b'
    "Google API key" = '\bAIza[0-9A-Za-z_-]{30,}\b'
    "private key block" = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
}
foreach ($file in $textFiles) {
    $text = Get-Content $file.FullName -Raw
    foreach ($entry in $secretPatterns.GetEnumerator()) {
        if ($text -match $entry.Value) {
            Add-Fail "Potential $($entry.Key) committed in: $($file.FullName.Substring($RepositoryRoot.Length + 1))"
        }
    }
}
if (-not ($script:Failures | Where-Object { $_ -like "Potential * committed in:*" })) {
    Add-Pass "No common credential formats detected in tracked text content"
}

# 9. Runtime state / auth files must never be tracked in this repository.
$tracked = @(& git ls-files)
if ($LASTEXITCODE -ne 0) {
    Add-Fail "git ls-files failed"
}
else {
    $forbiddenTracked = @(
        '(?i)(^|/)auth\.json$',
        '(?i)(^|/)\.codex(/|$)',
        '(?i)(^|/)(state|candidates|approved-models|discovered-models|discovery-baseline|stealth-models)\.json$',
        '(?i)(^|/)stealth-model-history\.jsonl$',
        '(?i)(^|/)handoffs?(/|$)',
        '(?i)(^|/)backups?(/|$)'
    )
    foreach ($path in $tracked) {
        foreach ($pattern in $forbiddenTracked) {
            if ($path -match $pattern) {
                Add-Fail "Runtime/auth state must not be tracked: $path"
            }
        }
    }
    if (-not ($script:Failures | Where-Object { $_ -like "Runtime/auth state must not be tracked:*" })) {
        Add-Pass "No Codex auth/runtime state is tracked"
    }
}

# 10. Entrypoint targets must exist after repository reorganization.
$entrypointTargets = [ordered]@{
    "installer/ONE_CLICK_SETUP.cmd" = "installer/setup.ps1"
    "installer/CODEX_MODEL_SWITCHER.cmd" = "installer/scripts/switch-model.ps1"
    "installer/HEALTH_CHECK.cmd" = "installer/scripts/health-check.ps1"
    "installer/MODEL_UPDATE_CENTER.cmd" = "installer/scripts/model-update-center.ps1"
    "installer/CHECK_NEW_MODELS.cmd" = "installer/scripts/discover-models.ps1"
    "installer/STEALTH_MODEL_REGISTRY.cmd" = "installer/scripts/stealth-model-center.ps1"
    "installer/INSTALL_SKILL_ONLY.cmd" = "installer/install-skill.ps1"
    "installer/LAUNCH_OX_ALPHA_EXPERIMENTAL.cmd" = "installer/scripts/launch-ox-alpha.ps1"
    "installer/ENABLE_WEEKLY_MODEL_CHECK.cmd" = "installer/scripts/schedule-weekly-check.ps1"
    "installer/DISABLE_WEEKLY_MODEL_CHECK.cmd" = "installer/scripts/schedule-weekly-check.ps1"
}
foreach ($entry in $entrypointTargets.GetEnumerator()) {
    if ((Test-Path (Join-Path $RepositoryRoot $entry.Key)) -and (Test-Path (Join-Path $RepositoryRoot $entry.Value))) {
        Add-Pass "Entrypoint target exists: $($entry.Key) -> $($entry.Value)"
    }
    else {
        Add-Fail "Broken entrypoint mapping: $($entry.Key) -> $($entry.Value)"
    }
}

# 11. Release package provenance gate (LR15 PR6). The provenance validator runs
# as a child process so this gate fails whenever the release package builder or
# its provenance checks regress. It is offline, needs no network or provider, and
# only ever writes inside throw-away temp directories; the exit code is the
# authority, so a partial or skipped run can never be reported as a pass.
$provenanceValidator = Join-Path $RepositoryRoot "tests/validate-release-package-provenance.ps1"
if (Test-Path -LiteralPath $provenanceValidator -PathType Leaf) {
    $childHost = Join-Path $PSHOME "pwsh.exe"
    if (-not (Test-Path -LiteralPath $childHost -PathType Leaf)) {
        $discovered = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($null -ne $discovered) { $childHost = $discovered.Source }
    }

    if (-not (Test-Path -LiteralPath $childHost -PathType Leaf)) {
        Add-Fail "Release package provenance validation cannot run: no PowerShell host was found"
    }
    else {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $provenanceOutput = & $childHost -NoProfile -ExecutionPolicy Bypass -File $provenanceValidator -RepositoryRoot $RepositoryRoot 2>&1
            $provenanceExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }

        if ($provenanceExit -eq 0) {
            Add-Pass "Release package provenance validation passed (scenarios A-L)"
        }
        else {
            Add-Fail "Release package provenance validation failed (exit $provenanceExit)"
            foreach ($line in @($provenanceOutput | Where-Object { $_ -is [string] -and $_.StartsWith("FAIL", [System.StringComparison]::Ordinal) })) {
                Write-Host ("      " + $line.Trim()) -ForegroundColor Red
            }
        }
    }
}
else {
    Add-Fail "Missing required path: tests/validate-release-package-provenance.ps1"
}

Write-Host ""
# LR15 PR7 ownership foundation: run actual isolated boundary regressions in
# the existing Windows Development Gate without changing the CI workflow.
$ownershipValidator = Join-Path $RepositoryRoot "tests/validate-router-install-ownership.ps1"
if (Test-Path -LiteralPath $ownershipValidator -PathType Leaf) {
    $ownershipHost = (Get-Process -Id $PID).Path
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $ownershipOutput = & $ownershipHost -NoLogo -NoProfile -File $ownershipValidator -RepositoryRoot $RepositoryRoot 2>&1
        $ownershipExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($ownershipExit -eq 0) { Add-Pass "Router install ownership validation passed" }
    else {
        Add-Fail "Router install ownership validation failed (exit $ownershipExit)"
        Write-Host ($ownershipOutput | Out-String)
    }
}
else { Add-Fail "Missing required path: tests/validate-router-install-ownership.ps1" }

# PR8 uses its real isolated executor tests in the existing Windows gate.
$uninstallValidator = Join-Path $RepositoryRoot "tests/validate-router-safe-uninstall.ps1"
if (Test-Path -LiteralPath $uninstallValidator -PathType Leaf) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $uninstallOutput = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -File $uninstallValidator -RepositoryRoot $RepositoryRoot 2>&1
        $uninstallExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    # Keep FIX1's real filesystem evidence visible in successful Windows CI too.
    foreach ($line in $uninstallOutput) {
        if ([string]$line -match '^ROOT_MOVE_(STATE|EXCEPTION|OUTCOME) ') { Write-Host ([string]$line) }
    }
    if ($uninstallExit -eq 0) { Add-Pass "Router safe uninstall validation passed" }
    else { Add-Fail "Router safe uninstall validation failed (exit $uninstallExit)"; Write-Host ($uninstallOutput | Out-String) }
}
else { Add-Fail "Missing required path: tests/validate-router-safe-uninstall.ps1" }

# PR9 cross-publishes from a clean temporary clone; on Windows it also starts
# ONLY the verified published apphost in an empty, sanitized temporary home.
$hostReleaseValidator = Join-Path $RepositoryRoot "tests/validate-router-host-release.ps1"
if (Test-Path -LiteralPath $hostReleaseValidator -PathType Leaf) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $hostReleaseOutput = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -File $hostReleaseValidator -RepositoryRoot $RepositoryRoot 2>&1
        $hostReleaseExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    foreach ($line in $hostReleaseOutput) {
        if ([string]$line -match '^HOST_RELEASE_(SUMMARY|WINDOWS_SMOKE) ') { Write-Host ([string]$line) }
    }
    if ($hostReleaseExit -eq 0) { Add-Pass "Router Host release validation passed" }
    else { Add-Fail "Router Host release validation failed (exit $hostReleaseExit)"; Write-Host ($hostReleaseOutput | Out-String) }
}
else { Add-Fail "Missing required path: tests/validate-router-host-release.ps1" }

# PR10A reuses the existing Release Host build; only an isolated fixture is
# compiled. Native concurrency is mandatory on the Windows Development Gate.
$startupValidator = Join-Path $RepositoryRoot "tests/validate-router-host-startup-gate.ps1"
if (Test-Path -LiteralPath $startupValidator -PathType Leaf) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $startupOutput = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -File $startupValidator -RepositoryRoot $RepositoryRoot -UseExistingBuild 2>&1
        $startupExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    foreach ($line in $startupOutput) {
        if ([string]$line -match '^STARTUP_GATE_(SUMMARY|NATIVE|RENAME_REFUSAL) ') { Write-Host ([string]$line) }
    }
    if ($startupExit -eq 0) { Add-Pass "Router Host startup gate validation passed (native Windows evidence required)" }
    else { Add-Fail "Router Host startup gate validation failed (exit $startupExit)"; Write-Host ($startupOutput | Out-String) }
}
else { Add-Fail "Missing required path: tests/validate-router-host-startup-gate.ps1" }

# PR10B composes the existing boundaries: it reuses the PR9 verified release
# path and the real Host build, and on Windows it starts and gracefully stops
# the verified Host. Only the summary markers are echoed into the gate log.
$lifecycleValidator = Join-Path $RepositoryRoot "tests/validate-router-host-lifecycle.ps1"
if (Test-Path -LiteralPath $lifecycleValidator -PathType Leaf) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lifecycleOutput = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -File $lifecycleValidator -RepositoryRoot $RepositoryRoot 2>&1
        $lifecycleExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    foreach ($line in $lifecycleOutput) {
        if ([string]$line -match '^LIFECYCLE_SUMMARY ') { Write-Host ([string]$line) }
    }
    if ($lifecycleExit -eq 0) { Add-Pass "Router Host lifecycle controller validation passed" }
    else { Add-Fail "Router Host lifecycle controller validation failed (exit $lifecycleExit)"; Write-Host ($lifecycleOutput | Out-String) }
}
else { Add-Fail "Missing required path: tests/validate-router-host-lifecycle.ps1" }

Write-Host "Validation summary" -ForegroundColor Cyan
Write-Host "PASS: $($script:Passes.Count)"
Write-Host "FAIL: $($script:Failures.Count)"

if ($script:Failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Development Gate FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "Development Gate PASSED" -ForegroundColor Green
exit 0
