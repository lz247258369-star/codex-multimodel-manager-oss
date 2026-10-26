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

$installerMigration = Join-Path $RepositoryRoot "installer/scripts/migrate-profile-v2.ps1"
$skillMigration = Join-Path $RepositoryRoot "skill/codex-multimodel-manager/scripts/migrate-profile-v2.ps1"

if ((Get-Content -Raw $installerMigration) -eq (Get-Content -Raw $skillMigration)) {
    Pass "Installer and Skill profile-v2 migration helpers are identical"
} else {
    Fail "Installer and Skill profile-v2 migration helpers differ"
}

foreach ($relative in @(
    "installer/scripts/switch-model.ps1",
    "skill/codex-multimodel-manager/scripts/switch-model.ps1"
)) {
    $text = Get-Content -Raw (Join-Path $RepositoryRoot $relative)
    if ($text.Contains('migrate-profile-v2.ps1')) {
        Pass "$relative migrates legacy Manager profiles before launch"
    } else {
        Fail "$relative does not invoke profile-v2 migration"
    }
    if ($text.Contains('Launch-LegacyCatalogOrDefault') -and $text.Contains('legacy-codex-catalog')) {
        Pass "$relative preserves access to the isolated legacy catalog"
    } else {
        Fail "$relative cannot launch the isolated legacy catalog"
    }
}

$oldCodexHome = $env:CODEX_HOME
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-mm-profile-v2-" + [guid]::NewGuid().ToString("N"))
$tempCodexHome = Join-Path $tempRoot "codex-home"
try {
    New-Item -ItemType Directory -Force -Path $tempCodexHome | Out-Null
    $env:CODEX_HOME = $tempCodexHome

    $configPath = Join-Path $tempCodexHome "config.toml"
    @'
model = "deepseek-v4-flash"
model_provider = "deepseek"
model_catalog_json = "C:/Users/example/.codex/models.json"
forced_login_method = "chatgpt"
profile = "mm_gpt56_chatgpt"

[model_providers.deepseek]
name = "Existing DeepSeek provider"
base_url = "https://example.invalid/v1"
env_key = "DEEPSEEK_API_KEY"
wire_api = "responses"

# >>> CODEX MULTIMODEL MANAGER BEGIN
# manager block
[profiles.mm_gpt56_chatgpt]
model = "gpt-5.6"
model_provider = "openai"
model_reasoning_effort = "high"

[model_providers.mm_openrouter]
name = "OpenRouter Responses"
base_url = "https://openrouter.ai/api/v1"
env_key = "OPENROUTER_API_KEY"
wire_api = "responses"
# <<< CODEX MULTIMODEL MANAGER END

# >>> CODEX AUTO MODELS BEGIN
[profiles.mm_auto_demo]
model = "vendor/demo"
model_provider = "mm_openrouter"
# <<< CODEX AUTO MODELS END

[profiles.user_custom]
model = "user/model"
'@ | Set-Content -Path $configPath -Encoding UTF8

    & pwsh -NoProfile -File $installerMigration -SkipBackup -Quiet
    if ($LASTEXITCODE -ne 0) {
        throw "migration exited with $LASTEXITCODE"
    }

    $migrated = Get-Content -Raw $configPath
    if ($migrated -notmatch '\[profiles\.mm_gpt56_chatgpt\]' -and
        $migrated -notmatch '\[profiles\.mm_auto_demo\]' -and
        $migrated -notmatch 'profile\s*=\s*"mm_gpt56_chatgpt"') {
        Pass "Manager legacy profile tables/selectors are removed from base config"
    } else {
        Fail "Manager legacy profile data remains in base config"
    }

    if ($migrated -match '\[model_providers\.mm_openrouter\]' -and
        $migrated -match '\[model_providers\.deepseek\]' -and
        $migrated -match '\[profiles\.user_custom\]') {
        Pass "Shared providers and unrelated user config are preserved"
    } else {
        Fail "Migration removed unrelated base configuration"
    }

    if ($migrated -notmatch '(?m)^\s*model_catalog_json\s*=' -and
        $migrated -notmatch '(?m)^\s*model_provider\s*=\s*"deepseek"\s*$' -and
        $migrated -notmatch '(?m)^\s*model\s*=\s*"deepseek-v4-flash"\s*$') {
        Pass "Provider-specific legacy model defaults are removed from global scope"
    } else {
        Fail "Legacy DeepSeek model catalog/defaults still pollute global scope"
    }

    if ($migrated -notmatch 'CODEX AUTO MODELS') {
        Pass "Legacy AUTO MODELS block is removed after migration"
    } else {
        Fail "Legacy AUTO MODELS block remains after migration"
    }

    $gptProfile = Join-Path $tempCodexHome "mm_gpt56_chatgpt.config.toml"
    $autoProfile = Join-Path $tempCodexHome "mm_auto_demo.config.toml"
    $legacyProfile = Join-Path $tempCodexHome "legacy-codex-catalog.config.toml"

    if ((Test-Path $gptProfile)) {
        $gptText = Get-Content -Raw $gptProfile
        if ($gptText -match 'model_provider\s*=\s*"openai"' -and
            $gptText -match 'model_reasoning_effort\s*=\s*"high"' -and
            $gptText -notmatch 'model\s*=\s*"gpt-5\.6"') {
            Pass "ChatGPT profile defers model selection to the account-supported official default"
        } else {
            Fail "ChatGPT profile still hard-codes an unsupported GPT-5.6 model or lost its provider settings"
        }
    } else {
        Fail "ChatGPT dedicated profile-v2 file is missing"
    }

    if ((Test-Path $autoProfile) -and
        (Get-Content -Raw $autoProfile) -match 'model\s*=\s*"vendor/demo"' -and
        (Get-Content -Raw $autoProfile) -match 'model_provider\s*=\s*"mm_openrouter"') {
        Pass "Dynamic approved profile is written as a dedicated profile-v2 file"
    } else {
        Fail "Dynamic dedicated profile-v2 file is missing or invalid"
    }

    if ((Test-Path $legacyProfile)) {
        $legacyText = Get-Content -Raw $legacyProfile
        if ($legacyText -match 'model\s*=\s*"deepseek-v4-flash"' -and
            $legacyText -match 'model_provider\s*=\s*"deepseek"' -and
            $legacyText -match 'model_catalog_json\s*=\s*"C:/Users/example/.codex/models.json"') {
            Pass "Legacy DeepSeek catalog/defaults are preserved in an isolated profile"
        } else {
            Fail "Isolated legacy catalog profile is incomplete"
        }
    } else {
        Fail "Legacy catalog profile was not created"
    }

    $manifestPath = Join-Path $tempCodexHome "multimodel-manager/profile-v2-files.json"
    $manifest = if (Test-Path $manifestPath) { @(Get-Content -Raw $manifestPath | ConvertFrom-Json) } else { @() }
    if ($manifest -contains "mm_gpt56_chatgpt" -and
        $manifest -contains "mm_auto_demo" -and
        $manifest -notcontains "legacy-codex-catalog") {
        Pass "Manager tracks only profile files it owns; preserved legacy catalog remains user-owned"
    } else {
        Fail "Profile-v2 ownership manifest is incorrect"
    }

    $beforeSecondRun = Get-Content -Raw $configPath
    $legacyBeforeSecondRun = Get-Content -Raw $legacyProfile
    & pwsh -NoProfile -File $installerMigration -SkipBackup -Quiet
    $afterSecondRun = Get-Content -Raw $configPath
    $legacyAfterSecondRun = Get-Content -Raw $legacyProfile
    if ($beforeSecondRun -eq $afterSecondRun -and $legacyBeforeSecondRun -eq $legacyAfterSecondRun) {
        Pass "Profile-v2/catalog isolation migration is idempotent"
    } else {
        Fail "Second migration changed an already-migrated configuration"
    }
}
catch {
    Fail "Profile-v2 runtime migration failed: $($_.Exception.Message)"
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
    Write-Host "Profile V2 validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "Profile V2 validation PASSED" -ForegroundColor Green
exit 0
