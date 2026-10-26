# Motion Design System v1 for Codex Multi-Model Manager V4.
#
# Production startup safety:
# Motion v1 is temporarily opt-in only until CI owns a real full-window startup
# smoke test. The silent VBS launcher hides pre-ShowDialog PowerShell failures,
# so optional visual polish must never prevent the manager from opening.
# Set CODEX_MM_ENABLE_MOTION_V1=1 only for explicit motion testing.
if ($env:CODEX_MM_ENABLE_MOTION_V1 -ne "1") {
    return
}

# Motion rules:
# - Linear: continuous progress/loading only.
# - EaseIn: elements leaving the scene.
# - EaseOut: elements entering the scene.
# - EaseInOut: spatial movement / expand-collapse / page movement.
# - Signature: product-specific emphasized movement.
#
# This runtime is loaded after the hierarchy and commercial-polish runtimes. It
# centralizes durations and curves, upgrades existing commercial animations to
# the shared curve engine, and adds restrained page/list/combo transitions.

$script:MotionSystemVersion = "1.0.0"

$script:MotionDurations = [ordered]@{
    Fast       = 100
    Exit       = 130
    Enter      = 160
    Move       = 220
    Smooth     = 220
    Emphasized = 280
    LinearLoop = 900
}

# Cubic-bezier / KeySpline control points. Values intentionally stay within the
# standard 0..1 range so WPF KeySpline behavior is deterministic.
$script:MotionCurves = [ordered]@{
    Linear     = [pscustomobject]@{ X1=0.00; Y1=0.00; X2=1.00; Y2=1.00; Purpose="持续加载 / 匀速运动" }
    EaseIn     = [pscustomobject]@{ X1=0.40; Y1=0.00; X2=1.00; Y2=1.00; Purpose="元素退出 / 收起" }
    EaseOut    = [pscustomobject]@{ X1=0.00; Y1=0.00; X2=0.20; Y2=1.00; Purpose="元素进入 / 弹出" }
    EaseInOut  = [pscustomobject]@{ X1=0.40; Y1=0.00; X2=0.20; Y2=1.00; Purpose="位移 / 页面切换 / 展开收起" }
    Signature  = [pscustomobject]@{ X1=0.16; Y1=1.00; X2=0.30; Y2=1.00; Purpose="Codex 关键状态与强调动作" }
}

# Respect the Windows client-area-animation accessibility preference when it is
# available. The UI still functions normally when motion is disabled.
$script:MotionEnabled = $true
try {
    $script:MotionEnabled = [bool][System.Windows.SystemParameters]::ClientAreaAnimation
}
catch {
    $script:MotionEnabled = $true
}

function Get-MotionDurationMilliseconds([string]$Token = "Enter") {
    if ($script:MotionDurations.Contains($Token)) {
        return [int]$script:MotionDurations[$Token]
    }
    return [int]$script:MotionDurations.Enter
}

function Get-MotionCurve([string]$Curve = "EaseOut") {
    if ($script:MotionCurves.Contains($Curve)) {
        return $script:MotionCurves[$Curve]
    }
    return $script:MotionCurves.EaseOut
}

function New-MotionDoubleAnimation(
    [double]$To,
    [string]$Curve = "EaseOut",
    [string]$DurationToken = "Enter",
    [int]$Milliseconds = 0
) {
    $durationMs = if ($Milliseconds -gt 0) { $Milliseconds } else { Get-MotionDurationMilliseconds $DurationToken }
    if (-not $script:MotionEnabled) { $durationMs = 1 }

    $duration = [TimeSpan]::FromMilliseconds([double]$durationMs)
    $curveSpec = Get-MotionCurve $Curve

    $animation = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $animation.Duration = [System.Windows.Duration]::new($duration)
    $animation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd

    $frame = New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame
    $frame.Value = $To
    $frame.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan($duration)
    $frame.KeySpline = [System.Windows.Media.Animation.KeySpline]::new(
        [double]$curveSpec.X1,
        [double]$curveSpec.Y1,
        [double]$curveSpec.X2,
        [double]$curveSpec.Y2
    )
    $animation.KeyFrames.Add($frame) | Out-Null
    return $animation
}

# Reusable linear loop for actual loading/progress indicators. This function does
# not start any decorative animation by itself; callers must attach it only while
# an operation is actively loading.
function New-MotionLinearLoopAnimation([double]$From = 0.0, [double]$To = 360.0) {
    $durationMs = Get-MotionDurationMilliseconds "LinearLoop"
    if (-not $script:MotionEnabled) { $durationMs = 1 }

    $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $animation.From = $From
    $animation.To = $To
    $animation.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds([double]$durationMs))
    $animation.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $animation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
    return $animation
}

function Get-MotionTranslateTransform($Element) {
    if ($null -eq $Element -or -not ($Element -is [System.Windows.UIElement])) { return $null }

    $current = $Element.RenderTransform
    if ($current -is [System.Windows.Media.TranslateTransform]) { return $current }

    if ($current -is [System.Windows.Media.TransformGroup]) {
        foreach ($child in $current.Children) {
            if ($child -is [System.Windows.Media.TranslateTransform]) { return $child }
        }
        $translate = New-Object System.Windows.Media.TranslateTransform
        $current.Children.Add($translate) | Out-Null
        return $translate
    }

    $group = New-Object System.Windows.Media.TransformGroup
    if ($null -ne $current -and $current -ne [System.Windows.Media.Transform]::Identity) {
        $group.Children.Add($current) | Out-Null
    }
    $translate = New-Object System.Windows.Media.TranslateTransform
    $group.Children.Add($translate) | Out-Null
    $Element.RenderTransform = $group
    return $translate
}

function Invoke-MotionPageEnter($Element) {
    if (-not $script:MotionEnabled -or $null -eq $Element -or -not ($Element -is [System.Windows.UIElement])) { return }

    $translate = Get-MotionTranslateTransform $Element
    if ($null -eq $translate) { return }

    $Element.Opacity = 0.0
    $translate.X = 14.0

    $Element.BeginAnimation(
        [System.Windows.UIElement]::OpacityProperty,
        (New-MotionDoubleAnimation -To 1.0 -Curve "EaseOut" -DurationToken "Enter")
    )
    $translate.BeginAnimation(
        [System.Windows.Media.TranslateTransform]::XProperty,
        (New-MotionDoubleAnimation -To 0.0 -Curve "EaseInOut" -DurationToken "Move")
    )
}

function Invoke-MotionListSettle($ListBox) {
    if (-not $script:MotionEnabled -or $null -eq $ListBox -or -not ($ListBox -is [System.Windows.Controls.ListBox])) { return }

    $translate = Get-MotionTranslateTransform $ListBox
    if ($null -eq $translate) { return }

    $ListBox.Opacity = 0.74
    $translate.Y = 7.0

    $ListBox.BeginAnimation(
        [System.Windows.UIElement]::OpacityProperty,
        (New-MotionDoubleAnimation -To 1.0 -Curve "EaseOut" -DurationToken "Enter")
    )
    $translate.BeginAnimation(
        [System.Windows.Media.TranslateTransform]::YProperty,
        (New-MotionDoubleAnimation -To 0.0 -Curve "Signature" -DurationToken "Emphasized")
    )
}

function Register-MotionComboEntrance($Combo) {
    if ($null -eq $Combo -or -not ($Combo -is [System.Windows.Controls.ComboBox])) { return }

    $Combo.Add_DropDownOpened({
        param($sender,$eventArgs)
        if (-not $script:MotionEnabled) { return }

        $scale = $sender.RenderTransform
        if (-not ($scale -is [System.Windows.Media.ScaleTransform])) {
            $scale = New-Object System.Windows.Media.ScaleTransform
            $sender.RenderTransformOrigin = [System.Windows.Point]::new(0.5,0.5)
            $sender.RenderTransform = $scale
        }

        $sender.Opacity = 0.88
        $scale.ScaleX = 0.992
        $scale.ScaleY = 0.992
        $sender.BeginAnimation(
            [System.Windows.UIElement]::OpacityProperty,
            (New-MotionDoubleAnimation -To 1.0 -Curve "EaseOut" -DurationToken "Enter")
        )
        $scale.BeginAnimation(
            [System.Windows.Media.ScaleTransform]::ScaleXProperty,
            (New-MotionDoubleAnimation -To 1.0 -Curve "EaseOut" -DurationToken "Fast")
        )
        $scale.BeginAnimation(
            [System.Windows.Media.ScaleTransform]::ScaleYProperty,
            (New-MotionDoubleAnimation -To 1.0 -Curve "EaseOut" -DurationToken "Fast")
        )
    })
}

# Upgrade the existing commercial hover/button motion to the same spline engine.
# Existing call sites keep their explicit duration, but no longer invent their own
# easing implementation.
function New-CommercialAnimation([double]$To, [int]$Milliseconds = 150) {
    return (New-MotionDoubleAnimation -To $To -Curve "EaseOut" -Milliseconds $Milliseconds)
}

# Override the base page switcher so every top-level page uses the same entrance
# language: fast visual appearance plus smooth spatial settling.
function Set-NavPage([int]$Index, [string]$Title, [string]$Subtitle, $SelectedButton) {
    $MainTabs.SelectedIndex = $Index
    $TopPageTitle.Text = $Title
    $TopPageSubTitle.Text = $Subtitle
    foreach ($button in @($NavDashboard,$NavModels,$NavProviders,$NavStealth,$NavTools)) {
        $button.Background = Get-ColorBrush "#00000000"
        $button.Foreground = Get-ColorBrush "#C4CEE2"
    }
    $SelectedButton.Background = Get-ColorBrush "#171D45"
    $SelectedButton.Foreground = Get-ColorBrush "#FFFFFF"

    Invoke-MotionPageEnter $MainTabs.SelectedContent
}

# Sorting should feel like the same objects re-settling rather than a hard redraw.
if ($null -ne $DashboardSortCombo) {
    $DashboardSortCombo.Add_SelectionChanged({ Invoke-MotionListSettle $DashboardModelList })
}
if ($null -ne $ModelsSortCombo) {
    $ModelsSortCombo.Add_SelectionChanged({ Invoke-MotionListSettle $ModelsModelList })
}

# Apply the same short entrance curve to interactive dropdown selectors. Hidden
# legacy combos are harmless here and keep compatibility with internal routing.
foreach ($combo in @(
    $WorkspaceCombo,
    $ProviderCombo,$BrandCombo,$ModelCombo,$EffortCombo,
    $VendorCombo,$FamilyCombo,$VariantCombo,$PerformanceCombo,
    $DashboardSortCombo,$ModelsSortCombo
)) {
    Register-MotionComboEntrance $combo
}
