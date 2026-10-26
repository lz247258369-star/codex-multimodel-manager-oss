# Readability pass for the V4 dashboard right rail.
# Keeps the commercial dark visual language while increasing contrast,
# type hierarchy, and scanability for status/provider/tool surfaces.

$script:providerReadableTemplateXaml = @'
<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Border x:Name="ProviderSurface" Background="#101A2F" BorderBrush="#2B3F63" BorderThickness="1" CornerRadius="15"
          Padding="15" Margin="0,0,0,12" RenderTransformOrigin="0.5,0.5">
    <Border.RenderTransform><ScaleTransform x:Name="ProviderScale" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
    <Border.Effect><DropShadowEffect x:Name="ProviderShadow" Color="#000000" BlurRadius="16" ShadowDepth="0" Opacity="0.22"/></Border.Effect>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Text="{Binding Label}" Foreground="#F7F9FF" FontSize="14" FontWeight="SemiBold"/>
        <TextBlock Text="{Binding StatusLine}" Foreground="{Binding Color}" FontSize="12" FontWeight="SemiBold" Margin="0,7,0,0"/>
        <TextBlock Text="{Binding Detail}" Foreground="#A9B7CE" FontSize="10.5" Margin="0,5,0,0" TextWrapping="Wrap" LineHeight="15"/>
      </StackPanel>
      <Border Grid.Column="1" Width="22" Height="22" CornerRadius="11" Background="#12223C" BorderBrush="#31507D" BorderThickness="1" VerticalAlignment="Top" Margin="12,1,0,0">
        <Ellipse Width="8" Height="8" Fill="{Binding Color}"/>
      </Border>
    </Grid>
    <Border.Triggers>
      <EventTrigger RoutedEvent="MouseEnter">
        <BeginStoryboard><Storyboard>
          <DoubleAnimation Storyboard.TargetName="ProviderScale" Storyboard.TargetProperty="ScaleX" To="1.012" Duration="0:0:0.14"/>
          <DoubleAnimation Storyboard.TargetName="ProviderScale" Storyboard.TargetProperty="ScaleY" To="1.012" Duration="0:0:0.14"/>
          <DoubleAnimation Storyboard.TargetName="ProviderShadow" Storyboard.TargetProperty="Opacity" To="0.36" Duration="0:0:0.14"/>
          <DoubleAnimation Storyboard.TargetName="ProviderShadow" Storyboard.TargetProperty="BlurRadius" To="24" Duration="0:0:0.14"/>
        </Storyboard></BeginStoryboard>
      </EventTrigger>
      <EventTrigger RoutedEvent="MouseLeave">
        <BeginStoryboard><Storyboard>
          <DoubleAnimation Storyboard.TargetName="ProviderScale" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.18"/>
          <DoubleAnimation Storyboard.TargetName="ProviderScale" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.18"/>
          <DoubleAnimation Storyboard.TargetName="ProviderShadow" Storyboard.TargetProperty="Opacity" To="0.22" Duration="0:0:0.18"/>
          <DoubleAnimation Storyboard.TargetName="ProviderShadow" Storyboard.TargetProperty="BlurRadius" To="16" Duration="0:0:0.18"/>
        </Storyboard></BeginStoryboard>
      </EventTrigger>
    </Border.Triggers>
  </Border>
</DataTemplate>
'@

function global:Set-RightRailButtonReadability($Button) {
    if ($null -eq $Button) { return }
    $Button.Foreground = Get-ColorBrush '#F4F7FF'
    $Button.Background = Get-ColorBrush '#14213A'
    $Button.BorderBrush = Get-ColorBrush '#304A73'
    $Button.FontSize = 13
    $Button.FontWeight = [System.Windows.FontWeights]::SemiBold
    $Button.Height = 42
}

$window.Add_Loaded({
    $readableProviderTemplate = [Windows.Markup.XamlReader]::Parse($script:providerReadableTemplateXaml)
    $DashboardProviderHealthList.ItemTemplate = $readableProviderTemplate
    $ProvidersPageList.ItemTemplate = $readableProviderTemplate

    $HealthSummaryText.Foreground = Get-ColorBrush '#B8C5DA'
    $HealthSummaryText.FontSize = 11.5
    $HealthSummaryText.FontWeight = [System.Windows.FontWeights]::Medium
    $HealthSummaryText.LineHeight = 16
    $HealthSummaryBadge.FontSize = 10
    $HealthSummaryBadge.FontWeight = [System.Windows.FontWeights]::Bold

    $systemStack = $RefreshHealthButton.Parent
    if ($systemStack -is [System.Windows.Controls.StackPanel]) {
        $systemCard = $systemStack.Parent
        if ($systemCard -is [System.Windows.Controls.Border]) {
            $systemCard.Background = Get-ColorBrush '#0F192C'
            $systemCard.BorderBrush = Get-ColorBrush '#263B5E'
        }
        if ($systemStack.Children.Count -gt 0 -and $systemStack.Children[0] -is [System.Windows.Controls.Grid]) {
            $systemHeader = $systemStack.Children[0]
            foreach ($child in @($systemHeader.Children)) {
                if ($child -is [System.Windows.Controls.TextBlock] -and $child -ne $HealthSummaryBadge) {
                    $child.Foreground = Get-ColorBrush '#F6F8FF'
                    $child.FontSize = 17
                    $child.FontWeight = [System.Windows.FontWeights]::SemiBold
                }
            }
        }
    }

    $toolsStack = $DashboardUpdateCenterButton.Parent
    if ($toolsStack -is [System.Windows.Controls.StackPanel]) {
        $toolsCard = $toolsStack.Parent
        if ($toolsCard -is [System.Windows.Controls.Border]) {
            $toolsCard.Background = Get-ColorBrush '#0F192C'
            $toolsCard.BorderBrush = Get-ColorBrush '#263B5E'
        }
        if ($toolsStack.Children.Count -gt 0 -and $toolsStack.Children[0] -is [System.Windows.Controls.TextBlock]) {
            $toolsTitle = $toolsStack.Children[0]
            $toolsTitle.Foreground = Get-ColorBrush '#F6F8FF'
            $toolsTitle.FontSize = 17
            $toolsTitle.FontWeight = [System.Windows.FontWeights]::SemiBold
            $toolsTitle.Margin = [System.Windows.Thickness]::new(0,0,0,12)
        }
    }

    foreach ($button in @(
        $RefreshHealthButton,
        $DashboardUpdateCenterButton,
        $DashboardStealthButton,
        $DashboardHealthDetailButton
    )) {
        Set-RightRailButtonReadability $button
    }
})

# Always-on crash diagnostics are retained for the whole V4 application.
$crashDiagnosticsPath = Join-Path $PSScriptRoot "visual-crash-diagnostics.ps1"
if (Test-Path -LiteralPath $crashDiagnosticsPath) {
    . $crashDiagnosticsPath
}

# The model matrix has one stable presentation only: Vendor grouping.
# Users reveal every model with the combined expand/collapse button; there is no
# alternate flat view and therefore no display-mode switch path to crash.
$cardGroupingRuntimePath = Join-Path $PSScriptRoot "visual-card-grouping-runtime.ps1"
if (Test-Path -LiteralPath $cardGroupingRuntimePath) {
    . $cardGroupingRuntimePath
}

# Replace the legacy OX-only Desktop route action with one stable button whose
# target follows the currently selected Manager model/provider.
$dynamicDesktopRoutePath = Join-Path $PSScriptRoot "visual-desktop-route-dynamic.ps1"
if (Test-Path -LiteralPath $dynamicDesktopRoutePath) {
    . $dynamicDesktopRoutePath
}

# Re-declare the legacy helper names in this exact runtime scope so the pre-existing
# Loaded handler resolves the generic route behavior instead of the old OX-only one.
$dynamicDesktopScopeFixPath = Join-Path $PSScriptRoot "visual-desktop-route-scope-fix.ps1"
if (Test-Path -LiteralPath $dynamicDesktopScopeFixPath) {
    . $dynamicDesktopScopeFixPath
}
