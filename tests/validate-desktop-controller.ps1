param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$cmdPath = Join-Path $RepositoryRoot "installer/CODEX_DESKTOP_CONTROLLER.cmd"
$controllerPath = Join-Path $RepositoryRoot "installer/scripts/desktop-controller.ps1"
$catalogHelperPath = Join-Path $RepositoryRoot "installer/scripts/controller-catalog.ps1"
$healthHelperPath = Join-Path $RepositoryRoot "installer/scripts/controller-health.ps1"
$launcherPath = Join-Path $RepositoryRoot "installer/scripts/launch-controller-model.ps1"
$catalogPath = Join-Path $RepositoryRoot "installer/model-catalog.json"
$docPath = Join-Path $RepositoryRoot "docs/DESKTOP_CONTROLLER.md"

foreach ($path in @($cmdPath,$controllerPath,$catalogHelperPath,$healthHelperPath,$launcherPath,$catalogPath,$docPath)) {
    if (Test-Path $path) { Pass "Exists: $($path.Substring($RepositoryRoot.Length + 1))" }
    else { Fail "Missing: $($path.Substring($RepositoryRoot.Length + 1))" }
}

foreach ($path in @($controllerPath,$catalogHelperPath,$healthHelperPath,$launcherPath)) {
    if (-not (Test-Path $path)) { continue }
    $tokens=$null; $errors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count -eq 0) { Pass "PowerShell parses: $($path.Substring($RepositoryRoot.Length + 1))" }
    else { foreach ($err in $errors) { Fail "PowerShell parse error: $($err.Message)" } }
}

if (Test-Path $cmdPath) {
    $cmd = Get-Content $cmdPath -Raw
    if ($cmd -match '(?i)pwsh\.exe' -and $cmd -match '(?i)-STA' -and $cmd -match 'desktop-controller\.ps1') { Pass "Desktop entrypoint uses PowerShell 7 STA" }
    else { Fail "Desktop entrypoint is missing pwsh -STA/controller target" }
}

$catalog = $null
if (Test-Path $catalogPath) {
    try { $catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json; Pass "Model catalog JSON parses" }
    catch { Fail "Model catalog JSON invalid: $($_.Exception.Message)" }
    if ($null -ne $catalog) {
        $providerIds = @($catalog.providers | ForEach-Object { $_.id })
        foreach ($id in @('chatgpt','modelstudio','openrouter','mimo')) {
            if ($id -in $providerIds) { Pass "Catalog provider present: $id" } else { Fail "Catalog provider missing: $id" }
        }

        $expectedKeys = @{
            chatgpt = ''
            modelstudio = 'CODEX_DASHSCOPE_API_KEY'
            openrouter = 'OPENROUTER_API_KEY'
            mimo = 'MIMO_API_KEY'
        }
        foreach ($provider in $catalog.providers) {
            if ($expectedKeys.ContainsKey([string]$provider.id)) {
                if ([string]$provider.env_key -eq $expectedKeys[[string]$provider.id]) { Pass "Catalog provider key binding valid: $($provider.id)" }
                else { Fail "Catalog provider key binding invalid: $($provider.id)" }
            }
        }

        $allModels = @($catalog.providers | ForEach-Object { $_.models })
        $modelIds = @($allModels | ForEach-Object { $_.id })
        foreach ($id in @('__account_default__','gpt-5.6-sol','qwen3-coder-plus','deepseek-v4-pro','deepseek-v4-flash','stealth/ox-alpha','z-ai/glm-5.3','mimo-v2.5-pro')) {
            if ($id -in $modelIds) { Pass "Catalog model present: $id" } else { Fail "Catalog model missing: $id" }
        }

        foreach ($model in $allModels) {
            if ($model.PSObject.Properties['brand'] -and -not [string]::IsNullOrWhiteSpace([string]$model.brand)) {
                Pass "Catalog model brand present: $($model.id) -> $($model.brand)"
            }
            else {
                Fail "Catalog model brand missing: $($model.id)"
            }
        }

        $modelStudio = @($catalog.providers | Where-Object { $_.id -eq 'modelstudio' })[0]
        $qwen = @($modelStudio.models | Where-Object { $_.id -eq 'qwen3-coder-plus' })[0]
        $deepseek = @($modelStudio.models | Where-Object { $_.id -eq 'deepseek-v4-pro' })[0]
        if ([string]$qwen.brand -eq 'Qwen') { Pass "Alibaba Qwen brand is separated" } else { Fail "Alibaba Qwen brand mapping is wrong" }
        if ([string]$deepseek.brand -eq 'DeepSeek') { Pass "Alibaba DeepSeek brand is separated" } else { Fail "Alibaba DeepSeek brand mapping is wrong" }
    }
}

if ((Test-Path $catalogHelperPath) -and $null -ne $catalog) {
    . $catalogHelperPath
    $fakeApproved = @(
        [pscustomobject]@{
            provider_id='mm_modelstudio'; model_id='qwen-vnext-approved'; display_name='Qwen VNext Approved';
            profile_id='mm_auto_test_qwen'; approved_at='2026-08-23T00:00:00Z'; basic_probe='PASS'; tool_probe='PASS'
        },
        [pscustomobject]@{
            provider_id='mm_xai'; model_id='grok-approved-but-unsupported-route'; display_name='Grok Approved';
            profile_id='mm_auto_test_grok'; approved_at='2026-08-23T00:00:00Z'; basic_probe='PASS'; tool_probe='PASS'
        },
        [pscustomobject]@{
            provider_id='mm_openrouter'; model_id='candidate-without-pass'; display_name='Candidate Without Pass';
            profile_id='mm_auto_test_fail'; approved_at='2026-08-23T00:00:00Z'; basic_probe='FAIL'; tool_probe='SKIP'
        }
    )
    try {
        $merged = Merge-ControllerCatalog -StaticCatalog $catalog -ApprovedModels $fakeApproved
        $mergedStudio = @($merged.providers | Where-Object { $_.id -eq 'modelstudio' })[0]
        $dynamic = @($mergedStudio.models | Where-Object { $_.id -eq 'qwen-vnext-approved' })[0]
        if ($null -ne $dynamic) { Pass "Approved dynamic model is merged into matching provider" } else { Fail "Approved dynamic model was not merged" }
        if ($null -ne $dynamic -and [string]$dynamic.brand -eq 'Qwen') { Pass "Dynamic model brand is inferred" } else { Fail "Dynamic model brand inference failed" }
        if ($null -ne $dynamic -and [string]$dynamic.source -eq 'approved_registry' -and [string]$dynamic.status -eq 'approved') { Pass "Dynamic model source/status are explicit" } else { Fail "Dynamic model source/status missing" }

        $mergedIds = @($merged.providers | ForEach-Object { $_.models } | ForEach-Object { $_.id })
        if ('grok-approved-but-unsupported-route' -notin $mergedIds) { Pass "Unsupported approved provider is not exposed in GUI" } else { Fail "Unsupported provider leaked into GUI catalog" }
        if ('candidate-without-pass' -notin $mergedIds) { Pass "Non-PASS approved record is fail-closed" } else { Fail "Non-PASS record leaked into GUI catalog" }

        if ([int]$merged.controller_meta.dynamic_added -eq 1) { Pass "Dynamic catalog added count is correct" } else { Fail "Dynamic catalog added count is wrong" }
        if ([int]$merged.controller_meta.ignored_provider -eq 1) { Pass "Unsupported provider count is correct" } else { Fail "Unsupported provider count is wrong" }
        if ([int]$merged.controller_meta.ignored_probe -eq 1) { Pass "Fail-closed probe count is correct" } else { Fail "Fail-closed probe count is wrong" }
    }
    catch {
        Fail "Controller catalog merge runtime failed: $($_.Exception.Message)"
    }
}

if ((Test-Path $healthHelperPath) -and $null -ne $catalog) {
    $healthText = Get-Content $healthHelperPath -Raw
    if ($healthText -match '(?i)Invoke-RestMethod|Invoke-WebRequest|/responses|api\.openrouter|api\.xiaomimimo|dashscope') {
        Fail "Health cockpit helper contains provider-network or inference calls"
    }
    else {
        Pass "Health cockpit helper is local-only and contains no provider HTTP/inference call"
    }

    . $healthHelperPath
    $tempConfig = Join-Path $env:RUNNER_TEMP ("controller-health-" + [guid]::NewGuid().ToString("N") + ".toml")
    $oldDash = [Environment]::GetEnvironmentVariable('CODEX_DASHSCOPE_API_KEY',[EnvironmentVariableTarget]::Process)
    $oldRouter = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY',[EnvironmentVariableTarget]::Process)
    $oldMimo = [Environment]::GetEnvironmentVariable('MIMO_API_KEY',[EnvironmentVariableTarget]::Process)
    try {
        @'
[model_providers.mm_modelstudio]
base_url = "https://example.invalid/v1"
[model_providers.mm_openrouter]
base_url = "https://example.invalid/v1"
[model_providers.mm_mimo]
base_url = "https://example.invalid/v1"
'@ | Set-Content -LiteralPath $tempConfig -Encoding UTF8
        [Environment]::SetEnvironmentVariable('CODEX_DASHSCOPE_API_KEY','TEST_DASH_SECRET',[EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY','TEST_ROUTER_SECRET',[EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('MIMO_API_KEY','TEST_MIMO_SECRET',[EnvironmentVariableTarget]::Process)

        $snapshot = Get-ControllerHealthSnapshot -Catalog $catalog -ConfigPath $tempConfig -SkipLoginProbe
        $studioHealth = @($snapshot.provider_health | Where-Object { $_.id -eq 'modelstudio' })[0]
        $routerHealth = @($snapshot.provider_health | Where-Object { $_.id -eq 'openrouter' })[0]
        $mimoHealth = @($snapshot.provider_health | Where-Object { $_.id -eq 'mimo' })[0]
        if ($studioHealth.status -eq 'PASS' -and $routerHealth.status -eq 'PASS' -and $mimoHealth.status -eq 'PASS') {
            Pass "Local health snapshot recognizes configured provider + key state"
        } else {
            Fail "Local health snapshot provider readiness mapping failed"
        }

        $qwenHealth = @($snapshot.model_health | Where-Object { $_.id -eq 'qwen3-coder-plus' })[0]
        $oxHealth = @($snapshot.model_health | Where-Object { $_.id -eq 'stealth/ox-alpha' })[0]
        $glmHealth = @($snapshot.model_health | Where-Object { $_.id -eq 'z-ai/glm-5.3' })[0]
        if ($qwenHealth.text -eq '已验证' -and $qwenHealth.raw_status -eq 'verified') { Pass "Verified model health mapping is stable" } else { Fail "Verified model health mapping changed" }
        if ($oxHealth.text -eq '实验' -and $oxHealth.raw_status -eq 'experimental') { Pass "Experimental model health mapping is stable" } else { Fail "Experimental model health mapping changed" }
        if ($glmHealth.text -eq '额度受限' -and $glmHealth.raw_status -eq 'credit') { Pass "Credit-limited model health mapping is stable" } else { Fail "Credit-limited model health mapping changed" }

        $snapshotJson = $snapshot | ConvertTo-Json -Depth 8
        if ($snapshotJson -match 'TEST_DASH_SECRET|TEST_ROUTER_SECRET|TEST_MIMO_SECRET') { Fail "Health snapshot leaked provider secret value" }
        else { Pass "Health snapshot never exposes provider key values" }
        if ($snapshot.mode -eq 'LOCAL_ONLY') { Pass "Health snapshot declares LOCAL_ONLY mode" } else { Fail "Health snapshot mode is not fail-safe LOCAL_ONLY" }
    }
    catch {
        Fail "Health cockpit runtime validation failed: $($_.Exception.Message)"
    }
    finally {
        [Environment]::SetEnvironmentVariable('CODEX_DASHSCOPE_API_KEY',$oldDash,[EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY',$oldRouter,[EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('MIMO_API_KEY',$oldMimo,[EnvironmentVariableTarget]::Process)
        Remove-Item -LiteralPath $tempConfig -Force -ErrorAction SilentlyContinue
    }
}

if (Test-Path $controllerPath) {
    $controller = Get-Content $controllerPath -Raw
    foreach ($needle in @(
        'model-catalog\.json','approved-models\.json','controller-catalog\.ps1','controller-health\.ps1','ProviderCombo','BrandCombo','ModelCombo','EffortCombo','LaunchSelectedButton',
        'Get-ProviderBrands','Refresh-BrandsForProvider','ReloadCatalogButton','Reload-ControllerCatalog','Get-ControllerCatalog','模型品牌','动态批准',
        'UpdateCenterButton','model-update-center\.ps1','launch-controller-model\.ps1','-Provider','-ModelId','-ReasoningEffort',
        '工作区有未提交变更','新 Codex 会话','LastModelText','Save-ControllerState','Provider-aware',
        'WorkspaceCombo','Get-WorkspaceCandidates','Resolve-InitialWorkspace','Refresh-WorkspaceStatus','last_workspace','工作目录','Projects',
        '模型健康驾驶舱','RefreshHealthDashboardButton','ProviderHealthList','ModelHealthList','HealthSummaryText','Refresh-HealthDashboard','LOCAL ONLY','详细健康检查'
    )) {
        if ($controller -match $needle) { Pass "Controller behavior present: $needle" } else { Fail "Controller behavior missing: $needle" }
    }

    if ($controller -match 'Text=\"当前项目\"' -or $controller -match '\bProjectPathBox\b') {
        Fail "Controller still duplicates Codex project-management wording/state"
    }
    else {
        Pass "Controller uses workspace semantics instead of duplicating Codex project management"
    }

    if ($controller -match 'Get-WorkspaceCandidates[\s\S]*Join-Path \$HOME \"Projects\"' -and $controller -match 'Get-GitInfo \$directory\.FullName') {
        Pass "Workspace quick list scans Git repositories under user Projects root"
    }
    else {
        Fail "Workspace quick-list discovery is missing"
    }

    if ($controller -match 'Resolve-InitialWorkspace[\s\S]*\$stateGit\.IsRepo' -and $controller -match 'Get-WorkspaceCandidates') {
        Pass "Initial workspace ignores stale non-Git saved locations when Git workspaces exist"
    }
    else {
        Fail "Initial workspace fallback is not Git-aware"
    }

    if ($controller -match '(?im)\bgit\s+(reset|clean|stash)\b') { Fail "Controller contains destructive Git command" }
    else { Pass "Controller does not reset/clean/stash Git worktrees" }

    $xamlMatch = [regex]::Match($controller,'(?s)\[xml\]\$xaml\s*=\s*@''\r?\n(?<xaml>.*?)\r?\n''@')
    if (-not $xamlMatch.Success) { Fail "Controller XAML here-string was not found" }
    else { try { [xml]$null=$xamlMatch.Groups['xaml'].Value; Pass "Controller XAML is well-formed XML" } catch { Fail "Controller XAML invalid: $($_.Exception.Message)" } }
}

if (Test-Path $launcherPath) {
    $launcher = Get-Content $launcherPath -Raw
    foreach ($needle in @(
        'ValidateSet\("chatgpt","modelstudio","openrouter","mimo"\)',
        'CODEX_DASHSCOPE_API_KEY','OPENROUTER_API_KEY','MIMO_API_KEY',
        'model_provider=\\?"mm_modelstudio\\?"','model_provider=\\?"mm_openrouter\\?"','model_provider=\\?"mm_mimo\\?"',
        'mm_gpt56_chatgpt','ModelId','ReasoningEffort','launch-ox-alpha\.ps1','collect-handoff\.ps1'
    )) {
        if ($launcher -match $needle) { Pass "Launcher route present: $needle" } else { Fail "Launcher route missing: $needle" }
    }
    if ($launcher -match '(?im)\bgit\s+(reset|clean|stash)\b') { Fail "Launcher contains destructive Git command" }
    else { Pass "Launcher does not reset/clean/stash Git worktrees" }
}

Write-Host ""
if ($failures.Count -gt 0) { Write-Host "Desktop Controller validation FAILED ($($failures.Count) failures)" -ForegroundColor Red; exit 1 }
Write-Host "Desktop Controller validation PASSED" -ForegroundColor Green
exit 0
