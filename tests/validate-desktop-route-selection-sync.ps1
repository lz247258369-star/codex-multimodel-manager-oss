param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot ".."))
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) {
    Write-Host "FAIL  $Message" -ForegroundColor Red
    $failures.Add($Message)
}

$displayRuntimePath = Join-Path $RepositoryRoot "installer\scripts\visual-combo-display-runtime.ps1"
$scopeFixPath = Join-Path $RepositoryRoot "installer\scripts\visual-desktop-route-scope-fix.ps1"

foreach ($path in @($displayRuntimePath,$scopeFixPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "Desktop route UI runtime exists: $path"
        continue
    }
    Pass "Desktop route UI runtime exists: $path"
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if (@($parseErrors).Count -eq 0) { Pass "PowerShell parses: $path" }
    else { Fail ("PowerShell parse errors for ${path}: " + ((@($parseErrors) | ForEach-Object Message) -join "; ")) }
}

if ((Test-Path -LiteralPath $displayRuntimePath) -and (Test-Path -LiteralPath $scopeFixPath)) {
    $displayText = Get-Content -Raw -LiteralPath $displayRuntimePath
    $scopeText = Get-Content -Raw -LiteralPath $scopeFixPath

    if ($displayText.Contains('Manager 待启动模型')) { Pass "Hero explicitly represents Manager pending model" }
    else { Fail "Hero pending-model label missing" }

    if ($scopeText.Contains('function Sync-ManagerSelectionToDesktopRoute')) { Pass "Compatibility sync hook exists" }
    else { Fail "Compatibility sync hook missing" }

    if ($scopeText.Contains('Update-DesktopRouteClarity') -and $scopeText.Contains('Update-DynamicDesktopRouteControls')) {
        Pass "Desktop route sync updates status/buttons only"
    }
    else { Fail "Desktop route status/button refresh missing" }

    if ($scopeText -notmatch 'Refresh-ProviderSelection') {
        Pass "Desktop route sync cannot overwrite Manager Provider/Model selection"
    }
    else { Fail "Desktop route sync still mutates Manager selection" }

    if ($scopeText -notmatch '(?i)\bgit\s+(reset|stash|clean)\b') { Pass "Desktop route sync does not mutate Git worktrees" }
    else { Fail "Desktop route sync contains destructive Git behavior" }

    # Execute the compatibility hook with guards. Any attempt to mutate the
    # Manager selectors must fail this test immediately.
    $script:clarityCalls = 0
    $script:controlCalls = 0
    function Get-DynamicDesktopRouteState { return $null }
    function Test-DynamicDesktopRouteActive($State) { return $false }
    function Get-DynamicDesktopRouteLabel($State) { return "" }
    function Get-ColorBrush([string]$Value) { return $Value }
    function Update-DynamicDesktopRouteControls { $script:controlCalls++ }
    function Refresh-ProviderSelection { throw "Manager selection mutation is forbidden from Desktop route sync" }
    $desktopRouteText = [pscustomobject]@{ Text=""; FontSize=0; FontWeight=$null; Foreground=$null }
    Add-Type -AssemblyName PresentationFramework

    . $scopeFixPath
    Sync-ManagerSelectionToDesktopRoute

    if ($script:controlCalls -eq 1) { Pass "Compatibility hook refreshed dynamic Desktop controls" }
    else { Fail "Dynamic Desktop controls were not refreshed exactly once" }

    if ([string]$desktopRouteText.Text -eq "当前桌面 Chat：ChatGPT / OpenAI 默认路由") {
        Pass "Compatibility hook refreshed Desktop route status"
    }
    else { Fail "Desktop route status was not refreshed" }
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Desktop route selection isolation validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Desktop route selection isolation validation PASSED" -ForegroundColor Green
