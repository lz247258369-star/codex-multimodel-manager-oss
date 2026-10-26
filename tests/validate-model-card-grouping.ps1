param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
$runtimePath = Join-Path $RepositoryRoot "installer/scripts/visual-card-grouping-runtime.ps1"
$loaderPath = Join-Path $RepositoryRoot "installer/scripts/visual-sidebar-readability.ps1"
$removedFlatRuntimePath = Join-Path $RepositoryRoot "installer/scripts/visual-card-grouping-safe-controls.ps1"

if (-not (Test-Path -LiteralPath $runtimePath)) { throw "Missing model-card grouping runtime: $runtimePath" }
if (-not (Test-Path -LiteralPath $loaderPath)) { throw "Missing grouping runtime loader: $loaderPath" }
if (Test-Path -LiteralPath $removedFlatRuntimePath) { throw "Removed flat-mode runtime must not exist: $removedFlatRuntimePath" }

$runtime = Get-Content -Raw -LiteralPath $runtimePath
$loader = Get-Content -Raw -LiteralPath $loaderPath
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($runtimePath, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) { throw "Model-card grouping runtime parse failed: $($errors[0].Message)" }

$requiredMarkers = @(
    'modelCardGroupingMode = "vendor"',
    'PropertyGroupDescription]::new("Vendor")',
    'Toggle-AllModelGroups',
    'Set-AllModelGroupsExpanded',
    'New-IsolatedModelListView',
    'ListCollectionView',
    'New-ModelMatrixItemsPanel',
    'DashboardGroupToggleButton',
    'ModelsGroupToggleButton',
    'Expand-SelectedModelGroup',
    'RefreshModelCardsBeforeGrouping',
    'UpdateSelectedRouteUIBeforeGrouping',
    'StringFormat={}{0} 个模型',
    'Text="{Binding Name}"',
    'GroupStyle.Panel controls how Vendor GroupItems are arranged',
    'ListBox ItemsPanel is used by each GroupItem',
    'AncestorType={x:Type ListBox}',
    'Path=ActualWidth'
)
foreach ($marker in $requiredMarkers) {
    if (-not $runtime.Contains($marker)) { throw "Missing vendor grouping marker: $marker" }
}

$forbiddenMarkers = @(
    '平铺全部模型',
    'Set-ModelGroupingMode',
    'New-GroupingModeCombo',
    'DashboardGroupingModeCombo',
    'ModelsGroupingModeCombo',
    'modelMatrixDisplayMode',
    'New-FlatModelList',
    'DashboardFlatModelList',
    'ModelsFlatModelList',
    'visual-card-grouping-safe-controls.ps1',
    'PropertyGroupDescription]::new("Family")'
)
foreach ($marker in $forbiddenMarkers) {
    if ($runtime.Contains($marker) -or $loader.Contains($marker)) {
        throw "Removed flat/grouping-mode capability leaked back into V4: $marker"
    }
}

if (-not $loader.Contains('visual-card-grouping-runtime.ps1')) { throw "V4 runtime chain does not load vendor grouping runtime." }

# Parse the actual Vendor GroupStyle with WPF so namespace/template errors are caught.
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
$styleMatch = [regex]::Match($runtime, '(?ms)\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
if (-not $styleMatch.Success) { throw "Could not locate vendor grouping Style XAML here-string." }
try {
    $parsedStyle = [Windows.Markup.XamlReader]::Parse($styleMatch.Groups['xaml'].Value)
}
catch {
    throw "Vendor grouping Style WPF XAML parse failed: $($_.Exception.Message)"
}
if (-not ($parsedStyle -is [System.Windows.Style])) { throw "Vendor grouping Style did not parse to System.Windows.Style." }

# Reproduce the real PowerShell 7 STA host used by V4. Render six vendors,
# verify one vendor per row, verify the toolbar contains only the combined toggle
# plus the existing sort selector, and exercise expand/collapse repeatedly.
$env:MM_GROUPING_TEST_ROOT = $RepositoryRoot
$staTest = Join-Path $env:TEMP ("mm-vendor-only-grouping-{0}.ps1" -f ([Guid]::NewGuid().ToString("N")))
@'
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore

$repo = $env:MM_GROUPING_TEST_ROOT
$runtimePath = Join-Path $repo "installer/scripts/visual-card-grouping-runtime.ps1"

$window = [System.Windows.Window]::new()
$window.Width = 980
$window.Height = 720
$window.Resources.Add("SoftButton", [System.Windows.Style]::new([System.Windows.Controls.Button]))

$dashboardToolbar = [System.Windows.Controls.StackPanel]::new()
$dashboardToolbar.Orientation = [System.Windows.Controls.Orientation]::Horizontal
$modelsToolbar = [System.Windows.Controls.StackPanel]::new()
$modelsToolbar.Orientation = [System.Windows.Controls.Orientation]::Horizontal
$DashboardSortCombo = [System.Windows.Controls.ComboBox]::new()
$ModelsSortCombo = [System.Windows.Controls.ComboBox]::new()
[void]$dashboardToolbar.Children.Add($DashboardSortCombo)
[void]$modelsToolbar.Children.Add($ModelsSortCombo)

$DashboardModelList = [System.Windows.Controls.ListBox]::new()
$DashboardModelList.Width = 900
$DashboardModelList.Height = 560
$ModelsModelList = [System.Windows.Controls.ListBox]::new()
$ProviderCombo = [System.Windows.Controls.ComboBox]::new()
$ModelCombo = [System.Windows.Controls.ComboBox]::new()

$provider = [pscustomobject]@{ id = "p1" }
$model = [pscustomobject]@{ id = "m1"; vendor = "Alibaba / Qwen" }
$ProviderCombo.ItemsSource = @($provider)
$ProviderCombo.SelectedItem = $provider
$ModelCombo.ItemsSource = @($model)
$ModelCombo.SelectedItem = $model

$script:modelCards = @(
    [pscustomobject]@{ ProviderId="p1"; Id="m1"; Vendor="Alibaba / Qwen" },
    [pscustomobject]@{ ProviderId="p1"; Id="m2"; Vendor="Alibaba / Qwen" },
    [pscustomobject]@{ ProviderId="p2"; Id="m3"; Vendor="DeepSeek" },
    [pscustomobject]@{ ProviderId="p3"; Id="m4"; Vendor="OpenAI" },
    [pscustomobject]@{ ProviderId="p4"; Id="m5"; Vendor="Stealth / Unknown" },
    [pscustomobject]@{ ProviderId="p5"; Id="m6"; Vendor="Xiaomi" },
    [pscustomobject]@{ ProviderId="p6"; Id="m7"; Vendor="Z.ai" }
)
$DashboardModelList.ItemsSource = $script:modelCards
$ModelsModelList.ItemsSource = $script:modelCards
$script:loadingRoute = $false

function Get-HierarchyVendor($Model) { return [string]$Model.vendor }
function Refresh-ModelCards { }
function Update-SelectedRouteUI { }

. $runtimePath

if ($script:modelCardGroupingMode -ne "vendor") { throw "Model matrix must remain vendor-only." }
if (-not ($DashboardModelList.ItemsSource -is [System.Windows.Data.ListCollectionView])) { throw "Dashboard must use an isolated ListCollectionView." }
if ($DashboardModelList.ItemsSource.GroupDescriptions.Count -ne 1) { throw "Vendor-only mode must have exactly one GroupDescription." }
if (-not ($DashboardModelList.ItemsPanel.LoadContent() -is [System.Windows.Controls.WrapPanel])) { throw "Expanded vendor must wrap model cards." }
if ($DashboardModelList.GroupStyle.Count -ne 1) { throw "Vendor mode must install exactly one GroupStyle." }
if (-not ($DashboardModelList.GroupStyle[0].Panel.LoadContent() -is [System.Windows.Controls.StackPanel])) { throw "Vendor GroupStyle.Panel must be a vertical StackPanel." }
if ($DashboardGroupToggleButton.Content -ne "全部展开") { throw "Combined group toggle must start at 全部展开." }
if ($dashboardToolbar.Children.Count -ne 2) { throw "Dashboard toolbar should contain only expand/collapse toggle plus sort selector." }
if (-not ($dashboardToolbar.Children[0] -is [System.Windows.Controls.Button])) { throw "First Dashboard grouping control must be the combined toggle button." }
if (-not [object]::ReferenceEquals($dashboardToolbar.Children[1],$DashboardSortCombo)) { throw "Sort selector must remain after the combined toggle button." }

$window.Content = $DashboardModelList
$window.Show()
$DashboardModelList.UpdateLayout()
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
$DashboardModelList.UpdateLayout()

$vendorExpanders = @(Get-VisualExpanders $DashboardModelList)
if ($vendorExpanders.Count -ne 6) { throw "Expected 6 rendered vendor rows, got $($vendorExpanders.Count)." }
$minimumVendorWidth = $DashboardModelList.ActualWidth * 0.90
$lastY = -1.0
foreach ($expander in $vendorExpanders) {
    if ($expander.ActualWidth -lt $minimumVendorWidth) {
        throw "Vendor row rendered too narrow ($([math]::Round($expander.ActualWidth,1))px of $([math]::Round($DashboardModelList.ActualWidth,1))px)."
    }
    $point = $expander.TranslatePoint([System.Windows.Point]::new(0,0), $DashboardModelList)
    if ($point.Y -le ($lastY + 1.0)) {
        throw "Vendor groups share one visual row. Expected a strict single-column stack."
    }
    $lastY = $point.Y
}

for ($i = 0; $i -lt 10; $i++) {
    Toggle-AllModelGroups
    $expected = if (($i % 2) -eq 0) { "全部收起" } else { "全部展开" }
    if ($DashboardGroupToggleButton.Content -ne $expected) { throw "Combined toggle label mismatch on iteration $i." }
    if ($DashboardModelList.ItemsSource.GroupDescriptions.Count -ne 1) { throw "Vendor grouping disappeared during expand/collapse iteration $i." }
}

$window.Close()
Write-Host "Vendor-only single-column grouping PASS" -ForegroundColor Green
'@ | Set-Content -LiteralPath $staTest -Encoding utf8BOM

try {
    & pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File $staTest
    if ($LASTEXITCODE -ne 0) { throw "Vendor-only single-column grouping failed with exit code $LASTEXITCODE." }
}
finally {
    Remove-Item -LiteralPath $staTest -Force -ErrorAction SilentlyContinue
    Remove-Item Env:MM_GROUPING_TEST_ROOT -ErrorAction SilentlyContinue
}

Write-Host "Vendor-only model-card grouping validation PASS" -ForegroundColor Green
