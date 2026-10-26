# PowerShell scope bridge for the dynamic Desktop route runtime.
# visual-combo-display-runtime.ps1 already defined OX-only local helpers before
# the dynamic runtime loaded. Re-declare them in the same dot-sourced runtime
# scope so existing handlers resolve the generic route behavior below.
#
# IMPORTANT: Desktop Chat route state is display/config state only. It must never
# overwrite the Manager's pending Provider / Brand / Model / Effort selection.
# The Manager selection controls what the Codex CLI launch action uses; Desktop
# Chat routing is a separate action and status surface.

function Get-DesktopRouteIsOxActive {
    $state = Get-DynamicDesktopRouteState
    return (Test-DynamicDesktopRouteActive $state -and [string]$state.model -eq "stealth/ox-alpha" -and [string]$state.provider -eq "mm_openrouter")
}

function Update-DesktopRouteClarity {
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

# Make the two launch surfaces explicit: these start Codex CLI, not a Codex
# Desktop Chat thread. This avoids confusing a fallback shell with Desktop Chat.
if ($null -ne $LaunchCurrentButton) {
    $LaunchCurrentButton.Content = "▶ 启动 Codex CLI"
}
if ($null -ne $ModelsLaunchButton) {
    $ModelsLaunchButton.Content = "启动 Codex CLI"
}

# Compatibility name retained because pre-existing Loaded/click handlers call it.
# It now refreshes only Desktop route status and controls; Manager selectors are
# intentionally left untouched.
function Sync-ManagerSelectionToDesktopRoute {
    Update-DesktopRouteClarity
    Update-DynamicDesktopRouteControls
}
