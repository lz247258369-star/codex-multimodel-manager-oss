$ErrorActionPreference = "Stop"

# Compatibility entrypoint for PowerShell 7.x.
#
# PowerShell can throw `Argument types do not match` when an object created as
# System.Collections.Generic.List[object] is wrapped with @($list). The V4 UI's
# model-card collector originally used that exact shape. Until the implementation
# is simplified to a native PowerShell array, the supported launchers normalize
# the known expression in memory before executing the repository-controlled UI.
#
# Opening the console itself does not modify repositories, Codex config, project
# files, Git state, or provider credentials. Desktop route changes happen only
# after an explicit button click and confirmation in the UI.

$sourcePath = Join-Path $PSScriptRoot "visual-console.ps1"
$hierarchyRuntimePath = Join-Path $PSScriptRoot "visual-hierarchy-runtime.ps1"
$comboDisplayRuntimePath = Join-Path $PSScriptRoot "visual-combo-display-runtime.ps1"
$commercialEffectsPath = Join-Path $PSScriptRoot "visual-commercial-effects.ps1"
$routerRuntimePath = Join-Path $PSScriptRoot "visual-router-runtime.ps1"
$appIdentityRuntimePath = Join-Path $PSScriptRoot "windows-app-identity.ps1"
if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Visual Console source not found: $sourcePath"
}
if (-not (Test-Path -LiteralPath $hierarchyRuntimePath)) {
    throw "Visual hierarchy runtime not found: $hierarchyRuntimePath"
}
if (-not (Test-Path -LiteralPath $comboDisplayRuntimePath)) {
    throw "Visual combo display runtime not found: $comboDisplayRuntimePath"
}
if (-not (Test-Path -LiteralPath $commercialEffectsPath)) {
    throw "Visual commercial effects runtime not found: $commercialEffectsPath"
}
if (-not (Test-Path -LiteralPath $routerRuntimePath)) {
    throw "Visual Router runtime not found: $routerRuntimePath"
}
if (-not (Test-Path -LiteralPath $appIdentityRuntimePath)) {
    throw "Windows app identity runtime not found: $appIdentityRuntimePath"
}

$sourceText = Get-Content -Raw -LiteralPath $sourcePath
$legacyExpression = '$script:modelCards = @($cards)'
$safeExpression = '$script:modelCards = $cards.ToArray()'

if ($sourceText.Contains($legacyExpression)) {
    $sourceText = $sourceText.Replace($legacyExpression, $safeExpression)
}

# Runtime-only usability + Desktop route integration for the existing V4 source.
# The source repository remains clean; the Desktop route tool changes only the
# user's ~/.codex configuration after explicit confirmation.
$uiUsabilityAnchor = '$script:loadingRoute = $false'
$uiUsabilityPatch = @'
$script:loadingRoute = $false

# CLI workspace selector: keep it visually consistent with the dark console,
# increase path readability, and make the scope explicit so users do not mistake
# it for the Codex Desktop project selector.
$WorkspaceCombo.Height = 38
$WorkspaceCombo.FontSize = 13
$WorkspaceCombo.FontWeight = [System.Windows.FontWeights]::SemiBold
$WorkspaceCombo.VerticalContentAlignment = [System.Windows.VerticalAlignment]::Center
$WorkspaceCombo.Padding = [System.Windows.Thickness]::new(12,4,10,4)
$WorkspaceCombo.Foreground = Get-ColorBrush "#F4F7FF"
$WorkspaceCombo.Background = Get-ColorBrush "#0B1221"
$WorkspaceCombo.BorderBrush = Get-ColorBrush "#40598A"
$WorkspaceCombo.BorderThickness = [System.Windows.Thickness]::new(1)
$BrowseButton.Content = "选择 CLI 目录"
$TopPageSubTitle.Text = "选择模型与 Provider；仅在启动 CLI 会话时指定工作目录"

$workspaceStack = $WorkspaceCombo.Parent
if ($workspaceStack -is [System.Windows.Controls.StackPanel] -and $workspaceStack.Children.Count -gt 0) {
    $workspaceHeaderGrid = $workspaceStack.Children[0]
    if ($workspaceHeaderGrid -is [System.Windows.Controls.Grid] -and $workspaceHeaderGrid.Children.Count -gt 0) {
        $workspaceHeaderText = $workspaceHeaderGrid.Children[0]
        if ($workspaceHeaderText -is [System.Windows.Controls.StackPanel] -and $workspaceHeaderText.Children.Count -ge 2) {
            $workspaceTitle = $workspaceHeaderText.Children[0]
            $workspaceSubtitle = $workspaceHeaderText.Children[1]
            if ($workspaceTitle -is [System.Windows.Controls.TextBlock]) {
                $workspaceTitle.Text = "CLI 工作目录"
                $workspaceTitle.FontSize = 15
            }
            if ($workspaceSubtitle -is [System.Windows.Controls.TextBlock]) {
                $workspaceSubtitle.Text = "仅用于启动新 Codex 会话（CLI）；不会切换 Codex Desktop 左侧项目。"
                $workspaceSubtitle.FontSize = 11
                $workspaceSubtitle.Foreground = Get-ColorBrush "#8FA0BC"
            }
        }
    }
}

$WorkspaceCombo.Add_Loaded({
    $editablePathBox = $WorkspaceCombo.Template.FindName("PART_EditableTextBox", $WorkspaceCombo)
    if ($null -ne $editablePathBox) {
        $editablePathBox.Foreground = Get-ColorBrush "#F4F7FF"
        $editablePathBox.Background = Get-ColorBrush "#0B1221"
        $editablePathBox.FontSize = 13
        $editablePathBox.FontWeight = [System.Windows.FontWeights]::SemiBold
        $editablePathBox.CaretBrush = Get-ColorBrush "#FFFFFF"
        $editablePathBox.SelectionBrush = Get-ColorBrush "#40598A"
        $editablePathBox.VerticalContentAlignment = [System.Windows.VerticalAlignment]::Center
    }
})
$WorkspaceCombo.Add_DropDownOpened({
    foreach ($workspaceItem in @($WorkspaceCombo.Items)) {
        $workspaceContainer = $WorkspaceCombo.ItemContainerGenerator.ContainerFromItem($workspaceItem)
        if ($null -ne $workspaceContainer) {
            $workspaceContainer.Foreground = Get-ColorBrush "#F4F7FF"
            $workspaceContainer.Background = Get-ColorBrush "#111B31"
            $workspaceContainer.FontSize = 12
        }
    }
})

function Register-ListWheelForwarding($ListBox) {
    if ($null -eq $ListBox) { return }
    $ListBox.Add_PreviewMouseWheel({
        param($sender, $eventArgs)

        $parentViewer = [System.Windows.Media.VisualTreeHelper]::GetParent($sender)
        while ($null -ne $parentViewer -and -not ($parentViewer -is [System.Windows.Controls.ScrollViewer])) {
            $parentViewer = [System.Windows.Media.VisualTreeHelper]::GetParent($parentViewer)
        }

        if ($null -eq $parentViewer -or $parentViewer.ScrollableHeight -le 0) { return }

        $scrollStep = [Math]::Max(60.0, [Math]::Abs([double]$eventArgs.Delta) * 0.65)
        if ($eventArgs.Delta -gt 0) {
            $targetOffset = [double]$parentViewer.VerticalOffset - $scrollStep
        }
        else {
            $targetOffset = [double]$parentViewer.VerticalOffset + $scrollStep
        }

        $targetOffset = [Math]::Max(0.0, [Math]::Min([double]$parentViewer.ScrollableHeight, $targetOffset))
        $parentViewer.ScrollToVerticalOffset($targetOffset)
        $eventArgs.Handled = $true
    })
}

Register-ListWheelForwarding $DashboardModelList
Register-ListWheelForwarding $ModelsModelList

# Desktop Chat route controls. These sit next to the existing CLI launch controls
# so "启动 Codex CLI 会话" and "切换 Codex Desktop Chat" remain distinct actions.
$desktopRouteScript = Join-Path $PSScriptRoot "desktop-chat-provider.ps1"
$desktopRouteStatePath = Join-Path (Get-ManagerHome) "desktop-route-state.json"
$heroActionPanel = $LaunchCurrentButton.Parent

$desktopRouteText = New-Object System.Windows.Controls.TextBlock
$desktopRouteText.FontSize = 10
$desktopRouteText.Margin = [System.Windows.Thickness]::new(2,10,2,2)
$desktopRouteText.TextWrapping = [System.Windows.TextWrapping]::Wrap

$desktopOxButton = New-Object System.Windows.Controls.Button
$desktopOxButton.Content = "切换桌面 Chat → OX"
$desktopOxButton.Style = $window.FindResource("SoftButton")
$desktopOxButton.Margin = [System.Windows.Thickness]::new(0,9,0,0)

$desktopRestoreButton = New-Object System.Windows.Controls.Button
$desktopRestoreButton.Content = "恢复桌面 ChatGPT"
$desktopRestoreButton.Style = $window.FindResource("SoftButton")
$desktopRestoreButton.Margin = [System.Windows.Thickness]::new(0,7,0,0)

function Refresh-DesktopRouteUI {
    $active = $false
    $routeModel = ""
    $routeProvider = ""
    if (Test-Path -LiteralPath $desktopRouteStatePath) {
        try {
            $routeState = Get-Content -Raw -LiteralPath $desktopRouteStatePath | ConvertFrom-Json
            if ($routeState.PSObject.Properties["active"]) { $active = [bool]$routeState.active }
            if ($routeState.PSObject.Properties["model"]) { $routeModel = [string]$routeState.model }
            if ($routeState.PSObject.Properties["provider"]) { $routeProvider = [string]$routeState.provider }
        }
        catch {
            $active = $false
        }
    }

    if ($active) {
        $desktopRouteText.Text = "Desktop Chat：OX ACTIVE · $routeModel → $routeProvider"
        $desktopRouteText.Foreground = Get-ColorBrush "#B6A9FF"
        $desktopRestoreButton.IsEnabled = $true
    }
    else {
        $desktopRouteText.Text = "Desktop Chat：ChatGPT / OpenAI 默认路由"
        $desktopRouteText.Foreground = Get-ColorBrush "#7C8BA5"
        $desktopRestoreButton.IsEnabled = (Test-Path -LiteralPath $desktopRouteStatePath)
    }
}

$desktopOxButton.Add_Click({
    $selectedProvider = $ProviderCombo.SelectedItem
    $selectedModel = $ModelCombo.SelectedItem
    if ($null -eq $selectedProvider -or $null -eq $selectedModel -or
        [string]$selectedProvider.id -ne "openrouter" -or [string]$selectedModel.id -ne "stealth/ox-alpha") {
        [System.Windows.MessageBox]::Show(
            "请先选择 Stealth / Unknown → Ox Alpha → Experimental，然后再切换桌面 Chat。",
            "Desktop Chat 模型选择",
            "OK",
            "Information"
        ) | Out-Null
        return
    }

    if (-not (Test-Path -LiteralPath $desktopRouteScript)) {
        [System.Windows.MessageBox]::Show("缺少 Desktop route 脚本：`n$desktopRouteScript", "Codex Multi-Model Manager", "OK", "Error") | Out-Null
        return
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "将 Codex Desktop Chat 的默认后台路由切换到 Ox Alpha / OpenRouter。`n`n系统会保留原 ChatGPT 配置用于一键恢复。`n切换后需要彻底退出 Codex Desktop、重新打开，并新建会话。`n`n继续？",
        "切换 Desktop Chat → Ox Alpha",
        "YesNo",
        "Warning"
    )
    if ($confirm -ne "Yes") { return }

    try {
        & $desktopRouteScript -Mode activate-ox -ConfirmationCode "OX"
        Refresh-DesktopRouteUI
        [System.Windows.MessageBox]::Show(
            "Desktop Chat 路由已准备为 Ox Alpha。`n`n请彻底退出 Codex Desktop，重新打开后新建一个对话。`n官方模型下拉框可能仍只显示 OpenAI 型号；成功时底部路由会显示为自定义 / OpenRouter。",
            "OX Desktop 已配置",
            "OK",
            "Information"
        ) | Out-Null
    }
    catch {
        [System.Windows.MessageBox]::Show("Desktop Chat 切换失败：`n$($_.Exception.Message)", "切换失败", "OK", "Error") | Out-Null
    }
})

$desktopRestoreButton.Add_Click({
    if (-not (Test-Path -LiteralPath $desktopRouteScript)) {
        [System.Windows.MessageBox]::Show("缺少 Desktop route 脚本：`n$desktopRouteScript", "Codex Multi-Model Manager", "OK", "Error") | Out-Null
        return
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "恢复切换 OX 前保存的 Codex Desktop / ChatGPT 配置？`n`n恢复后需要彻底退出 Codex Desktop、重新打开，并新建会话。",
        "恢复 Desktop ChatGPT",
        "YesNo",
        "Question"
    )
    if ($confirm -ne "Yes") { return }

    try {
        & $desktopRouteScript -Mode restore
        Refresh-DesktopRouteUI
        [System.Windows.MessageBox]::Show(
            "Desktop ChatGPT 配置已恢复。`n`n请彻底退出 Codex Desktop，重新打开后新建一个对话。",
            "ChatGPT Desktop 已恢复",
            "OK",
            "Information"
        ) | Out-Null
    }
    catch {
        [System.Windows.MessageBox]::Show("Desktop ChatGPT 恢复失败：`n$($_.Exception.Message)", "恢复失败", "OK", "Error") | Out-Null
    }
})

if ($heroActionPanel -is [System.Windows.Controls.Panel]) {
    $heroActionPanel.Children.Add($desktopOxButton) | Out-Null
    $heroActionPanel.Children.Add($desktopRestoreButton) | Out-Null
    $heroActionPanel.Children.Add($desktopRouteText) | Out-Null
}

Refresh-DesktopRouteUI
'@

# visual-console.ps1 contains this anchor more than once. Replace only the first
# occurrence; replacing all occurrences duplicates the Desktop route controls.
$uiAnchorIndex = $sourceText.IndexOf($uiUsabilityAnchor, [System.StringComparison]::Ordinal)
if ($uiAnchorIndex -ge 0) {
    $sourceText = $sourceText.Substring(0, $uiAnchorIndex) +
        $uiUsabilityPatch +
        $sourceText.Substring($uiAnchorIndex + $uiUsabilityAnchor.Length)
}

# Load the hierarchy, selected-value display adapter, commercial visual runtime,
# and the Windows app-identity runtime after the WPF Window object exists but
# before it is shown. SourceInitialized is the first point where the real HWND is
# available, so the explicit window AppUserModelID can override pwsh.exe grouping.
$hierarchyAnchor = '$initialWorkspace = Resolve-InitialWorkspace'
$hierarchyInjection = @'
. (Join-Path $PSScriptRoot "visual-hierarchy-runtime.ps1")
. (Join-Path $PSScriptRoot "visual-combo-display-runtime.ps1")
. (Join-Path $PSScriptRoot "visual-commercial-effects.ps1")
. (Join-Path $PSScriptRoot "visual-router-runtime.ps1")
. (Join-Path $PSScriptRoot "windows-app-identity.ps1")

$window.Add_SourceInitialized({
    try {
        $windowHandle = ([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle
        if ($windowHandle -ne [IntPtr]::Zero) {
            Set-ManagerWindowAppIdentity -WindowHandle $windowHandle
        }
    }
    catch {
        # Taskbar identity is shell metadata only. Never block V4 startup.
    }
})

$initialWorkspace = Resolve-InitialWorkspace
'@
$hierarchyIndex = $sourceText.IndexOf($hierarchyAnchor, [System.StringComparison]::Ordinal)
if ($hierarchyIndex -lt 0) {
    throw "Visual Console hierarchy injection anchor not found."
}
$sourceText = $sourceText.Substring(0, $hierarchyIndex) +
    $hierarchyInjection +
    $sourceText.Substring($hierarchyIndex + $hierarchyAnchor.Length)

# ScriptBlock.Create has no file-backed PSScriptRoot of its own. Replace the
# source token with a single-quoted literal for the real scripts directory.
# Doubling apostrophes keeps the literal safe even if a parent folder contains one.
$escapedRoot = $PSScriptRoot.Replace("'", "''")
$rootLiteral = "'" + $escapedRoot + "'"
$sourceText = $sourceText.Replace('$PSScriptRoot', $rootLiteral)
$runtimeBlock = [ScriptBlock]::Create($sourceText)

& $runtimeBlock
