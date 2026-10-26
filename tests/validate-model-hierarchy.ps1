param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

$catalogPath = Join-Path $RepositoryRoot "installer/model-catalog.json"
$catalogHelperPath = Join-Path $RepositoryRoot "installer/scripts/controller-catalog.ps1"
$hierarchyPath = Join-Path $RepositoryRoot "installer/scripts/visual-hierarchy-runtime.ps1"
$comboDisplayPath = Join-Path $RepositoryRoot "installer/scripts/visual-combo-display-runtime.ps1"
$entryPath = Join-Path $RepositoryRoot "installer/scripts/visual-console-entry.ps1"
$controllerLaunchPath = Join-Path $RepositoryRoot "installer/scripts/launch-controller-model.ps1"
$oxLaunchPath = Join-Path $RepositoryRoot "installer/scripts/launch-ox-alpha.ps1"
$stealthLaunchPath = Join-Path $RepositoryRoot "installer/scripts/launch-stealth-model.ps1"

foreach ($path in @($catalogPath,$catalogHelperPath,$hierarchyPath,$comboDisplayPath,$entryPath,$controllerLaunchPath,$oxLaunchPath,$stealthLaunchPath)) {
    if (Test-Path -LiteralPath $path) { Pass "Exists: $($path.Substring($RepositoryRoot.Length + 1))" }
    else { Fail "Missing: $($path.Substring($RepositoryRoot.Length + 1))" }
}

foreach ($path in @($catalogHelperPath,$hierarchyPath,$comboDisplayPath,$entryPath,$controllerLaunchPath,$oxLaunchPath,$stealthLaunchPath)) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) { Pass "PowerShell parses: $($path.Substring($RepositoryRoot.Length + 1))" }
    else { foreach ($err in $parseErrors) { Fail "Parse error in $($path.Substring($RepositoryRoot.Length + 1)): $($err.Message)" } }
}

if (Test-Path -LiteralPath $catalogPath) {
    try { $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json }
    catch { Fail "model-catalog.json is invalid JSON: $($_.Exception.Message)"; $catalog = $null }

    if ($null -ne $catalog) {
        if ([int]$catalog.version -ge 3) { Pass "Catalog schema version >= 3" } else { Fail "Catalog schema version must be >= 3" }
        if ([string]$catalog.price_basis -eq "USD per 1M tokens") { Pass "Catalog declares price basis" } else { Fail "Catalog price basis missing or unexpected" }

        foreach ($provider in @($catalog.providers)) {
            foreach ($model in @($provider.models)) {
                foreach ($property in @("vendor","family","variant","performance_levels","price_input","price_output","price_currency","price_source","price_updated_at")) {
                    if ($model.PSObject.Properties[$property]) { }
                    else { Fail "Model $($model.id) missing property: $property" }
                }
                if (@($model.performance_levels).Count -eq 0) { Fail "Model $($model.id) has no performance levels" }
                # DSR2: "max" is a legal canonical performance level (DeepSeek
                # official), while the historical levels stay legal. A level
                # outside the known set still fails closed.
                $unknownLevels = @(@($model.performance_levels) | Where-Object { [string]$_ -notin @("low", "medium", "high", "xhigh", "max") })
                if ($unknownLevels.Count -gt 0) { Fail "Model $($model.id) declares unknown performance levels: $($unknownLevels -join ', ')" }
            }
        }

        # DSR2: only the direct DeepSeek official models may expose "max" - the
        # capability must never be granted to every model automatically.
        $maxLevelProviderIds = @()
        foreach ($provider in @($catalog.providers)) {
            foreach ($model in @($provider.models)) {
                if (@($model.performance_levels) -contains "max") { $maxLevelProviderIds += [string]$provider.id }
            }
        }
        if (($maxLevelProviderIds | Sort-Object -Unique) -join "," -eq "deepseek") {
            Pass "Only the direct DeepSeek provider declares the max performance level"
        }
        else {
            Fail "Only direct DeepSeek models may declare max; found providers: $(($maxLevelProviderIds | Sort-Object -Unique) -join ', ')"
        }
        $allModels = @($catalog.providers | ForEach-Object { @($_.models) })
        $sol = @($allModels | Where-Object { $_.id -eq "gpt-5.6-sol" }) | Select-Object -First 1
        $terra = @($allModels | Where-Object { $_.id -eq "gpt-5.6-terra" }) | Select-Object -First 1
        $luna = @($allModels | Where-Object { $_.id -eq "gpt-5.6-luna" }) | Select-Object -First 1
        $ox = @($allModels | Where-Object { $_.id -eq "stealth/ox-alpha" }) | Select-Object -First 1

        if ($null -ne $sol -and [double]$sol.price_input -eq 5.0 -and [double]$sol.price_output -eq 30.0) { Pass "GPT-5.6 Sol reference price present" } else { Fail "GPT-5.6 Sol reference price mismatch" }
        if ($null -ne $terra -and [double]$terra.price_input -eq 2.0 -and [double]$terra.price_output -eq 12.0) { Pass "GPT-5.6 Terra reference price present" } else { Fail "GPT-5.6 Terra reference price mismatch" }
        if ($null -ne $luna -and [double]$luna.price_input -eq 0.2 -and [double]$luna.price_output -eq 1.2) { Pass "GPT-5.6 Luna reference price present" } else { Fail "GPT-5.6 Luna reference price mismatch" }
        if ($null -ne $sol -and "xhigh" -in @($sol.performance_levels)) { Pass "GPT-5.6 Sol exposes xhigh" } else { Fail "GPT-5.6 Sol missing xhigh" }
        if ($null -ne $ox -and "xhigh" -in @($ox.performance_levels)) { Pass "Ox Alpha exposes xhigh" } else { Fail "Ox Alpha missing xhigh" }
        $directFlash = @($allModels | Where-Object { $_.id -eq "deepseek-flash" }) | Select-Object -First 1
        $directPro = @($allModels | Where-Object { $_.id -eq "deepseek-v4-pro" -and @($_.performance_levels) -contains "max" }) | Select-Object -First 1
        if ($null -ne $directFlash -and (@($directFlash.performance_levels) -join ",") -eq "low,high,max") { Pass "Direct DeepSeek flash exposes low/high/max" } else { Fail "Direct DeepSeek flash performance levels must be low/high/max" }
        if ($null -ne $directPro) { Pass "Direct DeepSeek pro exposes max" } else { Fail "Direct DeepSeek pro must expose max" }
    }
}

if (Test-Path -LiteralPath $hierarchyPath) {
    $text = Get-Content -Raw -LiteralPath $hierarchyPath
    foreach ($needle in @(
        'VendorCombo','FamilyCombo','VariantCombo','PerformanceCombo',
        '厂商','模型系列','版本型号','性能',
        '输入价：低 → 高','输出价：低 → 高','性能：高 → 低',
        'API参考价','价格待同步','后台 Provider',
        'Refresh-ModelCards','Sort-Object','xhigh'
    )) {
        if ($text.Contains($needle)) { Pass "Hierarchy runtime behavior present: $needle" }
        else { Fail "Hierarchy runtime missing behavior: $needle" }
    }
}

if (Test-Path -LiteralPath $comboDisplayPath) {
    $text = Get-Content -Raw -LiteralPath $comboDisplayPath
    foreach ($needle in @(
        'New-ComboTextTemplate','BindingPath','Display','Label',
        '$VariantCombo.ItemTemplate','$PerformanceCombo.ItemTemplate',
        '$DashboardSortCombo.ItemTemplate','$ModelsSortCombo.ItemTemplate'
    )) {
        if ($text.Contains($needle)) { Pass "Combo object-label display behavior present: $needle" }
        else { Fail "Combo object-label display behavior missing: $needle" }
    }
    if ($text.Contains('$VariantCombo.DisplayMemberPath = ""') -and $text.Contains('$PerformanceCombo.DisplayMemberPath = ""')) {
        Pass "Object-backed hierarchy combos do not depend on default DisplayMemberPath selection rendering"
    }
    else { Fail "Object-backed hierarchy combo DisplayMemberPath fallback was not disabled" }
}

if (Test-Path -LiteralPath $entryPath) {
    $text = Get-Content -Raw -LiteralPath $entryPath
    foreach ($needle in @('visual-hierarchy-runtime.ps1','visual-combo-display-runtime.ps1','hierarchy injection anchor','CLI 工作目录','选择 CLI 目录')) {
        if ($text.Contains($needle)) { Pass "Entrypoint integration present: $needle" }
        else { Fail "Entrypoint hierarchy/workspace integration missing: $needle" }
    }
}

if (Test-Path -LiteralPath $controllerLaunchPath) {
    $text = Get-Content -Raw -LiteralPath $controllerLaunchPath
    if ($text.Contains('[ValidateSet("low","medium","high","xhigh")]')) { Pass "Controller launcher accepts xhigh" } else { Fail "Controller launcher missing xhigh ValidateSet" }
    if ($text.Contains('-ReasoningEffort $Effort')) { Pass "Controller passes selected effort to Ox launcher" } else { Fail "Controller does not pass effort to Ox launcher" }
}

if (Test-Path -LiteralPath $oxLaunchPath) {
    $text = Get-Content -Raw -LiteralPath $oxLaunchPath
    if ($text.Contains('-ReasoningEffort $ReasoningEffort')) { Pass "Ox launcher forwards selected effort" } else { Fail "Ox launcher does not forward effort" }
}

if (Test-Path -LiteralPath $stealthLaunchPath) {
    $text = Get-Content -Raw -LiteralPath $stealthLaunchPath
    if ($text.Contains('model_reasoning_effort')) { Pass "Stealth launcher applies reasoning effort" } else { Fail "Stealth launcher does not apply reasoning effort" }
}

if ((Test-Path -LiteralPath $catalogHelperPath) -and (Test-Path -LiteralPath $catalogPath)) {
    try {
        . $catalogHelperPath
        $tempApproved = Join-Path ([System.IO.Path]::GetTempPath()) ("approved-models-" + [guid]::NewGuid().ToString("N") + ".json")
        @(
            [ordered]@{
                model_id = "anthropic/claude-test-approved"
                display_name = "Claude Test Approved"
                provider_id = "mm_openrouter"
                basic_probe = "PASS"
                tool_probe = "PASS"
                approved_at = "2026-08-25T00:00:00Z"
                profile_id = "test"
            }
        ) | ConvertTo-Json | Set-Content -LiteralPath $tempApproved -Encoding UTF8

        $merged = Get-ControllerCatalog -StaticCatalogPath $catalogPath -ApprovedModelsPath $tempApproved
        $dynamic = @($merged.providers | Where-Object { $_.id -eq "openrouter" } | ForEach-Object { $_.models } | Where-Object { $_.id -eq "anthropic/claude-test-approved" }) | Select-Object -First 1
        if ($null -ne $dynamic -and $dynamic.PSObject.Properties["vendor"] -and $dynamic.PSObject.Properties["family"] -and $dynamic.PSObject.Properties["variant"] -and $dynamic.PSObject.Properties["performance_levels"]) {
            Pass "Approved dynamic models receive hierarchy metadata"
        }
        else { Fail "Approved dynamic model metadata enrichment failed" }
    }
    catch { Fail "Catalog enrichment runtime test failed: $($_.Exception.Message)" }
    finally { if ($tempApproved -and (Test-Path -LiteralPath $tempApproved)) { Remove-Item -LiteralPath $tempApproved -Force } }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Model hierarchy validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "Model hierarchy validation PASSED" -ForegroundColor Green
exit 0
