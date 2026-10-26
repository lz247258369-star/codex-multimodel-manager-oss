$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

function Get-CodexHome {
    if ($env:CODEX_HOME -and -not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { return $env:CODEX_HOME }
    return (Join-Path $HOME ".codex")
}

function Get-ManagerHome {
    $path = Join-Path (Get-CodexHome) "multimodel-manager"
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    return $path
}

function Get-VisualStatePath {
    return (Join-Path (Get-ManagerHome) "visual-console-state.json")
}

function Load-VisualState {
    $path = Get-VisualStatePath
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{} }
    try { return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json) }
    catch { return [pscustomobject]@{} }
}

function Save-VisualState(
    [string]$WorkspacePath,
    [string]$ProviderId,
    [string]$Brand,
    [string]$ModelId,
    [string]$ModelLabel,
    [string]$Effort
) {
    $path = Get-VisualStatePath
    $merged = [ordered]@{}
    $known = @("last_workspace","last_provider","last_brand","last_model_id","last_model_label","last_effort","saved_at")
    $existing = $null
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { $existing = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { $existing = $null }
    }
    if ($null -ne $existing) {
        foreach ($property in $existing.PSObject.Properties) {
            if ($property.Name -notin $known) {
                $merged[$property.Name] = $property.Value
            }
        }
    }
    $merged["last_workspace"] = $WorkspacePath
    $merged["last_provider"] = $ProviderId
    $merged["last_brand"] = $Brand
    $merged["last_model_id"] = $ModelId
    $merged["last_model_label"] = $ModelLabel
    $merged["last_effort"] = $Effort
    $merged["saved_at"] = (Get-Date -Format "o")
    $tempPath = $path + ".tmp"
    $merged | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $path -Force
}

function Get-GitInfo([string]$Path) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ IsRepo=$false; Dirty=$false; Branch=""; Head="" }
    }

    & git -C $Path rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ IsRepo=$false; Dirty=$false; Branch=""; Head="" }
    }

    $branch = ((& git -C $Path branch --show-current 2>$null) | Out-String).Trim()
    $head = ((& git -C $Path rev-parse --short=10 HEAD 2>$null) | Out-String).Trim()
    $status = ((& git -C $Path status --short 2>$null) | Out-String).Trim()

    return [pscustomobject]@{
        IsRepo = $true
        Dirty = (-not [string]::IsNullOrWhiteSpace($status))
        Branch = $branch
        Head = $head
    }
}

function Get-WorkspaceCandidates {
    $items = New-Object System.Collections.Generic.List[string]
    $state = Load-VisualState

    if ($state.PSObject.Properties["last_workspace"]) {
        $saved = [string]$state.last_workspace
        if (-not [string]::IsNullOrWhiteSpace($saved) -and (Test-Path -LiteralPath $saved)) {
            $gitInfo = Get-GitInfo $saved
            if ($gitInfo.IsRepo) { $items.Add((Resolve-Path -LiteralPath $saved).Path) }
        }
    }

    if ($PWD.Provider.Name -eq "FileSystem" -and (Test-Path -LiteralPath $PWD.Path) -and $PWD.Path -notmatch '(?i)\\Windows\\System32$') {
        $gitInfo = Get-GitInfo $PWD.Path
        if ($gitInfo.IsRepo -and $PWD.Path -notin $items) { $items.Add($PWD.Path) }
    }

    $projectsRoot = Join-Path $HOME "Projects"
    if (Test-Path -LiteralPath $projectsRoot) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $projectsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $gitInfo = Get-GitInfo $directory.FullName
            if ($gitInfo.IsRepo -and $directory.FullName -notin $items) { $items.Add($directory.FullName) }
        }
    }

    return @($items)
}

function Resolve-InitialWorkspace {
    $state = Load-VisualState
    if ($state.PSObject.Properties["last_workspace"]) {
        $saved = [string]$state.last_workspace
        if (-not [string]::IsNullOrWhiteSpace($saved) -and (Test-Path -LiteralPath $saved)) {
            $gitInfo = Get-GitInfo $saved
            if ($gitInfo.IsRepo) { return (Resolve-Path -LiteralPath $saved).Path }
        }
    }

    $candidates = @(Get-WorkspaceCandidates)
    if ($candidates.Count -gt 0) { return [string]$candidates[0] }

    $projectsRoot = Join-Path $HOME "Projects"
    if (Test-Path -LiteralPath $projectsRoot) { return $projectsRoot }
    return $HOME
}

function Quote-ProcessArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"','\"') + '"'
}

function Start-PwshScript([string]$ScriptPath, [string]$WorkingDirectory, [hashtable]$NamedArgs = @{}) {
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        [System.Windows.MessageBox]::Show("脚本不存在：`n$ScriptPath", "Codex Multi-Model Manager", "OK", "Error") | Out-Null
        return
    }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($part in @("-NoExit","-NoProfile","-ExecutionPolicy","Bypass","-File",(Quote-ProcessArgument $ScriptPath))) {
        $parts.Add($part)
    }
    foreach ($name in $NamedArgs.Keys) {
        $parts.Add("-$name")
        $parts.Add((Quote-ProcessArgument ([string]$NamedArgs[$name])))
    }

    Start-Process -FilePath "pwsh.exe" -WorkingDirectory $WorkingDirectory -ArgumentList ($parts -join " ") | Out-Null
}

function Get-ColorBrush([string]$Color) {
    return (New-Object Windows.Media.BrushConverter).ConvertFromString($Color)
}

function Get-Monogram([string]$Brand, [string]$ModelId) {
    $text = ("$Brand $ModelId").ToLowerInvariant()
    if ($text -match 'openai|gpt') { return "O" }
    if ($text -match 'mimo') { return "M" }
    if ($text -match 'qwen') { return "Q" }
    if ($text -match 'deepseek') { return "D" }
    if ($text -match 'glm|z-ai') { return "G" }
    if ($text -match 'ox-alpha|stealth') { return "α" }
    if ($text -match 'claude') { return "C" }
    if ($text -match 'gemini') { return "G" }
    if ($text -match 'kimi|moonshot') { return "K" }
    return "AI"
}

function Get-ModelIconBackground([string]$Brand, [string]$ModelId) {
    $text = ("$Brand $ModelId").ToLowerInvariant()
    if ($text -match 'openai|gpt') { return "#1A7F68" }
    if ($text -match 'mimo') { return "#E76F32" }
    if ($text -match 'qwen') { return "#6657FF" }
    if ($text -match 'deepseek') { return "#2563EB" }
    if ($text -match 'glm|z-ai') { return "#7C3AED" }
    if ($text -match 'ox-alpha|stealth') { return "#5B4FD8" }
    if ($text -match 'claude') { return "#A1604B" }
    if ($text -match 'gemini') { return "#3B82F6" }
    if ($text -match 'kimi|moonshot') { return "#202936" }
    return "#42526E"
}

$catalogHelper = Join-Path $PSScriptRoot "controller-catalog.ps1"
$healthHelper = Join-Path $PSScriptRoot "controller-health.ps1"
if (-not (Test-Path -LiteralPath $catalogHelper)) { throw "Missing controller catalog helper: $catalogHelper" }
if (-not (Test-Path -LiteralPath $healthHelper)) { throw "Missing controller health helper: $healthHelper" }
. $catalogHelper
. $healthHelper

$staticCatalogPath = (Resolve-Path (Join-Path $PSScriptRoot "..\model-catalog.json")).Path
$approvedModelsPath = Join-Path (Get-ManagerHome) "approved-models.json"
$configPath = Join-Path (Get-CodexHome) "config.toml"
$launchScript = Join-Path $PSScriptRoot "launch-controller-model.ps1"
$classicControllerScript = Join-Path $PSScriptRoot "desktop-controller.ps1"
$healthScript = Join-Path $PSScriptRoot "health-check.ps1"
$handoffScript = Join-Path $PSScriptRoot "resume-handoff.ps1"
$updateCenterScript = Join-Path $PSScriptRoot "model-update-center.ps1"
$stealthCenterScript = Join-Path $PSScriptRoot "stealth-model-center.ps1"
$setupScript = (Resolve-Path (Join-Path $PSScriptRoot "..\setup.ps1")).Path
$switcherScript = Join-Path $PSScriptRoot "switch-model.ps1"
$xamlPath = (Resolve-Path (Join-Path $PSScriptRoot "..\ui\visual-console.xaml")).Path

[xml]$xaml = Get-Content -Raw -LiteralPath $xamlPath
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$controlNames = @(
    "SidebarStatusDot","SidebarStatusText",
    "NavDashboard","NavModels","NavProviders","NavStealth","NavTools","NavRouter",
    "TopPageTitle","TopPageSubTitle","TopRefreshButton","TopSetupButton","MainTabs",
    "RouterFeatureBadge","RouterRuntimeBadge","RouterOverallText","RouterWarningsText","RouterRefreshButton","RouterRestoreDirectButton",
    "RouterConfiguredText","RouterInFlightText","RouterHealthText","RouterCrossModelText","RouterCircuitBreakerText",
    "RouterFeatureEnableButton","RouterFeatureDisableButton","RouterFeatureMutationText","RouterLifecycleText","RouterMutationStatusText",
    "RouterThreadCapabilityText","RouterThreadReadyText","RouterThreadFeatureEnableButton","RouterThreadFeatureDisableButton",
    "RouterThreadList","RouterThreadDualTruthText","RouterThreadModelCombo","RouterThreadSwitchButton","RouterThreadRestoreButton",
    "RouterThreadCaptureButton","RouterThreadCaptureCancelButton","RouterThreadClearAllButton","RouterThreadCaptureText","RouterThreadStatusText",
    "CliModeText","CliModelText","CliEffortText","CliReadinessText","RouterModelCombo","RouterEffortCombo","RouterModelInfoText",
    "RouterCliEnableButton","RouterCliDisableButton","RouterCliLaunchButton",
    "DesktopModeText","DesktopModelText","DesktopEffortText","DesktopReadinessText","RouterDesktopActivateButton","RouterDesktopRestoreButton",
    "RouterUsageText","RouterCostText","RouterPolicyText","RouterPolicyCombo","RouterPolicyRetryAttemptsBox","RouterPolicyRetrySaveButton","RouterPolicyTimeoutTotalBox","RouterPolicyTimeoutSaveButton","RouterPolicyFailoverProviderCheck","RouterPolicyFailoverSaveButton",
    "RouterRecentText","RouterRecentList","RouterLimitationsText",
    "HeroModelName","HeroModelMeta","HeroStatusBadge","HeroReadyBadge","LaunchCurrentButton","OpenLegacyControllerButton",
    "BrowseButton","RefreshWorkspaceButton","WorkspaceCombo","GitStatusText","LastModelText",
    "CatalogStatusText","ReloadCatalogButton","DashboardModelList",
    "HealthSummaryBadge","HealthSummaryText","DashboardProviderHealthList","RefreshHealthButton",
    "DashboardUpdateCenterButton","DashboardStealthButton","DashboardHealthDetailButton",
    "ModelsReloadButton","ProviderCombo","BrandCombo","ModelCombo","EffortCombo","ModelsLaunchButton","SelectedRouteText","ModelsModelList",
    "ProvidersPageList","ProvidersSetupButton","ProvidersRefreshButton",
    "StealthStatusText","StealthLaunchOxButton","StealthCenterButton",
    "ToolsHealthButton","ToolsHandoffButton","ToolsUpdateCenterButton","ToolsSwitcherButton","ToolsStatusText"
)
foreach ($controlName in $controlNames) {
    Set-Variable -Name $controlName -Scope Script -Value $window.FindName($controlName)
}

$script:catalog = $null
$script:health = $null
$script:modelCards = @()
$script:loadingRoute = $false
$script:loadingWorkspace = $false
$script:providerHealthCards = @()

$EffortCombo.ItemsSource = @("low","medium","high")
$EffortCombo.SelectedItem = "high"

function Set-NavPage([int]$Index, [string]$Title, [string]$Subtitle, $SelectedButton) {
    $MainTabs.SelectedIndex = $Index
    $TopPageTitle.Text = $Title
    $TopPageSubTitle.Text = $Subtitle
    foreach ($button in @($NavDashboard,$NavModels,$NavProviders,$NavStealth,$NavTools,$NavRouter)) {
        $button.Background = Get-ColorBrush "#00000000"
        $button.Foreground = Get-ColorBrush "#C4CEE2"
    }
    $SelectedButton.Background = Get-ColorBrush "#171D45"
    $SelectedButton.Foreground = Get-ColorBrush "#FFFFFF"
}

function Get-ProviderById([string]$ProviderId) {
    if ($null -eq $script:catalog) { return $null }
    return @($script:catalog.providers | Where-Object { [string]$_.id -eq $ProviderId }) | Select-Object -First 1
}

function Get-ModelBrand($ModelObject) {
    if ($null -eq $ModelObject) { return "" }
    if ($ModelObject.PSObject.Properties["brand"] -and -not [string]::IsNullOrWhiteSpace([string]$ModelObject.brand)) {
        return [string]$ModelObject.brand
    }
    return "其他"
}

function Get-ProviderHealth([string]$ProviderId) {
    if ($null -eq $script:health) { return $null }
    return @($script:health.provider_health | Where-Object { [string]$_.id -eq $ProviderId }) | Select-Object -First 1
}

function Convert-HealthToCard($healthItem) {
    return [pscustomobject]@{
        Label = [string]$healthItem.label
        StatusLine = ("{0} {1}" -f [string]$healthItem.badge, [string]$healthItem.text)
        Detail = [string]$healthItem.detail
        Color = [string]$healthItem.color
    }
}

function Get-ModelCardStatus($ModelObject) {
    $state = Convert-ControllerModelStatus ([string]$ModelObject.status)
    return [pscustomobject]@{
        Text = [string]$state.text
        Color = [string]$state.color
    }
}

function New-ModelCard($ProviderObject, $ModelObject) {
    $providerHealth = Get-ProviderHealth ([string]$ProviderObject.id)
    $modelStatus = Get-ModelCardStatus $ModelObject
    $providerReady = ($null -ne $providerHealth -and [string]$providerHealth.status -ne "BLOCK")
    $sourceText = if ($ModelObject.PSObject.Properties["source"] -and [string]$ModelObject.source -eq "approved_registry") { "动态批准" } else { "受控目录" }
    $brand = Get-ModelBrand $ModelObject

    return [pscustomobject]@{
        ProviderId = [string]$ProviderObject.id
        ProviderLabel = [string]$ProviderObject.label
        Id = [string]$ModelObject.id
        Label = [string]$ModelObject.label
        Brand = $brand
        BrandProviderLine = "$brand · $($ProviderObject.label)"
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

function Refresh-Health {
    if ($null -eq $script:catalog) { return }

    try {
        $script:health = Get-ControllerHealthSnapshot -Catalog $script:catalog -ConfigPath $configPath
        $script:providerHealthCards = @($script:health.provider_health | ForEach-Object { Convert-HealthToCard $_ })
        $DashboardProviderHealthList.ItemsSource = $script:providerHealthCards
        $ProvidersPageList.ItemsSource = $script:providerHealthCards

        if ($script:health.block_count -gt 0) {
            $HealthSummaryText.Text = "发现 $($script:health.block_count) 个 Provider 阻塞项，启动前请先配置。"
            $HealthSummaryBadge.Text = "NEEDS ATTENTION"
            $HealthSummaryBadge.Foreground = Get-ColorBrush "#FF6B81"
            $SidebarStatusText.Text = "存在 Provider 阻塞"
            $SidebarStatusDot.Fill = Get-ColorBrush "#FF6B81"
        }
        elseif ($script:health.warn_count -gt 0) {
            $HealthSummaryText.Text = "本地检查可用；有 $($script:health.warn_count) 个实验/额度状态需要留意。"
            $HealthSummaryBadge.Text = "LOCAL ONLY"
            $HealthSummaryBadge.Foreground = Get-ColorBrush "#F6B94A"
            $SidebarStatusText.Text = "本地状态可用"
            $SidebarStatusDot.Fill = Get-ColorBrush "#F6B94A"
        }
        else {
            $HealthSummaryText.Text = "本地检查通过，没有发现 Provider 阻塞。未执行付费推理。"
            $HealthSummaryBadge.Text = "ALL READY"
            $HealthSummaryBadge.Foreground = Get-ColorBrush "#2DD4A3"
            $SidebarStatusText.Text = "所有本地检查正常"
            $SidebarStatusDot.Fill = Get-ColorBrush "#2DD4A3"
        }

        $ToolsStatusText.Text = "LOCAL ONLY · Provider PASS $($script:health.pass_count) · WARN $($script:health.warn_count) · BLOCK $($script:health.block_count)"
    }
    catch {
        $HealthSummaryText.Text = "健康状态读取失败：$($_.Exception.Message)"
        $HealthSummaryBadge.Text = "CHECK FAILED"
        $HealthSummaryBadge.Foreground = Get-ColorBrush "#FF6B81"
        $SidebarStatusText.Text = "状态读取失败"
        $SidebarStatusDot.Fill = Get-ColorBrush "#FF6B81"
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
    $script:modelCards = @($cards)
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

function Get-ProviderBrands($ProviderObject) {
    if ($null -eq $ProviderObject) { return @() }
    return @($ProviderObject.models | ForEach-Object { Get-ModelBrand $_ } | Select-Object -Unique)
}

function Refresh-ProviderSelection([string]$PreferredProvider = "", [string]$PreferredBrand = "", [string]$PreferredModel = "") {
    if ($null -eq $script:catalog) { return }

    $script:loadingRoute = $true
    try {
        $ProviderCombo.ItemsSource = @($script:catalog.providers)
        $provider = @($script:catalog.providers | Where-Object { [string]$_.id -eq $PreferredProvider }) | Select-Object -First 1
        if ($null -eq $provider) { $provider = @($script:catalog.providers | Where-Object { [string]$_.id -eq "chatgpt" }) | Select-Object -First 1 }
        if ($null -eq $provider) { $provider = @($script:catalog.providers) | Select-Object -First 1 }
        $ProviderCombo.SelectedItem = $provider

        $brands = @(Get-ProviderBrands $provider)
        $BrandCombo.ItemsSource = $brands
        $brand = if ($PreferredBrand -in $brands) { $PreferredBrand } else { @($brands) | Select-Object -First 1 }
        $BrandCombo.SelectedItem = $brand

        $models = @($provider.models | Where-Object { (Get-ModelBrand $_) -eq $brand })
        $ModelCombo.ItemsSource = $models
        $model = @($models | Where-Object { [string]$_.id -eq $PreferredModel }) | Select-Object -First 1
        if ($null -eq $model) { $model = @($models) | Select-Object -First 1 }
        $ModelCombo.SelectedItem = $model
    }
    finally {
        $script:loadingRoute = $false
    }
    Update-SelectedRouteUI
}

function Refresh-RouteSelectors {
    $state = Load-VisualState
    $provider = if ($state.PSObject.Properties["last_provider"]) { [string]$state.last_provider } else { "chatgpt" }
    $brand = if ($state.PSObject.Properties["last_brand"]) { [string]$state.last_brand } else { "OpenAI" }
    $model = if ($state.PSObject.Properties["last_model_id"]) { [string]$state.last_model_id } else { "__account_default__" }
    $effort = if ($state.PSObject.Properties["last_effort"]) { [string]$state.last_effort } else { "high" }
    if ($effort -notin @("low","medium","high")) { $effort = "high" }
    $EffortCombo.SelectedItem = $effort
    Refresh-ProviderSelection -PreferredProvider $provider -PreferredBrand $brand -PreferredModel $model
}

function Refresh-Catalog {
    try {
        $script:catalog = Get-ControllerCatalog -StaticCatalogPath $staticCatalogPath -ApprovedModelsPath $approvedModelsPath
        $meta = $script:catalog.controller_meta
        $CatalogStatusText.Text = "受控目录 + 已批准模型 · 动态新增 $($meta.dynamic_added) · 忽略不安全记录 $($meta.ignored_provider + $meta.ignored_probe)"
        Refresh-Health
        Refresh-ModelCards
        Refresh-RouteSelectors
    }
    catch {
        $CatalogStatusText.Text = "模型目录加载失败：$($_.Exception.Message)"
        $CatalogStatusText.Foreground = Get-ColorBrush "#FF6B81"
    }
}

function Update-SelectedRouteUI {
    if ($script:loadingRoute) { return }
    $provider = $ProviderCombo.SelectedItem
    $model = $ModelCombo.SelectedItem
    if ($null -eq $provider -or $null -eq $model) {
        $HeroModelName.Text = "请选择模型"
        $HeroModelMeta.Text = "Provider / 模型尚未选择"
        return
    }

    $providerHealth = Get-ProviderHealth ([string]$provider.id)
    $modelState = Convert-ControllerModelStatus ([string]$model.status)
    $brand = Get-ModelBrand $model
    $effort = if ($EffortCombo.SelectedItem) { [string]$EffortCombo.SelectedItem } else { "medium" }

    $HeroModelName.Text = [string]$model.label
    $HeroModelMeta.Text = "$brand · $($provider.label) · reasoning $effort"
    $HeroStatusBadge.Text = ([string]$modelState.text).ToUpperInvariant()
    $HeroStatusBadge.Foreground = Get-ColorBrush ([string]$modelState.color)

    if ($null -ne $providerHealth -and [string]$providerHealth.status -eq "BLOCK") {
        $HeroReadyBadge.Text = "Provider 未就绪"
        $HeroReadyBadge.Foreground = Get-ColorBrush "#FF6B81"
        $LaunchCurrentButton.IsEnabled = $false
        $ModelsLaunchButton.IsEnabled = $false
    }
    else {
        $HeroReadyBadge.Text = "Provider 可启动"
        $HeroReadyBadge.Foreground = Get-ColorBrush "#2DD4A3"
        $LaunchCurrentButton.IsEnabled = $true
        $ModelsLaunchButton.IsEnabled = $true
    }

    $SelectedRouteText.Text = "路由：$($provider.label) → $brand → $($model.label) · $([string]$model.id) · reasoning=$effort"

    $card = @($script:modelCards | Where-Object { $_.ProviderId -eq [string]$provider.id -and $_.Id -eq [string]$model.id }) | Select-Object -First 1
    if ($null -ne $card) {
        $DashboardModelList.SelectedItem = $card
        $ModelsModelList.SelectedItem = $card
    }
}

function Apply-CardSelection($Card) {
    if ($null -eq $Card) { return }
    $provider = Get-ProviderById ([string]$Card.ProviderId)
    if ($null -eq $provider) { return }

    $script:loadingRoute = $true
    try {
        $ProviderCombo.SelectedItem = $provider
        $brands = @(Get-ProviderBrands $provider)
        $BrandCombo.ItemsSource = $brands
        $BrandCombo.SelectedItem = [string]$Card.Brand
        $models = @($provider.models | Where-Object { (Get-ModelBrand $_) -eq [string]$Card.Brand })
        $ModelCombo.ItemsSource = $models
        $model = @($models | Where-Object { [string]$_.id -eq [string]$Card.Id }) | Select-Object -First 1
        $ModelCombo.SelectedItem = $model
    }
    finally {
        $script:loadingRoute = $false
    }
    Update-SelectedRouteUI
}

function Refresh-WorkspaceCandidates([string]$Preferred = "") {
    $text = if (-not [string]::IsNullOrWhiteSpace($Preferred)) { $Preferred } else { [string]$WorkspaceCombo.Text }
    $script:loadingWorkspace = $true
    try {
        $WorkspaceCombo.ItemsSource = @(Get-WorkspaceCandidates)
        if (-not [string]::IsNullOrWhiteSpace($text)) { $WorkspaceCombo.Text = $text }
    }
    finally {
        $script:loadingWorkspace = $false
    }
}

function Refresh-WorkspaceStatus {
    $path = ([string]$WorkspaceCombo.Text).Trim()
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        $GitStatusText.Text = "工作目录无效"
        $GitStatusText.Foreground = Get-ColorBrush "#FF6B81"
        return
    }

    $gitInfo = Get-GitInfo $path
    if (-not $gitInfo.IsRepo) {
        $GitStatusText.Text = "Git：非仓库 · 仍可作为 Codex 工作目录"
        $GitStatusText.Foreground = Get-ColorBrush "#8C9AB5"
        return
    }

    $worktree = if ($gitInfo.Dirty) { "DIRTY" } else { "CLEAN" }
    $GitStatusText.Text = "Git：$worktree · branch：$($gitInfo.Branch) · HEAD：$($gitInfo.Head)"
    $GitStatusText.Foreground = if ($gitInfo.Dirty) { Get-ColorBrush "#F6B94A" } else { Get-ColorBrush "#2DD4A3" }
}

function Refresh-LastModelText {
    $state = Load-VisualState
    if ($state.PSObject.Properties["last_model_label"] -and -not [string]::IsNullOrWhiteSpace([string]$state.last_model_label)) {
        $LastModelText.Text = "上次：$($state.last_model_label)"
    }
    else {
        $LastModelText.Text = "尚无启动记录"
    }
}

function Confirm-WorkspaceForLaunch {
    $path = ([string]$WorkspaceCombo.Text).Trim()
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        [System.Windows.MessageBox]::Show("请选择有效的工作目录。", "Codex Multi-Model Manager", "OK", "Warning") | Out-Null
        return $null
    }

    $resolved = (Resolve-Path -LiteralPath $path).Path
    $gitInfo = Get-GitInfo $resolved
    if ($gitInfo.IsRepo -and $gitInfo.Dirty) {
        $result = [System.Windows.MessageBox]::Show(
            "当前 Git worktree 为 DIRTY。`n`nManager 不会 reset、stash 或 clean。`n是否仍然启动新 Codex 会话？",
            "Dirty worktree",
            "YesNo",
            "Warning"
        )
        if ($result -ne "Yes") { return $null }
    }
    return $resolved
}

function Start-SelectedModel {
    $provider = $ProviderCombo.SelectedItem
    $model = $ModelCombo.SelectedItem
    if ($null -eq $provider -or $null -eq $model) {
        [System.Windows.MessageBox]::Show("请先选择 Provider 和模型。", "Codex Multi-Model Manager", "OK", "Warning") | Out-Null
        return
    }

    $providerHealth = Get-ProviderHealth ([string]$provider.id)
    if ($null -ne $providerHealth -and [string]$providerHealth.status -eq "BLOCK") {
        [System.Windows.MessageBox]::Show(
            "该 Provider 当前未就绪：$($providerHealth.text)`n$($providerHealth.detail)",
            "Provider 未就绪",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }

    $workspace = Confirm-WorkspaceForLaunch
    if ($null -eq $workspace) { return }

    $brand = Get-ModelBrand $model
    $effort = if ($EffortCombo.SelectedItem) { [string]$EffortCombo.SelectedItem } else { "medium" }

    Save-VisualState -WorkspacePath $workspace -ProviderId ([string]$provider.id) -Brand $brand `
        -ModelId ([string]$model.id) -ModelLabel ([string]$model.label) -Effort $effort

    Start-PwshScript -ScriptPath $launchScript -WorkingDirectory $workspace -NamedArgs @{
        ProjectPath = $workspace
        Provider = [string]$provider.id
        ModelId = [string]$model.id
        ReasoningEffort = $effort
    }

    $LastModelText.Text = "已启动：$($model.label)"
}

function Open-ToolScript([string]$Path, [string]$WorkingDirectory = "") {
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = Split-Path -Parent $PSScriptRoot }
    Start-PwshScript -ScriptPath $Path -WorkingDirectory $WorkingDirectory
}

function Update-StealthStatus {
    $registryPath = Join-Path (Get-ManagerHome) "stealth-models.json"
    if (-not (Test-Path -LiteralPath $registryPath)) {
        $StealthStatusText.Text = "Ox Alpha · stealth/ox-alpha · 尚未建立本地 Registry"
        return
    }
    try {
        $loaded = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
        $records = @()
        if ($loaded -is [System.Array]) { $records = @($loaded) }
        elseif ($loaded.PSObject.Properties["models"]) { $records = @($loaded.models) }
        else { $records = @($loaded) }

        $ox = @($records | Where-Object {
            ([string]$_.alias -match '(?i)ox') -or ([string]$_.original_model_id -eq "stealth/ox-alpha") -or ([string]$_.model_id -eq "stealth/ox-alpha")
        }) | Select-Object -First 1

        if ($null -eq $ox) {
            $StealthStatusText.Text = "Ox Alpha · stealth/ox-alpha · Registry 已存在"
            return
        }

        $status = ""
        foreach ($name in @("status","current_status","lifecycle_status")) {
            if ($ox.PSObject.Properties[$name] -and -not [string]::IsNullOrWhiteSpace([string]$ox.$name)) {
                $status = [string]$ox.$name
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($status)) { $status = "TRACKED" }

        $resolvedId = "stealth/ox-alpha"
        foreach ($name in @("replacement_model_id","current_model_id","model_id","original_model_id")) {
            if ($ox.PSObject.Properties[$name] -and -not [string]::IsNullOrWhiteSpace([string]$ox.$name)) {
                $resolvedId = [string]$ox.$name
                break
            }
        }
        $StealthStatusText.Text = "Ox Alpha · $resolvedId · $status"
    }
    catch {
        $StealthStatusText.Text = "Ox Alpha Registry 读取失败 · 可打开 Registry 中心检查"
    }
}

$NavDashboard.Add_Click({ Set-NavPage 0 "仪表盘" "选择工作目录、Provider 和模型，然后启动全新 Codex 会话" $NavDashboard })
$NavModels.Add_Click({ Set-NavPage 1 "模型管理" "受控模型目录 + 已批准动态模型；不自动批准候选模型" $NavModels })
$NavProviders.Add_Click({ Set-NavPage 2 "Provider" "本地检查 Provider 配置和 Key 是否存在，不显示 secret" $NavProviders })
$NavStealth.Add_Click({ Set-NavPage 3 "Stealth Registry" "跟踪匿名模型从发现、验证到人工确认迁移的生命周期" $NavStealth })
$NavTools.Add_Click({ Set-NavPage 4 "工具与安全" "健康检查、handoff、模型更新和高级命令行入口" $NavTools })
$NavRouter.Add_Click({ Set-NavPage 5 "Local Router" "本地多模型路由、健康状态、用量成本与安全策略" $NavRouter })

$ProviderCombo.Add_SelectionChanged({
    if ($script:loadingRoute -or $null -eq $ProviderCombo.SelectedItem) { return }
    $script:loadingRoute = $true
    try {
        $provider = $ProviderCombo.SelectedItem
        $brands = @(Get-ProviderBrands $provider)
        $BrandCombo.ItemsSource = $brands
        $BrandCombo.SelectedItem = @($brands) | Select-Object -First 1
        $models = @($provider.models | Where-Object { (Get-ModelBrand $_) -eq [string]$BrandCombo.SelectedItem })
        $ModelCombo.ItemsSource = $models
        $ModelCombo.SelectedItem = @($models) | Select-Object -First 1
    }
    finally { $script:loadingRoute = $false }
    Update-SelectedRouteUI
})

$BrandCombo.Add_SelectionChanged({
    if ($script:loadingRoute -or $null -eq $ProviderCombo.SelectedItem -or $null -eq $BrandCombo.SelectedItem) { return }
    $script:loadingRoute = $true
    try {
        $provider = $ProviderCombo.SelectedItem
        $models = @($provider.models | Where-Object { (Get-ModelBrand $_) -eq [string]$BrandCombo.SelectedItem })
        $ModelCombo.ItemsSource = $models
        $ModelCombo.SelectedItem = @($models) | Select-Object -First 1
    }
    finally { $script:loadingRoute = $false }
    Update-SelectedRouteUI
})

$ModelCombo.Add_SelectionChanged({ if (-not $script:loadingRoute) { Update-SelectedRouteUI } })
$EffortCombo.Add_SelectionChanged({ if (-not $script:loadingRoute) { Update-SelectedRouteUI } })

$DashboardModelList.Add_SelectionChanged({
    if ($null -ne $DashboardModelList.SelectedItem) {
        Apply-CardSelection $DashboardModelList.SelectedItem
        $ModelsModelList.SelectedItem = $DashboardModelList.SelectedItem
    }
})
$ModelsModelList.Add_SelectionChanged({
    if ($null -ne $ModelsModelList.SelectedItem) {
        Apply-CardSelection $ModelsModelList.SelectedItem
        $DashboardModelList.SelectedItem = $ModelsModelList.SelectedItem
    }
})

$LaunchCurrentButton.Add_Click({ Start-SelectedModel })
$ModelsLaunchButton.Add_Click({ Start-SelectedModel })

$BrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "选择 Codex 新会话的工作目录"
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $WorkspaceCombo.Text = $dialog.SelectedPath
        Refresh-WorkspaceStatus
    }
})
$RefreshWorkspaceButton.Add_Click({ Refresh-WorkspaceCandidates -Preferred ([string]$WorkspaceCombo.Text); Refresh-WorkspaceStatus })
$WorkspaceCombo.Add_LostKeyboardFocus({ if (-not $script:loadingWorkspace) { Refresh-WorkspaceStatus } })

$TopRefreshButton.Add_Click({
    Refresh-WorkspaceCandidates -Preferred ([string]$WorkspaceCombo.Text)
    Refresh-WorkspaceStatus
    Refresh-Catalog
    Refresh-LastModelText
    Update-StealthStatus
    if (Get-Command Refresh-RouterV4UI -ErrorAction SilentlyContinue) { Refresh-RouterV4UI }
})
$ReloadCatalogButton.Add_Click({ Refresh-Catalog })
$ModelsReloadButton.Add_Click({ Refresh-Catalog })
$RefreshHealthButton.Add_Click({ Refresh-Health; Refresh-ModelCards; Update-SelectedRouteUI })
$ProvidersRefreshButton.Add_Click({ Refresh-Health; Refresh-ModelCards; Update-SelectedRouteUI })

$TopSetupButton.Add_Click({ Open-ToolScript $setupScript })
$ProvidersSetupButton.Add_Click({ Open-ToolScript $setupScript })
$DashboardHealthDetailButton.Add_Click({ Open-ToolScript $healthScript })
$ToolsHealthButton.Add_Click({ Open-ToolScript $healthScript })
$DashboardUpdateCenterButton.Add_Click({ Open-ToolScript $updateCenterScript })
$ToolsUpdateCenterButton.Add_Click({ Open-ToolScript $updateCenterScript })
$DashboardStealthButton.Add_Click({ Open-ToolScript $stealthCenterScript })
$StealthCenterButton.Add_Click({ Open-ToolScript $stealthCenterScript })
$ToolsSwitcherButton.Add_Click({ Open-ToolScript $switcherScript })

$ToolsHandoffButton.Add_Click({
    $workspace = ([string]$WorkspaceCombo.Text).Trim()
    if ([string]::IsNullOrWhiteSpace($workspace) -or -not (Test-Path -LiteralPath $workspace)) {
        [System.Windows.MessageBox]::Show("请先选择有效工作目录。", "Codex Multi-Model Manager", "OK", "Warning") | Out-Null
        return
    }
    Open-ToolScript -Path $handoffScript -WorkingDirectory $workspace
})

$StealthLaunchOxButton.Add_Click({
    Refresh-ProviderSelection -PreferredProvider "openrouter" -PreferredBrand "Stealth" -PreferredModel "stealth/ox-alpha"
    $result = [System.Windows.MessageBox]::Show(
        "Ox Alpha 是匿名实验模型。启动会继续执行现有 OpenRouter / Stealth Registry / OX 确认 / Git handoff 安全流程。`n`n继续？",
        "Ox Alpha · Experimental",
        "YesNo",
        "Warning"
    )
    if ($result -eq "Yes") { Start-SelectedModel }
})

$OpenLegacyControllerButton.Add_Click({ Open-ToolScript -Path $classicControllerScript })

$initialWorkspace = Resolve-InitialWorkspace
Refresh-WorkspaceCandidates -Preferred $initialWorkspace
Refresh-WorkspaceStatus
Refresh-Catalog
Refresh-LastModelText
Update-StealthStatus
Set-NavPage 0 "仪表盘" "选择工作目录、Provider 和模型，然后启动全新 Codex 会话" $NavDashboard

$window.ShowDialog() | Out-Null
