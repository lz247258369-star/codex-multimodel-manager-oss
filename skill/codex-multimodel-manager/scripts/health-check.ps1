param(
    [switch]$Repair,
    [switch]$Yes,
    [switch]$NoLoginCheck,
    [switch]$NoNetwork,
    [switch]$NoReport,
    [switch]$NoRuntimeCheck
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_common.ps1")

$codexHome = Get-CodexHome
$configPath = Join-Path $codexHome "config.toml"
$results = New-Object System.Collections.Generic.List[object]
$backupTaken = $false

function Add-Result([string]$Category, [string]$Status, [string]$Message) {
    $results.Add([pscustomobject]@{
        category = $Category
        status = $Status
        message = $Message
    })

    $color = switch ($Status) {
        "PASS" { "Green" }
        "WARN" { "Yellow" }
        "BLOCK" { "Red" }
        default { "DarkGray" }
    }
    Write-Host ("{0,-5} {1}: {2}" -f $Status, $Category, $Message) -ForegroundColor $color
}

function Get-ConfigText {
    if (-not (Test-Path $configPath)) { return "" }
    return (Get-Content -Raw -Path $configPath)
}

function Confirm-Repair([string]$Prompt) {
    if ($Yes) { return $true }
    $answer = Read-Host "$Prompt [y/N]"
    return ($answer.Trim().ToLowerInvariant() -in @("y", "yes", "1", "true", "是"))
}

function Ensure-Backup {
    if ($backupTaken) { return }
    Backup-CodexConfig | Out-Null
    $script:backupTaken = $true
}

function Test-UserOrProcessEnv([string]$Name) {
    $processValue = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($processValue)) { return $true }
    $userValue = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::User)
    return (-not [string]::IsNullOrWhiteSpace($userValue))
}

function Has-ActiveRootSetting([string]$Text, [string]$Name) {
    $firstTable = [regex]::Match($Text, '(?m)^\s*\[')
    $rootText = if ($firstTable.Success) { $Text.Substring(0, $firstTable.Index) } else { $Text }
    return [regex]::IsMatch($rootText, '(?m)^\s*' + [regex]::Escape($Name) + '\s*=')
}

function Get-ActiveRootValue([string]$Text, [string]$Name) {
    $firstTable = [regex]::Match($Text, '(?m)^\s*\[')
    $rootText = if ($firstTable.Success) { $Text.Substring(0, $firstTable.Index) } else { $Text }
    $match = [regex]::Match($rootText, '(?m)^\s*' + [regex]::Escape($Name) + '\s*=\s*"([^"]*)"\s*$')
    if ($match.Success) { return $match.Groups[1].Value }
    return ""
}

function Invoke-SafeMigration {
    $migration = Join-Path $PSScriptRoot "migrate-profile-v2.ps1"
    if (-not (Test-Path $migration)) {
        return $false
    }
    & $migration
    return $true
}

function Repair-ForcedApiLogin {
    $text = Get-ConfigText
    if (-not [regex]::IsMatch($text, '(?m)^\s*forced_login_method\s*=\s*"api"\s*$')) {
        return
    }
    if (-not (Confirm-Repair "检测到 forced_login_method=api。是否取消全局 API-only 登录限制，以允许 ChatGPT 与第三方 Provider 共存？")) {
        return
    }
    Ensure-Backup
    $newText = [regex]::Replace(
        $text,
        '(?m)^\s*forced_login_method\s*=\s*"api"\s*$',
        '# forced_login_method = "api"  # disabled by Codex Multi-Model Manager health repair'
    )
    Set-Content -Path $configPath -Value $newText -Encoding UTF8
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " Codex Multi-Model Manager V3.4 Health Check"
Write-Host " 只读诊断；仅在 -Repair 且确认后修改用户级 Codex 配置"
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if ($Repair) {
    [void](Invoke-SafeMigration)
    Repair-ForcedApiLogin
}

$configText = Get-ConfigText

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Add-Result "PowerShell" "PASS" ("PowerShell " + $PSVersionTable.PSVersion)
} else {
    Add-Result "PowerShell" "BLOCK" "需要 PowerShell 7+（pwsh）。"
}

if (-not $NoRuntimeCheck) {
    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $codexCommand) {
        Add-Result "Codex CLI" "BLOCK" "未找到 codex 命令。"
    } else {
        try {
            $version = (& codex --version 2>&1 | Out-String).Trim()
            Add-Result "Codex CLI" "PASS" $version
        } catch {
            Add-Result "Codex CLI" "WARN" "找到 codex，但版本查询失败。"
        }
    }

    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        Add-Result "Git" "WARN" "未找到 git；模型仍可启动，但 Git handoff 保护不可用。"
    } else {
        Add-Result "Git" "PASS" "git 命令可用。"
    }
}

if (-not (Test-Path $configPath)) {
    Add-Result "Codex config" "BLOCK" "~/.codex/config.toml 不存在，请先运行 ONE_CLICK_SETUP.cmd。"
} else {
    Add-Result "Codex config" "PASS" $configPath
}

if ([regex]::IsMatch($configText, '(?m)^\s*forced_login_method\s*=\s*"api"\s*$')) {
    Add-Result "Auth coexistence" "BLOCK" "forced_login_method=api 会阻止 ChatGPT 登录与第三方 Provider 共存。运行 HEALTH_CHECK.cmd 并选择修复，或执行 health-check.ps1 -Repair。"
} else {
    Add-Result "Auth coexistence" "PASS" "未发现全局 API-only 登录限制。"
}

$legacyManagerProfiles = [regex]::IsMatch($configText, '(?m)^\s*\[profiles\.mm_[^\]]+\]')
if ($legacyManagerProfiles) {
    Add-Result "Profile V2" "BLOCK" "基础 config.toml 仍含 Manager 旧 [profiles.mm_*] 表。运行健康修复可迁移。"
} else {
    Add-Result "Profile V2" "PASS" "基础 config.toml 未发现 Manager 旧 profile 表。"
}

$rootProvider = Get-ActiveRootValue $configText "model_provider"
$rootCatalog = Get-ActiveRootValue $configText "model_catalog_json"
if (-not [string]::IsNullOrWhiteSpace($rootCatalog) -and $rootProvider -ne "openai") {
    Add-Result "Model catalog isolation" "BLOCK" "检测到非 OpenAI 自定义 model_catalog_json 在全局生效，会污染 ChatGPT /model。运行健康修复可隔离并保留旧目录。"
} else {
    Add-Result "Model catalog isolation" "PASS" "未发现会覆盖 ChatGPT 的全局自定义模型目录。"
}

$chatProfile = Join-Path $codexHome "mm_gpt56_chatgpt.config.toml"
if (Test-Path $chatProfile) {
    $chatText = Get-Content -Raw $chatProfile
    if ([regex]::IsMatch($chatText, '(?m)^\s*model\s*=\s*"gpt-5\.6"\s*$')) {
        Add-Result "ChatGPT profile" "BLOCK" "ChatGPT profile 仍硬编码 gpt-5.6；该旧 ID 可能被服务端拒绝。运行健康修复可改为账号支持的官方默认模型。"
    } else {
        Add-Result "ChatGPT profile" "PASS" "未硬编码旧 gpt-5.6；由 Codex 使用账号实际可用官方模型。"
    }
} else {
    Add-Result "ChatGPT profile" "WARN" "未找到 mm_gpt56_chatgpt.config.toml；运行 setup 刷新配置。"
}

if (-not $NoLoginCheck -and -not $NoRuntimeCheck -and (Get-Command codex -ErrorAction SilentlyContinue)) {
    try {
        $loginStatus = (& codex login status 2>&1 | Out-String).Trim()
        if ($loginStatus -match '(?i)not logged in') {
            Add-Result "ChatGPT login" "BLOCK" "Codex 当前未登录。运行 codex login 并选择 ChatGPT 登录。"
        } elseif ([string]::IsNullOrWhiteSpace($loginStatus)) {
            Add-Result "ChatGPT login" "WARN" "Codex 未返回可识别的登录状态。"
        } else {
            Add-Result "ChatGPT login" "PASS" $loginStatus
        }
    } catch {
        Add-Result "ChatGPT login" "WARN" "无法读取 Codex 登录状态。"
    }
} else {
    Add-Result "ChatGPT login" "SKIP" "已跳过登录状态检查。"
}

$providers = @(
    [pscustomobject]@{ Label = "OpenAI API"; Id = "mm_openai_api"; Env = "CODEX_OPENAI_API_KEY" },
    [pscustomobject]@{ Label = "MiMo"; Id = "mm_mimo"; Env = "MIMO_API_KEY" },
    [pscustomobject]@{ Label = "Alibaba Model Studio"; Id = "mm_modelstudio"; Env = "CODEX_DASHSCOPE_API_KEY" },
    [pscustomobject]@{ Label = "xAI"; Id = "mm_xai"; Env = "XAI_API_KEY" },
    [pscustomobject]@{ Label = "Groq"; Id = "mm_groq"; Env = "GROQ_API_KEY" },
    [pscustomobject]@{ Label = "OpenRouter"; Id = "mm_openrouter"; Env = "OPENROUTER_API_KEY" }
)
foreach ($provider in $providers) {
    $configured = [regex]::IsMatch($configText, '(?m)^\s*\[model_providers\.' + [regex]::Escape($provider.Id) + '\]\s*$')
    if (-not $configured) {
        Add-Result ("Provider " + $provider.Label) "SKIP" "未配置。"
        continue
    }
    if (Test-UserOrProcessEnv $provider.Env) {
        Add-Result ("Provider " + $provider.Label) "PASS" ("Provider 已配置；" + $provider.Env + " 已设置（值不显示）。")
    } else {
        Add-Result ("Provider " + $provider.Label) "BLOCK" ("Provider 已配置，但缺少 " + $provider.Env + "。")
    }
}

$openRouterConfigured = [regex]::IsMatch($configText, '(?m)^\s*\[model_providers\.mm_openrouter\]\s*$')
if ($openRouterConfigured -and -not $NoNetwork -and (Test-UserOrProcessEnv "OPENROUTER_API_KEY")) {
    try {
        $key = [Environment]::GetEnvironmentVariable("OPENROUTER_API_KEY", [EnvironmentVariableTarget]::Process)
        if ([string]::IsNullOrWhiteSpace($key)) {
            $key = [Environment]::GetEnvironmentVariable("OPENROUTER_API_KEY", [EnvironmentVariableTarget]::User)
        }
        $headers = @{ Authorization = "Bearer $key" }
        $catalog = Invoke-RestMethod -Uri "https://openrouter.ai/api/v1/models" -Headers $headers -Method Get -TimeoutSec 20
        $ids = @($catalog.data | ForEach-Object { [string]$_.id })
        Add-Result "OpenRouter catalog" "PASS" ("只读 /models 查询成功，共 " + $ids.Count + " 个模型。")
        if ($ids -contains "stealth/ox-alpha") {
            Add-Result "Ox Alpha" "PASS" "stealth/ox-alpha 当前仍在 OpenRouter 模型目录。"
        } else {
            Add-Result "Ox Alpha" "WARN" "stealth/ox-alpha 当前未出现在目录；请打开 Stealth Model Registry 检查是否已揭晓/改名。"
        }
    } catch {
        Add-Result "OpenRouter catalog" "WARN" "只读模型目录检查失败；未执行任何付费推理。"
    } finally {
        $key = $null
    }
} elseif ($openRouterConfigured) {
    Add-Result "OpenRouter catalog" "SKIP" "已跳过在线 /models 检查。"
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) {
        $branch = (& git branch --show-current 2>$null | Out-String).Trim()
        $head = (& git rev-parse HEAD 2>$null | Out-String).Trim()
        $status = @(& git status --porcelain)
        if ($status.Count -eq 0) {
            Add-Result "Git handoff readiness" "PASS" ("Repo 当前 CLEAN；branch=" + $branch + "; HEAD=" + $head.Substring(0, [Math]::Min(12, $head.Length)))
        } else {
            Add-Result "Git handoff readiness" "WARN" ("Repo 有 " + $status.Count + " 条未提交状态；切换仍会快照，但请注意保护用户工作。")
        }
    } else {
        Add-Result "Git handoff readiness" "SKIP" "当前目录不是 Git 仓库。"
    }
}

Add-Result "Custom model metadata" "WARN" "匿名/第三方模型若未在 Codex 官方 catalog 中，可能显示 fallback metadata 警告；这不等于路由失败。V3.4 先诊断，不伪造未知模型能力参数。"

if (-not $NoReport) {
    $reportDir = Join-Path $codexHome "multimodel-manager\reports"
    Ensure-Directory $reportDir
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $reportPath = Join-Path $reportDir ("health-" + $stamp + ".json")
    # Materialize the generic List[object] before embedding it in a PSCustomObject.
    # PowerShell 7 can throw "Argument types do not match" for @($results) here.
    $reportChecks = $results.ToArray()
    $payload = [pscustomobject]@{
        generated_at = (Get-Date).ToString("o")
        version = "3.4.0"
        repair_requested = [bool]$Repair
        checks = $reportChecks
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding UTF8
    Write-Host ""
    Write-Host "健康报告：$reportPath" -ForegroundColor DarkGray
}

$blocks = @($results | Where-Object { $_.status -eq "BLOCK" })
$warnings = @($results | Where-Object { $_.status -eq "WARN" })
Write-Host ""
Write-Host "Health summary" -ForegroundColor Cyan
Write-Host ("BLOCK: " + $blocks.Count + " | WARN: " + $warnings.Count)
if ($blocks.Count -gt 0) {
    Write-Host "健康检查发现阻塞项；请先修复后再启动对应模型。" -ForegroundColor Red
    exit 2
}
Write-Host "HEALTH SAFE" -ForegroundColor Green
exit 0
