# Dynamic Codex Desktop route controls for V4.
# Replaces the legacy OX-only button injected by visual-console-entry.ps1.
# Button position stays stable; its target follows the Manager's selected model.

if (-not $script:dynamicDesktopRouteInstalled) {
    $script:dynamicDesktopRouteInstalled = $true

    $script:dynamicDesktopRouteScript = Join-Path $PSScriptRoot "desktop-chat-route.ps1"

    function Get-DynamicDesktopRouteState {
        if ([string]::IsNullOrWhiteSpace([string]$desktopRouteStatePath) -or -not (Test-Path -LiteralPath $desktopRouteStatePath)) { return $null }
        try { return (Get-Content -Raw -LiteralPath $desktopRouteStatePath | ConvertFrom-Json) }
        catch { return $null }
    }

    function Test-DynamicDesktopRouteActive($State) {
        return ($null -ne $State -and $State.PSObject.Properties["active"] -and [bool]$State.active)
    }

    function Get-DynamicDesktopRouteTarget {
        $provider = $ProviderCombo.SelectedItem
        $model = $ModelCombo.SelectedItem
        if ($null -eq $provider -or $null -eq $model) {
            return [pscustomobject]@{ Supported=$false; IsDefault=$false; ProviderId=""; CodexProvider=""; ModelId=""; Label="未选择模型"; ProviderLabel="" }
        }

        $providerId = [string]$provider.id
        $modelId = [string]$model.id
        $modelLabel = if ($model.PSObject.Properties["label"] -and -not [string]::IsNullOrWhiteSpace([string]$model.label)) { [string]$model.label } else { $modelId }
        $providerLabel = if ($provider.PSObject.Properties["label"]) { [string]$provider.label } else { $providerId }

        switch ($providerId) {
            "chatgpt" {
                return [pscustomobject]@{ Supported=$true; IsDefault=$true; ProviderId=$providerId; CodexProvider="openai"; ModelId=$modelId; Label="ChatGPT"; ProviderLabel=$providerLabel }
            }
            "modelstudio" {
                return [pscustomobject]@{ Supported=$true; IsDefault=$false; ProviderId=$providerId; CodexProvider="mm_modelstudio"; ModelId=$modelId; Label=$modelLabel; ProviderLabel=$providerLabel }
            }
            "openrouter" {
                return [pscustomobject]@{ Supported=$true; IsDefault=$false; ProviderId=$providerId; CodexProvider="mm_openrouter"; ModelId=$modelId; Label=$modelLabel; ProviderLabel=$providerLabel }
            }
            "mimo" {
                return [pscustomobject]@{ Supported=$true; IsDefault=$false; ProviderId=$providerId; CodexProvider="mm_mimo"; ModelId=$modelId; Label=$modelLabel; ProviderLabel=$providerLabel }
            }
            default {
                return [pscustomobject]@{ Supported=$false; IsDefault=$false; ProviderId=$providerId; CodexProvider=""; ModelId=$modelId; Label=$modelLabel; ProviderLabel=$providerLabel }
            }
        }
    }

    function Get-DynamicDesktopRouteLabel($State) {
        if ($null -eq $State) { return "" }
        if ($State.PSObject.Properties["label"] -and -not [string]::IsNullOrWhiteSpace([string]$State.label)) { return [string]$State.label }
        if ($State.PSObject.Properties["model"] -and [string]$State.model -eq "stealth/ox-alpha") { return "Ox Alpha" }
        if ($State.PSObject.Properties["model"]) { return [string]$State.model }
        return "自定义模型"
    }

    function Get-DynamicSourceProviderId($State) {
        if ($null -eq $State) { return "" }
        if ($State.PSObject.Properties["source_provider"] -and -not [string]::IsNullOrWhiteSpace([string]$State.source_provider)) { return [string]$State.source_provider }
        if ($State.PSObject.Properties["provider"]) {
            switch ([string]$State.provider) {
                "mm_modelstudio" { return "modelstudio" }
                "mm_openrouter" { return "openrouter" }
                "mm_mimo" { return "mimo" }
            }
        }
        return ""
    }

    # Override the legacy OX-only clarity helpers. The existing Loaded handler in
    # visual-combo-display-runtime resolves these functions at execution time, so
    # it automatically uses the generic route state after this runtime loads.
    function global:Get-DesktopRouteIsOxActive {
        $state = Get-DynamicDesktopRouteState
        return (Test-DynamicDesktopRouteActive $state -and [string]$state.model -eq "stealth/ox-alpha" -and [string]$state.provider -eq "mm_openrouter")
    }

    function global:Update-DesktopRouteClarity {
        if ($null -eq $desktopRouteText) { return }
        $state = Get-DynamicDesktopRouteState
        $desktopRouteText.FontSize = 11
        $desktopRouteText.FontWeight = [System.Windows.FontWeights]::SemiBold
        if (Test-DynamicDesktopRouteActive $state) {
            $label = Get-DynamicDesktopRouteLabel $state
            $model = if ($state.PSObject.Properties["model"]) { [string]$state.model } else { "" }
            $provider = if ($state.PSObject.Properties["provider"]) { [string]$state.provider } else { "" }
            $desktopRouteText.Text = "当前桌面 Chat：$label · $model → $provider"
            $desktopRouteText.Foreground = Get-ColorBrush "#C5BAFF"
        }
        else {
            $desktopRouteText.Text = "当前桌面 Chat：ChatGPT / OpenAI 默认路由"
            $desktopRouteText.Foreground = Get-ColorBrush "#A7B5CB"
        }
    }

    function global:Sync-ManagerSelectionToDesktopRoute {
        if ($null -eq $script:catalog) { return }
        $state = Get-DynamicDesktopRouteState
        if (Test-DynamicDesktopRouteActive $state) {
            $providerId = Get-DynamicSourceProviderId $state
            $modelId = if ($state.PSObject.Properties["model"]) { [string]$state.model } else { "" }
            if (-not [string]::IsNullOrWhiteSpace($providerId) -and -not [string]::IsNullOrWhiteSpace($modelId)) {
                $provider = Get-ProviderById $providerId
                $model = if ($null -ne $provider) { @($provider.models | Where-Object { [string]$_.id -eq $modelId }) | Select-Object -First 1 } else { $null }
                if ($null -ne $provider -and $null -ne $model) {
                    Refresh-ProviderSelection -PreferredProvider $providerId -PreferredBrand (Get-ModelBrand $model) -PreferredModel $modelId
                }
            }
        }
        else {
            Refresh-ProviderSelection -PreferredProvider "chatgpt" -PreferredBrand "OpenAI" -PreferredModel "__account_default__"
        }
        Update-DesktopRouteClarity
        Update-DynamicDesktopRouteControls
    }

    function Update-DynamicDesktopRouteControls {
        if ($null -eq $script:DynamicDesktopRouteButton -or $null -eq $script:DynamicDesktopRestoreButton) { return }
        $target = Get-DynamicDesktopRouteTarget
        $state = Get-DynamicDesktopRouteState
        $active = Test-DynamicDesktopRouteActive $state

        if (-not $target.Supported) {
            $script:DynamicDesktopRouteButton.Content = "当前模型暂不支持桌面 Chat"
            $script:DynamicDesktopRouteButton.IsEnabled = $false
        }
        elseif ($target.IsDefault) {
            if ($active) {
                $script:DynamicDesktopRouteButton.Content = "切换桌面 Chat → ChatGPT"
                $script:DynamicDesktopRouteButton.IsEnabled = $true
            }
            else {
                $script:DynamicDesktopRouteButton.Content = "桌面 Chat 已是 ChatGPT"
                $script:DynamicDesktopRouteButton.IsEnabled = $false
            }
        }
        else {
            $sameRoute = ($active -and [string]$state.model -eq [string]$target.ModelId -and [string]$state.provider -eq [string]$target.CodexProvider)
            if ($sameRoute) {
                $script:DynamicDesktopRouteButton.Content = "桌面 Chat 已是 → $($target.Label)"
                $script:DynamicDesktopRouteButton.IsEnabled = $false
            }
            else {
                $script:DynamicDesktopRouteButton.Content = "切换桌面 Chat → $($target.Label)"
                $script:DynamicDesktopRouteButton.IsEnabled = $true
            }
        }

        $script:DynamicDesktopRestoreButton.IsEnabled = $active
        Update-DesktopRouteClarity
    }

    function Invoke-DynamicDesktopRestore {
        if (-not (Test-Path -LiteralPath $script:dynamicDesktopRouteScript)) {
            [System.Windows.MessageBox]::Show("缺少通用 Desktop route 脚本：`n$($script:dynamicDesktopRouteScript)", "Codex Multi-Model Manager", "OK", "Error") | Out-Null
            return $false
        }
        try {
            & $script:dynamicDesktopRouteScript -Mode restore
            Sync-ManagerSelectionToDesktopRoute
            return $true
        }
        catch {
            [System.Windows.MessageBox]::Show("Desktop ChatGPT 恢复失败：`n$($_.Exception.Message)", "恢复失败", "OK", "Error") | Out-Null
            Update-DynamicDesktopRouteControls
            return $false
        }
    }

    function Invoke-DynamicDesktopTarget {
        $target = Get-DynamicDesktopRouteTarget
        if (-not $target.Supported) { return }
        $state = Get-DynamicDesktopRouteState
        $active = Test-DynamicDesktopRouteActive $state

        if ($target.IsDefault) {
            if (-not $active) { return }
            $confirm = [System.Windows.MessageBox]::Show(
                "恢复 Codex Desktop / ChatGPT 官方默认路由？`n`n恢复后请彻底退出 Codex Desktop、重新打开，并新建会话。",
                "切换 Desktop Chat → ChatGPT",
                "YesNo",
                "Question"
            )
            if ($confirm -ne "Yes") { return }
            if (Invoke-DynamicDesktopRestore) {
                [System.Windows.MessageBox]::Show("Desktop ChatGPT 配置已恢复。`n`n请彻底退出 Codex Desktop，重新打开后新建一个对话。", "ChatGPT Desktop 已恢复", "OK", "Information") | Out-Null
            }
            return
        }

        $warning = if ([string]$target.ModelId -eq "stealth/ox-alpha") {
            "`n`n注意：Ox Alpha 是匿名实验模型。"
        }
        else { "" }
        $confirm = [System.Windows.MessageBox]::Show(
            "将 Codex Desktop Chat 的后台路由切换到：$($target.Label)`nProvider：$($target.ProviderLabel)$warning`n`n系统会保留原 ChatGPT 配置用于恢复。`n切换后请彻底退出 Codex Desktop、重新打开，并新建会话。`n`n继续？",
            "切换 Desktop Chat → $($target.Label)",
            "YesNo",
            "Warning"
        )
        if ($confirm -ne "Yes") { return }
        if (-not (Test-Path -LiteralPath $script:dynamicDesktopRouteScript)) {
            [System.Windows.MessageBox]::Show("缺少通用 Desktop route 脚本：`n$($script:dynamicDesktopRouteScript)", "Codex Multi-Model Manager", "OK", "Error") | Out-Null
            return
        }

        $effort = if ($null -ne $EffortCombo -and $null -ne $EffortCombo.SelectedItem) { [string]$EffortCombo.SelectedItem } else { "high" }
        if ($effort -notin @("low","medium","high","xhigh")) { $effort = "high" }
        $confirmationCode = if ([string]$target.ModelId -eq "stealth/ox-alpha") { "OX" } else { "" }
        try {
            & $script:dynamicDesktopRouteScript -Mode activate -ProviderId ([string]$target.ProviderId) -ModelId ([string]$target.ModelId) -Label ([string]$target.Label) -Effort $effort -ConfirmationCode $confirmationCode
            Update-DynamicDesktopRouteControls
            [System.Windows.MessageBox]::Show(
                "Desktop Chat 路由已准备为 $($target.Label)。`n`n请彻底退出 Codex Desktop，重新打开后新建一个对话。`n官方模型下拉框可能仍不会显示第三方型号；成功时 Desktop 会显示自定义 Provider/Model 路由。",
                "Desktop Chat 已配置",
                "OK",
                "Information"
            ) | Out-Null
        }
        catch {
            [System.Windows.MessageBox]::Show("Desktop Chat 切换失败：`n$($_.Exception.Message)", "切换失败", "OK", "Error") | Out-Null
            Update-DynamicDesktopRouteControls
        }
    }

    # Remove the legacy OX-only controls from the visual tree. Their event handlers
    # remain attached only to the detached objects and therefore cannot fire.
    $panel = $heroActionPanel
    if ($null -eq $panel -and $null -ne $desktopOxButton) { $panel = $desktopOxButton.Parent }
    if ($panel -is [System.Windows.Controls.Panel]) {
        $insertAt = $panel.Children.Count
        if ($null -ne $desktopOxButton) {
            $oldIndex = $panel.Children.IndexOf($desktopOxButton)
            if ($oldIndex -ge 0) { $insertAt = $oldIndex }
        }
        foreach ($old in @($desktopOxButton,$desktopRestoreButton,$desktopRouteText)) {
            if ($null -ne $old -and $panel.Children.Contains($old)) { [void]$panel.Children.Remove($old) }
        }

        $script:DynamicDesktopRouteButton = New-Object System.Windows.Controls.Button
        $script:DynamicDesktopRouteButton.Style = $window.FindResource("SoftButton")
        $script:DynamicDesktopRouteButton.Margin = [System.Windows.Thickness]::new(0,9,0,0)

        $script:DynamicDesktopRestoreButton = New-Object System.Windows.Controls.Button
        $script:DynamicDesktopRestoreButton.Content = "恢复桌面 ChatGPT"
        $script:DynamicDesktopRestoreButton.Style = $window.FindResource("SoftButton")
        $script:DynamicDesktopRestoreButton.Margin = [System.Windows.Thickness]::new(0,7,0,0)

        $desktopRouteText = New-Object System.Windows.Controls.TextBlock
        $desktopRouteText.FontSize = 11
        $desktopRouteText.FontWeight = [System.Windows.FontWeights]::SemiBold
        $desktopRouteText.Margin = [System.Windows.Thickness]::new(2,10,2,2)
        $desktopRouteText.TextWrapping = [System.Windows.TextWrapping]::Wrap

        $panel.Children.Insert($insertAt,$script:DynamicDesktopRouteButton)
        $panel.Children.Insert($insertAt + 1,$script:DynamicDesktopRestoreButton)
        $panel.Children.Insert($insertAt + 2,$desktopRouteText)

        $script:DynamicDesktopRouteButton.Add_Click({ Invoke-DynamicDesktopTarget })
        $script:DynamicDesktopRestoreButton.Add_Click({
            $state = Get-DynamicDesktopRouteState
            if (-not (Test-DynamicDesktopRouteActive $state)) { return }
            $confirm = [System.Windows.MessageBox]::Show(
                "恢复原 Codex Desktop / ChatGPT 配置？`n`n恢复后请彻底退出 Codex Desktop、重新打开，并新建会话。",
                "恢复 Desktop ChatGPT",
                "YesNo",
                "Question"
            )
            if ($confirm -ne "Yes") { return }
            if (Invoke-DynamicDesktopRestore) {
                [System.Windows.MessageBox]::Show("Desktop ChatGPT 配置已恢复。", "ChatGPT Desktop 已恢复", "OK", "Information") | Out-Null
            }
        })

        foreach ($combo in @($ProviderCombo,$ModelCombo,$EffortCombo)) {
            if ($null -ne $combo) {
                $combo.Add_SelectionChanged({ Update-DynamicDesktopRouteControls })
            }
        }

        Update-DynamicDesktopRouteControls
    }
}
