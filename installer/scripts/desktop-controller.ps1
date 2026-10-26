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
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    return $path
}

function Get-ControllerStatePath {
    return (Join-Path (Get-ManagerHome) "controller-state.json")
}

function Load-ControllerState {
    $path = Get-ControllerStatePath
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{} }
    try { return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json) }
    catch { return [pscustomobject]@{} }
}

function Save-ControllerState(
    [string]$WorkspacePath,
    [string]$LastProvider = "",
    [string]$LastBrand = "",
    [string]$LastModelId = "",
    [string]$LastModelLabel = "",
    [string]$LastEffort = ""
) {
    $old = Load-ControllerState
    foreach ($pair in @(
        @("LastProvider","last_provider"),
        @("LastBrand","last_brand"),
        @("LastModelId","last_model_id"),
        @("LastModelLabel","last_model_label"),
        @("LastEffort","last_effort")
    )) {
        $variableName = $pair[0]
        $propertyName = $pair[1]
        $value = Get-Variable -Name $variableName -ValueOnly
        if ([string]::IsNullOrWhiteSpace([string]$value) -and $old.PSObject.Properties[$propertyName]) {
            Set-Variable -Name $variableName -Value ([string]$old.$propertyName)
        }
    }

    [ordered]@{
        last_workspace = $WorkspacePath
        last_project = $WorkspacePath
        last_provider = $LastProvider
        last_brand = $LastBrand
        last_model_id = $LastModelId
        last_model_label = $LastModelLabel
        last_effort = $LastEffort
        saved_at = (Get-Date -Format "o")
    } | ConvertTo-Json | Set-Content -LiteralPath (Get-ControllerStatePath) -Encoding UTF8
}

function Get-UserEnvironmentValue([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    return [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::User)
}

function Test-ProviderKey([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    return (-not [string]::IsNullOrWhiteSpace((Get-UserEnvironmentValue $Name)))
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

function Get-StateWorkspace {
    $state = Load-ControllerState
    foreach ($propertyName in @("last_workspace","last_project")) {
        if ($state.PSObject.Properties[$propertyName]) {
            $candidate = [string]$state.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }
    return ""
}

function Get-WorkspaceCandidates {
    $result = New-Object System.Collections.Generic.List[string]

    $stateWorkspace = Get-StateWorkspace
    if (-not [string]::IsNullOrWhiteSpace($stateWorkspace)) {
        $stateGit = Get-GitInfo $stateWorkspace
        if ($stateGit.IsRepo) { $result.Add($stateWorkspace) }
    }

    if ($PWD.Provider.Name -eq "FileSystem" -and (Test-Path -LiteralPath $PWD.Path) -and $PWD.Path -notmatch '(?i)\\Windows\\System32$') {
        $pwdGit = Get-GitInfo $PWD.Path
        if ($pwdGit.IsRepo -and $PWD.Path -notin $result) { $result.Add($PWD.Path) }
    }

    $projectsRoot = Join-Path $HOME "Projects"
    if (Test-Path -LiteralPath $projectsRoot) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $projectsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $gitInfo = Get-GitInfo $directory.FullName
            if ($gitInfo.IsRepo -and $directory.FullName -notin $result) { $result.Add($directory.FullName) }
        }
    }

    return @($result)
}

function Resolve-InitialWorkspace {
    $stateWorkspace = Get-StateWorkspace
    if (-not [string]::IsNullOrWhiteSpace($stateWorkspace)) {
        $stateGit = Get-GitInfo $stateWorkspace
        if ($stateGit.IsRepo) { return $stateWorkspace }
    }

    if ($PWD.Provider.Name -eq "FileSystem" -and (Test-Path -LiteralPath $PWD.Path) -and $PWD.Path -notmatch '(?i)\\Windows\\System32$') {
        $pwdGit = Get-GitInfo $PWD.Path
        if ($pwdGit.IsRepo) { return $PWD.Path }
    }

    $candidates = @(Get-WorkspaceCandidates)
    if ($candidates.Count -gt 0) { return [string]$candidates[0] }

    $projectsRoot = Join-Path $HOME "Projects"
    if (Test-Path -LiteralPath $projectsRoot) { return $projectsRoot }
    return $HOME
}

function Start-PwshScript([string]$ScriptPath, [string]$WorkingDirectory, [string[]]$ExtraArgs = @()) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($part in @("-NoExit","-NoProfile","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $ScriptPath))) {
        $parts.Add($part)
    }
    foreach ($arg in $ExtraArgs) { $parts.Add($arg) }
    Start-Process -FilePath "pwsh.exe" -WorkingDirectory $WorkingDirectory -ArgumentList ($parts -join " ") | Out-Null
}

$catalogHelper = Join-Path $PSScriptRoot "controller-catalog.ps1"
if (-not (Test-Path -LiteralPath $catalogHelper)) { throw "Missing controller catalog helper: $catalogHelper" }
. $catalogHelper

$healthHelper = Join-Path $PSScriptRoot "controller-health.ps1"
if (-not (Test-Path -LiteralPath $healthHelper)) { throw "Missing controller health helper: $healthHelper" }
. $healthHelper

$staticCatalogPath = (Resolve-Path (Join-Path $PSScriptRoot "..\model-catalog.json")).Path
$approvedModelsPath = Join-Path (Get-ManagerHome) "approved-models.json"
$configPath = Join-Path (Get-CodexHome) "config.toml"
$script:catalog = $null
$script:loadingCatalog = $false
$script:loadingWorkspaces = $false

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex Multi-Model Desktop Controller"
        Width="1220" Height="930" MinWidth="1040" MinHeight="790"
        WindowStartupLocation="CenterScreen" Background="#F4F5F7" FontFamily="Segoe UI">
 <Window.Resources>
  <Style x:Key="Card" TargetType="Border">
   <Setter Property="Background" Value="White"/>
   <Setter Property="CornerRadius" Value="18"/>
   <Setter Property="Padding" Value="20"/>
   <Setter Property="BorderBrush" Value="#E7E9ED"/>
   <Setter Property="BorderThickness" Value="1"/>
  </Style>
  <Style x:Key="SoftButton" TargetType="Button">
   <Setter Property="Background" Value="#F7F8FA"/>
   <Setter Property="Foreground" Value="#1D1D1F"/>
   <Setter Property="BorderBrush" Value="#D8DCE3"/>
   <Setter Property="BorderThickness" Value="1"/>
   <Setter Property="FontSize" Value="13"/>
   <Setter Property="FontWeight" Value="SemiBold"/>
   <Setter Property="Padding" Value="16,0"/>
   <Setter Property="Cursor" Value="Hand"/>
  </Style>
  <Style x:Key="PrimaryButton" TargetType="Button">
   <Setter Property="Background" Value="#17191C"/>
   <Setter Property="Foreground" Value="White"/>
   <Setter Property="BorderBrush" Value="#17191C"/>
   <Setter Property="BorderThickness" Value="1"/>
   <Setter Property="FontSize" Value="14"/>
   <Setter Property="FontWeight" Value="SemiBold"/>
   <Setter Property="Padding" Value="20,0"/>
   <Setter Property="Cursor" Value="Hand"/>
  </Style>
  <Style x:Key="Combo" TargetType="ComboBox">
   <Setter Property="Height" Value="42"/>
   <Setter Property="Padding" Value="10,6"/>
   <Setter Property="FontSize" Value="13"/>
   <Setter Property="Background" Value="#FBFBFC"/>
   <Setter Property="BorderBrush" Value="#D7DBE2"/>
  </Style>
 </Window.Resources>
 <ScrollViewer VerticalScrollBarVisibility="Auto">
  <Grid Margin="30">
   <Grid.RowDefinitions>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
   </Grid.RowDefinitions>

   <Grid Grid.Row="0" Margin="0,0,0,18">
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel>
     <TextBlock Text="Codex Multi-Model Controller" FontSize="30" FontWeight="SemiBold" Foreground="#111214"/>
     <TextBlock Text="工作目录 → Provider → 模型品牌 → 型号 → 推理强度 · 每次启动全新 Codex 会话" FontSize="14" Foreground="#6B7280" Margin="0,6,0,0"/>
    </StackPanel>
    <Border Grid.Column="1" Background="#EAF8EF" BorderBrush="#B9E5C7" BorderThickness="1" CornerRadius="12" Padding="14,8" VerticalAlignment="Center">
     <TextBlock Text="Provider-aware" Foreground="#176A3A" FontWeight="SemiBold" FontSize="12"/>
    </Border>
   </Grid>

   <Border Grid.Row="1" Background="#FFF8DB" BorderBrush="#F0D977" BorderThickness="1" CornerRadius="14" Padding="15" Margin="0,0,0,16">
    <TextBlock TextWrapping="Wrap" Foreground="#594A00" FontSize="13">Controller 不复制 Codex 的项目/线程管理。这里只选择新会话的工作目录，并锁定 Provider + 模型型号；跨 Provider 时始终启动新会话。</TextBlock>
   </Border>

   <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0,0,0,16">
    <Grid>
     <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <StackPanel Grid.ColumnSpan="3" Margin="0,0,0,13">
      <TextBlock Text="工作目录" FontWeight="SemiBold" FontSize="17"/>
      <TextBlock Text="快速列表只扫描 ~/Projects 下的 Git 仓库；不读取项目内容。也可手动选择任意文件夹。" FontSize="12" Foreground="#7B818C" Margin="0,4,0,0"/>
     </StackPanel>
     <ComboBox x:Name="WorkspaceCombo" Grid.Row="1" Height="38" Margin="0,0,10,0" Padding="10,6" FontSize="13" BorderBrush="#D7DBE2" Background="#FBFBFC" IsEditable="True" IsTextSearchEnabled="True"/>
     <Button x:Name="BrowseButton" Grid.Row="1" Grid.Column="1" Content="选择文件夹" Height="38" Margin="0,0,8,0" Style="{StaticResource SoftButton}"/>
     <Button x:Name="RefreshButton" Grid.Row="1" Grid.Column="2" Content="刷新状态" Height="38" Style="{StaticResource SoftButton}"/>
     <Grid Grid.Row="2" Grid.ColumnSpan="3" Margin="0,13,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="GitStatusText" FontSize="13" Foreground="#6B7280"/>
      <TextBlock x:Name="LastModelText" Grid.Column="1" FontSize="12" Foreground="#6B7280"/>
     </Grid>
    </Grid>
   </Border>

   <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0,0,0,16">
    <StackPanel>
     <Grid Margin="0,0,0,14">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel>
       <TextBlock Text="模型型号选择器" FontSize="19" FontWeight="SemiBold"/>
       <TextBlock Text="静态目录与 approved-models.json 只读合并；候选、未测试或未批准模型不会显示。" FontSize="12" Foreground="#7B818C" Margin="0,4,0,0"/>
       <TextBlock x:Name="CatalogStatusText" FontSize="12" Foreground="#315EA8" Margin="0,4,0,0"/>
      </StackPanel>
      <Button x:Name="ReloadCatalogButton" Grid.Column="1" Content="刷新模型目录" Height="36" Margin="0,0,8,0" Style="{StaticResource SoftButton}"/>
      <Border Grid.Column="2" Background="#EDF3FF" CornerRadius="9" Padding="10,5" VerticalAlignment="Center">
       <TextBlock Text="V3.8" Foreground="#315EA8" FontWeight="SemiBold" FontSize="11"/>
      </Border>
     </Grid>

     <Grid>
      <Grid.ColumnDefinitions>
       <ColumnDefinition Width="1.25*"/>
       <ColumnDefinition Width="0.9*"/>
       <ColumnDefinition Width="1.45*"/>
       <ColumnDefinition Width="0.75*"/>
      </Grid.ColumnDefinitions>
      <StackPanel Margin="0,0,10,0">
       <TextBlock Text="路由提供商" FontSize="12" Foreground="#666D78" Margin="0,0,0,6"/>
       <ComboBox x:Name="ProviderCombo" Style="{StaticResource Combo}" DisplayMemberPath="label"/>
      </StackPanel>
      <StackPanel Grid.Column="1" Margin="0,0,10,0">
       <TextBlock Text="模型品牌" FontSize="12" Foreground="#666D78" Margin="0,0,0,6"/>
       <ComboBox x:Name="BrandCombo" Style="{StaticResource Combo}"/>
      </StackPanel>
      <StackPanel Grid.Column="2" Margin="0,0,10,0">
       <TextBlock Text="模型型号" FontSize="12" Foreground="#666D78" Margin="0,0,0,6"/>
       <ComboBox x:Name="ModelCombo" Style="{StaticResource Combo}" DisplayMemberPath="label"/>
      </StackPanel>
      <StackPanel Grid.Column="3">
       <TextBlock Text="推理强度" FontSize="12" Foreground="#666D78" Margin="0,0,0,6"/>
       <ComboBox x:Name="EffortCombo" Style="{StaticResource Combo}"/>
      </StackPanel>
     </Grid>

     <Grid Margin="0,14,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel>
       <TextBlock x:Name="RouteStatusText" FontSize="13" Foreground="#6B7280"/>
       <TextBlock x:Name="SelectedIdText" FontSize="12" Foreground="#9298A1" Margin="0,4,0,0"/>
      </StackPanel>
      <Button x:Name="LaunchSelectedButton" Grid.Column="1" Content="启动新 Codex 会话" Height="44" MinWidth="180" Style="{StaticResource PrimaryButton}"/>
     </Grid>
     <TextBlock x:Name="LaunchStatusText" Margin="0,12,0,0" Foreground="#197044" FontSize="13" FontWeight="SemiBold"/>
    </StackPanel>
   </Border>

   <Border Grid.Row="4" Style="{StaticResource Card}" Margin="0,0,0,16">
    <StackPanel>
     <Grid Margin="0,0,0,12">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel>
       <TextBlock Text="模型健康驾驶舱" FontSize="19" FontWeight="SemiBold"/>
       <TextBlock Text="本地只读诊断：不执行付费推理，不查询实时余额，也不显示 API Key。" FontSize="12" Foreground="#7B818C" Margin="0,4,0,0"/>
      </StackPanel>
      <Button x:Name="RefreshHealthDashboardButton" Grid.Column="1" Content="刷新健康状态" Height="36" Style="{StaticResource SoftButton}"/>
     </Grid>

     <TextBlock x:Name="HealthSummaryText" FontSize="13" FontWeight="SemiBold" Foreground="#596273" Margin="0,0,0,10"/>

     <TextBlock Text="Provider" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,6"/>
     <ItemsControl x:Name="ProviderHealthList" Margin="0,0,0,12">
      <ItemsControl.ItemsPanel>
       <ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate>
      </ItemsControl.ItemsPanel>
      <ItemsControl.ItemTemplate>
       <DataTemplate>
        <Border Width="255" MinHeight="76" Background="#FAFAFB" BorderBrush="#E3E6EB" BorderThickness="1" CornerRadius="12" Padding="12" Margin="0,0,10,10">
         <StackPanel>
          <TextBlock Text="{Binding Label}" FontWeight="SemiBold" FontSize="13" TextTrimming="CharacterEllipsis"/>
          <TextBlock Text="{Binding StatusLine}" Foreground="{Binding Color}" FontWeight="SemiBold" FontSize="12" Margin="0,5,0,0"/>
          <TextBlock Text="{Binding Detail}" Foreground="#8A9099" FontSize="10" Margin="0,3,0,0" TextWrapping="Wrap"/>
         </StackPanel>
        </Border>
       </DataTemplate>
      </ItemsControl.ItemTemplate>
     </ItemsControl>

     <TextBlock Text="重点模型" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,6"/>
     <ItemsControl x:Name="ModelHealthList">
      <ItemsControl.ItemsPanel>
       <ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate>
      </ItemsControl.ItemsPanel>
      <ItemsControl.ItemTemplate>
       <DataTemplate>
        <Border Width="205" MinHeight="66" Background="#FAFAFB" BorderBrush="#E3E6EB" BorderThickness="1" CornerRadius="12" Padding="11" Margin="0,0,10,10">
         <StackPanel>
          <TextBlock Text="{Binding Label}" FontWeight="SemiBold" FontSize="12" TextTrimming="CharacterEllipsis"/>
          <TextBlock Text="{Binding StatusLine}" Foreground="{Binding Color}" FontWeight="SemiBold" FontSize="11" Margin="0,5,0,0"/>
          <TextBlock Text="{Binding RouteLine}" Foreground="#8A9099" FontSize="10" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
         </StackPanel>
        </Border>
       </DataTemplate>
      </ItemsControl.ItemTemplate>
     </ItemsControl>
     <TextBlock x:Name="HealthNoteText" FontSize="11" Foreground="#8A9099" Margin="0,2,0,0" TextWrapping="Wrap"/>
    </StackPanel>
   </Border>

   <Border Grid.Row="5" Style="{StaticResource Card}" Margin="0,0,0,16">
    <StackPanel>
     <TextBlock Text="快捷预设" FontSize="17" FontWeight="SemiBold" Margin="0,0,0,10"/>
     <UniformGrid Columns="3">
      <Button x:Name="PresetGPT" Content="GPT / 官方默认" Tag="chatgpt|__account_default__|high" Height="54" Margin="0,0,8,8" Style="{StaticResource SoftButton}"/>
      <Button x:Name="PresetQwen" Content="Qwen3 Coder Plus" Tag="modelstudio|qwen3-coder-plus|medium" Height="54" Margin="0,0,8,8" Style="{StaticResource SoftButton}"/>
      <Button x:Name="PresetDeepSeek" Content="DeepSeek V4 Pro" Tag="modelstudio|deepseek-v4-pro|medium" Height="54" Margin="0,0,0,8" Style="{StaticResource SoftButton}"/>
      <Button x:Name="PresetOx" Content="Ox Alpha" Tag="openrouter|stealth/ox-alpha|medium" Height="54" Margin="0,0,8,0" Style="{StaticResource SoftButton}"/>
      <Button x:Name="PresetGLM" Content="GLM 5.3" Tag="openrouter|z-ai/glm-5.3|medium" Height="54" Margin="0,0,8,0" Style="{StaticResource SoftButton}"/>
      <Button x:Name="PresetMiMo" Content="MiMo V2.5 Pro" Tag="mimo|mimo-v2.5-pro|high" Height="54" Style="{StaticResource SoftButton}"/>
     </UniformGrid>
    </StackPanel>
   </Border>

   <Border Grid.Row="6" Style="{StaticResource Card}">
    <StackPanel>
     <TextBlock Text="工具" FontSize="17" FontWeight="SemiBold" Margin="0,0,0,10"/>
     <WrapPanel>
      <Button x:Name="HealthButton" Content="详细健康检查" Height="38" Style="{StaticResource SoftButton}" Margin="0,0,8,8"/>
      <Button x:Name="HandoffButton" Content="校验交接" Height="38" Style="{StaticResource SoftButton}" Margin="0,0,8,8"/>
      <Button x:Name="UpdateCenterButton" Content="模型更新中心" Height="38" Style="{StaticResource SoftButton}" Margin="0,0,8,8"/>
      <Button x:Name="SetupButton" Content="Provider 配置" Height="38" Style="{StaticResource SoftButton}" Margin="0,0,8,8"/>
      <Button x:Name="SwitcherButton" Content="命令行高级模式" Height="38" Style="{StaticResource SoftButton}" Margin="0,0,8,8"/>
     </WrapPanel>
    </StackPanel>
   </Border>
  </Grid>
 </ScrollViewer>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$WorkspaceCombo = $window.FindName("WorkspaceCombo")
$BrowseButton = $window.FindName("BrowseButton")
$RefreshButton = $window.FindName("RefreshButton")
$GitStatusText = $window.FindName("GitStatusText")
$LastModelText = $window.FindName("LastModelText")
$ProviderCombo = $window.FindName("ProviderCombo")
$BrandCombo = $window.FindName("BrandCombo")
$ModelCombo = $window.FindName("ModelCombo")
$EffortCombo = $window.FindName("EffortCombo")
$CatalogStatusText = $window.FindName("CatalogStatusText")
$ReloadCatalogButton = $window.FindName("ReloadCatalogButton")
$RouteStatusText = $window.FindName("RouteStatusText")
$SelectedIdText = $window.FindName("SelectedIdText")
$LaunchSelectedButton = $window.FindName("LaunchSelectedButton")
$LaunchStatusText = $window.FindName("LaunchStatusText")
$HealthSummaryText = $window.FindName("HealthSummaryText")
$ProviderHealthList = $window.FindName("ProviderHealthList")
$ModelHealthList = $window.FindName("ModelHealthList")
$HealthNoteText = $window.FindName("HealthNoteText")
$RefreshHealthDashboardButton = $window.FindName("RefreshHealthDashboardButton")
$HealthButton = $window.FindName("HealthButton")
$HandoffButton = $window.FindName("HandoffButton")
$UpdateCenterButton = $window.FindName("UpdateCenterButton")
$SetupButton = $window.FindName("SetupButton")
$SwitcherButton = $window.FindName("SwitcherButton")

$EffortCombo.ItemsSource = @("low","medium","high")
$EffortCombo.SelectedItem = "medium"

function Get-ProviderById([string]$Id) {
    if ($null -eq $script:catalog) { return $null }
    return @($script:catalog.providers | Where-Object { [string]$_.id -eq $Id }) | Select-Object -First 1
}

function Get-ModelById($ProviderObject, [string]$Id) {
    if ($null -eq $ProviderObject) { return $null }
    return @($ProviderObject.models | Where-Object { [string]$_.id -eq $Id }) | Select-Object -First 1
}

function Get-ModelBrand($ModelObject) {
    if ($null -eq $ModelObject) { return "" }
    if ($ModelObject.PSObject.Properties["brand"] -and -not [string]::IsNullOrWhiteSpace([string]$ModelObject.brand)) {
        return [string]$ModelObject.brand
    }
    return "其他"
}

function Get-ProviderBrands($ProviderObject) {
    if ($null -eq $ProviderObject) { return @() }
    return @($ProviderObject.models | ForEach-Object { Get-ModelBrand $_ } | Select-Object -Unique)
}

function Refresh-WorkspaceCandidates([string]$PreferredPath = "") {
    $currentText = if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) { $PreferredPath } else { [string]$WorkspaceCombo.Text }
    $script:loadingWorkspaces = $true
    try {
        $WorkspaceCombo.ItemsSource = @(Get-WorkspaceCandidates)
        if (-not [string]::IsNullOrWhiteSpace($currentText)) { $WorkspaceCombo.Text = $currentText }
    }
    finally {
        $script:loadingWorkspaces = $false
    }
}

function Refresh-WorkspaceStatus {
    $path = $WorkspaceCombo.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        $GitStatusText.Text = "工作目录无效"
        $GitStatusText.Foreground = "#B42318"
        return
    }
    $gitInfo = Get-GitInfo $path
    if (-not $gitInfo.IsRepo) {
        $GitStatusText.Text = "Git：非仓库 · 仍可作为 Codex 工作目录"
        $GitStatusText.Foreground = "#6B7280"
        return
    }
    $stateText = if ($gitInfo.Dirty) { "DIRTY" } else { "CLEAN" }
    $GitStatusText.Text = "Git：$stateText  ·  branch：$($gitInfo.Branch)  ·  HEAD：$($gitInfo.Head)"
    $GitStatusText.Foreground = if ($gitInfo.Dirty) { "#9A6700" } else { "#197044" }
}

function Refresh-LastModelStatus {
    $state = Load-ControllerState
    if ($state.PSObject.Properties["last_model_label"] -and -not [string]::IsNullOrWhiteSpace([string]$state.last_model_label)) {
        $providerText = if ($state.PSObject.Properties["last_provider"]) { [string]$state.last_provider } else { "" }
        $brandText = if ($state.PSObject.Properties["last_brand"] -and -not [string]::IsNullOrWhiteSpace([string]$state.last_brand)) { " · $($state.last_brand)" } else { "" }
        $LastModelText.Text = "上次启动：$($state.last_model_label)$brandText · $providerText"
    }
    else {
        $LastModelText.Text = "尚无启动记录"
    }
}

function Refresh-CatalogStatus {
    if ($null -eq $script:catalog -or -not $script:catalog.PSObject.Properties["controller_meta"]) {
        $CatalogStatusText.Text = "目录：固定受控模型"
        $CatalogStatusText.Foreground = "#315EA8"
        return
    }
    $meta = $script:catalog.controller_meta
    $CatalogStatusText.Text = "目录：动态新增 $($meta.dynamic_added) · 已批准固定型号 $($meta.approved_existing) · 批准记录 $($meta.approved_loaded)"
    $CatalogStatusText.Foreground = "#315EA8"
    if ($meta.PSObject.Properties["warning"] -and -not [string]::IsNullOrWhiteSpace([string]$meta.warning)) {
        $CatalogStatusText.Text += " · 警告：$($meta.warning)"
        $CatalogStatusText.Foreground = "#9A6700"
    }
}

function Refresh-HealthDashboard {
    if ($null -eq $script:catalog) {
        $HealthSummaryText.Text = "健康状态：模型目录尚未加载"
        $HealthSummaryText.Foreground = "#596273"
        $ProviderHealthList.ItemsSource = @()
        $ModelHealthList.ItemsSource = @()
        return
    }

    try {
        $snapshot = Get-ControllerHealthSnapshot -Catalog $script:catalog -ConfigPath $configPath
        $providerItems = @($snapshot.provider_health | ForEach-Object {
            [pscustomobject]@{
                Label = [string]$_.label
                StatusLine = ([string]$_.badge + " " + [string]$_.text)
                Detail = [string]$_.detail
                Color = [string]$_.color
            }
        })
        $ProviderHealthList.ItemsSource = $providerItems

        $importantRaw = @("recommended","verified","experimental","credit","approved")
        $importantModels = @($snapshot.model_health | Where-Object {
            ([string]$_.raw_status -in $importantRaw) -or ([string]$_.source -eq "动态批准")
        })
        $modelItems = @($importantModels | ForEach-Object {
            [pscustomobject]@{
                Label = [string]$_.label
                StatusLine = ([string]$_.badge + " " + [string]$_.text)
                RouteLine = ([string]$_.brand + " · " + [string]$_.provider_label)
                Color = [string]$_.color
            }
        })
        $ModelHealthList.ItemsSource = $modelItems

        $stamp = try { ([datetime]$snapshot.generated_at).ToString("HH:mm:ss") } catch { "刚刚" }
        $HealthSummaryText.Text = "LOCAL ONLY · Provider 阻塞 $($snapshot.block_count) · 警告 $($snapshot.warn_count) · 正常/已验证 $($snapshot.pass_count) · $stamp"
        if ([int]$snapshot.block_count -gt 0) {
            $HealthSummaryText.Foreground = "#B42318"
        }
        elseif ([int]$snapshot.warn_count -gt 0) {
            $HealthSummaryText.Foreground = "#9A6700"
        }
        else {
            $HealthSummaryText.Foreground = "#197044"
        }
        $HealthNoteText.Text = [string]$snapshot.note
    }
    catch {
        $HealthSummaryText.Text = "健康驾驶舱刷新失败：$($_.Exception.Message)"
        $HealthSummaryText.Foreground = "#B42318"
        $ProviderHealthList.ItemsSource = @()
        $ModelHealthList.ItemsSource = @()
        $HealthNoteText.Text = "可使用下方【详细健康检查】查看完整诊断。"
    }
}

function Refresh-RouteStatus {
    $provider = $ProviderCombo.SelectedItem
    $brand = [string]$BrandCombo.SelectedItem
    $model = $ModelCombo.SelectedItem
    if ($null -eq $provider) { return }

    $keyOk = Test-ProviderKey ([string]$provider.env_key)
    $keyText = if ([string]::IsNullOrWhiteSpace([string]$provider.env_key)) {
        "ChatGPT 登录"
    }
    elseif ($keyOk) { "Key 已配置" } else { "Key 未配置" }

    if ($null -eq $model) {
        $RouteStatusText.Text = "路由：$($provider.label) · $keyText"
        $SelectedIdText.Text = "品牌：$brand"
        return
    }

    $statusText = if ($model.PSObject.Properties["status"]) { [string]$model.status } else { "" }
    $sourceText = if ($model.PSObject.Properties["source"] -and [string]$model.source -eq "approved_registry") { "动态批准" } else { "受控目录" }
    $RouteStatusText.Text = "路由：$($provider.label) · $keyText · 品牌：$brand"
    $SelectedIdText.Text = "Model ID：$($model.id) · 状态：$statusText · 来源：$sourceText"
}

function Refresh-ModelsForBrand([string]$PreferredModelId = "") {
    $provider = $ProviderCombo.SelectedItem
    $brand = [string]$BrandCombo.SelectedItem
    if ($null -eq $provider -or [string]::IsNullOrWhiteSpace($brand)) {
        $ModelCombo.ItemsSource = @()
        Refresh-RouteStatus
        return
    }

    $models = @($provider.models | Where-Object { (Get-ModelBrand $_) -eq $brand })
    $ModelCombo.ItemsSource = $models
    $selected = $null
    if (-not [string]::IsNullOrWhiteSpace($PreferredModelId)) {
        $selected = @($models | Where-Object { [string]$_.id -eq $PreferredModelId }) | Select-Object -First 1
    }
    if ($null -eq $selected -and $models.Count -gt 0) { $selected = $models[0] }
    $ModelCombo.SelectedItem = $selected
    Refresh-RouteStatus
}

function Refresh-BrandsForProvider([string]$PreferredBrand = "", [string]$PreferredModelId = "") {
    $provider = $ProviderCombo.SelectedItem
    if ($null -eq $provider) {
        $BrandCombo.ItemsSource = @()
        $ModelCombo.ItemsSource = @()
        return
    }

    $brands = @(Get-ProviderBrands $provider)
    $BrandCombo.ItemsSource = $brands
    $selectedBrand = $PreferredBrand
    if ([string]::IsNullOrWhiteSpace($selectedBrand) -or $selectedBrand -notin $brands) {
        if (-not [string]::IsNullOrWhiteSpace($PreferredModelId)) {
            $preferredModel = Get-ModelById $provider $PreferredModelId
            if ($null -ne $preferredModel) { $selectedBrand = Get-ModelBrand $preferredModel }
        }
    }
    if ([string]::IsNullOrWhiteSpace($selectedBrand) -or $selectedBrand -notin $brands) {
        $selectedBrand = if ($brands.Count -gt 0) { [string]$brands[0] } else { "" }
    }
    $BrandCombo.SelectedItem = $selectedBrand
    Refresh-ModelsForBrand -PreferredModelId $PreferredModelId
}

function Select-Route([string]$ProviderId, [string]$ModelId, [string]$Effort, [string]$Brand = "") {
    $provider = Get-ProviderById $ProviderId
    if ($null -eq $provider) {
        $provider = @($script:catalog.providers) | Select-Object -First 1
    }
    if ($null -eq $provider) { return }

    $ProviderCombo.SelectedItem = $provider
    $model = Get-ModelById $provider $ModelId
    $resolvedBrand = $Brand
    if ([string]::IsNullOrWhiteSpace($resolvedBrand) -and $null -ne $model) { $resolvedBrand = Get-ModelBrand $model }
    Refresh-BrandsForProvider -PreferredBrand $resolvedBrand -PreferredModelId $ModelId
    if ($Effort -in @("low","medium","high")) { $EffortCombo.SelectedItem = $Effort }
    Refresh-RouteStatus
}

function Reload-ControllerCatalog([switch]$PreserveSelection) {
    $providerId = ""
    $brand = ""
    $modelId = ""
    $effort = [string]$EffortCombo.SelectedItem
    if ($PreserveSelection) {
        if ($null -ne $ProviderCombo.SelectedItem) { $providerId = [string]$ProviderCombo.SelectedItem.id }
        $brand = [string]$BrandCombo.SelectedItem
        if ($null -ne $ModelCombo.SelectedItem) { $modelId = [string]$ModelCombo.SelectedItem.id }
    }

    $script:loadingCatalog = $true
    try {
        $script:catalog = Get-ControllerCatalog -StaticCatalogPath $staticCatalogPath -ApprovedModelsPath $approvedModelsPath
        $ProviderCombo.ItemsSource = @($script:catalog.providers)
        Refresh-CatalogStatus
    }
    finally {
        $script:loadingCatalog = $false
    }

    if ([string]::IsNullOrWhiteSpace($providerId)) {
        $state = Load-ControllerState
        $providerId = if ($state.PSObject.Properties["last_provider"] -and -not [string]::IsNullOrWhiteSpace([string]$state.last_provider)) { [string]$state.last_provider } else { "chatgpt" }
        $brand = if ($state.PSObject.Properties["last_brand"]) { [string]$state.last_brand } else { "" }
        $modelId = if ($state.PSObject.Properties["last_model_id"] -and -not [string]::IsNullOrWhiteSpace([string]$state.last_model_id)) { [string]$state.last_model_id } else { "__account_default__" }
        $effort = if ($state.PSObject.Properties["last_effort"] -and ([string]$state.last_effort -in @("low","medium","high"))) { [string]$state.last_effort } else { "medium" }
    }

    Select-Route -ProviderId $providerId -ModelId $modelId -Effort $effort -Brand $brand
    Refresh-HealthDashboard
}

function Start-SelectedSession {
    $provider = $ProviderCombo.SelectedItem
    $brand = [string]$BrandCombo.SelectedItem
    $model = $ModelCombo.SelectedItem
    $effort = [string]$EffortCombo.SelectedItem
    $workspace = $WorkspaceCombo.Text.Trim()

    if ($null -eq $provider -or $null -eq $model) {
        [System.Windows.MessageBox]::Show("请先选择 Provider、模型品牌和模型型号。","Codex Controller","OK","Warning") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($workspace) -or -not (Test-Path -LiteralPath $workspace)) {
        [System.Windows.MessageBox]::Show("请先选择有效的工作目录。","Codex Controller","OK","Warning") | Out-Null
        return
    }
    if (-not (Test-ProviderKey ([string]$provider.env_key))) {
        [System.Windows.MessageBox]::Show("$($provider.label) 的 API Key 尚未配置。请先运行 Provider 配置。","Codex Controller","OK","Warning") | Out-Null
        return
    }

    $resolved = (Resolve-Path -LiteralPath $workspace).Path
    $gitInfo = Get-GitInfo $resolved
    if ($gitInfo.IsRepo -and $gitInfo.Dirty) {
        $answer = [System.Windows.MessageBox]::Show(
            "工作区有未提交变更。Controller 不会 reset、clean 或 stash。仍要启动新 Codex 会话吗？",
            "Codex Controller",
            "YesNo",
            "Warning"
        )
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }

    $launcher = Join-Path $PSScriptRoot "launch-controller-model.ps1"
    $args = @(
        "-ProjectPath", ('"{0}"' -f $resolved),
        "-Provider", [string]$provider.id,
        "-ModelId", [string]$model.id,
        "-ReasoningEffort", $effort
    )
    Start-PwshScript -ScriptPath $launcher -WorkingDirectory $resolved -ExtraArgs $args

    $stateArgs = @{
        WorkspacePath = $resolved
        LastProvider = [string]$provider.id
        LastBrand = $brand
        LastModelId = [string]$model.id
        LastModelLabel = [string]$model.label
        LastEffort = $effort
    }
    Save-ControllerState @stateArgs
    Refresh-WorkspaceCandidates -PreferredPath $resolved
    Refresh-LastModelStatus
    $LaunchStatusText.Text = "已启动新会话：$($model.label) · $brand · $($provider.label) · $effort"
}

$ProviderCombo.Add_SelectionChanged({
    if ($script:loadingCatalog) { return }
    if ($null -ne $ProviderCombo.SelectedItem) { Refresh-BrandsForProvider }
    Refresh-RouteStatus
})
$BrandCombo.Add_SelectionChanged({
    if ($script:loadingCatalog) { return }
    Refresh-ModelsForBrand
    Refresh-RouteStatus
})
$ModelCombo.Add_SelectionChanged({ if (-not $script:loadingCatalog) { Refresh-RouteStatus } })
$EffortCombo.Add_SelectionChanged({ if (-not $script:loadingCatalog) { Refresh-RouteStatus } })
$LaunchSelectedButton.Add_Click({ Start-SelectedSession })
$ReloadCatalogButton.Add_Click({
    Reload-ControllerCatalog -PreserveSelection
    $LaunchStatusText.Text = "模型目录与健康状态已刷新；只读取固定目录和已批准模型。"
})
$RefreshHealthDashboardButton.Add_Click({ Refresh-HealthDashboard })

foreach ($name in @("PresetGPT","PresetQwen","PresetDeepSeek","PresetOx","PresetGLM","PresetMiMo")) {
    $button = $window.FindName($name)
    $button.Add_Click({
        param($sender,$eventArgs)
        $parts = ([string]$sender.Tag).Split('|')
        Select-Route $parts[0] $parts[1] $parts[2]
        Start-SelectedSession
    })
}

$WorkspaceCombo.Add_SelectionChanged({
    if (-not $script:loadingWorkspaces -and $null -ne $WorkspaceCombo.SelectedItem) {
        $WorkspaceCombo.Text = [string]$WorkspaceCombo.SelectedItem
        Refresh-WorkspaceStatus
    }
})
$WorkspaceCombo.Add_LostKeyboardFocus({ if (-not $script:loadingWorkspaces) { Refresh-WorkspaceStatus } })

$BrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "选择新 Codex 会话的工作目录"
    $dialog.ShowNewFolderButton = $false
    if (Test-Path -LiteralPath $WorkspaceCombo.Text) { $dialog.SelectedPath = $WorkspaceCombo.Text }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $WorkspaceCombo.Text = $dialog.SelectedPath
        Refresh-WorkspaceCandidates -PreferredPath $dialog.SelectedPath
        Refresh-WorkspaceStatus
    }
})

$RefreshButton.Add_Click({ Refresh-WorkspaceCandidates -PreferredPath $WorkspaceCombo.Text; Refresh-WorkspaceStatus; Refresh-RouteStatus; Refresh-LastModelStatus })
$HealthButton.Add_Click({ Start-PwshScript -ScriptPath (Join-Path $PSScriptRoot "health-check.ps1") -WorkingDirectory $WorkspaceCombo.Text })
$HandoffButton.Add_Click({ Start-PwshScript -ScriptPath (Join-Path $PSScriptRoot "resume-handoff.ps1") -WorkingDirectory $WorkspaceCombo.Text })
$UpdateCenterButton.Add_Click({ Start-PwshScript -ScriptPath (Join-Path $PSScriptRoot "model-update-center.ps1") -WorkingDirectory $WorkspaceCombo.Text })
$SetupButton.Add_Click({ Start-PwshScript -ScriptPath (Resolve-Path (Join-Path $PSScriptRoot "..\setup.ps1")).Path -WorkingDirectory (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path })
$SwitcherButton.Add_Click({ Start-PwshScript -ScriptPath (Join-Path $PSScriptRoot "switch-model.ps1") -WorkingDirectory $WorkspaceCombo.Text })

$initialWorkspace = Resolve-InitialWorkspace
Refresh-WorkspaceCandidates -PreferredPath $initialWorkspace
$WorkspaceCombo.Text = $initialWorkspace
Refresh-WorkspaceStatus
Refresh-LastModelStatus
Reload-ControllerCatalog

$window.ShowDialog() | Out-Null
