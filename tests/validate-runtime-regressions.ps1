param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) {
    Write-Host "PASS  $Message" -ForegroundColor Green
}

function Fail([string]$Message) {
    $failures.Add($Message)
    Write-Host "FAIL  $Message" -ForegroundColor Red
}

# Regression 1: choosing 0 in setup must terminate the outer loop, not only the switch.
$setupPath = Join-Path $RepositoryRoot "installer/setup.ps1"
$setupText = Get-Content -Raw $setupPath
if (
    $setupText.Contains('$setupRunning = $true') -and
    $setupText.Contains('while ($setupRunning)') -and
    $setupText.Contains('$setupRunning = $false')
) {
    Pass "Setup has an explicit outer-loop termination flag"
}
else {
    Fail "Setup exit flow does not explicitly terminate the outer loop"
}

# Regression 2: keep the exact stealth sync implementation away from the generic
# List[object] + @($list) combination that produced `Argument types do not match`.
$syncPath = Join-Path $RepositoryRoot "installer/scripts/sync-stealth-registry.ps1"
$syncText = Get-Content -Raw $syncPath
if ($syncText.Contains('$suspects = @()')) {
    Pass "Stealth sync uses a native PowerShell suspect array"
}
else {
    Fail "Stealth sync does not initialize suspects as a native PowerShell array"
}

if ($syncText.Contains('[object[]]$suspectArray = $suspects')) {
    Pass "Stealth sync normalizes suspected replacements to object[]"
}
else {
    Fail "Stealth sync is missing explicit object[] suspect normalization"
}

if ($syncText -match 'New-Object\s+System\.Collections\.Generic\.List\[object\]') {
    Fail "Stealth sync reintroduced the generic List[object] suspect collector"
}
else {
    Pass "Stealth sync does not use the failing generic List[object] suspect collector"
}

# Exercise the exact persistence shape with both empty and non-empty arrays.
function Set-TestRecordField($Record, [string]$Name, $Value) {
    $Record | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

try {
    $record = [pscustomobject]@{ suspected_replacements = @() }

    $suspects = @()
    [object[]]$suspectArray = $suspects
    Set-TestRecordField $record "suspected_replacements" $suspectArray
    if (@($record.suspected_replacements).Count -eq 0) {
        Pass "Empty suspect array persists without a type-binding failure"
    }
    else {
        Fail "Empty suspect array persistence produced unexpected data"
    }

    $suspects = @(
        [pscustomobject]@{ id = "vendor/ox-alpha-official"; name = "Ox Alpha Official" }
    )
    [object[]]$suspectArray = $suspects
    Set-TestRecordField $record "suspected_replacements" $suspectArray
    $persisted = @($record.suspected_replacements)
    if ($persisted.Count -eq 1 -and $persisted[0].id -eq "vendor/ox-alpha-official") {
        Pass "Non-empty suspect array persists without a type-binding failure"
    }
    else {
        Fail "Non-empty suspect array persistence produced unexpected data"
    }
}
catch {
    Fail "Suspect array persistence regression test failed: $($_.Exception.Message)"
}

# Regression 3: handoff scripts must not use PowerShell's automatic $Args variable
# as the named git-argument parameter. Doing so caused `& git @Args` to launch bare git.
$handoffPairs = @(
    "installer/scripts/collect-handoff.ps1",
    "installer/scripts/resume-handoff.ps1",
    "skill/codex-multimodel-manager/scripts/collect-handoff.ps1",
    "skill/codex-multimodel-manager/scripts/resume-handoff.ps1"
)
foreach ($relative in $handoffPairs) {
    $text = Get-Content -Raw (Join-Path $RepositoryRoot $relative)
    if ($text.Contains('function GitText([string[]]$GitArgs)') -and $text.Contains('& git @GitArgs')) {
        Pass "$relative uses an explicit GitArgs parameter"
    }
    else {
        Fail "$relative does not safely forward git arguments"
    }
    if ($text -match '(?i)function\s+GitText\s*\(\s*\[string\[\]\]\s*\$Args\s*\)' -or $text.Contains('& git @Args')) {
        Fail "$relative reintroduced the automatic Args-variable collision"
    }
}

# Smoke-test the actual collect/resume scripts in a temporary Git repository.
$oldCodexHome = $env:CODEX_HOME
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-mm-handoff-ci-" + [guid]::NewGuid().ToString("N"))
$tempRepo = Join-Path $tempRoot "repo"
$tempCodexHome = Join-Path $tempRoot "codex-home"
try {
    New-Item -ItemType Directory -Force -Path $tempRepo | Out-Null
    New-Item -ItemType Directory -Force -Path $tempCodexHome | Out-Null
    $env:CODEX_HOME = $tempCodexHome

    Push-Location $tempRepo
    try {
        & git init -q
        if ($LASTEXITCODE -ne 0) { throw "git init failed" }
        Set-Content -Path (Join-Path $tempRepo "README.md") -Value "handoff smoke test" -Encoding UTF8
        & git add README.md
        if ($LASTEXITCODE -ne 0) { throw "git add failed" }
        & git -c user.name="CI" -c user.email="ci@example.invalid" -c commit.gpgsign=false commit -q -m "initial"
        if ($LASTEXITCODE -ne 0) { throw "git commit failed" }

        $collectPath = Join-Path $RepositoryRoot "installer/scripts/collect-handoff.ps1"
        & pwsh -NoProfile -File $collectPath -TargetModel "CI Smoke"
        if ($LASTEXITCODE -ne 0) { throw "collect-handoff failed with exit code $LASTEXITCODE" }

        $handoffFiles = @(Get-ChildItem -Path (Join-Path $tempCodexHome "handoffs") -Filter "*-latest.json" -File)
        if ($handoffFiles.Count -eq 1) {
            $snapshot = Get-Content -Raw $handoffFiles[0].FullName | ConvertFrom-Json
            $expectedRepo = (Resolve-Path $tempRepo).Path
            if ($snapshot.repo -eq $expectedRepo -and $snapshot.target_model -eq "CI Smoke") {
                Pass "collect-handoff forwards git subcommands and writes the expected snapshot"
            }
            else {
                Fail "collect-handoff snapshot contents are unexpected"
            }
        }
        else {
            Fail "collect-handoff did not create exactly one handoff snapshot"
        }

        $resumePath = Join-Path $RepositoryRoot "installer/scripts/resume-handoff.ps1"
        & pwsh -NoProfile -File $resumePath
        if ($LASTEXITCODE -eq 0) {
            Pass "resume-handoff verifies an unchanged repository"
        }
        else {
            Fail "resume-handoff failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}
catch {
    Fail "Handoff runtime regression test failed: $($_.Exception.Message)"
}
finally {
    if ($null -eq $oldCodexHome) {
        Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    }
    else {
        $env:CODEX_HOME = $oldCodexHome
    }
    Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
}

# Regression 4: provider keys saved at Windows User scope must be hydrated into
# the current process before Codex is launched. Existing terminals do not receive
# newly-created user variables automatically.
foreach ($relative in @(
    "installer/scripts/switch-model.ps1",
    "skill/codex-multimodel-manager/scripts/switch-model.ps1"
)) {
    $text = Get-Content -Raw (Join-Path $RepositoryRoot $relative)
    if ($text.Contains('function Import-UserEnvToProcess') -and
        $text.Contains('[EnvironmentVariableTarget]::User') -and
        $text.Contains('Set-Item -Path "Env:$Name" -Value $userValue')) {
        Pass "$relative hydrates user-scoped provider secrets into the launcher process"
    }
    else {
        Fail "$relative does not hydrate user-scoped provider secrets before launch"
    }
}

foreach ($relative in @(
    "installer/scripts/launch-stealth-model.ps1",
    "skill/codex-multimodel-manager/scripts/launch-stealth-model.ps1"
)) {
    $text = Get-Content -Raw (Join-Path $RepositoryRoot $relative)
    if ($text.Contains('Set-Item -Path "Env:OPENROUTER_API_KEY" -Value $key')) {
        Pass "$relative passes OPENROUTER_API_KEY to the Codex child process"
    }
    else {
        Fail "$relative does not pass OPENROUTER_API_KEY to the Codex child process"
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Runtime regression validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "Runtime regression validation PASSED" -ForegroundColor Green
exit 0
