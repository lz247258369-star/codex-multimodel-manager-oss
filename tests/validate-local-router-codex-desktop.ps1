param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Pass $Message } else { Fail $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}

function Assert-ThrowsMatch([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $matched = $false
    try { & $Action | Out-Null } catch { $matched = ($_.Exception.Message -match $Pattern) }
    Assert-True $matched $Message
}

function Save-ProcessEnvSnapshot {
    $names = @("OPENROUTER_API_KEY","CODEX_DASHSCOPE_API_KEY","CODEX_OPENAI_API_KEY","MIMO_API_KEY","DEEPSEEK_API_KEY","CODEX_LOCAL_ROUTER_TOKEN","CODEX_HOME","RUNNER_TEMP") | Sort-Object -Unique
    $snapshot = [ordered]@{}
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        $snapshot[$name] = if ($null -eq $value) { $null } else { [string]$value }
    }
    return $snapshot
}

function Restore-ProcessEnvSnapshot($Snapshot) {
    foreach ($entry in $Snapshot.GetEnumerator()) {
        if ($null -eq $entry.Value) { Remove-Item -Path ("Env:" + $entry.Key) -ErrorAction SilentlyContinue }
        else { Set-Item -Path ("Env:" + $entry.Key) -Value ([string]$entry.Value) -ErrorAction SilentlyContinue }
    }
}

function Compare-ProcessEnvSnapshot($Before, $After) {
    $differences = @()
    foreach ($entry in $Before.GetEnumerator()) {
        $beforeValue = $entry.Value
        $afterValue = $After[$entry.Key]
        if ($null -eq $beforeValue -and $null -eq $afterValue) { continue }
        if ($null -ne $beforeValue -and $null -ne $afterValue -and $beforeValue -eq $afterValue) { continue }
        $differences += $entry.Key
    }
    return $differences
}

$envBefore = Save-ProcessEnvSnapshot
$adapterPath = Join-Path $RepositoryRoot "installer/scripts/desktop-router-route.ps1"
$cliModulePath = Join-Path $RepositoryRoot "installer/scripts/router-codex-cli.ps1"
$directRoutePath = Join-Path $RepositoryRoot "installer/scripts/desktop-chat-route.ps1"
$matrixPath = Join-Path $RepositoryRoot "docs/CODEX_DESKTOP_ROUTER_COMPATIBILITY_MATRIX.md"
$activateCmd = Join-Path $RepositoryRoot "installer/ACTIVATE_ROUTER_DESKTOP.cmd"
$statusCmd = Join-Path $RepositoryRoot "installer/STATUS_ROUTER_DESKTOP.cmd"
$restoreCmd = Join-Path $RepositoryRoot "installer/RESTORE_ROUTER_DESKTOP.cmd"

foreach ($path in @($adapterPath,$cliModulePath,$directRoutePath,$matrixPath,$activateCmd,$statusCmd,$restoreCmd)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail "LR-13 required file missing: $path" }
}
if ($failures.Count -gt 0) {
    Write-Host "LR-13 Codex Desktop validation FAILED (missing files)" -ForegroundColor Red
    exit 1
}

$adapterText = Get-Content -Raw -LiteralPath $adapterPath
$cliModuleText = Get-Content -Raw -LiteralPath $cliModulePath
$staticChecks = [ordered]@{
    "Desktop Router adapter uses mm_local_router only" = ($adapterText.Contains('"mm_local_router"') -and -not $adapterText.Contains('mm_desktop_router'))
    "Responses-only boundary" = ($cliModuleText.Contains('wire_api = "responses"') -and $adapterText.Contains("Set-RouterProviderBlockInConfig") -and -not $adapterText.Contains('chat/completions'))
    "Local token reference only" = $adapterText.Contains('CODEX_LOCAL_ROUTER_TOKEN')
    "No auth.json access" = -not $adapterText.Contains("auth.json")
    "No Desktop binary patch" = (-not $adapterText.Contains("Program Files") -and -not $adapterText.Contains("Electron") -and -not $adapterText.Contains("DLL") -and -not $adapterText.Contains("binary patch"))
    "Desktop activation requires a full restart" = ($adapterText.Contains("Restart required") -and $adapterText.Contains("full Codex Desktop restart"))
    "Acceptance experiment reopens the SAME existing conversation" = ($adapterText.Contains("reopen the SAME existing conversation") -and $adapterText.Contains("REOPEN SAME THREAD AFTER RESTART"))
    "Same-thread picker stays PENDING NPG1-B" = ($adapterText.Contains("PENDING NPG1-B") -and $adapterText.Contains("NOT YET VERIFIED"))
    "Obsolete NEW-conversation claim removed" = (-not $adapterText.Contains("NEW conversation") -and -not $adapterText.Contains("New conversation"))
    "Obsolete hot-switch claim removed" = (-not $adapterText.Contains("Hot switch") -and -not $adapterText.Contains("hot-switched"))
    "DeepSeek upstream secret is forbidden in the Router block" = ($adapterText.Contains('"DEEPSEEK_API_KEY"') -and $adapterText.Contains("DesktopForbiddenUpstreamSecrets"))
    "Local token stays an env reference only" = ($adapterText.Contains('CODEX_LOCAL_ROUTER_TOKEN') -and -not $adapterText.Contains("CODEX_LOCAL_ROUTER_TOKEN="))
    "Explicit ROUTER confirmation" = $adapterText.Contains('"ROUTER"')
    "route_kind schema" = $adapterText.Contains("route_kind")
    "Single rollback state file" = $adapterText.Contains("desktop-route-state.json")
    "Shares CLI provider ownership registry" = $adapterText.Contains("Register-RouterProviderOwner") -and $adapterText.Contains("client.codex_desktop")
    "mm_openai_api gap preserved" = $adapterText.Contains("MM_OPENAI_API_CATALOG_CAPABILITY_GAP") -or (Get-Content -Raw -LiteralPath $cliModulePath).Contains("MM_OPENAI_API_CATALOG_CAPABILITY_GAP")
    "No upstream key copy in Router mode" = -not ($adapterText.Contains("OPENROUTER_API_KEY=") -or $adapterText.Contains("DEEPSEEK_API_KEY="))
}
foreach ($entry in $staticChecks.GetEnumerator()) {
    Assert-True $entry.Value $entry.Key
}

Assert-True ($cliModuleText.Contains("Register-RouterProviderOwner") -and $cliModuleText.Contains("Unregister-RouterProviderOwner")) "CLI module exposes shared provider ownership registry"
Assert-True ($cliModuleText.Contains("client.codex_desktop") -or (Get-Content -Raw -LiteralPath $adapterPath).Contains("client.codex_desktop")) "Desktop client identity is client.codex_desktop"

$adapterForbiddenUserApi = "Set" + "EnvironmentVariable"
Assert-True (-not $adapterText.Contains($adapterForbiddenUserApi)) "Desktop Router adapter never writes User/Process env through the .NET setter"

$oldCodexHome = $env:CODEX_HOME
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-mm-lr13-" + [guid]::NewGuid().ToString("N"))
$codexHome = Join-Path $tempRoot "codex-home"
$managerHome = Join-Path $codexHome "multimodel-manager"
$configPath = Join-Path $codexHome "config.toml"
$envPath = Join-Path $codexHome ".env"
$routerConfigPath = Join-Path $managerHome "local-router/router.config.json"
$runtimePath = Join-Path $managerHome "local-router/runtime/router.state.json"
$desktopStatePath = Join-Path $managerHome "desktop-route-state.json"
$env:CODEX_HOME = $codexHome

$baselineConfig = @'
# User baseline Codex configuration
approval_policy = "on-request"
model = "gpt-old"
model_provider = "openai"
model_reasoning_effort = "medium"

[profiles.keep_me]
model = "keep-me"

[model_providers.mm_openrouter]
name = "OpenRouter user provider"
base_url = "https://openrouter.ai/api/v1"
env_key = "OPENROUTER_API_KEY"
wire_api = "responses"
'@
$baselineEnv = "EXISTING_VALUE=keep`r`nOTHER_USER=preserve`r`n"

function Write-FixtureFile([string]$Path, [string]$Content) {
    Set-Content -LiteralPath $Path -Value $Content -NoNewline -Encoding UTF8
}

function New-RouterRouteConfig([int]$Port) {
    return [pscustomobject]@{
        schema_version = 1
        version = 1
        mode = "router"
        local_router = @{
            enabled = $true
            host = "127.0.0.1"
            port = $Port
            client_auth = @{ mode = "bearer_env_ref"; token_ref = "CODEX_LOCAL_ROUTER_TOKEN" }
            limits = @{ max_request_bytes = 16777216; max_header_bytes = 32768; max_connections = 32; shutdown_grace_ms = 15000 }
        }
        clients = @()
        protocol_routes = @()
        provider_routes = @(
            [pscustomobject]@{ provider_route_id = "provider-route.modelstudio"; provider_id = "mm_modelstudio"; adapter_id = "adapter.provider.mm_modelstudio.responses.v1"; adapter_version = "1.0"; enabled = $true; version = 1 },
            [pscustomobject]@{ provider_route_id = "provider-route.openrouter"; provider_id = "mm_openrouter"; adapter_id = "adapter.provider.mm_openrouter.responses.v1"; adapter_version = "1.0"; enabled = $true; version = 1 },
            [pscustomobject]@{ provider_route_id = "provider-route.mimo"; provider_id = "mm_mimo"; adapter_id = "adapter.provider.mm_mimo.responses.v1"; adapter_version = "1.0"; enabled = $true; version = 1 },
            [pscustomobject]@{ provider_route_id = "provider-route.openai-api"; provider_id = "mm_openai_api"; adapter_id = "adapter.provider.mm_openai_api.responses.v1"; adapter_version = "1.0"; enabled = $true; version = 1 }
        )
        model_routes = @(
            [pscustomobject]@{ model_route_id = "model-route.modelstudio.deepseek"; provider_id = "mm_modelstudio"; client_model_id = "deepseek-v4-pro"; model_id = "deepseek-v4-pro"; upstream_model_id = "deepseek-v4-pro"; identity_verification = "explicit_config"; enabled = $true; version = 1 },
            [pscustomobject]@{ model_route_id = "model-route.modelstudio.qwen"; provider_id = "mm_modelstudio"; client_model_id = "qwen3-coder-plus"; model_id = "qwen3-coder-plus"; upstream_model_id = "qwen3-coder-plus"; identity_verification = "explicit_config"; enabled = $true; version = 1 },
            [pscustomobject]@{ model_route_id = "model-route.openrouter.glm"; provider_id = "mm_openrouter"; client_model_id = "z-ai/glm-5.3"; model_id = "z-ai/glm-5.3"; upstream_model_id = "z-ai/glm-5.3"; identity_verification = "explicit_config"; enabled = $true; version = 1 },
            [pscustomobject]@{ model_route_id = "model-route.mimo.mimo-pro"; provider_id = "mm_mimo"; client_model_id = "mimo-v2.5-pro"; model_id = "mimo-v2.5-pro"; upstream_model_id = "mimo-v2.5-pro"; identity_verification = "explicit_config"; enabled = $true; version = 1 },
            [pscustomobject]@{ model_route_id = "model-route.openai-api.gpt"; provider_id = "mm_openai_api"; client_model_id = "gpt-5.6-sol"; model_id = "gpt-5.6-sol"; upstream_model_id = "gpt-5.6-sol"; identity_verification = "explicit_config"; enabled = $true; version = 1 }
        )
        routes = @(
            [pscustomobject]@{ route_id = "route.modelstudio.deepseek"; provider_route_id = "provider-route.modelstudio"; protocol_route_id = "protocol-route.responses"; model_route_id = "model-route.modelstudio.deepseek"; enabled = $true; priority = 0; weight = 1; health_state = "UNKNOWN"; timeout_policy_id = ""; retry_policy_id = ""; failover_policy_id = ""; created_at = "2026-08-27T00:00:00Z"; updated_at = "2026-08-27T00:00:00Z"; version = 1 },
            [pscustomobject]@{ route_id = "route.modelstudio.qwen"; provider_route_id = "provider-route.modelstudio"; protocol_route_id = "protocol-route.responses"; model_route_id = "model-route.modelstudio.qwen"; enabled = $true; priority = 0; weight = 1; health_state = "UNKNOWN"; timeout_policy_id = ""; retry_policy_id = ""; failover_policy_id = ""; created_at = "2026-08-27T00:00:00Z"; updated_at = "2026-08-27T00:00:00Z"; version = 1 },
            [pscustomobject]@{ route_id = "route.openrouter.glm"; provider_route_id = "provider-route.openrouter"; protocol_route_id = "protocol-route.responses"; model_route_id = "model-route.openrouter.glm"; enabled = $true; priority = 0; weight = 1; health_state = "UNKNOWN"; timeout_policy_id = ""; retry_policy_id = ""; failover_policy_id = ""; created_at = "2026-08-27T00:00:00Z"; updated_at = "2026-08-27T00:00:00Z"; version = 1 },
            [pscustomobject]@{ route_id = "route.mimo.mimo-pro"; provider_route_id = "provider-route.mimo"; protocol_route_id = "protocol-route.responses"; model_route_id = "model-route.mimo.mimo-pro"; enabled = $true; priority = 0; weight = 1; health_state = "UNKNOWN"; timeout_policy_id = ""; retry_policy_id = ""; failover_policy_id = ""; created_at = "2026-08-27T00:00:00Z"; updated_at = "2026-08-27T00:00:00Z"; version = 1 },
            [pscustomobject]@{ route_id = "route.openai-api.gpt"; provider_route_id = "provider-route.openai-api"; protocol_route_id = "protocol-route.responses"; model_route_id = "model-route.openai-api.gpt"; enabled = $true; priority = 0; weight = 1; health_state = "UNKNOWN"; timeout_policy_id = ""; retry_policy_id = ""; failover_policy_id = ""; created_at = "2026-08-27T00:00:00Z"; updated_at = "2026-08-27T00:00:00Z"; version = 1 }
        )
        policies = @()
        updated_at = "2026-08-27T00:00:00Z"
    }
}

function Initialize-Fixture {
    New-Item -ItemType Directory -Force -Path (Join-Path $managerHome "local-router/runtime") | Out-Null
    Write-FixtureFile $configPath $baselineConfig
    Write-FixtureFile $envPath $baselineEnv
    (New-RouterRouteConfig 47831) | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $routerConfigPath -Encoding UTF8
    @{
        schema_version = 1
        version = 1
        lifecycle = "READY"
        config_generation = ""
        started_at = "2026-09-03T00:00:00Z"
        updated_at = "2026-09-03T00:00:00Z"
        last_failure = $null
        migration_receipts = @()
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimePath -Encoding UTF8
    @{
        openrouter_enabled = $true
        aliyun_enabled = $true
        aliyun_base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        mimo_enabled = $true
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $managerHome "state.json") -Encoding UTF8
}

function Reset-ToBaseline {
    Write-FixtureFile $configPath $baselineConfig
    Write-FixtureFile $envPath $baselineEnv
    foreach ($relative in @(
        "desktop-route-state.json",
        "router-cli-state.json",
        "router-provider-owners.json",
        "mm_local_router.config.toml",
        "router-provider-baseline"
    )) {
        $target = Join-Path $managerHome $relative
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $profilePath = Join-Path $codexHome "mm_local_router.config.toml"
    if (Test-Path -LiteralPath $profilePath) { Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue }
    $backupsRoot = Join-Path $codexHome "backups"
    if (Test-Path -LiteralPath $backupsRoot) { Remove-Item -LiteralPath $backupsRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-DesktopState {
    if (-not (Test-Path -LiteralPath $desktopStatePath -PathType Leaf)) { return $null }
    return (Get-Content -Raw -LiteralPath $desktopStatePath | ConvertFrom-Json)
}

function Get-ConfigText {
    return (Get-Content -Raw -LiteralPath $configPath)
}

function Count-RouterProviderTables([string]$Text) {
    return @([regex]::Matches($Text, '(?m)^\s*\[model_providers\.mm_local_router\]\s*$')).Count
}

function Invoke-RouterDesktop([string[]]$RouteArgs) {
    & pwsh -NoProfile -File $adapterPath @RouteArgs
    if ($LASTEXITCODE -ne 0) { throw "desktop-router-route.ps1 exited with $LASTEXITCODE" }
}

# Captures the adapter's own stdout so the staged activation/status messaging
# can be asserted; a non-zero exit is still a hard failure.
function Get-RouterDesktopOutput([string[]]$RouteArgs) {
    $output = & pwsh -NoProfile -File $adapterPath @RouteArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "desktop-router-route.ps1 exited with $LASTEXITCODE" }
    return $output
}

function Invoke-DirectDesktop([string[]]$DirectArgs) {
    & pwsh -NoProfile -File $directRoutePath @DirectArgs
    if ($LASTEXITCODE -ne 0) { throw "desktop-chat-route.ps1 exited with $LASTEXITCODE" }
}

function Invoke-RouterDesktopCaptureFail([string[]]$RouteArgs) {
    $output = & pwsh -NoProfile -File $adapterPath @RouteArgs 2>&1 | Out-String
    return $output
}

try {
    . $cliModulePath
    $env:CODEX_LOCAL_ROUTER_TOKEN = "lr13-local-token-fixture"
    $env:OPENROUTER_API_KEY = "manager-openrouter-key-not-real"
    $env:CODEX_DASHSCOPE_API_KEY = "manager-dashscope-key-not-real"
    $env:MIMO_API_KEY = "manager-mimo-key-not-real"
    # DSR7-A: direct DeepSeek is a first-class Router provider now, so a DeepSeek
    # upstream secret is present while the Desktop route is activated: it must
    # never be copied into the Router block, the profile, or the .env file.
    $env:DEEPSEEK_API_KEY = "manager-deepseek-key-not-real"
    Initialize-Fixture

    # Scenario A: CLI Router OFF + Desktop Router ON.
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    $stateA = Get-DesktopState
    Assert-True ($null -ne $stateA -and [bool]$stateA.active -and [string]$stateA.route_kind -eq "router") "A: Desktop Router activation records route_kind=router"
    $textA = Get-ConfigText
    Assert-True ((Count-RouterProviderTables $textA) -eq 1) "A: exactly one mm_local_router provider table"
    Assert-True ($textA -match '(?m)^model_provider\s*=\s*"mm_local_router"\s*$') "A: Desktop top-level route uses mm_local_router"
    $ownersA = Get-Content -Raw -LiteralPath (Join-Path $managerHome "router-provider-owners.json") | ConvertFrom-Json
    Assert-True (@($ownersA.owners | Where-Object { $_.client_id -eq "client.codex_desktop" }).Count -eq 1) "A: Desktop owner registered"

    $routerBlockA = [regex]::Match($textA, '(?s)# >>> CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN.*?# <<< CODEX MULTIMODEL MANAGER ROUTER CLI END')
    Assert-True $routerBlockA.Success "A: activation writes the shared mm_local_router provider block"
    Assert-True ($routerBlockA.Value.Contains("CODEX_LOCAL_ROUTER_TOKEN")) "A: Router block references the local token env name"
    Assert-True (-not $routerBlockA.Value.Contains("CODEX_LOCAL_ROUTER_TOKEN=")) "A: Router block never inlines the local token value"
    foreach ($secretName in @("DEEPSEEK_API_KEY","OPENROUTER_API_KEY","CODEX_DASHSCOPE_API_KEY","CODEX_OPENAI_API_KEY","MIMO_API_KEY","experimental_bearer_token")) {
        Assert-True (-not $routerBlockA.Value.Contains($secretName)) "A: Router block never references the upstream secret $secretName"
        Assert-True (-not $textA.Contains($secretName + "=")) "A: config.toml never carries an upstream secret assignment for $secretName"
    }
    Assert-True (-not (Get-Content -Raw -LiteralPath $envPath).Contains("DEEPSEEK_API_KEY")) "A: .env never receives the DeepSeek upstream secret"

    $statusA = Get-RouterDesktopOutput @("-Mode","status")
    Assert-True ($statusA -match "PENDING NPG1-B") "A: status reports the same-thread picker as PENDING NPG1-B"
    Assert-True ($statusA -match "REOPEN SAME THREAD AFTER RESTART") "A: status tells the operator to reopen the same existing conversation"
    Assert-True (-not ($statusA -match "NEW conversation|New conversation|Hot switch|hot-switched")) "A: status no longer claims a new conversation or denies hot switch"
    Invoke-RouterDesktop @("-Mode","doctor")
    Invoke-RouterDesktop @("-Mode","restore")
    Assert-True ((Get-ConfigText) -eq $baselineConfig) "A restore: config bytes == baseline"
    Assert-True ((Get-Content -Raw -LiteralPath $envPath) -eq $baselineEnv) "A restore: .env bytes == baseline"
    Reset-ToBaseline

    # CLI-only receipt semantics remain active (Desktop never participated).
    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    Disable-RouterCli -Force | Out-Null
    Assert-True ((Get-ConfigText) -eq $baselineConfig) "CLI-only enable/disable returns exact baseline config"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $codexHome "mm_local_router.config.toml") -PathType Leaf)) "CLI-only disable removes the CLI profile"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $managerHome "router-provider-owners.json") -PathType Leaf)) "CLI-only disable leaves no ownership registry"

    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    $configForExternal = Get-ConfigText
    $configForExternal = $configForExternal + "`r`n[profiles.external_user_change]`r`nmodel = `"keep-external`"`r`n"
    Write-FixtureFile $configPath $configForExternal
    Assert-True ((Get-ConfigText) -match '(?m)^\[profiles\.external_user_change\]\s*$') "External user table is present before CLI-only disable"
    Disable-RouterCli -Force | Out-Null
    $configAfterExternal = Get-ConfigText
    Assert-True ($configAfterExternal -match '(?m)^\[profiles\.external_user_change\]\s*$') "CLI-only receipt path preserves external user change"
    Assert-True ((Count-RouterProviderTables $configAfterExternal) -eq 0) "CLI-only receipt path removes Router block on external-change fallback"
    Reset-ToBaseline

    # Scenario B/C/D/E: CLI and Desktop share one provider table and never break each other.
    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    $textBC = Get-ConfigText
    Assert-True ((Count-RouterProviderTables $textBC) -eq 1) "B: CLI ON + Desktop ON keeps exactly one provider table"
    $ownersBC = Get-Content -Raw -LiteralPath (Join-Path $managerHome "router-provider-owners.json") | ConvertFrom-Json
    $ownerIds = @($ownersBC.owners | ForEach-Object { $_.client_id })
    Assert-True ("client.codex_cli" -in $ownerIds -and "client.codex_desktop" -in $ownerIds) "B: both Router client owners registered"

    Disable-RouterCli -Force | Out-Null
    $textD = Get-ConfigText
    Assert-True ((Count-RouterProviderTables $textD) -eq 1) "D: CLI disable keeps the shared provider table for Desktop Router"
    $stateD = Get-DesktopState
    Assert-True ($null -ne $stateD -and [bool]$stateD.active -and [string]$stateD.route_kind -eq "router") "D: Desktop Router remains active after CLI disable"
    $cliStateD = Get-RouterCliState
    Assert-True ([string]$cliStateD.mode -eq "direct") "D: CLI state returns to direct while Desktop Router stays active"

    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    Invoke-RouterDesktop @("-Mode","restore")
    $textE = Get-ConfigText
    Assert-True ((Count-RouterProviderTables $textE) -eq 1) "E: Desktop restore keeps the provider table for active CLI Router"
    $stateE = Get-DesktopState
    Assert-True ($null -ne $stateE -and -not [bool]$stateE.active) "E: Desktop route state inactive after restore"
    $cliStateE = Get-RouterCliState
    Assert-True ([string]$cliStateE.mode -eq "router") "E: CLI Router remains enabled after Desktop restore"

    Disable-RouterCli -Force | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $managerHome "router-provider-owners.json") -PathType Leaf)) "F: last owner removal deletes the ownership registry"
    Assert-True ((Get-ConfigText) -eq $baselineConfig) "F: CLI + Desktop both disabled -> config bytes == baseline"
    Assert-True ((Get-Content -Raw -LiteralPath $envPath) -eq $baselineEnv) "F: CLI + Desktop both disabled -> .env bytes == baseline"
    Reset-ToBaseline

    # Scenario C order: Desktop ON then CLI ON.
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    $textC = Get-ConfigText
    Assert-True ((Count-RouterProviderTables $textC) -eq 1) "C: Desktop ON then CLI ON keeps exactly one provider table"
    Invoke-RouterDesktop @("-Mode","restore")
    Disable-RouterCli -Force | Out-Null
    Assert-True ((Get-ConfigText) -eq $baselineConfig) "C order cleanup restores exact baseline"
    Reset-ToBaseline

    # Router -> Direct must never leave a stale desktop Router owner.
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    $ownersBeforeDirect = Get-Content -Raw -LiteralPath (Join-Path $managerHome "router-provider-owners.json") | ConvertFrom-Json
    Assert-True (@($ownersBeforeDirect.owners | Where-Object { $_.client_id -eq "client.codex_desktop" }).Count -eq 1) "Router->Direct scenario starts with one desktop owner"
    Invoke-DirectDesktop @("-Mode","activate","-ProviderId","openrouter","-ModelId","z-ai/glm-5.3","-Effort","high")
    $directStateAfterRouter = Get-DesktopState
    Assert-True ([string]$directStateAfterRouter.route_kind -eq "direct") "Router->Direct records route_kind=direct"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $managerHome "router-provider-owners.json") -PathType Leaf)) "Router->Direct removes desktop owner when no CLI owner remains"
    Assert-True ((Count-RouterProviderTables (Get-ConfigText)) -eq 0) "Router->Direct removes stale mm_local_router table when last owner"
    Invoke-DirectDesktop @("-Mode","restore")
    Assert-True ((Get-ConfigText) -eq $baselineConfig) "Router->Direct->Restore returns exact baseline config"
    Assert-True ((Get-Content -Raw -LiteralPath $envPath) -eq $baselineEnv) "Router->Direct->Restore returns exact baseline .env"
    Reset-ToBaseline

    # Router -> Direct -> CLI ON -> CLI OFF -> Direct restore leaves no stale Router state.
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    Invoke-DirectDesktop @("-Mode","activate","-ProviderId","modelstudio","-ModelId","deepseek-v4-pro","-Effort","high")
    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    Disable-RouterCli -Force | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $managerHome "router-provider-owners.json") -PathType Leaf)) "Router->Direct->CLI cycle leaves no ownership registry"
    Invoke-DirectDesktop @("-Mode","restore")
    Assert-True ((Get-ConfigText) -eq $baselineConfig) "Router->Direct->CLI->Direct restore returns exact baseline config"
    Assert-True ((Get-Content -Raw -LiteralPath $envPath) -eq $baselineEnv) "Router->Direct->CLI->Direct restore returns exact baseline .env"
    Reset-ToBaseline

    # Router -> Direct MiMo -> Router: desktop owner registers exactly once.
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    Invoke-DirectDesktop @("-Mode","activate","-ProviderId","mimo","-ModelId","mimo-v2.5-pro","-Effort","high")
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","mimo-v2.5-pro","-Effort","high","-ConfirmationCode","ROUTER")
    $ownersReentry = Get-Content -Raw -LiteralPath (Join-Path $managerHome "router-provider-owners.json") | ConvertFrom-Json
    Assert-True (@($ownersReentry.owners | Where-Object { $_.client_id -eq "client.codex_desktop" }).Count -eq 1) "Router->Direct->Router registers desktop owner exactly once"
    Invoke-RouterDesktop @("-Mode","restore")
    Assert-True ((Get-ConfigText) -eq $baselineConfig) "Router->Direct->Router cleanup restores exact baseline"
    Reset-ToBaseline

    # Desktop restore while CLI Router remains must restore prior top-level values.
    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    Invoke-RouterDesktop @("-Mode","restore")
    $textDesktopRestoreCli = Get-ConfigText
    Assert-True ($textDesktopRestoreCli -match '(?m)^model\s*=\s*"gpt-old"\s*$') "Desktop restore while CLI ON returns prior model=gpt-old"
    Assert-True ($textDesktopRestoreCli -match '(?m)^model_provider\s*=\s*"openai"\s*$') "Desktop restore while CLI ON returns prior model_provider=openai"
    Assert-True ($textDesktopRestoreCli -match '(?m)^model_reasoning_effort\s*=\s*"medium"\s*$') "Desktop restore while CLI ON returns prior reasoning effort=medium"
    Assert-True ((Count-RouterProviderTables $textDesktopRestoreCli) -eq 1) "Desktop restore while CLI ON keeps one mm_local_router table for CLI"
    $cliAfterDesktopRestore = Get-RouterCliState
    Assert-True ([string]$cliAfterDesktopRestore.mode -eq "router") "CLI Router survives Desktop restore"
    Assert-True (Test-Path -LiteralPath (Join-Path $codexHome "mm_local_router.config.toml") -PathType Leaf) "CLI profile survives Desktop restore"
    $ownersAfterDesktopRestore = Get-Content -Raw -LiteralPath (Join-Path $managerHome "router-provider-owners.json") | ConvertFrom-Json
    $ownerIdsAfterDesktopRestore = @($ownersAfterDesktopRestore.owners | ForEach-Object { $_.client_id })
    Assert-True ("client.codex_cli" -in $ownerIdsAfterDesktopRestore -and "client.codex_desktop" -notin $ownerIdsAfterDesktopRestore) "Desktop restore removes desktop owner and keeps CLI owner"
    Disable-RouterCli -Force | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $managerHome "router-provider-owners.json") -PathType Leaf)) "Desktop restore + CLI disable leaves no ownership registry"
    Assert-True ((Get-ConfigText) -eq $baselineConfig) "Desktop restore + CLI disable returns exact baseline config"
    Assert-True ((Get-Content -Raw -LiteralPath $envPath) -eq $baselineEnv) "Desktop restore + CLI disable returns exact baseline .env"
    Reset-ToBaseline

    # CLI last-owner cleanup must preserve a currently active Desktop Direct route.
    $directMatrix = @(
        @{ ProviderId = "openrouter"; ModelId = "z-ai/glm-5.3"; CodexProvider = "mm_openrouter" },
        @{ ProviderId = "modelstudio"; ModelId = "deepseek-v4-pro"; CodexProvider = "mm_modelstudio" },
        @{ ProviderId = "mimo"; ModelId = "mimo-v2.5-pro"; CodexProvider = "mm_mimo" }
    )
    foreach ($entry in $directMatrix) {
        Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
        Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
        Invoke-DirectDesktop @("-Mode","activate","-ProviderId",$entry.ProviderId,"-ModelId",$entry.ModelId,"-Effort","high")
        $directWhileCli = Get-DesktopState
        Assert-True ([string]$directWhileCli.provider -eq $entry.CodexProvider -and [string]$directWhileCli.model -eq $entry.ModelId) "CLI ON path switches Desktop to Direct $($entry.CodexProvider)"
        Disable-RouterCli -Force | Out-Null
        $directAfterCliOff = Get-DesktopState
        $configAfterCliOff = Get-ConfigText
        Assert-True ($null -ne $directAfterCliOff -and [bool]$directAfterCliOff.active -and [string]$directAfterCliOff.route_kind -eq "direct") "Direct Desktop route stays ACTIVE after last CLI owner leaves"
        Assert-True ($configAfterCliOff -match ('(?m)^model\s*=\s*"' + [regex]::Escape($entry.ModelId) + '"\s*$')) "Config still points at Direct model after last CLI owner leaves"
        Assert-True ($configAfterCliOff -match ('(?m)^model_provider\s*=\s*"' + [regex]::Escape($entry.CodexProvider) + '"\s*$')) "Config still points at Direct provider after last CLI owner leaves"
        Assert-True ((Count-RouterProviderTables $configAfterCliOff) -eq 0) "CLI last-owner cleanup removes only the Router-owned provider block"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $managerHome "router-provider-owners.json") -PathType Leaf)) "No Router owner remains after CLI OFF over Direct Desktop route"
        Invoke-DirectDesktop @("-Mode","restore")
        Assert-True ((Get-ConfigText) -eq $baselineConfig) "Direct restore after CLI OFF returns exact baseline config"
        Assert-True ((Get-Content -Raw -LiteralPath $envPath) -eq $baselineEnv) "Direct restore after CLI OFF returns exact baseline .env"
        Reset-ToBaseline
    }

    # Unrelated user config must survive CLI last-owner cleanup (option A).
    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    $configWithRouter = Get-ConfigText
    $configWithUserTable = $configWithRouter + "`r`n[profiles.user_added_later]`r`nmodel = `"keep-me-later`"`r`n"
    Write-FixtureFile $configPath $configWithUserTable
    Invoke-DirectDesktop @("-Mode","activate","-ProviderId","openrouter","-ModelId","z-ai/glm-5.3","-Effort","high")
    Disable-RouterCli -Force | Out-Null
    $configPreserved = Get-ConfigText
    Assert-True ($configPreserved -match '(?m)^\[profiles\.user_added_later\]\s*$') "Unrelated user profile survives CLI last-owner cleanup"
    Assert-True ($configPreserved -match '(?m)^model_provider\s*=\s*"mm_openrouter"\s*$') "Direct route remains after CLI last-owner cleanup with user changes"
    Assert-True ((Count-RouterProviderTables $configPreserved) -eq 0) "CLI cleanup removes Router block while preserving user tables"
    Invoke-DirectDesktop @("-Mode","restore")
    Assert-True ((Get-ConfigText) -eq $baselineConfig) "Direct restore after user-change scenario returns exact baseline config"
    Reset-ToBaseline

    # Pre-existing user-owned CLI profile must fail closed with zero side effects.
    $userProfilePath = Join-Path $codexHome "mm_local_router.config.toml"
    $userProfileContent = 'model = "user-owned-model"' + "`r`n"
    Write-FixtureFile $userProfilePath $userProfileContent
    $configBeforeUserProfile = Get-ConfigText
    Assert-Throws { Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force } "Pre-existing user-owned CLI profile fails closed on Enable"
    Assert-True ((Get-Content -Raw -LiteralPath $userProfilePath) -eq $userProfileContent) "Pre-existing user-owned profile bytes unchanged"
    Assert-True ((Get-ConfigText) -eq $configBeforeUserProfile) "Pre-existing user-owned profile failure leaves config unchanged"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $managerHome "router-provider-owners.json") -PathType Leaf)) "Pre-existing user-owned profile failure performs no ownership registration"
    Remove-Item -LiteralPath $userProfilePath -Force
    Reset-ToBaseline

    # Scenario: route-to-route switch preserving first backup.
    Invoke-DirectDesktop @("-Mode","activate","-ProviderId","openrouter","-ModelId","z-ai/glm-5.3","-Effort","high")
    $state1 = Get-DesktopState
    $firstBackup = [string]$state1.backup_dir
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    $state2 = Get-DesktopState
    Assert-True ([string]$state2.backup_dir -eq $firstBackup) "Direct->Router keeps the same first rollback backup"
    $routerEnv = Get-Content -Raw -LiteralPath $envPath -ErrorAction SilentlyContinue
    Assert-True ($routerEnv -notmatch 'OPENROUTER_API_KEY\s*=\s*manager-') "Router activation removes Manager-injected OpenRouter key"
    Invoke-DirectDesktop @("-Mode","activate","-ProviderId","modelstudio","-ModelId","deepseek-v4-pro","-Effort","high")
    $state3 = Get-DesktopState
    Assert-True ([string]$state3.backup_dir -eq $firstBackup) "Router->Direct switch keeps the same first rollback backup"
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","mimo-v2.5-pro","-Effort","high","-ConfirmationCode","ROUTER")
    $state4 = Get-DesktopState
    Assert-True ([string]$state4.backup_dir -eq $firstBackup) "Direct->Router (2) keeps the same first rollback backup"
    Invoke-RouterDesktop @("-Mode","restore")
    Assert-True ((Get-ConfigText) -eq $baselineConfig) "Route-to-route final restore returns config bytes to baseline"
    Assert-True ((Get-Content -Raw -LiteralPath $envPath) -eq $baselineEnv) "Route-to-route final restore returns .env bytes to baseline"
    Reset-ToBaseline

    # Scenario: Desktop Router idempotency and model switch preserve first backup.
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    $firstRouterState = Get-DesktopState
    $firstRouterBackup = [string]$firstRouterState.backup_dir
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    $secondRouterState = Get-DesktopState
    Assert-True ([string]$secondRouterState.backup_dir -eq $firstRouterBackup) "Repeated Router activation is idempotent and preserves first backup"
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","deepseek-v4-pro","-Effort","high","-ConfirmationCode","ROUTER")
    $switchRouterState = Get-DesktopState
    Assert-True ([string]$switchRouterState.backup_dir -eq $firstRouterBackup) "Router model switch preserves the same first backup"
    Invoke-RouterDesktop @("-Mode","restore")
    Assert-True ((Get-ConfigText) -eq $baselineConfig) "Router idempotency/model-switch restore returns exact baseline"
    Reset-ToBaseline

    # Scenario: ChatGPT/default Desktop regression.
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $codexHome "auth.json") -PathType Leaf)) "Baseline has no auth.json"
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $codexHome "auth.json") -PathType Leaf)) "Desktop Router activation never creates auth.json"
    Invoke-RouterDesktop @("-Mode","restore")
    Assert-True ((Get-ConfigText) -eq $baselineConfig) "ChatGPT/default Desktop config returns exactly after Router cycle"
    Assert-True ((Get-Content -Raw -LiteralPath $envPath) -eq $baselineEnv) "ChatGPT/default Desktop .env returns exactly after Router cycle"
    Reset-ToBaseline

    # Scenario: user-owned .env keys are preserved; Manager-injected are removed.
    $userEnv = "EXISTING_VALUE=keep`r`nOTHER_USER=preserve`r`nOPENROUTER_API_KEY=user-owned-key`r`n"
    Write-FixtureFile $envPath $userEnv
    $baselineUserEnv = $userEnv
    Invoke-DirectDesktop @("-Mode","activate","-ProviderId","openrouter","-ModelId","z-ai/glm-5.3","-Effort","high")
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    $routerActiveEnv = Get-Content -Raw -LiteralPath $envPath
    Assert-True ($routerActiveEnv -match '(?m)^OPENROUTER_API_KEY=user-owned-key\s*$') "User-owned baseline OpenRouter key is preserved during Router route"
    Assert-True ($routerActiveEnv -notmatch 'OPENROUTER_API_KEY=manager-') "Manager-injected OpenRouter value is not left for Router route"
    Invoke-RouterDesktop @("-Mode","restore")
    Assert-True ((Get-Content -Raw -LiteralPath $envPath) -eq $baselineUserEnv) "User-owned .env restored exactly after Router restore"
    Reset-ToBaseline

    # Scenario: safety gates fail closed.
    Remove-Item Env:CODEX_LOCAL_ROUTER_TOKEN -ErrorAction SilentlyContinue
    $beforeMissingToken = Get-ConfigText
    Assert-Throws { Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER") } "Missing local token makes Desktop Router activation fail closed"
    Assert-True ((Get-ConfigText) -eq $beforeMissingToken) "Missing token leaves config untouched"
    $env:CODEX_LOCAL_ROUTER_TOKEN = "lr13-local-token-fixture"

    $runtime = Get-Content -Raw -LiteralPath $runtimePath | ConvertFrom-Json
    $runtime.lifecycle = "STOPPED"
    $runtime | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimePath -Encoding UTF8
    $beforeStopped = Get-ConfigText
    Assert-Throws { Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER") } "Router lifecycle not READY makes Desktop Router activation fail closed"
    Assert-True ((Get-ConfigText) -eq $beforeStopped) "Not-ready Router leaves config untouched"
    $runtime.lifecycle = "FAILED"
    $runtime | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimePath -Encoding UTF8
    Assert-Throws { Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER") } "Port-conflict/FAILED Router lifecycle makes Desktop activation fail closed"
    Assert-True ((Get-ConfigText) -eq $beforeStopped) "FAILED Router lifecycle leaves config untouched"
    $runtime.lifecycle = "READY"
    $runtime | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimePath -Encoding UTF8

    Set-Content -LiteralPath $routerConfigPath -Value "{ corrupt" -Encoding UTF8
    $beforeCorrupt = Get-ConfigText
    Assert-Throws { Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER") } "Corrupt Router config makes Desktop Router activation fail closed"
    Assert-True ((Get-ConfigText) -eq $beforeCorrupt) "Corrupt Router config leaves config untouched"
    (New-RouterRouteConfig 47831) | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $routerConfigPath -Encoding UTF8

    $portConflictConfig = New-RouterRouteConfig 0
    $portConflictConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $routerConfigPath -Encoding UTF8
    Assert-Throws { Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER") } "Invalid Router port fails closed for Desktop activation"
    (New-RouterRouteConfig 47831) | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $routerConfigPath -Encoding UTF8

    # Direct Desktop route still works while Router is stopped (Router absence safe).
    $runtime.lifecycle = "STOPPED"
    $runtime | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimePath -Encoding UTF8
    Invoke-DirectDesktop @("-Mode","activate","-ProviderId","openrouter","-ModelId","z-ai/glm-5.3","-Effort","high")
    $directState = Get-DesktopState
    Assert-True ($null -ne $directState -and [bool]$directState.active) "Direct Desktop route remains usable while Router is stopped"
    Invoke-DirectDesktop @("-Mode","restore")
    $runtime.lifecycle = "READY"
    $runtime | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimePath -Encoding UTF8
    Reset-ToBaseline

    # mm_openai_api gap preserved for Desktop Router.
    $beforeGap = Get-ConfigText
    $gapOutput = Invoke-RouterDesktopCaptureFail @("-Mode","activate","-ModelId","gpt-5.6-sol","-Effort","high","-ConfirmationCode","ROUTER")
    Assert-True (($LASTEXITCODE -ne 0) -and ($gapOutput -match "MM_OPENAI_API_CATALOG_CAPABILITY_GAP")) "Desktop Router keeps mm_openai_api capability gap fail-closed"
    Assert-True ((Get-ConfigText) -eq $beforeGap) "mm_openai_api gap rejection leaves config untouched"
    Assert-True (-not $baselineConfig.Contains("mm_openai_api") -or -not ($baselineConfig -match 'model_provider\s*=\s*"mm_openai_api"')) "No ChatGPT->mm_openai_api identity mapping exists"

    # Config literal token absence while Router active.
    Invoke-RouterDesktop @("-Mode","activate","-ModelId","qwen3-coder-plus","-Effort","high","-ConfirmationCode","ROUTER")
    $activeFinal = Get-ConfigText
    Assert-True ($activeFinal -notmatch 'CODEX_LOCAL_ROUTER_TOKEN\s*=\s*"lr13-local-token-fixture"') "Config never contains a literal local token value"
    Invoke-RouterDesktop @("-Mode","restore")
}
catch {
    Fail "LR-13 runtime validation failed: $($_.Exception.Message)"
}
finally {
    Restore-ProcessEnvSnapshot $envBefore
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$envAfter = Save-ProcessEnvSnapshot
$envDifferences = @(Compare-ProcessEnvSnapshot $envBefore $envAfter)
Assert-True ($envDifferences.Count -eq 0) "LR-13 validator Process environment snapshot restored exactly (before == after)"

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Local Router Codex Desktop validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}
Write-Host "Local Router Codex Desktop validation PASSED" -ForegroundColor Green
exit 0
