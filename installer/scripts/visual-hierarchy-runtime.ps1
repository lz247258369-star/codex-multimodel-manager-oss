# Runtime extension for Codex Multi-Model Manager V4.
# Dot-source this after visual-console.ps1 has registered its base handlers and
# before the initial Refresh-Catalog call. It keeps Provider routing internal while
# presenting the user-facing hierarchy as Vendor -> Family -> Variant -> Performance.

$script:syncingHierarchy = $false
$script:syncingSort = $false
$script:modelSortMode = "hierarchy"

function Get-HierarchyVendor($Model) {
    if ($null -ne $Model -and $Model.PSObject.Properties["vendor"] -and -not [string]::IsNullOrWhiteSpace([string]$Model.vendor)) {
        return [string]$Model.vendor
    }
    return (Get-ModelBrand $Model)
}

function Get-HierarchyFamily($Model) {
    if ($null -ne $Model -and $Model.PSObject.Properties["family"] -and -not [string]::IsNullOrWhiteSpace([string]$Model.family)) {
        return [string]$Model.family
    }
    return [string]$Model.label
}

function Get-HierarchyVariant($Model) {
    if ($null -ne $Model -and $Model.PSObject.Properties["variant"] -and -not [string]::IsNullOrWhiteSpace([string]$Model.variant)) {
        return [string]$Model.variant
    }
    return "Standard"
}

function Get-HierarchyPerformanceLevels($Model) {
    if ($null -ne $Model -and $Model.PSObject.Properties["performance_levels"] -and $null -ne $Model.performance_levels) {
        $levels = @($Model.performance_levels | ForEach-Object { [string]$_ } | Where-Object { $_ -in @("low","medium","high","xhigh","max") } | Select-Object -Unique)
        if ($levels.Count -gt 0) { return $levels }
    }
    return @("low","medium","high")
}

function Get-PerformanceLabel([string]$Id) {
    switch ($Id) {
        "low" { return "低" }
        "medium" { return "中" }
        "high" { return "高" }
        "xhigh" { return "极高" }
        "max" { return "最大" }
        default { return $Id }
    }
}

function Get-PerformanceRank([string]$Id) {
    switch ($Id) {
        "low" { return 1 }
        "medium" { return 2 }
        "high" { return 3 }
        "xhigh" { return 4 }
        "max" { return 5 }
        default { return 0 }
    }
}

function Get-ModelMaxPerformanceRank($Model) {
    $rank = 0
    foreach ($level in @(Get-HierarchyPerformanceLevels $Model)) {
        $rank = [Math]::Max($rank, (Get-PerformanceRank $level))
    }
    return $rank
}

function Get-NullablePrice($Model, [string]$PropertyName) {
    if ($null -eq $Model -or -not $Model.PSObject.Properties[$PropertyName]) { return $null }
    $value = $Model.$PropertyName
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $null }
    try { return [double]$value } catch { return $null }
}

function Format-ModelReferencePrice($Model) {
    $inputPrice = Get-NullablePrice -Model $Model -PropertyName "price_input"
    $outputPrice = Get-NullablePrice -Model $Model -PropertyName "price_output"
    if ($null -eq $inputPrice -and $null -eq $outputPrice) { return "价格待同步" }

    $currency = if ($Model.PSObject.Properties["price_currency"] -and -not [string]::IsNullOrWhiteSpace([string]$Model.price_currency)) { [string]$Model.price_currency } else { "USD" }
    $prefix = if ($currency -eq "USD") { '$' } else { "$currency " }
    $inputText = if ($null -ne $inputPrice) { $prefix + $inputPrice.ToString("0.####", [Globalization.CultureInfo]::InvariantCulture) } else { "-" }
    $outputText = if ($null -ne $outputPrice) { $prefix + $outputPrice.ToString("0.####", [Globalization.CultureInfo]::InvariantCulture) } else { "-" }
    return "API参考价 · 输入 $inputText / 输出 $outputText · 每1M tokens"
}

function Get-HierarchyRouteEntries {
    $entries = New-Object System.Collections.Generic.List[object]
    if ($null -eq $script:catalog) { return @() }

    foreach ($provider in @($script:catalog.providers)) {
        foreach ($model in @($provider.models)) {
            $entries.Add([pscustomobject]@{
                ProviderId = [string]$provider.id
                Provider = $provider
                Model = $model
                ModelId = [string]$model.id
                Vendor = Get-HierarchyVendor $model
                Family = Get-HierarchyFamily $model
                Variant = Get-HierarchyVariant $model
                Display = Get-HierarchyVariant $model
            })
        }
    }
    return $entries.ToArray()
}

function New-PerformanceOption([string]$Id) {
    return [pscustomobject]@{ Id=$Id; Label=(Get-PerformanceLabel $Id); Rank=(Get-PerformanceRank $Id) }
}

function Set-HierarchyPerformanceOptions($Model, [string]$Preferred = "") {
    $levels = @(Get-HierarchyPerformanceLevels $Model)
    if ($levels.Count -eq 0) { $levels = @("medium") }
    $options = @($levels | ForEach-Object { New-PerformanceOption $_ })

    $selectedId = $Preferred
    if ($selectedId -notin $levels) {
        if ("high" -in $levels) { $selectedId = "high" }
        elseif ("medium" -in $levels) { $selectedId = "medium" }
        else { $selectedId = [string]$levels[$levels.Count - 1] }
    }

    $PerformanceCombo.ItemsSource = $options
    $PerformanceCombo.SelectedItem = @($options | Where-Object { $_.Id -eq $selectedId }) | Select-Object -First 1

    $script:loadingRoute = $true
    try {
        $EffortCombo.ItemsSource = $levels
        $EffortCombo.SelectedItem = $selectedId
    }
    finally { $script:loadingRoute = $false }
}

function Select-HierarchyRouteEntry($Entry, [string]$PreferredEffort = "") {
    if ($null -eq $Entry) { return }
    $provider = Get-ProviderById ([string]$Entry.ProviderId)
    if ($null -eq $provider) { return }

    $model = @($provider.models | Where-Object { [string]$_.id -eq [string]$Entry.ModelId }) | Select-Object -First 1
    if ($null -eq $model) { return }
    $brand = Get-ModelBrand $model

    $script:loadingRoute = $true
    try {
        $ProviderCombo.SelectedItem = $provider
        $brands = @(Get-ProviderBrands $provider)
        $BrandCombo.ItemsSource = $brands
        $BrandCombo.SelectedItem = $brand
        $models = @($provider.models | Where-Object { (Get-ModelBrand $_) -eq $brand })
        $ModelCombo.ItemsSource = $models
        $ModelCombo.SelectedItem = $model
    }
    finally { $script:loadingRoute = $false }

    $effort = $PreferredEffort
    if ([string]::IsNullOrWhiteSpace($effort) -and $EffortCombo.SelectedItem) { $effort = [string]$EffortCombo.SelectedItem }
    Set-HierarchyPerformanceOptions -Model $model -Preferred $effort
    Update-SelectedRouteUI
}

function Sync-HierarchySelectorsFromInternalRoute {
    if ($script:syncingHierarchy) { return }
    $provider = $ProviderCombo.SelectedItem
    $model = $ModelCombo.SelectedItem
    if ($null -eq $provider -or $null -eq $model) { return }

    $entries = @(Get-HierarchyRouteEntries)
    $vendor = Get-HierarchyVendor $model
    $family = Get-HierarchyFamily $model
    $modelId = [string]$model.id
    $providerId = [string]$provider.id
    $effort = if ($EffortCombo.SelectedItem) { [string]$EffortCombo.SelectedItem } else { "high" }

    $script:syncingHierarchy = $true
    try {
        $vendors = @($entries | ForEach-Object { $_.Vendor } | Sort-Object -Unique)
        $VendorCombo.ItemsSource = $vendors
        $VendorCombo.SelectedItem = $vendor

        $families = @($entries | Where-Object { $_.Vendor -eq $vendor } | ForEach-Object { $_.Family } | Sort-Object -Unique)
        $FamilyCombo.ItemsSource = $families
        $FamilyCombo.SelectedItem = $family

        $variants = @($entries | Where-Object { $_.Vendor -eq $vendor -and $_.Family -eq $family } | Sort-Object Variant, ProviderId)
        $VariantCombo.ItemsSource = $variants
        $VariantCombo.SelectedItem = @($variants | Where-Object { $_.ProviderId -eq $providerId -and $_.ModelId -eq $modelId }) | Select-Object -First 1

        Set-HierarchyPerformanceOptions -Model $model -Preferred $effort
    }
    finally { $script:syncingHierarchy = $false }
}

function Rebuild-HierarchyAfterVendorChange {
    if ($script:syncingHierarchy -or $null -eq $VendorCombo.SelectedItem) { return }
    $entries = @(Get-HierarchyRouteEntries)
    $vendor = [string]$VendorCombo.SelectedItem
    $entry = $null

    $script:syncingHierarchy = $true
    try {
        $families = @($entries | Where-Object { $_.Vendor -eq $vendor } | ForEach-Object { $_.Family } | Sort-Object -Unique)
        $FamilyCombo.ItemsSource = $families
        $FamilyCombo.SelectedItem = @($families) | Select-Object -First 1
        $family = [string]$FamilyCombo.SelectedItem
        $variants = @($entries | Where-Object { $_.Vendor -eq $vendor -and $_.Family -eq $family } | Sort-Object Variant, ProviderId)
        $VariantCombo.ItemsSource = $variants
        $VariantCombo.SelectedItem = @($variants) | Select-Object -First 1
        $entry = $VariantCombo.SelectedItem
    }
    finally { $script:syncingHierarchy = $false }

    if ($null -ne $entry) { Select-HierarchyRouteEntry $entry }
}

function Rebuild-HierarchyAfterFamilyChange {
    if ($script:syncingHierarchy -or $null -eq $VendorCombo.SelectedItem -or $null -eq $FamilyCombo.SelectedItem) { return }
    $entries = @(Get-HierarchyRouteEntries)
    $vendor = [string]$VendorCombo.SelectedItem
    $family = [string]$FamilyCombo.SelectedItem
    $entry = $null

    $script:syncingHierarchy = $true
    try {
        $variants = @($entries | Where-Object { $_.Vendor -eq $vendor -and $_.Family -eq $family } | Sort-Object Variant, ProviderId)
        $VariantCombo.ItemsSource = $variants
        $VariantCombo.SelectedItem = @($variants) | Select-Object -First 1
        $entry = $VariantCombo.SelectedItem
    }
    finally { $script:syncingHierarchy = $false }

    if ($null -ne $entry) { Select-HierarchyRouteEntry $entry }
}

function New-ModelCard($ProviderObject, $ModelObject) {
    $providerHealth = Get-ProviderHealth ([string]$ProviderObject.id)
    $modelStatus = Get-ModelCardStatus $ModelObject
    $providerReady = ($null -ne $providerHealth -and [string]$providerHealth.status -ne "BLOCK")
    $sourceText = if ($ModelObject.PSObject.Properties["source"] -and [string]$ModelObject.source -eq "approved_registry") { "动态批准" } else { "受控目录" }
    $brand = Get-ModelBrand $ModelObject
    $vendor = Get-HierarchyVendor $ModelObject
    $family = Get-HierarchyFamily $ModelObject
    $variant = Get-HierarchyVariant $ModelObject
    $levels = @(Get-HierarchyPerformanceLevels $ModelObject)
    $maxRank = Get-ModelMaxPerformanceRank $ModelObject
    $inputPrice = Get-NullablePrice -Model $ModelObject -PropertyName "price_input"
    $outputPrice = Get-NullablePrice -Model $ModelObject -PropertyName "price_output"

    return [pscustomobject]@{
        ProviderId = [string]$ProviderObject.id
        ProviderLabel = [string]$ProviderObject.label
        Id = [string]$ModelObject.id
        Label = [string]$ModelObject.label
        Brand = $brand
        Vendor = $vendor
        Family = $family
        Variant = $variant
        HierarchyLine = "$vendor → $family → $variant"
        ProviderLine = "调用渠道：$($ProviderObject.label)"
        PerformanceText = "性能：" + (@($levels | ForEach-Object { Get-PerformanceLabel $_ }) -join " / ")
        PerformanceRank = $maxRank
        PriceText = Format-ModelReferencePrice $ModelObject
        PriceInputKnown = if ($null -eq $inputPrice) { 1 } else { 0 }
        PriceInputSort = if ($null -eq $inputPrice) { [double]::PositiveInfinity } else { [double]$inputPrice }
        PriceOutputKnown = if ($null -eq $outputPrice) { 1 } else { 0 }
        PriceOutputSort = if ($null -eq $outputPrice) { [double]::PositiveInfinity } else { [double]$outputPrice }
        StatusText = [string]$modelStatus.Text
        StatusColor = [string]$modelStatus.Color
        ReadyText = if ($providerReady) { "● Provider 就绪" } else { "● Provider 未就绪" }
        ReadyColor = if ($providerReady) { "#2DD4A3" } else { "#FF6B81" }
        SourceText = $sourceText
        Monogram = Get-Monogram -Brand $brand -ModelId ([string]$ModelObject.id)
        IconBackground = Get-ModelIconBackground -Brand $brand -ModelId ([string]$ModelObject.id)
        RawStatus = [string]$ModelObject.status
    }
}

function Refresh-ModelCards {
    if ($null -eq $script:catalog) { return }

    $currentProvider = if ($ProviderCombo.SelectedItem) { [string]$ProviderCombo.SelectedItem.id } else { "" }
    $currentModel = if ($ModelCombo.SelectedItem) { [string]$ModelCombo.SelectedItem.id } else { "" }

    $cards = New-Object System.Collections.Generic.List[object]
    foreach ($provider in @($script:catalog.providers)) {
        foreach ($model in @($provider.models)) {
            $cards.Add((New-ModelCard -ProviderObject $provider -ModelObject $model))
        }
    }

    switch ($script:modelSortMode) {
        "input-asc" { $sorted = @($cards | Sort-Object @{Expression={$_.PriceInputKnown};Ascending=$true}, @{Expression={$_.PriceInputSort};Ascending=$true}, Vendor, Family, Variant) }
        "input-desc" { $sorted = @($cards | Sort-Object @{Expression={$_.PriceInputKnown};Ascending=$true}, @{Expression={$_.PriceInputSort};Descending=$true}, Vendor, Family, Variant) }
        "output-asc" { $sorted = @($cards | Sort-Object @{Expression={$_.PriceOutputKnown};Ascending=$true}, @{Expression={$_.PriceOutputSort};Ascending=$true}, Vendor, Family, Variant) }
        "output-desc" { $sorted = @($cards | Sort-Object @{Expression={$_.PriceOutputKnown};Ascending=$true}, @{Expression={$_.PriceOutputSort};Descending=$true}, Vendor, Family, Variant) }
        "performance-desc" { $sorted = @($cards | Sort-Object @{Expression={$_.PerformanceRank};Descending=$true}, Vendor, Family, Variant) }
        default { $sorted = @($cards | Sort-Object Vendor, Family, Variant, ProviderLabel) }
    }

    $script:modelCards = @($sorted)
    $DashboardModelList.ItemsSource = $script:modelCards
    $ModelsModelList.ItemsSource = $script:modelCards

    if (-not [string]::IsNullOrWhiteSpace($currentProvider) -and -not [string]::IsNullOrWhiteSpace($currentModel)) {
        $match = @($script:modelCards | Where-Object { $_.ProviderId -eq $currentProvider -and $_.Id -eq $currentModel }) | Select-Object -First 1
        if ($null -ne $match) {
            $DashboardModelList.SelectedItem = $match
            $ModelsModelList.SelectedItem = $match
        }
    }
}

function Refresh-RouteSelectors {
    $state = Load-VisualState
    $provider = if ($state.PSObject.Properties["last_provider"]) { [string]$state.last_provider } else { "chatgpt" }
    $brand = if ($state.PSObject.Properties["last_brand"]) { [string]$state.last_brand } else { "OpenAI" }
    $model = if ($state.PSObject.Properties["last_model_id"]) { [string]$state.last_model_id } else { "__account_default__" }
    $effort = if ($state.PSObject.Properties["last_effort"]) { [string]$state.last_effort } else { "high" }
    if ($effort -notin @("low","medium","high","xhigh","max")) { $effort = "high" }
    $EffortCombo.ItemsSource = @("low","medium","high","xhigh","max")
    $EffortCombo.SelectedItem = $effort
    Refresh-ProviderSelection -PreferredProvider $provider -PreferredBrand $brand -PreferredModel $model
}

function Update-SelectedRouteUI {
    if ($script:loadingRoute) { return }
    $provider = $ProviderCombo.SelectedItem
    $model = $ModelCombo.SelectedItem
    if ($null -eq $provider -or $null -eq $model) {
        $HeroModelName.Text = "请选择模型"
        $HeroModelMeta.Text = "厂商 / 模型系列 / 版本尚未选择"
        return
    }

    $providerHealth = Get-ProviderHealth ([string]$provider.id)
    $modelState = Convert-ControllerModelStatus ([string]$model.status)
    $vendor = Get-HierarchyVendor $model
    $family = Get-HierarchyFamily $model
    $variant = Get-HierarchyVariant $model
    $effort = if ($EffortCombo.SelectedItem) { [string]$EffortCombo.SelectedItem } else { "medium" }
    $performanceLabel = Get-PerformanceLabel $effort
    $priceText = Format-ModelReferencePrice $model

    $HeroModelName.Text = if ($variant -in @("Standard","自动")) { $family } else { "$family · $variant" }
    $HeroModelMeta.Text = "$vendor · 性能 $performanceLabel · $priceText · $($provider.label)"
    $HeroStatusBadge.Text = ([string]$modelState.text).ToUpperInvariant()
    $HeroStatusBadge.Foreground = Get-ColorBrush ([string]$modelState.color)

    if ($null -ne $providerHealth -and [string]$providerHealth.status -eq "BLOCK") {
        $HeroReadyBadge.Text = "Provider 未就绪"
        $HeroReadyBadge.Foreground = Get-ColorBrush "#FF6B81"
        $LaunchCurrentButton.IsEnabled = $false
        $ModelsLaunchButton.IsEnabled = $false
        $HierarchyLaunchButton.IsEnabled = $false
    }
    else {
        $HeroReadyBadge.Text = "Provider 可启动"
        $HeroReadyBadge.Foreground = Get-ColorBrush "#2DD4A3"
        $LaunchCurrentButton.IsEnabled = $true
        $ModelsLaunchButton.IsEnabled = $true
        $HierarchyLaunchButton.IsEnabled = $true
    }

    $SelectedRouteText.Text = "选择：$vendor → $family → $variant → 性能 $performanceLabel · $priceText · 后台 Provider：$($provider.label) · $([string]$model.id)"

    $card = @($script:modelCards | Where-Object { $_.ProviderId -eq [string]$provider.id -and $_.Id -eq [string]$model.id }) | Select-Object -First 1
    if ($null -ne $card) {
        $DashboardModelList.SelectedItem = $card
        $ModelsModelList.SelectedItem = $card
    }

    Sync-HierarchySelectorsFromInternalRoute
}

function Apply-CardSelection($Card) {
    if ($null -eq $Card) { return }
    $entry = @(Get-HierarchyRouteEntries | Where-Object { $_.ProviderId -eq [string]$Card.ProviderId -and $_.ModelId -eq [string]$Card.Id }) | Select-Object -First 1
    if ($null -ne $entry) { Select-HierarchyRouteEntry $entry }
}

# Replace the old flat model card template with hierarchy-aware cards.
$modelCardTemplateXaml = @'
<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border Width="36" Height="36" CornerRadius="10" Background="{Binding IconBackground}">
        <TextBlock Text="{Binding Monogram}" FontSize="18" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Grid.Column="1" Margin="10,0,0,0">
        <TextBlock Text="{Binding Family}" FontSize="14" FontWeight="SemiBold" Foreground="#F5F7FE" TextTrimming="CharacterEllipsis"/>
        <TextBlock Text="{Binding Variant}" FontSize="12" FontWeight="SemiBold" Foreground="#B9C6DC" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </Grid>
    <TextBlock Text="{Binding Vendor}" Foreground="#8391AA" FontSize="10" Margin="0,10,0,0" TextTrimming="CharacterEllipsis"/>
    <TextBlock Text="{Binding PerformanceText}" Foreground="#A99CFF" FontSize="10" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/>
    <TextBlock Text="{Binding PriceText}" Foreground="#E9EEFA" FontSize="10" Margin="0,5,0,0" TextWrapping="Wrap"/>
    <TextBlock Text="{Binding ProviderLine}" Foreground="#71809C" FontSize="9" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/>
    <Grid Margin="0,10,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock Text="{Binding ReadyText}" Foreground="{Binding ReadyColor}" FontSize="10" FontWeight="SemiBold"/>
      <TextBlock Grid.Column="1" Text="{Binding SourceText}" Foreground="#6F7D96" FontSize="9"/>
    </Grid>
  </StackPanel>
</DataTemplate>
'@
$hierarchyCardTemplate = [Windows.Markup.XamlReader]::Parse($modelCardTemplateXaml)
$DashboardModelList.ItemTemplate = $hierarchyCardTemplate
$ModelsModelList.ItemTemplate = $hierarchyCardTemplate

# Hide the old Provider/Brand/Model selector card. Provider still exists internally
# for routing, but the visible selector follows the user-facing hierarchy.
$legacySelectorGrid = $ModelsLaunchButton.Parent
$legacySelectorBorder = if ($null -ne $legacySelectorGrid) { $legacySelectorGrid.Parent } else { $null }
$modelsPageStack = if ($null -ne $legacySelectorBorder) { $legacySelectorBorder.Parent } else { $null }
if ($null -ne $legacySelectorBorder) { $legacySelectorBorder.Visibility = [System.Windows.Visibility]::Collapsed }

$HierarchySelectorBorder = New-Object System.Windows.Controls.Border
$HierarchySelectorBorder.Style = $window.FindResource("Card")
$HierarchySelectorBorder.Margin = [System.Windows.Thickness]::new(0,0,0,16)

$HierarchyGrid = New-Object System.Windows.Controls.Grid
foreach ($width in @("1.05*","1.1*","1.0*","0.8*","Auto")) {
    $definition = New-Object System.Windows.Controls.ColumnDefinition
    $definition.Width = New-Object System.Windows.GridLengthConverter | ForEach-Object { $_.ConvertFromString($width) }
    $HierarchyGrid.ColumnDefinitions.Add($definition)
}

function Add-HierarchyComboColumn([int]$Column, [string]$Label, $Combo) {
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = [System.Windows.Thickness]::new(0,0,10,0)
    [System.Windows.Controls.Grid]::SetColumn($panel, $Column)
    $caption = New-Object System.Windows.Controls.TextBlock
    $caption.Text = $Label
    $caption.FontSize = 10
    $caption.Foreground = Get-ColorBrush "#7C8BA5"
    $caption.Margin = [System.Windows.Thickness]::new(0,0,0,5)
    $panel.Children.Add($caption) | Out-Null
    $Combo.Style = $window.FindResource("DarkCombo")
    $panel.Children.Add($Combo) | Out-Null
    $HierarchyGrid.Children.Add($panel) | Out-Null
}

$script:VendorCombo = New-Object System.Windows.Controls.ComboBox
$script:FamilyCombo = New-Object System.Windows.Controls.ComboBox
$script:VariantCombo = New-Object System.Windows.Controls.ComboBox
$VariantCombo.DisplayMemberPath = "Display"
$script:PerformanceCombo = New-Object System.Windows.Controls.ComboBox
$PerformanceCombo.DisplayMemberPath = "Label"
$script:HierarchyLaunchButton = New-Object System.Windows.Controls.Button
$HierarchyLaunchButton.Content = "启动"
$HierarchyLaunchButton.Style = $window.FindResource("PrimaryButton")
$HierarchyLaunchButton.MinWidth = 110
$HierarchyLaunchButton.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
[System.Windows.Controls.Grid]::SetColumn($HierarchyLaunchButton, 4)

Add-HierarchyComboColumn 0 "厂商" $VendorCombo
Add-HierarchyComboColumn 1 "模型系列" $FamilyCombo
Add-HierarchyComboColumn 2 "版本型号" $VariantCombo
Add-HierarchyComboColumn 3 "性能" $PerformanceCombo
$HierarchyGrid.Children.Add($HierarchyLaunchButton) | Out-Null
$HierarchySelectorBorder.Child = $HierarchyGrid

if ($modelsPageStack -is [System.Windows.Controls.StackPanel]) {
    $insertIndex = $modelsPageStack.Children.IndexOf($legacySelectorBorder)
    if ($insertIndex -lt 0) { $insertIndex = 1 }
    $modelsPageStack.Children.Insert($insertIndex, $HierarchySelectorBorder)
}

# Sorting controls are mirrored on Dashboard and Model Management.
$sortItems = @(
    [pscustomobject]@{Id="hierarchy";Label="厂商 / 系列 / 版本"},
    [pscustomobject]@{Id="input-asc";Label="输入价：低 → 高"},
    [pscustomobject]@{Id="input-desc";Label="输入价：高 → 低"},
    [pscustomobject]@{Id="output-asc";Label="输出价：低 → 高"},
    [pscustomobject]@{Id="output-desc";Label="输出价：高 → 低"},
    [pscustomobject]@{Id="performance-desc";Label="性能：高 → 低"}
)

function New-ModelSortCombo {
    $combo = New-Object System.Windows.Controls.ComboBox
    $combo.Style = $window.FindResource("DarkCombo")
    $combo.Width = 178
    $combo.Height = 36
    $combo.DisplayMemberPath = "Label"
    $combo.ItemsSource = $sortItems
    $combo.SelectedItem = $sortItems[0]
    return $combo
}

$script:DashboardSortCombo = New-ModelSortCombo
$script:ModelsSortCombo = New-ModelSortCombo

function Install-SortComboNextToButton($Button, $Combo) {
    $grid = $Button.Parent
    if (-not ($grid -is [System.Windows.Controls.Grid])) { return }
    $grid.Children.Remove($Button)
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $panel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $Combo.Margin = [System.Windows.Thickness]::new(0,0,8,0)
    $panel.Children.Add($Combo) | Out-Null
    $panel.Children.Add($Button) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($panel, 1)
    $grid.Children.Add($panel) | Out-Null
}

Install-SortComboNextToButton $ReloadCatalogButton $DashboardSortCombo
Install-SortComboNextToButton $ModelsReloadButton $ModelsSortCombo

# Clarify that the visible model hierarchy is independent of the Provider route.
if ($null -ne $ModelsReloadButton.Parent -and $ModelsReloadButton.Parent.Parent -is [System.Windows.Controls.StackPanel]) {
    # Header text remains managed by XAML; route details below show the hidden Provider.
}

$VendorCombo.Add_SelectionChanged({ if (-not $script:syncingHierarchy) { Rebuild-HierarchyAfterVendorChange } })
$FamilyCombo.Add_SelectionChanged({ if (-not $script:syncingHierarchy) { Rebuild-HierarchyAfterFamilyChange } })
$VariantCombo.Add_SelectionChanged({
    if (-not $script:syncingHierarchy -and $null -ne $VariantCombo.SelectedItem) {
        Select-HierarchyRouteEntry $VariantCombo.SelectedItem
    }
})
$PerformanceCombo.Add_SelectionChanged({
    if ($script:syncingHierarchy -or $null -eq $PerformanceCombo.SelectedItem) { return }
    $selectedId = [string]$PerformanceCombo.SelectedItem.Id
    $script:loadingRoute = $true
    try { $EffortCombo.SelectedItem = $selectedId }
    finally { $script:loadingRoute = $false }
    Update-SelectedRouteUI
})
$HierarchyLaunchButton.Add_Click({ Start-SelectedModel })

function Apply-ModelSortSelection($Combo, $OtherCombo) {
    if ($script:syncingSort -or $null -eq $Combo.SelectedItem) { return }
    $script:syncingSort = $true
    try {
        $script:modelSortMode = [string]$Combo.SelectedItem.Id
        $OtherCombo.SelectedItem = @($sortItems | Where-Object { $_.Id -eq $script:modelSortMode }) | Select-Object -First 1
    }
    finally { $script:syncingSort = $false }
    Refresh-ModelCards
}

$DashboardSortCombo.Add_SelectionChanged({ Apply-ModelSortSelection $DashboardSortCombo $ModelsSortCombo })
$ModelsSortCombo.Add_SelectionChanged({ Apply-ModelSortSelection $ModelsSortCombo $DashboardSortCombo })

# Keep the hidden compatibility selector capable of xhigh and max even though the
# visible Performance selector is now the primary control.
$EffortCombo.ItemsSource = @("low","medium","high","xhigh","max")
