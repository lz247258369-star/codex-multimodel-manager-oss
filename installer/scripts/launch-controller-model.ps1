param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet("chatgpt","mimo","qwen","deepseek","glm","ox")]
    [string]$Target = "",

    [Parameter(Mandatory = $false)]
    [ValidateSet("chatgpt","modelstudio","openrouter","mimo")]
    [string]$Provider = "",

    [Parameter(Mandatory = $false)]
    [string]$ModelId = "",

    [Parameter(Mandatory = $false)]
    [ValidateSet("low","medium","high","xhigh")]
    [string]$ReasoningEffort = "medium"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_common.ps1")

function Import-UserEnvToProcess([string]$Name) {
    $processValue = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($processValue)) { return $true }

    $userValue = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::User)
    if ([string]::IsNullOrWhiteSpace($userValue)) { return $false }

    Set-Item -Path "Env:$Name" -Value $userValue
    return $true
}

function Require-ProviderKey([string]$Name) {
    if (-not (Import-UserEnvToProcess $Name)) {
        throw "Missing environment variable: $Name. Run ONE_CLICK_SETUP.cmd first."
    }
}

function Prepare-Handoff([string]$Label) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) { return }

    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { return }

    $handoff = Join-Path $PSScriptRoot "collect-handoff.ps1"
    & $handoff -TargetModel $Label
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to prepare Git handoff."
    }
    Write-Host ""
}

function Show-CliLaunchBanner(
    [string]$Workspace,
    [string]$ProviderId,
    [string]$SelectedModel,
    [string]$Effort
) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host " Codex Multi-Model Manager -> Codex CLI" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "Workspace : $Workspace" -ForegroundColor White
    Write-Host "Provider  : $ProviderId" -ForegroundColor White
    Write-Host "Model     : $SelectedModel" -ForegroundColor White
    Write-Host "Reasoning : $Effort" -ForegroundColor White
    Write-Host ""
    Write-Host "Starting Codex CLI..." -ForegroundColor Cyan
    Write-Host ""
}

function Stop-CliLaunchFailure([string]$Message, [int]$ExitCode = 1) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host " CODEX CLI DID NOT START / ENDED WITH AN ERROR" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host $Message -ForegroundColor Yellow
    Write-Host ""
    Write-Host "当前窗口不是 Codex 对话，不要在这里粘贴给 Codex 的任务说明。" -ForegroundColor Yellow
    Write-Host "请回到 Codex Multi-Model Manager 检查工作目录、Provider、模型和 Key。" -ForegroundColor Yellow
    Write-Host ""
    try { Read-Host "按 Enter 关闭此窗口" | Out-Null } catch {}
    exit $ExitCode
}

function Invoke-CodexRoute([string]$ProviderId, [string]$SelectedModel, [string]$Effort) {
    $effortConfig = 'model_reasoning_effort="{0}"' -f $Effort

    switch ($ProviderId) {
        "chatgpt" {
            $displayModel = if ($SelectedModel -eq "__account_default__" -or [string]::IsNullOrWhiteSpace($SelectedModel)) { "ChatGPT account default" } else { $SelectedModel }
            Prepare-Handoff $displayModel
            [Console]::Title = "Codex - $displayModel"
            if ($SelectedModel -eq "__account_default__" -or [string]::IsNullOrWhiteSpace($SelectedModel)) {
                & codex --profile mm_gpt56_chatgpt -c $effortConfig
            }
            else {
                & codex --profile mm_gpt56_chatgpt -m $SelectedModel -c $effortConfig
            }
        }
        "modelstudio" {
            Require-ProviderKey "CODEX_DASHSCOPE_API_KEY"
            if ([string]::IsNullOrWhiteSpace($SelectedModel)) { throw "ModelId is required for Alibaba Model Studio." }
            Prepare-Handoff "$SelectedModel / Alibaba Model Studio"
            [Console]::Title = "Codex - $SelectedModel"
            & codex -c 'model_provider="mm_modelstudio"' -m $SelectedModel -c $effortConfig
        }
        "openrouter" {
            Require-ProviderKey "OPENROUTER_API_KEY"
            if ([string]::IsNullOrWhiteSpace($SelectedModel)) { throw "ModelId is required for OpenRouter." }
            if ($SelectedModel -eq "stealth/ox-alpha") {
                [Console]::Title = "Codex - Ox Alpha"
                & (Join-Path $PSScriptRoot "launch-ox-alpha.ps1") -ReasoningEffort $Effort
            }
            else {
                Prepare-Handoff "$SelectedModel / OpenRouter"
                [Console]::Title = "Codex - $SelectedModel"
                & codex -c 'model_provider="mm_openrouter"' -m $SelectedModel -c $effortConfig
            }
        }
        "mimo" {
            Require-ProviderKey "MIMO_API_KEY"
            if ([string]::IsNullOrWhiteSpace($SelectedModel)) { throw "ModelId is required for Xiaomi MiMo." }
            Prepare-Handoff "$SelectedModel / Xiaomi MiMo"
            [Console]::Title = "Codex - $SelectedModel"
            & codex -c 'model_provider="mm_mimo"' -m $SelectedModel -c $effortConfig
        }
        default {
            throw "Unsupported provider route: $ProviderId"
        }
    }
}

try {
    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $codexCommand) {
        throw "找不到 codex 命令。请确认 Codex CLI 已安装并可从 PowerShell PATH 访问。"
    }

    $resolvedProject = (Resolve-Path -LiteralPath $ProjectPath).Path
    Set-Location -LiteralPath $resolvedProject

    $actualLocation = (Get-Location).Path
    if (-not [string]::Equals($actualLocation, $resolvedProject, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "CLI 工作目录切换失败。Expected=$resolvedProject Actual=$actualLocation"
    }

    $migrationScript = Join-Path $PSScriptRoot "migrate-profile-v2.ps1"
    if (Test-Path $migrationScript) {
        & $migrationScript
    }

    $effectiveProvider = $Provider
    $effectiveModel = $ModelId
    $effectiveEffort = $ReasoningEffort

    if ([string]::IsNullOrWhiteSpace($effectiveProvider)) {
        switch ($Target) {
            "chatgpt" { $effectiveProvider = "chatgpt"; $effectiveModel = "__account_default__"; $effectiveEffort = "high" }
            "mimo" { $effectiveProvider = "mimo"; $effectiveModel = "mimo-v2.5-pro"; $effectiveEffort = "high" }
            "qwen" { $effectiveProvider = "modelstudio"; $effectiveModel = "qwen3-coder-plus"; $effectiveEffort = "medium" }
            "deepseek" { $effectiveProvider = "modelstudio"; $effectiveModel = "deepseek-v4-pro"; $effectiveEffort = "medium" }
            "glm" { $effectiveProvider = "openrouter"; $effectiveModel = "z-ai/glm-5.3"; $effectiveEffort = "medium" }
            "ox" { $effectiveProvider = "openrouter"; $effectiveModel = "stealth/ox-alpha"; $effectiveEffort = "medium" }
            default { throw "Specify either -Provider/-ModelId or a legacy -Target preset." }
        }
    }

    $displayModel = if ($effectiveModel -eq "__account_default__") { "ChatGPT account default" } else { $effectiveModel }
    Show-CliLaunchBanner -Workspace $resolvedProject -ProviderId $effectiveProvider -SelectedModel $displayModel -Effort $effectiveEffort

    Invoke-CodexRoute -ProviderId $effectiveProvider -SelectedModel $effectiveModel -Effort $effectiveEffort

    $codexExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($codexExitCode -ne 0) {
        Stop-CliLaunchFailure -Message "Codex CLI exited with code $codexExitCode." -ExitCode $codexExitCode
    }

    # Never fall back to an interactive PowerShell prompt after a Codex session.
    # This prevents Codex task text from being accidentally executed as shell commands.
    exit 0
}
catch {
    Stop-CliLaunchFailure -Message $_.Exception.Message -ExitCode 1
}
