# Commercial-grade visual polish for Codex Multi-Model Manager V4.
# Loaded after the hierarchy runtime, before the first catalog refresh.
# Motion is intentionally subtle: short hover lift, soft shadow/glow, selected
# accent ring, and tactile button feedback. No continuous decorative animation.

$script:commercialMotionRegistered = New-Object 'System.Collections.Generic.HashSet[int]'

# WPF event handlers created with GetNewClosure execute later in their own dynamic
# module scope. Keep this small factory globally visible for the lifetime of the
# V4 pwsh process so hover/button events cannot lose command resolution after the
# compatibility entrypoint materializes the UI into a ScriptBlock.
function global:New-CommercialAnimation([double]$To, [int]$Milliseconds = 150) {
    $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $animation.To = $To
    $animation.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($Milliseconds))
    $animation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $animation.EasingFunction = $ease
    return $animation
}

function Register-CommercialCardMotion($Border, [double]$HoverScale = 1.006) {
    if ($null -eq $Border -or -not ($Border -is [System.Windows.Controls.Border])) { return }
    $key = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Border)
    if (-not $script:commercialMotionRegistered.Add($key)) { return }

    $scale = New-Object System.Windows.Media.ScaleTransform
    $scale.ScaleX = 1.0
    $scale.ScaleY = 1.0
    $Border.RenderTransformOrigin = [System.Windows.Point]::new(0.5,0.5)
    $Border.RenderTransform = $scale

    $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $shadow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString('#000000')
    $shadow.BlurRadius = 16
    $shadow.ShadowDepth = 0
    $shadow.Opacity = 0.18
    $Border.Effect = $shadow

    $originalBorderBrush = $Border.BorderBrush
    $hoverBrush = Get-ColorBrush '#354B78'

    $enter = {
        param($sender,$eventArgs)
        $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-CommercialAnimation -To $HoverScale -Milliseconds 140))
        $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-CommercialAnimation -To $HoverScale -Milliseconds 140))
        $shadow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, (New-CommercialAnimation -To 0.34 -Milliseconds 150))
        $shadow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty, (New-CommercialAnimation -To 24 -Milliseconds 150))
        if ($null -ne $hoverBrush) { $sender.BorderBrush = $hoverBrush }
    }.GetNewClosure()

    $leave = {
        param($sender,$eventArgs)
        $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-CommercialAnimation -To 1.0 -Milliseconds 170))
        $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-CommercialAnimation -To 1.0 -Milliseconds 170))
        $shadow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, (New-CommercialAnimation -To 0.18 -Milliseconds 180))
        $shadow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty, (New-CommercialAnimation -To 16 -Milliseconds 180))
        $sender.BorderBrush = $originalBorderBrush
    }.GetNewClosure()

    $Border.Add_MouseEnter($enter)
    $Border.Add_MouseLeave($leave)
}

function Register-CommercialButtonMotion($Button) {
    if ($null -eq $Button -or -not ($Button -is [System.Windows.Controls.Button])) { return }
    $key = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Button)
    if (-not $script:commercialMotionRegistered.Add($key)) { return }

    $scale = New-Object System.Windows.Media.ScaleTransform
    $scale.ScaleX = 1.0
    $scale.ScaleY = 1.0
    $Button.RenderTransformOrigin = [System.Windows.Point]::new(0.5,0.5)
    $Button.RenderTransform = $scale

    $Button.Add_MouseEnter(({ param($sender,$eventArgs)
        if ($sender.IsEnabled) {
            $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-CommercialAnimation -To 1.012 -Milliseconds 110))
            $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-CommercialAnimation -To 1.012 -Milliseconds 110))
        }
    }).GetNewClosure())
    $Button.Add_MouseLeave(({ param($sender,$eventArgs)
        $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-CommercialAnimation -To 1.0 -Milliseconds 140))
        $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-CommercialAnimation -To 1.0 -Milliseconds 140))
    }).GetNewClosure())
    $Button.Add_PreviewMouseLeftButtonDown(({ param($sender,$eventArgs)
        if ($sender.IsEnabled) {
            $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-CommercialAnimation -To 0.985 -Milliseconds 70))
            $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-CommercialAnimation -To 0.985 -Milliseconds 70))
        }
    }).GetNewClosure())
    $Button.Add_PreviewMouseLeftButtonUp(({ param($sender,$eventArgs)
        if ($sender.IsEnabled) {
            $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-CommercialAnimation -To 1.012 -Milliseconds 90))
            $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-CommercialAnimation -To 1.012 -Milliseconds 90))
        }
    }).GetNewClosure())
}

function Get-CommercialVisualDescendants($Root) {
    if ($null -eq $Root) { return @() }
    $result = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        $count = 0
        try { $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node) } catch { $count = 0 }
        for ($i = 0; $i -lt $count; $i++) {
            $child = [System.Windows.Media.VisualTreeHelper]::GetChild($node,$i)
            $result.Add($child)
            $stack.Push($child)
        }
    }
    return $result.ToArray()
}

# Model cards: subtle accent glow, lift and selected state. The content template is
# also tightened so hierarchy/status/price scan like a commercial model catalog.
$commercialModelItemStyleXaml = @'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
       TargetType="ListBoxItem">
  <Setter Property="Width" Value="258"/>
  <Setter Property="MinHeight" Value="184"/>
  <Setter Property="Margin" Value="0,0,14,14"/>
  <Setter Property="Padding" Value="0"/>
  <Setter Property="Foreground" Value="#F4F7FF"/>
  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ListBoxItem">
        <Grid Margin="3">
          <Border x:Name="GlowBorder" CornerRadius="18" Background="#070B16" Opacity="0">
            <Border.Effect>
              <DropShadowEffect Color="#7768FF" BlurRadius="30" ShadowDepth="0" Opacity="0.72"/>
            </Border.Effect>
          </Border>
          <Border x:Name="CardBorder" Background="#0D1729" BorderBrush="#213252" BorderThickness="1"
                  CornerRadius="17" Padding="16" RenderTransformOrigin="0.5,0.5">
            <Border.RenderTransform>
              <TransformGroup>
                <ScaleTransform x:Name="CardScale" ScaleX="1" ScaleY="1"/>
                <TranslateTransform x:Name="CardLift" Y="0"/>
              </TransformGroup>
            </Border.RenderTransform>
            <Border.Effect>
              <DropShadowEffect x:Name="CardShadow" Color="#000000" BlurRadius="18" ShadowDepth="0" Opacity="0.28"/>
            </Border.Effect>
            <ContentPresenter/>
          </Border>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="CardBorder" Property="Background" Value="#111E35"/>
            <Setter TargetName="CardBorder" Property="BorderBrush" Value="#4E67A4"/>
            <Setter TargetName="GlowBorder" Property="Opacity" Value="0.36"/>
          </Trigger>
          <Trigger Property="IsSelected" Value="True">
            <Setter TargetName="CardBorder" Property="Background" Value="#171B42"/>
            <Setter TargetName="CardBorder" Property="BorderBrush" Value="#8A79FF"/>
            <Setter TargetName="GlowBorder" Property="Opacity" Value="0.52"/>
          </Trigger>
          <EventTrigger RoutedEvent="MouseEnter">
            <BeginStoryboard>
              <Storyboard>
                <DoubleAnimation Storyboard.TargetName="CardScale" Storyboard.TargetProperty="ScaleX" To="1.018" Duration="0:0:0.14"/>
                <DoubleAnimation Storyboard.TargetName="CardScale" Storyboard.TargetProperty="ScaleY" To="1.018" Duration="0:0:0.14"/>
                <DoubleAnimation Storyboard.TargetName="CardLift" Storyboard.TargetProperty="Y" To="-3" Duration="0:0:0.14"/>
                <DoubleAnimation Storyboard.TargetName="CardShadow" Storyboard.TargetProperty="Opacity" To="0.42" Duration="0:0:0.14"/>
                <DoubleAnimation Storyboard.TargetName="CardShadow" Storyboard.TargetProperty="BlurRadius" To="26" Duration="0:0:0.14"/>
              </Storyboard>
            </BeginStoryboard>
          </EventTrigger>
          <EventTrigger RoutedEvent="MouseLeave">
            <BeginStoryboard>
              <Storyboard>
                <DoubleAnimation Storyboard.TargetName="CardScale" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.18"/>
                <DoubleAnimation Storyboard.TargetName="CardScale" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.18"/>
                <DoubleAnimation Storyboard.TargetName="CardLift" Storyboard.TargetProperty="Y" To="0" Duration="0:0:0.18"/>
                <DoubleAnimation Storyboard.TargetName="CardShadow" Storyboard.TargetProperty="Opacity" To="0.28" Duration="0:0:0.18"/>
                <DoubleAnimation Storyboard.TargetName="CardShadow" Storyboard.TargetProperty="BlurRadius" To="18" Duration="0:0:0.18"/>
              </Storyboard>
            </BeginStoryboard>
          </EventTrigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
'@

$commercialModelTemplateXaml = @'
<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <StackPanel>
    <Border Height="2" CornerRadius="2" Margin="0,-2,0,13">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
          <GradientStop Color="#7C4DFF" Offset="0"/>
          <GradientStop Color="#2D8CFF" Offset="0.55"/>
          <GradientStop Color="#2DD4A3" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
    </Border>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="46"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border Width="40" Height="40" CornerRadius="12" Background="{Binding IconBackground}" VerticalAlignment="Top">
        <Border.Effect><DropShadowEffect Color="#5E7BFF" BlurRadius="14" ShadowDepth="0" Opacity="0.32"/></Border.Effect>
        <TextBlock Text="{Binding Monogram}" FontSize="18" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Grid.Column="1" Margin="10,0,0,0">
        <TextBlock Text="{Binding Family}" FontSize="15" FontWeight="SemiBold" Foreground="#F7F9FF" TextTrimming="CharacterEllipsis"/>
        <TextBlock Text="{Binding Variant}" FontSize="12" FontWeight="SemiBold" Foreground="#B9C6DC" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
        <TextBlock Text="{Binding Vendor}" FontSize="10" Foreground="#7F90AD" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </Grid>
    <WrapPanel Margin="0,13,0,0">
      <Border Background="#161F36" BorderBrush="#293A5C" BorderThickness="1" CornerRadius="8" Padding="8,4" Margin="0,0,7,0">
        <TextBlock Text="{Binding PerformanceText}" Foreground="#B8ACFF" FontSize="10" FontWeight="SemiBold"/>
      </Border>
      <Border Background="#101B2E" BorderBrush="#243554" BorderThickness="1" CornerRadius="8" Padding="8,4">
        <TextBlock Text="{Binding StatusText}" Foreground="{Binding StatusColor}" FontSize="10" FontWeight="SemiBold"/>
      </Border>
    </WrapPanel>
    <TextBlock Text="{Binding PriceText}" Foreground="#EDF2FF" FontSize="10" FontWeight="SemiBold" Margin="0,11,0,0" TextWrapping="Wrap"/>
    <TextBlock Text="{Binding ProviderLine}" Foreground="#7586A3" FontSize="9" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/>
    <Grid Margin="0,11,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock Text="{Binding ReadyText}" Foreground="{Binding ReadyColor}" FontSize="10" FontWeight="SemiBold"/>
      <TextBlock Grid.Column="1" Text="{Binding SourceText}" Foreground="#6D7D99" FontSize="9"/>
    </Grid>
  </StackPanel>
</DataTemplate>
'@

$commercialProviderTemplateXaml = @'
<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Border x:Name="ProviderSurface" Background="#0D1729" BorderBrush="#213252" BorderThickness="1" CornerRadius="14"
          Padding="14" Margin="0,0,0,11" RenderTransformOrigin="0.5,0.5">
    <Border.RenderTransform><ScaleTransform x:Name="ProviderScale" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
    <Border.Effect><DropShadowEffect x:Name="ProviderShadow" Color="#000000" BlurRadius="14" ShadowDepth="0" Opacity="0.20"/></Border.Effect>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Text="{Binding Label}" Foreground="#F7F9FF" FontSize="12" FontWeight="SemiBold"/>
        <TextBlock Text="{Binding StatusLine}" Foreground="{Binding Color}" FontSize="10" FontWeight="SemiBold" Margin="0,6,0,0"/>
        <TextBlock Text="{Binding Detail}" Foreground="#7C8DA9" FontSize="9" Margin="0,4,0,0" TextWrapping="Wrap"/>
      </StackPanel>
      <Border Grid.Column="1" Width="18" Height="18" CornerRadius="9" Background="#111F37" BorderBrush="#263A60" BorderThickness="1" VerticalAlignment="Top" Margin="10,0,0,0">
        <Ellipse Width="7" Height="7" Fill="{Binding Color}"/>
      </Border>
    </Grid>
    <Border.Triggers>
      <EventTrigger RoutedEvent="MouseEnter">
        <BeginStoryboard><Storyboard>
          <DoubleAnimation Storyboard.TargetName="ProviderScale" Storyboard.TargetProperty="ScaleX" To="1.012" Duration="0:0:0.14"/>
          <DoubleAnimation Storyboard.TargetName="ProviderScale" Storyboard.TargetProperty="ScaleY" To="1.012" Duration="0:0:0.14"/>
          <DoubleAnimation Storyboard.TargetName="ProviderShadow" Storyboard.TargetProperty="Opacity" To="0.34" Duration="0:0:0.14"/>
          <DoubleAnimation Storyboard.TargetName="ProviderShadow" Storyboard.TargetProperty="BlurRadius" To="22" Duration="0:0:0.14"/>
        </Storyboard></BeginStoryboard>
      </EventTrigger>
      <EventTrigger RoutedEvent="MouseLeave">
        <BeginStoryboard><Storyboard>
          <DoubleAnimation Storyboard.TargetName="ProviderScale" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.18"/>
          <DoubleAnimation Storyboard.TargetName="ProviderScale" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.18"/>
          <DoubleAnimation Storyboard.TargetName="ProviderShadow" Storyboard.TargetProperty="Opacity" To="0.20" Duration="0:0:0.18"/>
          <DoubleAnimation Storyboard.TargetName="ProviderShadow" Storyboard.TargetProperty="BlurRadius" To="14" Duration="0:0:0.18"/>
        </Storyboard></BeginStoryboard>
      </EventTrigger>
    </Border.Triggers>
  </Border>
</DataTemplate>
'@

$DashboardModelList.ItemContainerStyle = [Windows.Markup.XamlReader]::Parse($commercialModelItemStyleXaml)
$ModelsModelList.ItemContainerStyle = [Windows.Markup.XamlReader]::Parse($commercialModelItemStyleXaml)
$commercialModelTemplate = [Windows.Markup.XamlReader]::Parse($commercialModelTemplateXaml)
$DashboardModelList.ItemTemplate = $commercialModelTemplate
$ModelsModelList.ItemTemplate = $commercialModelTemplate
$commercialProviderTemplate = [Windows.Markup.XamlReader]::Parse($commercialProviderTemplateXaml)
$DashboardProviderHealthList.ItemTemplate = $commercialProviderTemplate
$ProvidersPageList.ItemTemplate = $commercialProviderTemplate

# Apply the same subtle elevation language to major surface cards and tactile
# feedback to buttons after WPF has materialized the visual tree.
$window.Add_Loaded({
    $cardStyle = $window.FindResource('Card')
    $primaryStyle = $window.FindResource('PrimaryButton')
    $softStyle = $window.FindResource('SoftButton')

    foreach ($node in @(Get-CommercialVisualDescendants $window)) {
        if ($node -is [System.Windows.Controls.Border] -and $node.Style -eq $cardStyle) {
            Register-CommercialCardMotion -Border $node -HoverScale 1.004
        }
        elseif ($node -is [System.Windows.Controls.Button] -and ($node.Style -eq $primaryStyle -or $node.Style -eq $softStyle)) {
            Register-CommercialButtonMotion $node
        }
    }
})
