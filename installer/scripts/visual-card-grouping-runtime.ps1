# Vendor-only grouping for the V4 model matrices.
# Loaded after visual-hierarchy-runtime.ps1, so Vendor card metadata and
# DashboardSortCombo/ModelsSortCombo already exist. Grouping and sorting remain
# independent: sort controls order cards; this runtime controls presentation.
#
# There is intentionally no Flat presentation mode. The model matrix always
# stays grouped by Vendor; users can expose every card with the single
# 全部展开 / 全部收起 toggle without switching WPF collection views.

$script:modelCardGroupingMode = "vendor"
$script:modelGroupsAllExpanded = $false
$script:modelGroupingLastError = ""

function New-ManagerVendorGroupStyle {
    $xaml = @"
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="{x:Type GroupItem}">
  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="{x:Type GroupItem}">
        <Expander IsExpanded="False" Foreground="#F4F7FF" Margin="0,0,0,14" HorizontalAlignment="Stretch" HorizontalContentAlignment="Stretch" Width="{Binding Path=ActualWidth, RelativeSource={RelativeSource AncestorType={x:Type ListBox}}}">
          <Expander.Header>
            <Border Background="#101A2E" BorderBrush="#2A416A" BorderThickness="1" CornerRadius="12" Padding="14,10" MinHeight="48" MinWidth="280" HorizontalAlignment="Stretch">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Text="{Binding Name}" Foreground="#F5F7FF" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/>
                <Border Grid.Column="1" Background="#0A1222" BorderBrush="#2A416A" BorderThickness="1" CornerRadius="8" Padding="9,4" Margin="12,0,0,0">
                  <TextBlock Text="{Binding ItemCount, StringFormat={}{0} 个模型}" Foreground="#9FB0CA" FontSize="10"/>
                </Border>
              </Grid>
            </Border>
          </Expander.Header>
          <ItemsPresenter Margin="12,10,0,4"/>
        </Expander>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
"@

    $style = New-Object System.Windows.Controls.GroupStyle
    $style.ContainerStyle = [Windows.Markup.XamlReader]::Parse($xaml)
    # GroupStyle.Panel controls how Vendor GroupItems are arranged: one row each.
    $style.Panel = [Windows.Markup.XamlReader]::Parse('<ItemsPanelTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><StackPanel/></ItemsPanelTemplate>')
    return $style
}

function New-ModelMatrixItemsPanel {
    # With WPF grouping enabled, the ListBox ItemsPanel is used by each GroupItem's
    # ItemsPresenter. Model cards may wrap horizontally inside an expanded vendor.
    return [Windows.Markup.XamlReader]::Parse('<ItemsPanelTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><WrapPanel/></ItemsPanelTemplate>')
}

function New-IsolatedModelListView {
    $source = New-Object System.Collections.ArrayList
    foreach ($card in @($script:modelCards)) { [void]$source.Add($card) }
    $view = [System.Windows.Data.ListCollectionView]::new($source)
    return ,$view
}

function Find-CurrentModelCard($PreferredCard) {
    if ($null -ne $PreferredCard) {
        $same = @($script:modelCards | Where-Object {
            $_.ProviderId -eq $PreferredCard.ProviderId -and $_.Id -eq $PreferredCard.Id
        }) | Select-Object -First 1
        if ($null -ne $same) { return $same }
    }

    if ($null -ne $ModelCombo -and $null -ne $ModelCombo.SelectedItem) {
        $providerId = if ($null -ne $ProviderCombo -and $null -ne $ProviderCombo.SelectedItem) { [string]$ProviderCombo.SelectedItem.id } else { "" }
        $modelId = [string]$ModelCombo.SelectedItem.id
        return @($script:modelCards | Where-Object {
            ([string]::IsNullOrWhiteSpace($providerId) -or $_.ProviderId -eq $providerId) -and $_.Id -eq $modelId
        }) | Select-Object -First 1
    }
    return $null
}

function Bind-ModelListPresentation($ListBox) {
    if ($null -eq $ListBox) { return }
    $selected = Find-CurrentModelCard $ListBox.SelectedItem
    $view = New-IsolatedModelListView
    $view.GroupDescriptions.Add([System.Windows.Data.PropertyGroupDescription]::new("Vendor"))

    $ListBox.ItemsSource = $null
    $ListBox.GroupStyle.Clear()
    $ListBox.ItemsPanel = New-ModelMatrixItemsPanel
    $ListBox.GroupStyle.Add((New-ManagerVendorGroupStyle))
    $ListBox.ItemsSource = $view

    if ($null -ne $selected) { $ListBox.SelectedItem = $selected }
}

function Update-ModelGroupingControlState {
    $label = if ($script:modelGroupsAllExpanded) { "全部收起" } else { "全部展开" }
    foreach ($button in @($script:DashboardGroupToggleButton,$script:ModelsGroupToggleButton)) {
        if ($null -eq $button) { continue }
        $button.Content = $label
        $button.IsEnabled = $true
        $button.Visibility = [System.Windows.Visibility]::Visible
    }
}

function Apply-ModelGroupingToAllLists {
    $previousLoadingRoute = $script:loadingRoute
    $script:loadingRoute = $true
    try {
        Bind-ModelListPresentation $DashboardModelList
        Bind-ModelListPresentation $ModelsModelList
    }
    finally {
        $script:loadingRoute = $previousLoadingRoute
    }
    Update-ModelGroupingControlState
}

function Get-VisualExpanders($Root) {
    $found = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Root) { return $found.ToArray() }
    try {
        $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Root)
        for ($i = 0; $i -lt $count; $i++) {
            $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Root, $i)
            if ($child -is [System.Windows.Controls.Expander]) { $found.Add($child) }
            foreach ($nested in @(Get-VisualExpanders $child)) { $found.Add($nested) }
        }
    }
    catch { }
    return $found.ToArray()
}

function Set-AllModelGroupsExpanded([bool]$Expanded) {
    $script:modelGroupsAllExpanded = $Expanded
    foreach ($list in @($DashboardModelList,$ModelsModelList)) {
        if ($null -eq $list) { continue }
        $list.UpdateLayout()
        foreach ($expander in @(Get-VisualExpanders $list)) { $expander.IsExpanded = $Expanded }
    }
    Update-ModelGroupingControlState
}

function Toggle-AllModelGroups {
    Set-AllModelGroupsExpanded (-not $script:modelGroupsAllExpanded)
}

function Expand-SelectedModelGroup {
    $model = $ModelCombo.SelectedItem
    if ($null -eq $model) { return }
    $vendor = Get-HierarchyVendor $model

    foreach ($list in @($DashboardModelList,$ModelsModelList)) {
        if ($null -eq $list) { continue }
        $list.UpdateLayout()
        foreach ($expander in @(Get-VisualExpanders $list)) {
            $group = $expander.DataContext
            if ($null -ne $group -and $group.PSObject.Properties["Name"] -and [string]$group.Name -eq $vendor) {
                $expander.IsExpanded = $true
            }
        }
    }

    if (-not $script:modelGroupsAllExpanded) { Update-ModelGroupingControlState }
}

function New-GroupingActionButton([string]$Text) {
    $button = New-Object System.Windows.Controls.Button
    $button.Content = $Text
    $button.Style = $window.FindResource("SoftButton")
    $button.Height = 36
    $button.Padding = [System.Windows.Thickness]::new(10,0,10,0)
    return $button
}

function Install-GroupingControls($SortCombo) {
    if ($null -eq $SortCombo -or -not ($SortCombo.Parent -is [System.Windows.Controls.StackPanel])) { return $null }
    $panel = $SortCombo.Parent
    $toggle = New-GroupingActionButton "全部展开"
    $toggle.Margin = [System.Windows.Thickness]::new(0,0,8,0)

    $index = [Math]::Max(0,$panel.Children.IndexOf($SortCombo))
    $panel.Children.Insert($index,$toggle)
    $toggle.Add_Click({ Toggle-AllModelGroups })
    return $toggle
}

$script:DashboardGroupToggleButton = Install-GroupingControls $DashboardSortCombo
$script:ModelsGroupToggleButton = Install-GroupingControls $ModelsSortCombo

# Re-apply the single Vendor grouping whenever hierarchy runtime replaces cards.
$script:RefreshModelCardsBeforeGrouping = ${function:Refresh-ModelCards}
function Refresh-ModelCards {
    & $script:RefreshModelCardsBeforeGrouping
    Apply-ModelGroupingToAllLists
}

# Keep the selected model visible by opening its Vendor group.
$script:UpdateSelectedRouteUIBeforeGrouping = ${function:Update-SelectedRouteUI}
function Update-SelectedRouteUI {
    & $script:UpdateSelectedRouteUIBeforeGrouping
    Expand-SelectedModelGroup
}

Apply-ModelGroupingToAllLists
Update-ModelGroupingControlState
