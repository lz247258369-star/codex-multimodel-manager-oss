. (Join-Path $PSScriptRoot "scripts\_common.ps1")

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SkillSource = Join-Path $RepoRoot "skill\codex-multimodel-manager"

function Install-Skill {
    $codexHome = Get-CodexHome
    $skillsHome = Join-Path $codexHome "skills"
    $dest = Join-Path $skillsHome "codex-multimodel-manager"
    Ensure-Directory $skillsHome

    if (-not (Test-Path (Join-Path $SkillSource "SKILL.md"))) {
        throw "Skill source not found: $SkillSource"
    }

    if (Test-Path $dest) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $backup = "$dest.backup-$stamp"
        Move-Item $dest $backup
        Write-Host "旧 Skill 已备份：$backup" -ForegroundColor DarkGray
    }

    Copy-Item $SkillSource $dest -Recurse -Force
    Write-Host "Skill 已安装：$dest" -ForegroundColor Green
}

function Invoke-ProfileV2Migration([switch]$SkipBackup) {
    $script = Join-Path $PSScriptRoot "scripts\migrate-profile-v2.ps1"
    if (Test-Path $script) {
        if ($SkipBackup) { & $script -SkipBackup } else { & $script }
    }
}

function Install-DesktopEntrypoints {
    $script = Join-Path $PSScriptRoot "scripts\install-desktop-shortcuts.ps1"
    if (-not (Test-Path -LiteralPath $script)) {
        Write-Host "install-desktop-shortcuts.ps1 不存在，请先更新 Manager。" -ForegroundColor Yellow
        return
    }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $script
}

function Configure-OpenAI($state) {
    Write-Host ""
    Write-Host "OpenAI / ChatGPT 官方模型" -ForegroundColor Cyan
    Write-Host "ChatGPT 登录模式无需填写 API Key；Manager profile 不硬编码模型 ID，由 Codex 使用账号实际可用的官方模型。"
    if (Read-YesNo "是否另外配置 OpenAI API Key 付费通道？" $false) {
        if (Set-UserSecretEnv "CODEX_OPENAI_API_KEY" "粘贴 OpenAI API Key") {
            Set-StateValue $state "openai_api_enabled" $true
        }
    }
}

function Configure-MiMo($state) {
    Write-Host ""
    Write-Host "Xiaomi MiMo" -ForegroundColor Cyan
    Write-Host "1. 按量付费  https://api.xiaomimimo.com/v1"
    Write-Host "2. Token Plan https://token-plan-cn.xiaomimo.com/v1"
    $mode = Read-Host "选择 1/2"
    switch ($mode) {
        "1" { $base = "https://api.xiaomimimo.com/v1"; $modeName = "payg" }
        "2" { $base = "https://token-plan-cn.xiaomimo.com/v1"; $modeName = "token-plan" }
        default { Write-Host "已取消。" -ForegroundColor Yellow; return }
    }
    if (Set-UserSecretEnv "MIMO_API_KEY" "粘贴 MiMo API Key") {
        Set-StateValue $state "mimo_enabled" $true
        Set-StateValue $state "mimo_base_url" $base
        Set-StateValue $state "mimo_mode" $modeName
    }
}

function Configure-Aliyun($state) {
    Write-Host ""
    Write-Host "Alibaba Model Studio / Qwen / DeepSeek V4 (Responses)" -ForegroundColor Cyan
    Write-Host "1. 按量付费 - 北京业务空间"
    Write-Host "2. 按量付费 - 新加坡业务空间"
    Write-Host "3. Token Plan 个人/团队"
    Write-Host "4. 试用域名 - 北京"
    Write-Host "5. 试用域名 - 新加坡"
    $mode = Read-Host "选择 1-5"
    switch ($mode) {
        "1" {
            $wid = Read-NonEmpty "Workspace ID"
            $base = "https://$wid.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
            $modeName = "payg-beijing"
        }
        "2" {
            $wid = Read-NonEmpty "Workspace ID"
            $base = "https://$wid.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
            $modeName = "payg-singapore"
        }
        "3" {
            $base = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
            $modeName = "token-plan"
        }
        "4" {
            $base = "https://trial.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
            $modeName = "trial-beijing"
        }
        "5" {
            $base = "https://trial.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
            $modeName = "trial-singapore"
        }
        default { Write-Host "已取消。" -ForegroundColor Yellow; return }
    }

    if (Set-UserSecretEnv "CODEX_DASHSCOPE_API_KEY" "粘贴百炼 / Token Plan API Key") {
        Set-StateValue $state "aliyun_enabled" $true
        Set-StateValue $state "aliyun_base_url" $base
        Set-StateValue $state "aliyun_mode" $modeName
    }
}

function Configure-xAI($state) {
    Write-Host ""
    Write-Host "xAI / Grok" -ForegroundColor Cyan
    $model = Read-NonEmpty "默认 Grok 模型 ID" "grok-4.6"
    if (Set-UserSecretEnv "XAI_API_KEY" "粘贴 xAI API Key") {
        Set-StateValue $state "xai_enabled" $true
        Set-StateValue $state "xai_model" $model
    }
}

function Configure-Groq($state) {
    Write-Host ""
    Write-Host "Groq Responses" -ForegroundColor Cyan
    $model = Read-NonEmpty "默认 Groq 模型 ID" "openai/gpt-oss-20b"
    if (Set-UserSecretEnv "GROQ_API_KEY" "粘贴 Groq API Key") {
        Set-StateValue $state "groq_enabled" $true
        Set-StateValue $state "groq_model" $model
    }
}

function Configure-OpenRouter($state) {
    Write-Host ""
    Write-Host "OpenRouter - 通用备用通道" -ForegroundColor Cyan
    Write-Host "适合 Claude / Gemini / Kimi / GLM / MiniMax / DeepSeek 等备用模型。"
    if (Set-UserSecretEnv "OPENROUTER_API_KEY" "粘贴 OpenRouter API Key") {
        Set-StateValue $state "openrouter_enabled" $true
        $default = Read-Host "可选：粘贴一个 OpenRouter 完整模型 slug（可直接回车跳过）"
        Set-StateValue $state "openrouter_default_model" $default.Trim()
    }
}

function Remove-ManagedBlock {
    $codexHome = Get-CodexHome
    $config = Join-Path $codexHome "config.toml"
    if (-not (Test-Path $config)) {
        Write-Host "config.toml 不存在。" -ForegroundColor Yellow
        return
    }
    Backup-CodexConfig | Out-Null
    $text = Get-Content -Raw $config
    $pattern = '(?s)\r?\n?# >>> CODEX MULTIMODEL MANAGER BEGIN.*?# <<< CODEX MULTIMODEL MANAGER END\r?\n?'
    $newText = [regex]::Replace($text, $pattern, "`r`n", 1)
    Set-Content $config $newText -Encoding UTF8

    $profileManifest = Join-Path $codexHome "multimodel-manager\profile-v2-files.json"
    if (Test-Path $profileManifest) {
        try {
            foreach ($profileId in @(Get-Content -Raw $profileManifest | ConvertFrom-Json)) {
                if ([string]::IsNullOrWhiteSpace([string]$profileId)) { continue }
                $profilePath = Join-Path $codexHome ([string]$profileId + ".config.toml")
                Remove-Item -Path $profilePath -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -Path $profileManifest -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Host "Profile V2 清理清单读取失败，请手动检查 Manager profile 文件。" -ForegroundColor Yellow
        }
    }

    Write-Host "已移除 Manager 管理区及其独立 profile 文件；其它 Codex 配置未动。" -ForegroundColor Green
}

Clear-Host
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Codex Multi-Model Manager V3.5.2"
Write-Host " ChatGPT 官方模型 + 多模型备用 | Windows"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Test-CodexInstalled | Out-Null
Install-Skill

$state = Load-State
$setupRunning = $true

while ($setupRunning) {
    Write-Host ""
    Write-Host "请选择：" -ForegroundColor Cyan
    Write-Host " 1. OpenAI / ChatGPT 官方模型（ChatGPT 登录 + 可选 API）"
    Write-Host " 2. Xiaomi MiMo V2.5 / V2.5 Pro"
    Write-Host " 3. 阿里云百炼：Qwen + DeepSeek V4（Responses）"
    Write-Host " 4. xAI Grok（Responses）"
    Write-Host " 5. Groq（Responses）"
    Write-Host " 6. OpenRouter 通用通道（Claude/Gemini/Kimi/GLM/MiniMax 等）"
    Write-Host " 7. 写入/刷新 Codex 配置"
    Write-Host " 8. 查看配置状态"
    Write-Host " 9. 移除本 Manager 管理区（不动其它配置）"
    Write-Host "10. 一键健康检查 / 安全修复"
    Write-Host "11. 安装 Desktop Controller 桌面/开始菜单入口"
    Write-Host " 0. 保存并退出"
    $choice = Read-Host "输入数字"

    switch ($choice) {
        "1" { Configure-OpenAI $state; Save-State $state }
        "2" { Configure-MiMo $state; Save-State $state }
        "3" { Configure-Aliyun $state; Save-State $state }
        "4" { Configure-xAI $state; Save-State $state }
        "5" { Configure-Groq $state; Save-State $state }
        "6" { Configure-OpenRouter $state; Save-State $state }
        "7" {
            Backup-CodexConfig | Out-Null
            Apply-ManagedConfig $state
            Invoke-ProfileV2Migration -SkipBackup
        }
        "8" { & (Join-Path $PSScriptRoot "scripts\show-status.ps1") }
        "9" {
            if (Read-YesNo "确认只移除 MultiModel Manager 管理区？" $false) {
                Remove-ManagedBlock
            }
        }
        "10" {
            $health = Join-Path $PSScriptRoot "scripts\health-check.ps1"
            if (Test-Path $health) {
                & pwsh -NoProfile -ExecutionPolicy Bypass -File $health
            } else {
                Write-Host "health-check.ps1 不存在，请更新 Manager。" -ForegroundColor Yellow
            }
        }
        "11" { Install-DesktopEntrypoints }
        "0" {
            Save-State $state
            if (Read-YesNo "退出前自动备份并刷新 Codex 配置？" $true) {
                Backup-CodexConfig | Out-Null
                Apply-ManagedConfig $state
                Invoke-ProfileV2Migration -SkipBackup
            }
            if (Read-YesNo "是否创建/刷新 Desktop Controller 桌面与开始菜单快捷方式？" $true) {
                Install-DesktopEntrypoints
            }
            Write-Host ""
            Write-Host "完成。可直接从桌面打开 Codex Multi-Model Controller；也可运行 installer\HEALTH_CHECK.cmd。" -ForegroundColor Green
            Write-Host "现有项目代码、Git 仓库、原有 Codex 配置均不会因本向导被删除。"
            $setupRunning = $false
        }
        default { Write-Host "无效选择。" -ForegroundColor Yellow }
    }
}
