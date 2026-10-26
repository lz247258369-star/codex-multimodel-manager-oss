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

function Normalize-HealthScript([string]$Text) {
    # Ignore line-ending differences while still requiring identical executable logic.
    return (($Text -replace "`r`n", "`n").TrimEnd())
}

$installerHealth = Join-Path $RepositoryRoot "installer/scripts/health-check.ps1"
$skillHealth = Join-Path $RepositoryRoot "skill/codex-multimodel-manager/scripts/health-check.ps1"
$entrypoint = Join-Path $RepositoryRoot "installer/HEALTH_CHECK.cmd"

if ((Test-Path $installerHealth) -and (Test-Path $skillHealth)) {
    $installerNormalized = Normalize-HealthScript (Get-Content -Raw $installerHealth)
    $skillNormalized = Normalize-HealthScript (Get-Content -Raw $skillHealth)
    if ($installerNormalized -eq $skillNormalized) {
        Pass "Installer and Skill health-check executable logic is identical"
    } else {
        Fail "Installer and Skill health-check executable logic differs"
    }
} else {
    Fail "Health-check runtime script missing from installer or Skill"
}

if ((Test-Path $entrypoint) -and (Get-Content -Raw $entrypoint) -match 'scripts\\health-check\.ps1') {
    Pass "HEALTH_CHECK.cmd targets health-check.ps1"
} else {
    Fail "HEALTH_CHECK.cmd is missing or points at the wrong script"
}

foreach ($relative in @(
    "installer/scripts/switch-model.ps1",
    "skill/codex-multimodel-manager/scripts/switch-model.ps1"
)) {
    $text = Get-Content -Raw (Join-Path $RepositoryRoot $relative)
    if ($text -match '13\. 一键健康检查' -and $text -match 'health-check\.ps1') {
        Pass "$relative exposes health check in the switcher"
    } else {
        Fail "$relative does not expose the V3.4 health check"
    }
}

$oldCodexHome = $env:CODEX_HOME
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-mm-health-" + [guid]::NewGuid().ToString("N"))
$tempCodexHome = Join-Path $tempRoot "codex-home"
try {
    New-Item -ItemType Directory -Force -Path $tempCodexHome | Out-Null
    $env:CODEX_HOME = $tempCodexHome

    $modelsPath = Join-Path $tempCodexHome "models.json"
    '{"models":[{"id":"deepseek-v4-flash"}]}' | Set-Content -Path $modelsPath -Encoding UTF8
    $modelsBefore = Get-Content -Raw $modelsPath

    $configPath = Join-Path $tempCodexHome "config.toml"
    @'
forced_login_method = "api"
model = "deepseek-v4-flash"
model_provider = "deepseek"
model_catalog_json = "C:/Users/demo/.codex/models.json"

[model_providers.deepseek]
name = "Legacy DeepSeek"
base_url = "https://example.invalid/v1"
env_key = "DEEPSEEK_API_KEY"
wire_api = "responses"

# >>> CODEX MULTIMODEL MANAGER BEGIN
[profiles.mm_gpt56_chatgpt]
model = "gpt-5.6"
model_provider = "openai"
model_reasoning_effort = "high"
# <<< CODEX MULTIMODEL MANAGER END
'@ | Set-Content -Path $configPath -Encoding UTF8

    # Do not pass -NoReport: this intentionally exercises the real JSON report path.
    & pwsh -NoProfile -File $installerHealth -Repair -Yes -NoRuntimeCheck -NoLoginCheck -NoNetwork
    $healthExit = $LASTEXITCODE
    if ($healthExit -eq 0) {
        Pass "Health repair exits HEALTH SAFE for the synthetic repaired config"
    } else {
        Fail "Health repair exited with code $healthExit"
    }

    $reportDir = Join-Path $tempCodexHome "multimodel-manager\reports"
    $reports = @(Get-ChildItem -Path $reportDir -Filter "health-*.json" -File -ErrorAction SilentlyContinue)
    if ($reports.Count -eq 1) {
        try {
            $report = Get-Content -Raw $reports[0].FullName | ConvertFrom-Json
            $checkCount = @($report.checks).Count
            if ($checkCount -gt 0) {
                Pass "Health report JSON is created and contains diagnostic checks"
            } else {
                Fail "Health report JSON contains no diagnostic checks"
            }
        } catch {
            Fail "Health report JSON could not be parsed: $($_.Exception.Message)"
        }
    } else {
        Fail "Expected exactly one health report JSON, found $($reports.Count)"
    }

    $configAfter = Get-Content -Raw $configPath
    if ($configAfter -notmatch '(?m)^\s*forced_login_method\s*=\s*"api"\s*$') {
        Pass "Health repair removes active API-only login restriction"
    } else {
        Fail "Active forced_login_method=api remains after repair"
    }

    if ($configAfter -notmatch '(?m)^\s*model_catalog_json\s*=' -and
        $configAfter -notmatch '(?m)^\s*model_provider\s*=\s*"deepseek"\s*$' -and
        $configAfter -notmatch '(?m)^\s*\[profiles\.mm_gpt56_chatgpt\]') {
        Pass "Health repair removes legacy global catalog and old Manager profile from base config"
    } else {
        Fail "Legacy global catalog or Manager profile remains in base config"
    }

    $legacyProfile = Join-Path $tempCodexHome "legacy-codex-catalog.config.toml"
    if ((Test-Path $legacyProfile) -and
        (Get-Content -Raw $legacyProfile) -match 'model_provider\s*=\s*"deepseek"' -and
        (Get-Content -Raw $legacyProfile) -match 'model_catalog_json\s*=') {
        Pass "Legacy custom catalog is preserved in a dedicated profile"
    } else {
        Fail "Legacy custom catalog was not preserved correctly"
    }

    $chatProfile = Join-Path $tempCodexHome "mm_gpt56_chatgpt.config.toml"
    if ((Test-Path $chatProfile) -and
        (Get-Content -Raw $chatProfile) -match 'model_provider\s*=\s*"openai"' -and
        (Get-Content -Raw $chatProfile) -notmatch 'model\s*=\s*"gpt-5\.6"') {
        Pass "ChatGPT profile no longer hard-codes the rejected legacy GPT-5.6 ID"
    } else {
        Fail "ChatGPT profile normalization failed"
    }

    if ((Get-Content -Raw $modelsPath) -eq $modelsBefore) {
        Pass "Health repair does not rewrite or delete the user's legacy models.json"
    } else {
        Fail "Health repair changed the user's legacy models.json"
    }
}
catch {
    Fail "Health-check runtime regression failed: $($_.Exception.Message)"
}
finally {
    if ($null -eq $oldCodexHome) {
        Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_HOME = $oldCodexHome
    }
    Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Health-check validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "Health-check validation PASSED" -ForegroundColor Green
exit 0
