param(
    [switch]$SkipBackup,
    [switch]$Quiet
)

. (Join-Path $PSScriptRoot "_common.ps1")

$codexHome = Get-CodexHome
$configPath = Join-Path $codexHome "config.toml"
if (-not (Test-Path $configPath)) {
    return
}

$text = Get-Content -Raw -Path $configPath
$originalText = $text
$profileIds = New-Object System.Collections.Generic.List[string]
$legacyCatalogProfileId = "legacy-codex-catalog"
$legacyCatalogMigrated = $false
$chatGptProfileNormalized = $false

function Write-ProfileV2([string]$ProfileId, [string]$Body) {
    if ([string]::IsNullOrWhiteSpace($ProfileId) -or [string]::IsNullOrWhiteSpace($Body)) {
        return
    }

    $profilePath = Join-Path $codexHome ($ProfileId + ".config.toml")
    $normalized = $Body.Trim()
    Set-Content -Path $profilePath -Value ($normalized + "`r`n") -Encoding UTF8
    if (-not $profileIds.Contains($ProfileId)) {
        $profileIds.Add($ProfileId)
    }
}

function Migrate-BlockProfiles([string]$Block) {
    if ([string]::IsNullOrWhiteSpace($Block)) {
        return $Block
    }

    $profilePattern = '(?ms)^\[profiles\.([A-Za-z0-9_-]+)\]\s*\r?\n(.*?)(?=^\[[^\r\n]+\]\s*$|^# <<<|\z)'
    $matches = [regex]::Matches($Block, $profilePattern)
    foreach ($match in $matches) {
        Write-ProfileV2 $match.Groups[1].Value $match.Groups[2].Value
    }
    return [regex]::Replace($Block, $profilePattern, "")
}

function Isolate-LegacyRootCatalog([string]$InputText) {
    $firstTable = [regex]::Match($InputText, '(?m)^\s*\[')
    $rootEnd = if ($firstTable.Success) { $firstTable.Index } else { $InputText.Length }
    $rootText = $InputText.Substring(0, $rootEnd)
    $restText = $InputText.Substring($rootEnd)

    $providerMatch = [regex]::Match($rootText, '(?m)^\s*model_provider\s*=\s*"([^"]+)"\s*$')
    $catalogMatch = [regex]::Match($rootText, '(?m)^\s*model_catalog_json\s*=\s*"([^"]+)"\s*$')
    if (-not $providerMatch.Success -or -not $catalogMatch.Success) {
        return [pscustomobject]@{ Text = $InputText; Migrated = $false }
    }

    $provider = $providerMatch.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($provider) -or $provider -eq "openai") {
        return [pscustomobject]@{ Text = $InputText; Migrated = $false }
    }

    $keys = @(
        "model",
        "model_provider",
        "model_catalog_json",
        "model_reasoning_effort",
        "model_reasoning_summary",
        "model_verbosity",
        "plan_mode_reasoning_effort"
    )
    $moved = New-Object System.Collections.Generic.List[string]
    foreach ($key in $keys) {
        $pattern = '(?m)^\s*' + [regex]::Escape($key) + '\s*=\s*[^\r\n]+\r?\n?'
        $match = [regex]::Match($rootText, $pattern)
        if ($match.Success) {
            $moved.Add($match.Value.Trim())
            $rootText = [regex]::Replace($rootText, $pattern, "", 1)
        }
    }

    if (-not ($moved | Where-Object { $_ -match '^model_provider\s*=' }) -or
        -not ($moved | Where-Object { $_ -match '^model_catalog_json\s*=' })) {
        return [pscustomobject]@{ Text = $InputText; Migrated = $false }
    }

    $legacyProfilePath = Join-Path $codexHome ($legacyCatalogProfileId + ".config.toml")
    $body = @(
        "# Preserved from legacy global Codex settings by Codex Multi-Model Manager.",
        "# Kept profile-scoped so a custom model catalog cannot override ChatGPT /model.",
        ""
    ) + $moved.ToArray()
    Set-Content -Path $legacyProfilePath -Value (($body -join "`r`n") + "`r`n") -Encoding UTF8

    return [pscustomobject]@{ Text = ($rootText + $restText); Migrated = $true }
}

function Normalize-ManagerChatGPTProfile {
    $profilePath = Join-Path $codexHome "mm_gpt56_chatgpt.config.toml"
    if (-not (Test-Path $profilePath)) {
        return $false
    }

    $profileText = Get-Content -Raw -Path $profilePath
    # A ChatGPT login can only use models enabled for that account. Leaving the
    # model unset lets Codex select its official account-supported default instead
    # of forcing a model ID that the service may reject.
    $normalized = [regex]::Replace(
        $profileText,
        '(?m)^\s*model\s*=\s*"gpt-5\.6"\s*\r?\n?',
        ""
    )
    if ($normalized -eq $profileText) {
        return $false
    }

    Set-Content -Path $profilePath -Value $normalized.TrimStart() -Encoding UTF8
    return $true
}

$managerPattern = '(?s)# >>> CODEX MULTIMODEL MANAGER BEGIN.*?# <<< CODEX MULTIMODEL MANAGER END'
$managerMatch = [regex]::Match($text, $managerPattern)
if ($managerMatch.Success) {
    $migratedManagerBlock = Migrate-BlockProfiles $managerMatch.Value
    $text = $text.Substring(0, $managerMatch.Index) + $migratedManagerBlock + $text.Substring($managerMatch.Index + $managerMatch.Length)
}

$autoPattern = '(?s)\r?\n?# >>> CODEX AUTO MODELS BEGIN.*?# <<< CODEX AUTO MODELS END\r?\n?'
$autoMatch = [regex]::Match($text, $autoPattern)
if ($autoMatch.Success) {
    [void](Migrate-BlockProfiles $autoMatch.Value)
    $text = $text.Substring(0, $autoMatch.Index) + "`r`n" + $text.Substring($autoMatch.Index + $autoMatch.Length)
}

# Preserve an old provider-specific global model catalog in its own profile.
# This fixes configurations where a DeepSeek/custom models.json globally replaced
# the official ChatGPT model list.
$legacyResult = Isolate-LegacyRootCatalog $text
$text = $legacyResult.Text
$legacyCatalogMigrated = [bool]$legacyResult.Migrated

# Remove only legacy selector lines that point at Manager-owned profiles.
$managerSelectorPattern = '(?m)^\s*profile\s*=\s*"(mm_(?:gpt56(?:_[A-Za-z0-9_-]+)?|mimo_[A-Za-z0-9_-]+|qwen[A-Za-z0-9_-]*|deepseek_[A-Za-z0-9_-]+|grok|groq_[A-Za-z0-9_-]+|openrouter_[A-Za-z0-9_-]+|auto_[A-Za-z0-9_-]+))"\s*\r?\n?'
$text = [regex]::Replace($text, $managerSelectorPattern, "")

$chatGptProfileNormalized = Normalize-ManagerChatGPTProfile
$changed = ($text -ne $originalText) -or ($profileIds.Count -gt 0) -or $legacyCatalogMigrated -or $chatGptProfileNormalized
if (-not $changed) {
    return
}

if (-not $SkipBackup) {
    Backup-CodexConfig | Out-Null
}

Set-Content -Path $configPath -Value $text -Encoding UTF8

$managerHome = Join-Path $codexHome "multimodel-manager"
Ensure-Directory $managerHome
$manifestPath = Join-Path $managerHome "profile-v2-files.json"
$existing = @()
if (Test-Path $manifestPath) {
    try { $existing = @(Get-Content -Raw $manifestPath | ConvertFrom-Json) } catch { $existing = @() }
}
$allIds = @($existing + $profileIds.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
ConvertTo-Json -InputObject ([object[]]$allIds) | Set-Content -Path $manifestPath -Encoding UTF8

if (-not $Quiet) {
    Write-Host "已迁移 Codex Profile V2 配置。" -ForegroundColor Green
    Write-Host "基础 config.toml 仅保留共享配置；Manager profiles 已写入独立 *.config.toml。" -ForegroundColor Green
    if ($legacyCatalogMigrated) {
        Write-Host "旧的全局自定义模型目录已隔离到 legacy-codex-catalog.config.toml；ChatGPT 将恢复官方模型目录。" -ForegroundColor Green
    }
    if ($chatGptProfileNormalized) {
        Write-Host "ChatGPT profile 已取消硬编码 gpt-5.6，改由 Codex 选择当前账号实际可用的官方默认模型。" -ForegroundColor Green
    }
    if ($profileIds.Count -gt 0) {
        Write-Host ("Profiles: " + (($profileIds.ToArray() | Sort-Object -Unique) -join ", ")) -ForegroundColor DarkGray
    }
}
