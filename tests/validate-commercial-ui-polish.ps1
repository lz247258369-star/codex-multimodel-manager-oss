param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

$effectsPath = Join-Path $RepositoryRoot "installer/scripts/visual-commercial-effects.ps1"
$readabilityPath = Join-Path $RepositoryRoot "installer/scripts/visual-sidebar-readability.ps1"
$comboDisplayPath = Join-Path $RepositoryRoot "installer/scripts/visual-combo-display-runtime.ps1"
$entryPath = Join-Path $RepositoryRoot "installer/scripts/visual-console-entry.ps1"

if (-not (Test-Path -LiteralPath $effectsPath)) {
    Fail "Missing commercial effects runtime"
}
else {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($effectsPath,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) { Pass "Commercial effects runtime parses" }
    else { foreach ($err in $parseErrors) { Fail "PowerShell parse error: $($err.Message)" } }

    $text = Get-Content -Raw -LiteralPath $effectsPath
    foreach ($needle in @(
        'function global:New-CommercialAnimation',
        'Register-CommercialCardMotion',
        'Register-CommercialButtonMotion',
        'commercialModelItemStyleXaml',
        'commercialModelTemplateXaml',
        'commercialProviderTemplateXaml',
        'DropShadowEffect',
        'MouseEnter',
        'MouseLeave',
        'CardLift',
        'PriceText',
        'PerformanceText',
        'StatusText'
    )) {
        if ($text.Contains($needle)) { Pass "Commercial UI behavior present: $needle" }
        else { Fail "Commercial UI behavior missing: $needle" }
    }

    if ($text -match '(?i)RepeatBehavior\s*=\s*["'']Forever') { Fail "Commercial polish must not use infinite decorative animation" }
    else { Pass "No infinite decorative animation" }

    if ($text -match 'To="1\.(0[3-9]|[1-9][0-9])') { Fail "Hover scaling is too aggressive for commercial UI" }
    else { Pass "Hover scaling stays subtle" }

    try {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $factoryMatch = [regex]::Match($text, '(?ms)^function global:New-CommercialAnimation.*?^}')
        if (-not $factoryMatch.Success) {
            Fail "Could not extract global commercial animation factory"
        }
        else {
            try {
                & ([ScriptBlock]::Create($factoryMatch.Value))
                $factoryCommand = Get-Command New-CommercialAnimation -CommandType Function -ErrorAction Stop
                $probeAnimation = New-CommercialAnimation -To 1.01 -Milliseconds 10
                if ($null -ne $factoryCommand -and $probeAnimation -is [System.Windows.Media.Animation.DoubleAnimation]) {
                    Pass "Commercial animation factory survives event-scope command lookup"
                }
                else {
                    Fail "Commercial animation factory did not create a DoubleAnimation"
                }
            }
            catch {
                Fail "Commercial animation factory runtime probe failed: $($_.Exception.Message)"
            }
            finally {
                Remove-Item Function:\New-CommercialAnimation -ErrorAction SilentlyContinue
            }
        }

        $styleMatch = [regex]::Match($text, '(?s)\$commercialModelItemStyleXaml\s*=\s*@''\r?\n(.*?)\r?\n''@')
        $modelMatch = [regex]::Match($text, '(?s)\$commercialModelTemplateXaml\s*=\s*@''\r?\n(.*?)\r?\n''@')
        $providerMatch = [regex]::Match($text, '(?s)\$commercialProviderTemplateXaml\s*=\s*@''\r?\n(.*?)\r?\n''@')
        foreach ($pair in @(
            [pscustomobject]@{Name='model item style';Match=$styleMatch},
            [pscustomobject]@{Name='model card template';Match=$modelMatch},
            [pscustomobject]@{Name='provider card template';Match=$providerMatch}
        )) {
            if (-not $pair.Match.Success) {
                Fail "Could not extract $($pair.Name) XAML"
                continue
            }
            try {
                [void][Windows.Markup.XamlReader]::Parse($pair.Match.Groups[1].Value)
                Pass "$($pair.Name) XAML parses"
            }
            catch { Fail "$($pair.Name) XAML parse failed: $($_.Exception.Message)" }
        }
    }
    catch { Fail "WPF validation setup failed: $($_.Exception.Message)" }
}

if (-not (Test-Path -LiteralPath $readabilityPath)) {
    Fail "Missing right-rail readability runtime"
}
else {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($readabilityPath,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) { Pass "Right-rail readability runtime parses" }
    else { foreach ($err in $parseErrors) { Fail "Right-rail readability parse error: $($err.Message)" } }

    $readability = Get-Content -Raw -LiteralPath $readabilityPath
    foreach ($needle in @(
        '$script:providerReadableTemplateXaml',
        'function global:Set-RightRailButtonReadability',
        'HealthSummaryText',
        '#A9B7CE',
        'FontSize="14"',
        'FontSize="12"',
        '#F6F8FF',
        '#304A73'
    )) {
        if ($readability.Contains($needle)) { Pass "Right-rail readability token present: $needle" }
        else { Fail "Right-rail readability token missing: $needle" }
    }

    try {
        Add-Type -AssemblyName PresentationFramework
        $readableProviderMatch = [regex]::Match($readability, '(?s)\$script:providerReadableTemplateXaml\s*=\s*@''\r?\n(.*?)\r?\n''@')
        if (-not $readableProviderMatch.Success) {
            Fail "Could not extract readable provider-card XAML"
        }
        else {
            [void][Windows.Markup.XamlReader]::Parse($readableProviderMatch.Groups[1].Value)
            Pass "Readable provider-card XAML parses"
        }
    }
    catch { Fail "Readable provider-card XAML parse failed: $($_.Exception.Message)" }
}

if (-not (Test-Path -LiteralPath $comboDisplayPath)) {
    Fail "Missing ComboBox display runtime"
}
else {
    $comboDisplay = Get-Content -Raw -LiteralPath $comboDisplayPath
    if ($comboDisplay.Contains('visual-sidebar-readability.ps1')) { Pass "Combo display runtime wires right-rail readability" }
    else { Fail "Combo display runtime does not wire right-rail readability" }
}

if (-not (Test-Path -LiteralPath $entryPath)) {
    Fail "Missing Visual Console entrypoint"
}
else {
    $entry = Get-Content -Raw -LiteralPath $entryPath
    foreach ($needle in @(
        'visual-commercial-effects.ps1',
        '$commercialEffectsPath',
        'Visual commercial effects runtime not found'
    )) {
        if ($entry.Contains($needle)) { Pass "Entrypoint loads commercial polish: $needle" }
        else { Fail "Entrypoint missing commercial polish wiring: $needle" }
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Commercial UI polish validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "Commercial UI polish validation PASSED" -ForegroundColor Green
exit 0
