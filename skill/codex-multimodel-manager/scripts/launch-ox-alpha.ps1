param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("low","medium","high","xhigh")]
    [string]$ReasoningEffort = "high"
)

$ErrorActionPreference = "Stop"

$launcher = Join-Path $PSScriptRoot "launch-stealth-model.ps1"
if (-not (Test-Path $launcher)) {
    Write-Host "缺少 launch-stealth-model.ps1，无法启动 Ox Alpha。" -ForegroundColor Red
    exit 1
}

& $launcher -Alias "Ox Alpha" -ConfirmationCode "OX" -ReasoningEffort $ReasoningEffort
exit $LASTEXITCODE
