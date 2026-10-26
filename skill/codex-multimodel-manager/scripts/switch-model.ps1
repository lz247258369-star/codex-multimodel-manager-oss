. (Join-Path $PSScriptRoot "_common.ps1")

function Import-UserEnvToProcess([string]$Name) {
    $processValue = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($processValue)) {
        return $true
    }

    $userValue = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::User)
    if ([string]::IsNullOrWhiteSpace($userValue)) {
        return $false
    }

    Set-Item -Path "Env:$Name" -Value $userValue
    return $true
}

function Import-KnownProviderSecrets {
    foreach ($name in @(
        "CODEX_OPENAI_API_KEY",
        "MIMO_API_KEY",
        "CODEX_DASHSCOPE_API_KEY",
        "XAI_API_KEY",
        "GROQ_API_KEY",
        "OPENROUTER_API_KEY"
    )) {
        [void](Import-UserEnvToProcess $name)
    }
}

function Test-Env([string]$Name) {
    return (Import-UserEnvToProcess $Name)
}

function Prepare-Handoff([string]$Target) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) { return }
    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) {
        $handoff = Join-Path $PSScriptRoot "collect-handoff.ps1"
        & $handoff -TargetModel $Target
        Write-Host ""
    }
}

function Launch-Profile([string]$Profile, [string]$Label, [string]$RequiredEnv = "") {
    if ($RequiredEnv -and -not (Test-Env $RequiredEnv)) {
        Write-Host "缺少环境变量 $RequiredEnv。请先运行 ONE_CLICK_SETUP.cmd。" -ForegroundColor Yellow
        return
    }
    Prepare-Handoff $Label
    & codex --profile $Profile
}

function Launch-OpenRouterFixedModel([string]$Model, [string]$Label) {
    if (-not (Test-Env "OPENROUTER_API_KEY")) {
        Write-Host "缺少环境变量 OPENROUTER_API_KEY。请先运行 ONE_CLICK_SETUP.cmd 配置 OpenRouter。" -ForegroundColor Yellow
        return
    }
    Prepare-Handoff $Label
    & codex -c 'model_provider="mm_openrouter"' -m $Model
}

function Launch-LegacyCatalogOrDefault {
    $legacyPath = Join-Path (Get-CodexHome) "legacy-codex-catalog.config.toml"
    if (Test-Path $legacyPath) {
        Launch-Profile "legacy-codex-catalog" "Legacy custom model catalog"
        return
    }

    Prepare-Handoff "Existing Codex default"
    & codex
}

function Launch-AutoModels {
    Import-KnownProviderSecrets
    $managerHome = if ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME "multimodel-manager" } else { Join-Path $HOME ".codex\multimodel-manager" }
    $approvedPath = Join-Path $managerHome "approved-models.json"
    if (-not (Test-Path $approvedPath)) {
        Write-Host "暂无自动发现后批准的模型。" -ForegroundColor Yellow
        return
    }
    $models = @(Get-Content -Raw $approvedPath | ConvertFrom-Json)
    if ($models.Count -eq 0) {
        Write-Host "暂无自动发现后批准的模型。" -ForegroundColor Yellow
        return
    }
    Write-Host ""
    Write-Host "动态批准模型：" -ForegroundColor Cyan
    for ($i=0; $i -lt $models.Count; $i++) {
        $m = $models[$i]
        Write-Host ("{0,3}. {1} :: {2}" -f ($i+1), $m.provider_name, $m.model_id)
    }
    $n = [int](Read-Host "选择编号")
    if ($n -lt 1 -or $n -gt $models.Count) { return }
    $m = $models[$n-1]
    Prepare-Handoff ("Auto model: " + $m.model_id)
    & codex --profile $m.profile_id
}

function Open-HealthCheck {
    $health = Join-Path $PSScriptRoot "health-check.ps1"
    if (-not (Test-Path $health)) {
        Write-Host "health-check.ps1 不存在，请更新 Manager。" -ForegroundColor Yellow
        return
    }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $health
}

$migrationScript = Join-Path $PSScriptRoot "migrate-profile-v2.ps1"
if (Test-Path $migrationScript) {
    & $migrationScript
}

Import-KnownProviderSecrets

Clear-Host
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Codex Model Switcher V3.5.0"
Write-Host " ChatGPT 官方模型 + 固定备用 + 动态/匿名模型管理"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " 1. ChatGPT 官方默认（首选；按账号实际可用模型）"
Write-Host " 2. MiMo V2.5 Pro"
Write-Host " 3. Qwen3 Coder Plus（百炼 Responses）"
Write-Host " 4. DeepSeek V4 Pro（百炼 Responses）"
Write-Host " 5. GLM 5.3（OpenRouter）"
Write-Host " 6. Groq 默认模型"
Write-Host " 7. 动态批准的新模型 ★"
Write-Host " 8. 原来的自定义模型目录（如已隔离）/ Codex 默认"
Write-Host " 9. 校验上一次模型交接"
Write-Host "10. 打开模型更新中心"
Write-Host "11. Ox Alpha（通过 Stealth Registry 解析）"
Write-Host "12. 打开 Stealth Model Registry"
Write-Host "13. 一键健康检查 / 安全修复"
Write-Host " 0. 退出"
$c = Read-Host "选择"

switch ($c) {
    "1" { Launch-Profile "mm_gpt56_chatgpt" "ChatGPT official account model" }
    "2" { Launch-Profile "mm_mimo_v25_pro" "MiMo V2.5 Pro" "MIMO_API_KEY" }
    "3" { Launch-Profile "mm_qwen3_coder_plus" "Qwen3 Coder Plus" "CODEX_DASHSCOPE_API_KEY" }
    "4" { Launch-Profile "mm_deepseek_v4_pro_aliyun" "DeepSeek V4 Pro" "CODEX_DASHSCOPE_API_KEY" }
    "5" { Launch-OpenRouterFixedModel "z-ai/glm-5.3" "GLM 5.3 / OpenRouter" }
    "6" { Launch-Profile "mm_groq_default" "Groq Responses" "GROQ_API_KEY" }
    "7" { Launch-AutoModels }
    "8" { Launch-LegacyCatalogOrDefault }
    "9" { & (Join-Path $PSScriptRoot "resume-handoff.ps1") }
    "10" { & (Join-Path $PSScriptRoot "model-update-center.ps1") }
    "11" { & (Join-Path $PSScriptRoot "launch-ox-alpha.ps1") }
    "12" { & (Join-Path $PSScriptRoot "stealth-model-center.ps1") }
    "13" { Open-HealthCheck }
}