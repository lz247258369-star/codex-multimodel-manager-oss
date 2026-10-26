# Selected-value display helpers for the V4 dark ComboBox template.
#
# The hierarchy/runtime selectors use PSCustomObject items for variants,
# performance choices, and sort modes. A fully custom ComboBox template cannot
# rely on Windows' default DisplayMemberPath rendering for the selection box, so
# these object-backed combos get explicit ItemTemplates. String-backed combos
# (vendor, family, workspace) remain unchanged.

function New-ComboTextTemplate([string]$BindingPath) {
    if ([string]::IsNullOrWhiteSpace($BindingPath)) { return $null }
    $safePath = [System.Security.SecurityElement]::Escape($BindingPath)
    $xaml = @"
<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <TextBlock Text="{Binding $safePath}" Foreground="#F2F6FF" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
</DataTemplate>
"@
    return [Windows.Markup.XamlReader]::Parse($xaml)
}

$variantDisplayTemplate = New-ComboTextTemplate "Display"
$labelDisplayTemplate = New-ComboTextTemplate "Label"

if ($null -ne $VariantCombo) {
    $VariantCombo.DisplayMemberPath = ""
    $VariantCombo.ItemTemplate = $variantDisplayTemplate
}
if ($null -ne $PerformanceCombo) {
    $PerformanceCombo.DisplayMemberPath = ""
    $PerformanceCombo.ItemTemplate = $labelDisplayTemplate
}
if ($null -ne $DashboardSortCombo) {
    $DashboardSortCombo.DisplayMemberPath = ""
    $DashboardSortCombo.ItemTemplate = $labelDisplayTemplate
}
if ($null -ne $ModelsSortCombo) {
    $ModelsSortCombo.DisplayMemberPath = ""
    $ModelsSortCombo.ItemTemplate = $labelDisplayTemplate
}

# Keep the hero semantics explicit. The hero is the Manager model that would be
# used by the launch action; Desktop Chat route state is shown separately below
# the Desktop route buttons. Route actions synchronize this selection once so a
# completed restore cannot leave an Ox Alpha hero above a ChatGPT route status.
if ($null -ne $HeroModelName -and $HeroModelName.Parent -is [System.Windows.Controls.StackPanel]) {
    $heroStack = $HeroModelName.Parent
    if ($heroStack.Children.Count -gt 0 -and $heroStack.Children[0] -is [System.Windows.Controls.TextBlock]) {
        $heroStack.Children[0].Text = "Manager 待启动模型"
        $heroStack.Children[0].Foreground = Get-ColorBrush "#9BAAC3"
    }
}

function Get-DesktopRouteIsOxActive {
    if ([string]::IsNullOrWhiteSpace([string]$desktopRouteStatePath) -or
        -not (Test-Path -LiteralPath $desktopRouteStatePath)) {
        return $false
    }

    try {
        $routeState = Get-Content -Raw -LiteralPath $desktopRouteStatePath | ConvertFrom-Json
        if (-not $routeState.PSObject.Properties["active"] -or -not [bool]$routeState.active) {
            return $false
        }

        $routeModel = if ($routeState.PSObject.Properties["model"]) { [string]$routeState.model } else { "" }
        $routeProvider = if ($routeState.PSObject.Properties["provider"]) { [string]$routeState.provider } else { "" }
        return ($routeModel -eq "stealth/ox-alpha" -and $routeProvider -eq "mm_openrouter")
    }
    catch {
        return $false
    }
}

function Update-DesktopRouteClarity {
    if ($null -eq $desktopRouteText) { return }

    $desktopRouteText.FontSize = 11
    $desktopRouteText.FontWeight = [System.Windows.FontWeights]::SemiBold
    if (Get-DesktopRouteIsOxActive) {
        $desktopRouteText.Text = "当前桌面 Chat：OX / OpenRouter ACTIVE · stealth/ox-alpha"
        $desktopRouteText.Foreground = Get-ColorBrush "#C5BAFF"
    }
    else {
        $desktopRouteText.Text = "当前桌面 Chat：ChatGPT / OpenAI 默认路由"
        $desktopRouteText.Foreground = Get-ColorBrush "#A7B5CB"
    }
}

function Sync-ManagerSelectionToDesktopRoute {
    if ($null -eq $script:catalog) { return }

    if (Get-DesktopRouteIsOxActive) {
        Refresh-ProviderSelection `
            -PreferredProvider "openrouter" `
            -PreferredBrand "Stealth" `
            -PreferredModel "stealth/ox-alpha"
    }
    else {
        Refresh-ProviderSelection `
            -PreferredProvider "chatgpt" `
            -PreferredBrand "OpenAI" `
            -PreferredModel "__account_default__"
    }

    Update-DesktopRouteClarity
}

# The route controls are injected earlier by visual-console-entry.ps1. Their
# original handlers perform the config mutation synchronously; these later
# handlers only synchronize the Manager selection after the state file confirms
# that the requested transition actually happened.
if ($null -ne $desktopOxButton) {
    $desktopOxButton.Add_Click({
        if (Get-DesktopRouteIsOxActive) {
            Sync-ManagerSelectionToDesktopRoute
        }
    })
}

if ($null -ne $desktopRestoreButton) {
    $desktopRestoreButton.Add_Click({
        if (-not (Get-DesktopRouteIsOxActive) -and (Test-Path -LiteralPath $desktopRouteStatePath)) {
            Sync-ManagerSelectionToDesktopRoute
        }
    })
}

Update-DesktopRouteClarity

# Refresh-Catalog runs before ShowDialog(). Loaded therefore occurs after the
# initial saved CLI selection has been restored but before the first visible
# render. Synchronize once here so reopening V4 cannot initially show an OX hero
# while Desktop Chat is already back on the ChatGPT/OpenAI default route.
$script:desktopRouteInitialSelectionSyncDone = $false
$window.Add_Loaded({
    if ($script:desktopRouteInitialSelectionSyncDone) { return }
    $script:desktopRouteInitialSelectionSyncDone = $true
    Sync-ManagerSelectionToDesktopRoute
})

# Brand the actual WPF window/taskbar icon as well as the Windows shortcuts.
# This is best-effort only: an icon problem must never block V4 startup.
$brandingHelperPath = Join-Path $PSScriptRoot "branding-assets.ps1"
$script:managerBrandIconPath = ""
if (Test-Path -LiteralPath $brandingHelperPath) {
    try {
        . $brandingHelperPath
        $script:managerBrandIconPath = Get-ManagerBrandIconPath
        if (Test-Path -LiteralPath $script:managerBrandIconPath) {
            $brandIconUri = [Uri]::new($script:managerBrandIconPath, [UriKind]::Absolute)
            $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($brandIconUri)
        }
    }
    catch {
        Write-Verbose "Brand icon could not be applied: $($_.Exception.Message)"
    }
}

# PowerShell remains the V4 UI host, but the desktop/start-menu entry now starts
# a tiny native CodexManager.exe first. The native launcher owns the branded
# taskbar identity immediately and waits until this HWND has the same AppID.
# Keep this WPF window out of the taskbar until its explicit metadata is committed,
# then reveal it so Windows can hand the existing Codex taskbar group to the real UI.
$taskbarMetadataPath = Join-Path $PSScriptRoot "windows-taskbar-metadata.ps1"
if (Test-Path -LiteralPath $taskbarMetadataPath) {
    try {
        . $taskbarMetadataPath
        $installerRoot = Split-Path -Parent $PSScriptRoot
        $script:managerHiddenLauncher = Join-Path $installerRoot "LAUNCH_VISUAL_CONSOLE.vbs"
        $script:managerNativeLauncher = Join-Path $env:LOCALAPPDATA "Codex Multi-Model Manager\CodexManager.exe"
        $script:managerWscriptPath = Join-Path $env:WINDIR "System32\wscript.exe"

        $window.ShowInTaskbar = $false
        try {
            $window.Add_SourceInitialized({
                try {
                    if ([string]::IsNullOrWhiteSpace($script:managerBrandIconPath) -or
                        -not (Test-Path -LiteralPath $script:managerBrandIconPath) -or
                        -not (Test-Path -LiteralPath $script:managerHiddenLauncher)) {
                        return
                    }

                    $windowHandle = ([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle
                    if ($windowHandle -eq [IntPtr]::Zero) { return }

                    $relaunchIconPath = $script:managerBrandIconPath
                    if (Test-Path -LiteralPath $script:managerNativeLauncher) {
                        $relaunchCommand = ('"{0}" "{1}"' -f $script:managerNativeLauncher, $script:managerHiddenLauncher)
                        $relaunchIconPath = $script:managerNativeLauncher
                    }
                    elseif (Test-Path -LiteralPath $script:managerWscriptPath) {
                        $relaunchCommand = ('"{0}" "{1}"' -f $script:managerWscriptPath, $script:managerHiddenLauncher)
                    }
                    else {
                        return
                    }

                    Set-ManagerWindowTaskbarMetadata `
                        -WindowHandle $windowHandle `
                        -RelaunchCommand $relaunchCommand `
                        -DisplayName "Codex Manager" `
                        -IconPath $relaunchIconPath
                }
                catch {
                    Write-Verbose "Taskbar relaunch metadata could not be applied: $($_.Exception.Message)"
                }
                finally {
                    $window.ShowInTaskbar = $true
                }
            })
        }
        catch {
            $window.ShowInTaskbar = $true
            throw
        }
    }
    catch {
        $window.ShowInTaskbar = $true
        Write-Verbose "Taskbar metadata runtime could not be loaded: $($_.Exception.Message)"
    }
}

$sidebarReadabilityPath = Join-Path $PSScriptRoot "visual-sidebar-readability.ps1"
if (Test-Path -LiteralPath $sidebarReadabilityPath) {
    . $sidebarReadabilityPath
}