param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

$cmdPath = Join-Path $RepositoryRoot "installer/CODEX_VISUAL_CONSOLE.cmd"
$vbsPath = Join-Path $RepositoryRoot "installer/LAUNCH_VISUAL_CONSOLE.vbs"
$singleInstancePath = Join-Path $RepositoryRoot "installer/scripts/visual-console-single-instance.ps1"
$entryPath = Join-Path $RepositoryRoot "installer/scripts/visual-console-entry.ps1"
$scriptPath = Join-Path $RepositoryRoot "installer/scripts/visual-console.ps1"
$xamlPath = Join-Path $RepositoryRoot "installer/ui/visual-console.xaml"
$catalogHelper = Join-Path $RepositoryRoot "installer/scripts/controller-catalog.ps1"
$healthHelper = Join-Path $RepositoryRoot "installer/scripts/controller-health.ps1"
$launcher = Join-Path $RepositoryRoot "installer/scripts/launch-controller-model.ps1"

foreach ($path in @($cmdPath,$vbsPath,$singleInstancePath,$entryPath,$scriptPath,$xamlPath,$catalogHelper,$healthHelper,$launcher)) {
    if (Test-Path -LiteralPath $path) { Pass "Exists: $($path.Substring($RepositoryRoot.Length + 1))" }
    else { Fail "Missing: $($path.Substring($RepositoryRoot.Length + 1))" }
}

foreach ($path in @($singleInstancePath,$entryPath,$scriptPath)) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) { Pass "PowerShell parses: $($path.Substring($RepositoryRoot.Length + 1))" }
    else { foreach ($err in $parseErrors) { Fail "PowerShell parse error: $($err.Message)" } }
}

if (Test-Path -LiteralPath $entryPath) {
    $entry = Get-Content -Raw -LiteralPath $entryPath
    foreach ($needle in @(
        'visual-console\.ps1','Argument types do not match','\$script:modelCards = @\(\$cards\)',
        '\$script:modelCards = \$cards\.ToArray\(\)','ScriptBlock\]::Create','rootLiteral'
    )) {
        if ($entry -match $needle) { Pass "Compatibility entry behavior present: $needle" }
        else { Fail "Compatibility entry behavior missing: $needle" }
    }
    if ($entry -match '(?im)\bgit\s+(reset|clean|stash)\b') { Fail "Compatibility entry contains destructive Git command" }
    else { Pass "Compatibility entry does not mutate Git worktrees" }
    if ($entry -match '(?i)OPENROUTER_API_KEY|MIMO_API_KEY|DASHSCOPE|API[_ ]?KEY') { Fail "Compatibility entry should be secret-independent" }
    else { Pass "Compatibility entry is secret-independent" }
}

if (Test-Path -LiteralPath $singleInstancePath) {
    $guard = Get-Content -Raw -LiteralPath $singleInstancePath
    foreach ($needle in @('Local\CodexMultiModelManagerV4','System.Threading.Mutex','visual-console-entry.ps1')) {
        if ($guard.Contains($needle)) { Pass "Process single-instance guard present: $needle" }
        else { Fail "Process single-instance guard missing: $needle" }
    }
}

if (Test-Path -LiteralPath $scriptPath) {
    $text = Get-Content -Raw -LiteralPath $scriptPath
    foreach ($needle in @(
        'controller-catalog\.ps1','controller-health\.ps1','launch-controller-model\.ps1',
        'model-update-center\.ps1','stealth-model-center\.ps1','health-check\.ps1','resume-handoff\.ps1',
        'visual-console-state\.json','Get-WorkspaceCandidates','Get-GitInfo','Confirm-WorkspaceForLaunch',
        'ProviderCombo','BrandCombo','ModelCombo','EffortCombo','DashboardModelList','ProvidersPageList',
        'Start-SelectedModel','Dirty worktree','Provider 未就绪','OpenLegacyControllerButton'
    )) {
        if ($text -match $needle) { Pass "Visual Console behavior present: $needle" }
        else { Fail "Visual Console behavior missing: $needle" }
    }

    if ($text -match '(?im)\bgit\s+(reset|clean|stash)\b') { Fail "Visual Console contains destructive Git command" }
    else { Pass "Visual Console does not reset/clean/stash worktrees" }

    if ($text -match '(?i)Invoke-RestMethod|Invoke-WebRequest|/responses') { Fail "Visual Console directly performs provider network/inference calls" }
    else { Pass "Visual Console itself is local-only and delegates existing gated tools" }

    if ($text -match '(?i)Write-Host\s+.*API[_ ]?Key|MessageBox.*API[_ ]?Key.*\$env:') { Fail "Visual Console may display a secret value" }
    else { Pass "Visual Console has no direct API-key value display path" }
}

if (Test-Path -LiteralPath $xamlPath) {
    $xamlText = Get-Content -Raw -LiteralPath $xamlPath
    try {
        [xml]$xamlXml = $xamlText
        Pass "Visual Console XAML is well-formed XML"
    }
    catch {
        Fail "Visual Console XAML invalid: $($_.Exception.Message)"
    }

    foreach ($name in @(
        'NavDashboard','NavModels','NavProviders','NavStealth','NavTools','MainTabs',
        'LaunchCurrentButton','WorkspaceCombo','GitStatusText','DashboardModelList',
        'ProviderCombo','BrandCombo','ModelCombo','EffortCombo','ModelsLaunchButton',
        'DashboardProviderHealthList','ProvidersPageList','StealthLaunchOxButton','ToolsHandoffButton'
    )) {
        if ($xamlText -match ('x:Name="' + [regex]::Escape($name) + '"')) { Pass "XAML control present: $name" }
        else { Fail "XAML control missing: $name" }
    }

    foreach ($visual in @('#070B16','#0E1526','AccentGradient','ModelCardTemplate','ProviderCardTemplate','V4.0')) {
        if ($xamlText.Contains($visual)) { Pass "Visual system token present: $visual" }
        else { Fail "Visual system token missing: $visual" }
    }

    foreach ($needle in @(
        'x:Key="DarkComboItem"',
        'x:Key="DarkCombo"',
        'x:Name="PART_EditableTextBox"',
        'x:Name="PART_Popup"',
        'Background="#0A1120"',
        'ItemContainerStyle" Value="{StaticResource DarkComboItem}"',
        'x:Name="WorkspaceCombo" Style="{StaticResource DarkCombo}"'
    )) {
        if ($xamlText.Contains($needle)) { Pass "Dark ComboBox contract present: $needle" }
        else { Fail "Dark ComboBox contract missing: $needle" }
    }

    try {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase
        [xml]$runtimeXaml = $xamlText
        $reader = New-Object System.Xml.XmlNodeReader $runtimeXaml
        $window = [Windows.Markup.XamlReader]::Load($reader)
        if ($null -ne $window -and $null -ne $window.FindName('LaunchCurrentButton')) {
            Pass "Visual Console XAML loads in WPF runtime"
        }
        else {
            Fail "Visual Console WPF runtime load returned missing controls"
        }

        try {
            $darkComboStyle = $window.FindResource('DarkCombo')
            $darkComboItemStyle = $window.FindResource('DarkComboItem')
            $workspaceCombo = $window.FindName('WorkspaceCombo')
            if ($darkComboStyle -is [System.Windows.Style] -and
                $darkComboItemStyle -is [System.Windows.Style] -and
                $null -ne $workspaceCombo -and
                $workspaceCombo.Style -eq $darkComboStyle) {
                Pass "Dark ComboBox resources load and CLI workspace uses them"
            }
            else {
                Fail "Dark ComboBox resources or CLI workspace style binding are invalid"
            }
        }
        catch {
            Fail "Dark ComboBox WPF runtime probe failed: $($_.Exception.Message)"
        }

        $window.Close()
    }
    catch {
        Fail "Visual Console WPF runtime load failed: $($_.Exception.Message)"
    }
}

if (Test-Path -LiteralPath $cmdPath) {
    $cmd = Get-Content -Raw -LiteralPath $cmdPath
    if ($cmd -match '(?i)pwsh\.exe' -and $cmd -match '(?i)-STA' -and $cmd -match 'visual-console-entry\.ps1') { Pass "Visible V4 launcher uses PowerShell 7 STA compatibility entrypoint" }
    else { Fail "Visible V4 launcher target/runtime invalid" }
}

if (Test-Path -LiteralPath $vbsPath) {
    $vbs = Get-Content -Raw -LiteralPath $vbsPath
    if ($vbs -match 'visual-console-single-instance\.ps1' -and $vbs -match 'pwsh\.exe' -and $vbs -match 'shell\.Run command, 0, False') {
        Pass "Silent V4 launcher targets the process-level single-instance guard"
    }
    else {
        Fail "Silent V4 launcher target/runtime invalid"
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "V4 Visual Console validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "V4 Visual Console validation PASSED" -ForegroundColor Green
exit 0
