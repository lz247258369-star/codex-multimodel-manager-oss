param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot ".."))
)

$ErrorActionPreference = "Stop"
$visualPath = Join-Path $RepositoryRoot "installer/scripts/visual-console.ps1"
$scopePath = Join-Path $RepositoryRoot "installer/scripts/visual-desktop-route-scope-fix.ps1"
$launcherPath = Join-Path $RepositoryRoot "installer/scripts/launch-controller-model.ps1"

foreach ($path in @($visualPath,$scopePath,$launcherPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing required runtime: $path" }
    $tokens=$null; $errors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors) | Out-Null
    if (@($errors).Count -gt 0) { throw "PowerShell parse failed for ${path}: $($errors[0].Message)" }
}

$visual = Get-Content -Raw -LiteralPath $visualPath
$scope = Get-Content -Raw -LiteralPath $scopePath
$launcher = Get-Content -Raw -LiteralPath $launcherPath

$launchMarkers = @(
    'function Start-SelectedModel',
    '$provider = $ProviderCombo.SelectedItem',
    '$model = $ModelCombo.SelectedItem',
    'Provider = [string]$provider.id',
    'ModelId = [string]$model.id',
    'ReasoningEffort = $effort',
    '$LaunchCurrentButton.Add_Click({ Start-SelectedModel })'
)
foreach ($marker in $launchMarkers) {
    if (-not $visual.Contains($marker)) { throw "Manager launch contract missing: $marker" }
}

if ($scope -match 'Refresh-ProviderSelection') {
    throw "Desktop route compatibility hook still overwrites Manager selection."
}
if (-not $scope.Contains('Update-DesktopRouteClarity') -or -not $scope.Contains('Update-DynamicDesktopRouteControls')) {
    throw "Desktop route compatibility hook must still refresh route status and controls."
}

foreach ($marker in @(
    '$LaunchCurrentButton.Content = "▶ 启动 Codex CLI"',
    '$ModelsLaunchButton.Content = "启动 Codex CLI"'
)) {
    if (-not $scope.Contains($marker)) { throw "Codex CLI launch surface is ambiguous: $marker" }
}

$guardMarkers = @(
    'Get-Command codex -ErrorAction SilentlyContinue',
    'Set-Location -LiteralPath $resolvedProject',
    'CLI 工作目录切换失败',
    'Show-CliLaunchBanner',
    'CODEX CLI DID NOT START / ENDED WITH AN ERROR',
    '当前窗口不是 Codex 对话',
    '不要在这里粘贴给 Codex 的任务说明',
    'Read-Host "按 Enter 关闭此窗口"',
    'Never fall back to an interactive PowerShell prompt',
    'exit 0'
)
foreach ($marker in $guardMarkers) {
    if (-not $launcher.Contains($marker)) { throw "Codex CLI fail-closed guard missing: $marker" }
}

Write-Host "Manager launch selection + CLI fail-closed validation PASS" -ForegroundColor Green
