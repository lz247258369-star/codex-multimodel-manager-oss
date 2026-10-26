param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
$runtimePath = Join-Path $RepositoryRoot "installer/scripts/visual-desktop-route-dynamic.ps1"
$scopeFixPath = Join-Path $RepositoryRoot "installer/scripts/visual-desktop-route-scope-fix.ps1"
$loaderPath = Join-Path $RepositoryRoot "installer/scripts/visual-sidebar-readability.ps1"
foreach ($path in @($runtimePath,$scopeFixPath,$loaderPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing dynamic Desktop route UI dependency: $path" }
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors) | Out-Null
    if (@($errors).Count -gt 0) { throw "Dynamic Desktop route UI parse failed for ${path}: $($errors[0].Message)" }
}

$runtime = Get-Content -Raw -LiteralPath $runtimePath
$loader = Get-Content -Raw -LiteralPath $loaderPath
foreach ($marker in @(
    '切换桌面 Chat → $($target.Label)',
    '桌面 Chat 已是 → $($target.Label)',
    '"modelstudio"',
    'CodexProvider="mm_modelstudio"',
    '"openrouter"',
    'CodexProvider="mm_openrouter"',
    '"mimo"',
    'CodexProvider="mm_mimo"',
    '当前模型暂不支持桌面 Chat',
    '恢复桌面 ChatGPT'
)) {
    if (-not $runtime.Contains($marker)) { throw "Missing dynamic route UI marker: $marker" }
}
if (-not $loader.Contains('visual-desktop-route-dynamic.ps1')) { throw "Dynamic Desktop route UI is not loaded by V4." }
if (-not $loader.Contains('visual-desktop-route-scope-fix.ps1')) { throw "Desktop route scope override is not loaded by V4." }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore

$tempRoot = Join-Path $env:TEMP ("mm-dynamic-route-ui-{0}" -f ([Guid]::NewGuid().ToString("N")))
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $desktopRouteStatePath = Join-Path $tempRoot "desktop-route-state.json"
    $window = [System.Windows.Window]::new()
    $window.Resources.Add("SoftButton", [System.Windows.Style]::new([System.Windows.Controls.Button]))
    function Get-ColorBrush([string]$Hex) { return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex) }

    $heroActionPanel = [System.Windows.Controls.StackPanel]::new()
    $desktopOxButton = [System.Windows.Controls.Button]::new(); $desktopOxButton.Content = "切换桌面 Chat → OX"
    $desktopRestoreButton = [System.Windows.Controls.Button]::new(); $desktopRestoreButton.Content = "恢复桌面 ChatGPT"
    $desktopRouteText = [System.Windows.Controls.TextBlock]::new()
    [void]$heroActionPanel.Children.Add($desktopOxButton)
    [void]$heroActionPanel.Children.Add($desktopRestoreButton)
    [void]$heroActionPanel.Children.Add($desktopRouteText)

    $ProviderCombo = [System.Windows.Controls.ComboBox]::new()
    $ModelCombo = [System.Windows.Controls.ComboBox]::new()
    $EffortCombo = [System.Windows.Controls.ComboBox]::new()
    $EffortCombo.ItemsSource = @("low","medium","high")
    $EffortCombo.SelectedItem = "high"

    $deepseekProvider = [pscustomobject]@{ id="modelstudio"; label="阿里云百炼（Qwen / DeepSeek）" }
    $deepseekModel = [pscustomobject]@{ id="deepseek-v4-flash"; label="DeepSeek V4 Flash" }
    $ProviderCombo.ItemsSource = @($deepseekProvider)
    $ProviderCombo.SelectedItem = $deepseekProvider
    $ModelCombo.ItemsSource = @($deepseekModel)
    $ModelCombo.SelectedItem = $deepseekModel

    . $runtimePath
    . $scopeFixPath

    if ($heroActionPanel.Children.Contains($desktopOxButton)) { throw "Legacy OX-only button still exists in the visual tree." }
    if ($null -eq $script:DynamicDesktopRouteButton) { throw "Dynamic Desktop route button was not created." }
    if ([string]$script:DynamicDesktopRouteButton.Content -ne "切换桌面 Chat → DeepSeek V4 Flash") {
        throw "DeepSeek selection did not update Desktop route button: $($script:DynamicDesktopRouteButton.Content)"
    }

    $openRouterProvider = [pscustomobject]@{ id="openrouter"; label="OpenRouter" }
    $oxModel = [pscustomobject]@{ id="stealth/ox-alpha"; label="Ox Alpha（实验）" }
    $ProviderCombo.ItemsSource = @($openRouterProvider); $ProviderCombo.SelectedItem = $openRouterProvider
    $ModelCombo.ItemsSource = @($oxModel); $ModelCombo.SelectedItem = $oxModel
    Update-DynamicDesktopRouteControls
    if ([string]$script:DynamicDesktopRouteButton.Content -ne "切换桌面 Chat → Ox Alpha（实验）") {
        throw "OX selection did not update Desktop route button: $($script:DynamicDesktopRouteButton.Content)"
    }

    $mimoProvider = [pscustomobject]@{ id="mimo"; label="Xiaomi MiMo" }
    $mimoModel = [pscustomobject]@{ id="mimo-v2.5-pro"; label="MiMo V2.5 Pro" }
    $ProviderCombo.ItemsSource = @($mimoProvider); $ProviderCombo.SelectedItem = $mimoProvider
    $ModelCombo.ItemsSource = @($mimoModel); $ModelCombo.SelectedItem = $mimoModel
    Update-DynamicDesktopRouteControls
    if ([string]$script:DynamicDesktopRouteButton.Content -ne "切换桌面 Chat → MiMo V2.5 Pro") {
        throw "MiMo selection did not update Desktop route button: $($script:DynamicDesktopRouteButton.Content)"
    }

    $chatgptProvider = [pscustomobject]@{ id="chatgpt"; label="OpenAI / ChatGPT" }
    $chatgptModel = [pscustomobject]@{ id="__account_default__"; label="官方默认（按账号实际可用模型）" }
    $ProviderCombo.ItemsSource = @($chatgptProvider); $ProviderCombo.SelectedItem = $chatgptProvider
    $ModelCombo.ItemsSource = @($chatgptModel); $ModelCombo.SelectedItem = $chatgptModel
    Update-DynamicDesktopRouteControls
    if ([string]$script:DynamicDesktopRouteButton.Content -ne "桌面 Chat 已是 ChatGPT") {
        throw "ChatGPT default selection label mismatch: $($script:DynamicDesktopRouteButton.Content)"
    }
    if ($script:DynamicDesktopRouteButton.IsEnabled) { throw "ChatGPT target button should be disabled when no custom route is active." }
    if ([string]$desktopRouteText.Text -ne "当前桌面 Chat：ChatGPT / OpenAI 默认路由") { throw "Default Desktop route status text mismatch." }

    Write-Host "Dynamic Desktop route button selection PASS" -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
