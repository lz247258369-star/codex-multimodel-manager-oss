param(
    [switch]$Enable,
    [switch]$Disable
)

$ErrorActionPreference = "Stop"
$taskName = "Codex MultiModel Weekly Model Check"
$scriptPath = Join-Path $PSScriptRoot "discover-models.ps1"

if ($Disable) {
    schtasks.exe /Delete /TN $taskName /F | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "已关闭每周模型检查。" -ForegroundColor Green
    } else {
        Write-Host "任务可能不存在或删除失败。" -ForegroundColor Yellow
    }
    exit
}

if ($Enable) {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -eq $pwsh) {
        throw "需要 PowerShell 7 (pwsh.exe)。请先运行：winget install --id Microsoft.PowerShell -e --source winget"
    }

    # Sunday 10:00 local time. This is only installed when user explicitly runs this file.
    $cmd = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Scheduled"
    schtasks.exe /Create /TN $taskName /SC WEEKLY /D SUN /ST 10:00 /TR $cmd /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "创建计划任务失败。"
    }
    Write-Host "已开启每周模型检查：每周日 10:00（本机时间）。" -ForegroundColor Green
    Write-Host "定时任务只调用 /models 做发现，不运行付费模型推理测试，也不会自动修改 Codex 配置。"
    exit
}

Write-Host "请使用 -Enable 或 -Disable。"
