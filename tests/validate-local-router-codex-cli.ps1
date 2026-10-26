param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) {
    Write-Host "PASS  $Message" -ForegroundColor Green
}

function Fail([string]$Message) {
    $failures.Add($Message)
    Write-Host "FAIL  $Message" -ForegroundColor Red
}

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Pass $Message } else { Fail $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $threw = $true
    }
    Assert-True $threw $Message
}

function Assert-ThrowsMatch([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $matched = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $matched = ($_.Exception.Message -match $Pattern)
    }
    Assert-True $matched $Message
}

function Save-ProcessEnvSnapshot {
    $names = @(
        "OPENROUTER_API_KEY",
        "CODEX_DASHSCOPE_API_KEY",
        "CODEX_OPENAI_API_KEY",
        "MIMO_API_KEY",
        "CODEX_LOCAL_ROUTER_TOKEN",
        "CODEX_HOME",
        "RUNNER_TEMP"
    ) | Sort-Object -Unique
    $snapshot = [ordered]@{}
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        $snapshot[$name] = if ($null -eq $value) { $null } else { [string]$value }
    }
    return $snapshot
}

function Restore-ProcessEnvSnapshot($Snapshot) {
    foreach ($entry in $Snapshot.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            Remove-Item -Path ("Env:" + $entry.Key) -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -Path ("Env:" + $entry.Key) -Value ([string]$entry.Value) -ErrorAction SilentlyContinue
        }
    }
}

function Compare-ProcessEnvSnapshot($Before, $After) {
    $differences = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Before.GetEnumerator()) {
        $afterValue = $After[$entry.Key]
        $beforeValue = $entry.Value
        if ($null -eq $beforeValue -and $null -eq $afterValue) { continue }
        if ($null -ne $beforeValue -and $null -ne $afterValue -and $beforeValue -eq $afterValue) { continue }
        $differences.Add($entry.Key)
    }
    return @($differences.ToArray())
}

$envBefore = Save-ProcessEnvSnapshot
$validatorPath = Join-Path $RepositoryRoot "tests/validate-local-router-codex-cli.ps1"
$validatorText = Get-Content -Raw -LiteralPath $validatorPath
$setEnvApiPattern = "Set" + "EnvironmentVariable"
$userTargetPattern = "EnvironmentVariableTarget]::" + "User"
Assert-True (-not $validatorText.Contains($setEnvApiPattern)) ("Validator never calls " + $setEnvApiPattern + " (no User-scope writes)")
Assert-True (-not $validatorText.Contains($userTargetPattern)) "Validator never references User-scope environment target"

$modulePath = Join-Path $RepositoryRoot "installer/scripts/router-codex-cli.ps1"
$modeSelectorPath = Join-Path $RepositoryRoot "installer/scripts/launch-codex-mode.ps1"
$directLauncherPath = Join-Path $RepositoryRoot "installer/scripts/launch-controller-model.ps1"
$fakeRouterPath = Join-Path $RepositoryRoot "tests/fixtures/local-router/codex-cli/fake-router.ps1"
$compatRunnerPath = Join-Path $RepositoryRoot "tests/fixtures/local-router/codex-cli/run-codex-compat.ps1"

if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { Fail "Router CLI adapter module missing: $modulePath" }
if (-not (Test-Path -LiteralPath $modeSelectorPath -PathType Leaf)) { Fail "ModeSelector dispatch missing: $modeSelectorPath" }
if (-not (Test-Path -LiteralPath $fakeRouterPath -PathType Leaf)) { Fail "Fake Codex loopback fixture missing: $fakeRouterPath" }
if (-not (Test-Path -LiteralPath $compatRunnerPath -PathType Leaf)) { Fail "Codex loopback compatibility runner missing: $compatRunnerPath" }
if ($failures.Count -gt 0) {
    Write-Host "LR-12 Codex CLI validation FAILED (missing files)" -ForegroundColor Red
    exit 1
}

$moduleText = Get-Content -Raw -LiteralPath $modulePath
$selectorText = Get-Content -Raw -LiteralPath $modeSelectorPath

$staticChecks = [ordered]@{
    "Router provider identity mm_local_router" = $moduleText.Contains('"mm_local_router"')
    "Client token env ref CODEX_LOCAL_ROUTER_TOKEN" = $moduleText.Contains('CODEX_LOCAL_ROUTER_TOKEN')
    "Router profile wire_api responses only" = ($moduleText.Contains('wire_api = "responses"') -and -not $moduleText.Contains('wire_api = "chat"'))
    "requires_openai_auth=false projection" = $moduleText.Contains("requires_openai_auth = false")
    "supports_websockets=false projection" = $moduleText.Contains("supports_websockets = false")
    "Codex request retries disabled" = $moduleText.Contains("request_max_retries = 0")
    "Codex stream retries disabled" = $moduleText.Contains("stream_max_retries = 0")
    "Default ModeSelector is direct" = $moduleText.Contains('mode = "direct"')
    "No auth.json access" = -not $moduleText.Contains("auth.json")
    "No Chat Completions wiring" = -not $moduleText.Contains("/v1/chat/completions")
    "Ownership markers present" = ($moduleText.Contains("# >>> CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN") -and $moduleText.Contains("# >>> CODEX MULTIMODEL MANAGER ROUTER CLI PROFILE BEGIN"))
    "ModeSelector does not rewrite Direct launcher" = ($selectorText.Contains("launch-controller-model.ps1") -and -not $selectorText.Contains("Set-Content"))
    "Model gate consumes canonical catalog" = $moduleText.Contains("model-catalog.json")
    "Model gate consumes enabled Router routes" = $moduleText.Contains("model_routes")
    "User-env injectable seam exists" = ($moduleText.Contains("Get-RouterCliUserEnvironmentValue") -and $moduleText.Contains("Lr12UserEnvLookup"))
    "mm_openai_api capability gap is explicit" = $moduleText.Contains("MM_OPENAI_API_CATALOG_CAPABILITY_GAP")
    "ChatGPT identity never maps to mm_openai_api" = (-not $moduleText.Contains('"chatgpt" = "mm_openai_api"'))
    "Child env isolation lists upstream secrets" = ($moduleText.Contains("OPENROUTER_API_KEY") -and $moduleText.Contains("CODEX_DASHSCOPE_API_KEY") -and $moduleText.Contains("CODEX_OPENAI_API_KEY") -and $moduleText.Contains("MIMO_API_KEY"))
    "Enable offers interactive model selection" = $moduleText.Contains("Enter Router model ID")
    "Compatibility runner reports NOT RUN honestly" = (Get-Content -Raw -LiteralPath $compatRunnerPath).Contains("CODEX LOOPBACK COMPAT = NOT RUN / CODEX CLI UNAVAILABLE")
}
foreach ($entry in $staticChecks.GetEnumerator()) {
    Assert-True $entry.Value $entry.Key
}

$oldCodexHome = $env:CODEX_HOME
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-mm-lr12-" + [guid]::NewGuid().ToString("N"))
$tempCodexHome = Join-Path $tempRoot "codex-home"
$env:CODEX_HOME = $tempCodexHome

$originalConfigText = @'
# Existing user Codex configuration (must be preserved exactly)
model = "gpt-5.6"
model_provider = "openai"
approval_policy = "on-request"

[model_providers.mm_openrouter]
name = "OpenRouter (existing user provider)"
base_url = "https://openrouter.ai/api/v1"
env_key = "OPENROUTER_API_KEY"
wire_api = "responses"

[model_providers.mm_modelstudio]
name = "Model Studio (existing user provider)"
base_url = "https://example.invalid/v1"
env_key = "CODEX_DASHSCOPE_API_KEY"
wire_api = "responses"

[model_providers.mm_mimo]
name = "MiMo (existing user provider)"
base_url = "https://example.invalid/v1"
env_key = "MIMO_API_KEY"
wire_api = "responses"

# >>> CODEX MULTIMODEL MANAGER BEGIN
# Existing manager-owned block must survive Router CLI enable/disable untouched.
[model_providers.mm_openai_api]
name = "OpenAI API (manager block)"
base_url = "https://api.openai.com/v1"
env_key = "CODEX_OPENAI_API_KEY"
wire_api = "responses"
# <<< CODEX MULTIMODEL MANAGER END

[profiles.user_custom]
model = "user/model"
'@

function New-RouterConfigJson([int]$Port) {
    return [pscustomobject]@{
        schema_version = 1
        version = 1
        mode = "router"
        local_router = @{
            enabled = $true
            host = "127.0.0.1"
            port = $Port
            client_auth = @{
                mode = "bearer_env_ref"
                token_ref = "CODEX_LOCAL_ROUTER_TOKEN"
            }
            limits = @{
                max_request_bytes = 16777216
                max_header_bytes = 32768
                max_connections = 32
                shutdown_grace_ms = 15000
            }
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

function Write-RouterConfigFixture([int]$Port) {
    $router = New-RouterConfigJson $Port
    $router | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $tempCodexHome "multimodel-manager/local-router/router.config.json") -Encoding UTF8
}

try {
    . $modulePath
    $script:Lr12UserEnvLookup = @{
        "CODEX_LOCAL_ROUTER_TOKEN" = "fixture-user-token-never-written-to-user-env"
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $tempCodexHome "multimodel-manager/local-router") | Out-Null
    Set-Content -LiteralPath (Join-Path $tempCodexHome "config.toml") -Value $originalConfigText -Encoding UTF8
    Write-RouterConfigFixture 47821
    $env:CODEX_LOCAL_ROUTER_TOKEN = "test-process-token-never-logged"

    $configPath = Join-Path $tempCodexHome "config.toml"
    $profilePath = Join-Path $tempCodexHome "mm_local_router.config.toml"
    $statePath = Join-Path $tempCodexHome "multimodel-manager/router-cli-state.json"
    $routerConfigPath = Join-Path $tempCodexHome "multimodel-manager/local-router/router.config.json"
    $originalOnDiskText = Get-Content -Raw -LiteralPath $configPath
    $directHashBefore = Get-FileSha256 $directLauncherPath

    # The injectable user-env seam is used instead of touching real User scope.
    $seamValue = Get-RouterCliUserEnvironmentValue "CODEX_LOCAL_ROUTER_TOKEN"
    Assert-True ($seamValue -eq "fixture-user-token-never-written-to-user-env") "User-env seam supplies fixture token without writing User scope"

    # Unknown / ambiguous / disabled model gates fail closed before any write.
    $configBeforeReject = Get-Content -Raw -LiteralPath $configPath
    Assert-Throws { Enable-RouterCli -Model "totally-unknown-model" -Effort "medium" -Force } "Unknown model fails closed on Enable"
    Assert-True ((Get-Content -Raw -LiteralPath $configPath) -eq $configBeforeReject) "Unknown model rejection never changes config"
    Assert-True (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) "Unknown model rejection never writes Router profile"

    $ambiguousProviderJson = @'
{
  "provider_route_id": "provider-route.mimo-dup",
  "provider_id": "mm_mimo",
  "adapter_id": "adapter.provider.mm_mimo.responses.v1",
  "adapter_version": "1.0",
  "enabled": true,
  "version": 1
}
'@ | ConvertFrom-Json
    $modelRouteJson = @'
{
  "model_route_id": "model-route.mimo.deepseek-dup",
  "provider_id": "mm_mimo",
  "client_model_id": "deepseek-v4-pro",
  "model_id": "mimo-v2.5-pro",
  "upstream_model_id": "mimo-v2.5-pro",
  "identity_verification": "explicit_config",
  "enabled": true,
  "version": 1
}
'@ | ConvertFrom-Json
    $ambiguousRouteJson = @'
{
  "route_id": "route.mimo.deepseek-dup",
  "provider_route_id": "provider-route.mimo-dup",
  "protocol_route_id": "protocol-route.responses",
  "model_route_id": "model-route.mimo.deepseek-dup",
  "enabled": true,
  "priority": 0,
  "weight": 1,
  "health_state": "UNKNOWN",
  "timeout_policy_id": "",
  "retry_policy_id": "",
  "failover_policy_id": "",
  "created_at": "2026-08-27T00:00:00Z",
  "updated_at": "2026-08-27T00:00:00Z",
  "version": 1
}
'@ | ConvertFrom-Json
    $routerCfg = Get-Content -Raw -LiteralPath $routerConfigPath | ConvertFrom-Json
    $routerCfg.provider_routes = @($routerCfg.provider_routes + $ambiguousProviderJson)
    $routerCfg.model_routes = @($routerCfg.model_routes + $modelRouteJson)
    $routerCfg.routes = @($routerCfg.routes + $ambiguousRouteJson)
    $routerCfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $routerConfigPath -Encoding UTF8
    Assert-Throws { Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force } "Ambiguous enabled route fails closed"
    $routerCfg = Get-Content -Raw -LiteralPath $routerConfigPath | ConvertFrom-Json
    $routerCfg.provider_routes = @($routerCfg.provider_routes | Where-Object { $_.provider_route_id -ne "provider-route.mimo-dup" })
    $routerCfg.model_routes = @($routerCfg.model_routes | Where-Object { $_.model_route_id -ne "model-route.mimo.deepseek-dup" })
    $routerCfg.routes = @($routerCfg.routes | Where-Object { $_.route_id -ne "route.mimo.deepseek-dup" })
    $routerCfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $routerConfigPath -Encoding UTF8

    Assert-Throws { Enable-RouterCli -Model "deepseek-v4-pro" -Effort "xhigh" -Force } "Unsupported reasoning effort fails closed"

    $disabledRouteJson = Get-Content -Raw -LiteralPath $routerConfigPath | ConvertFrom-Json
    $disabledRouteJson.model_routes[0].enabled = $false
    $disabledRouteJson | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $routerConfigPath -Encoding UTF8
    Assert-Throws { Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force } "Disabled model route fails closed"
    $disabledRouteJson.model_routes[0].enabled = $true
    $disabledRouteJson | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $routerConfigPath -Encoding UTF8

    # Provider selection matrix: modelstudio / openrouter / mimo are selectable.
    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    Assert-True ((Get-Content -Raw -LiteralPath $profilePath).Contains('model = "deepseek-v4-pro"')) "mm_modelstudio model selection PASS"
    $gateStudio = @(Get-LaunchGateFailures)
    Assert-True ($gateStudio.Count -eq 0) "mm_modelstudio healthy launch gate PASS"
    Disable-RouterCli -Force | Out-Null

    Enable-RouterCli -Model "z-ai/glm-5.3" -Effort "high" -Force | Out-Null
    Assert-True ((Get-Content -Raw -LiteralPath $profilePath).Contains('model = "z-ai/glm-5.3"')) "mm_openrouter model selection PASS"
    $gateOpenRouter = @(Get-LaunchGateFailures)
    Assert-True ($gateOpenRouter.Count -eq 0) "mm_openrouter healthy launch gate PASS"
    Disable-RouterCli -Force | Out-Null

    Enable-RouterCli -Model "mimo-v2.5-pro" -Effort "high" -Force | Out-Null
    Assert-True ((Get-Content -Raw -LiteralPath $profilePath).Contains('model = "mimo-v2.5-pro"')) "mm_mimo model selection PASS"
    $gateMimo = @(Get-LaunchGateFailures)
    Assert-True ($gateMimo.Count -eq 0) "mm_mimo healthy launch gate PASS"
    Disable-RouterCli -Force | Out-Null

    # mm_openai_api: no canonical/versioned capability source exists in LR-12.
    $configBeforeGap = Get-Content -Raw -LiteralPath $configPath
    Assert-ThrowsMatch { Enable-RouterCli -Model "gpt-5.6-sol" -Effort "high" -Force } "MM_OPENAI_API_CATALOG_CAPABILITY_GAP" "mm_openai_api fails closed with explicit capability gap"
    Assert-True ((Get-Content -Raw -LiteralPath $configPath) -eq $configBeforeGap) "mm_openai_api gap rejection never changes config"
    Assert-True (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) "mm_openai_api gap rejection never writes profile"

    # Full modelstudio flow (used by the remaining assertions).
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    $state = Get-RouterCliState
    Assert-True ($state.mode -eq "router") "Enable transitions ModeSelector to router"
    Assert-True ([int]$state.generation -eq 1) "Enable bumps generation to 1"
    Assert-True ([string]$state.selected_model -eq "deepseek-v4-pro") "Enable records selected model"

    Assert-True (Test-Path -LiteralPath $profilePath -PathType Leaf) "Enable creates Router-owned profile file"
    $profileText = Get-Content -Raw -LiteralPath $profilePath
    Assert-True ($profileText.Contains('model_provider = "mm_local_router"')) "Router profile references mm_local_router"
    Assert-True ($profileText.Contains('model = "deepseek-v4-pro"')) "Router profile projects selected model"
    Assert-True ($profileText.Contains('model_reasoning_effort = "high"')) "Router profile projects reasoning effort"
    Assert-True ($profileText.Contains("request_max_retries = 0") -and $profileText.Contains("stream_max_retries = 0")) "Router profile disables Codex-side retries"
    Assert-True ($profileText -notmatch 'OPENROUTER_API_KEY|CODEX_DASHSCOPE_API_KEY|MIMO_API_KEY|CODEX_OPENAI_API_KEY') "Router profile exposes no upstream key reference"

    $configText = Get-Content -Raw -LiteralPath $configPath
    Assert-True ($configText.Contains('[model_providers.mm_local_router]')) "Enable adds Router provider to base config"
    Assert-True ($configText.Contains('base_url = "http://127.0.0.1:47821/v1"')) "Provider block projects loopback base_url with Router port"
    Assert-True ($configText.Contains('env_key = "CODEX_LOCAL_ROUTER_TOKEN"')) "Provider block uses local token env ref only"
    Assert-True ($configText.Contains('requires_openai_auth = false')) "Provider block disables OpenAI auth requirement"
    $routerBlockMatch = [regex]::Match($configText, '(?s)# >>> CODEX MULTIMODEL MANAGER ROUTER CLI BEGIN.*?# <<< CODEX MULTIMODEL MANAGER ROUTER CLI END')
    Assert-True ($routerBlockMatch.Success -and $routerBlockMatch.Value -notmatch 'OPENROUTER_API_KEY|CODEX_DASHSCOPE_API_KEY|MIMO_API_KEY|CODEX_OPENAI_API_KEY') "Router-owned block exposes no upstream key reference"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempCodexHome "auth.json") -PathType Leaf)) "Enable never creates auth.json"
    Assert-True ($configText.Contains('[model_providers.mm_openrouter]')) "Existing Direct OpenRouter provider preserved"
    Assert-True ($configText.Contains('[model_providers.mm_modelstudio]')) "Existing Direct Model Studio provider preserved"
    Assert-True ($configText.Contains('[model_providers.mm_mimo]')) "Existing Direct MiMo provider preserved"
    Assert-True ($configText.Contains('[model_providers.mm_openai_api]')) "Existing Manager OpenAI API provider preserved"
    Assert-True ($configText.Contains('[profiles.user_custom]')) "Unrelated user profile preserved"
    Assert-True ($configText.Contains('approval_policy = "on-request"')) "Unrelated top-level user setting preserved"

    # Healthy state regression: Direct provider env refs present + Router launch gate PASS.
    $gateFailures = @(Get-LaunchGateFailures)
    Assert-True ($gateFailures.Count -eq 0) "Healthy existing Direct config + Router launch gate has zero failures"

    # Router child environment isolation: process-scope only, exact restore.
    $upstreamNames = @("OPENROUTER_API_KEY", "CODEX_DASHSCOPE_API_KEY", "CODEX_OPENAI_API_KEY", "MIMO_API_KEY")
    foreach ($name in $upstreamNames) {
        Set-Item -Path ("Env:" + $name) -Value ("dummy-process-" + $name) -ErrorAction SilentlyContinue
    }
    Remove-Item Env:CODEX_LOCAL_ROUTER_TOKEN -ErrorAction SilentlyContinue
    $processBefore = Save-ProcessEnvSnapshot
    $snapshot = Get-RouterCliChildEnvSnapshot
    Set-RouterCliChildEnv $snapshot
    foreach ($name in $upstreamNames) {
        Assert-True ($null -eq [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)) "Router child env removes $name from Process scope"
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("CODEX_LOCAL_ROUTER_TOKEN", [EnvironmentVariableTarget]::Process))) "Router child env keeps CODEX_LOCAL_ROUTER_TOKEN in Process scope"
    Restore-RouterCliChildEnv $snapshot
    $processAfter = Save-ProcessEnvSnapshot
    Assert-True ((Compare-ProcessEnvSnapshot $processBefore $processAfter).Count -eq 0) "Router child env isolation restores Process env exactly"
    foreach ($name in $upstreamNames) {
        Assert-True ([string]([Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)) -eq ("dummy-process-" + $name)) "Router child env restores $name to previous Process value"
    }
    $env:CODEX_LOCAL_ROUTER_TOKEN = "test-process-token-never-logged"

    $configAfterEnable = Get-Content -Raw -LiteralPath $configPath
    $profileAfterEnable = Get-Content -Raw -LiteralPath $profilePath
    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    $state2 = Get-RouterCliState
    Assert-True (([int]$state2.generation) -eq 1) "Repeated enable is idempotent (generation unchanged)"
    Assert-True ((Get-Content -Raw -LiteralPath $configPath) -eq $configAfterEnable) "Repeated enable leaves config bytes unchanged"
    Assert-True ((Get-Content -Raw -LiteralPath $profilePath) -eq $profileAfterEnable) "Repeated enable leaves profile bytes unchanged"

    Select-RouterCliModel -Model "qwen3-coder-plus" -Effort "medium" | Out-Null
    $state3 = Get-RouterCliState
    Assert-True ([int]$state3.generation -eq 2) "SelectModel bumps generation"
    Assert-True ((Get-Content -Raw -LiteralPath $profilePath).Contains('model = "qwen3-coder-plus"')) "SelectModel rewrites Router profile model"
    Assert-Throws { Select-RouterCliModel -Model "unknown-model" -Effort "medium" } "SelectModel rejects unknown model"
    Assert-Throws { Select-RouterCliModel -Model "qwen3-coder-plus" -Effort "xhigh" } "SelectModel rejects unsupported effort"

    Assert-True ([bool](Invoke-RouterCliLaunch -Model "qwen3-coder-plus" -Effort "low" -CheckOnly)) "Launch accepts supported ReasoningEffort override (low)"
    Assert-True (-not [bool](Invoke-RouterCliLaunch -Model "qwen3-coder-plus" -Effort "xhigh" -CheckOnly)) "Launch rejects unsupported ReasoningEffort override (xhigh)"
    Assert-True (-not [bool](Invoke-RouterCliLaunch -Model "unknown-model" -Effort "medium" -CheckOnly)) "Launch rejects unknown model override"
    Assert-True (-not [bool](Invoke-RouterCliLaunch -Effort "xhigh" -CheckOnly)) "Launch rejects unsupported state effort without silent downgrade"

    $routerCfg = Get-Content -Raw -LiteralPath $routerConfigPath | ConvertFrom-Json
    $routerCfg.local_router.port = 47822
    $routerCfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $routerConfigPath -Encoding UTF8
    Enable-RouterCli -Model "qwen3-coder-plus" -Effort "medium" -Force | Out-Null
    $state4 = Get-RouterCliState
    Assert-True ([int]$state4.port -eq 47822) "Port change is reflected in Router CLI state"
    Assert-True ((Get-Content -Raw -LiteralPath $configPath).Contains('base_url = "http://127.0.0.1:47822/v1"')) "Port change updates provider projection"
    Assert-True ([int]$state4.generation -eq 3) "Port change bumps generation"

    Disable-RouterCli -Force | Out-Null
    $state5 = Get-RouterCliState
    Assert-True ($state5.mode -eq "direct") "Disable transitions ModeSelector back to direct"
    Assert-True (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) "Disable removes Router-owned profile"
    Assert-True ((Get-Content -Raw -LiteralPath $configPath) -eq $originalOnDiskText) "Disable restores exact original config bytes"
    Assert-True (-not (Get-Content -Raw -LiteralPath $configPath).Contains("mm_local_router")) "Disable removes Router provider block"
    Assert-True ((Get-FileSha256 $directLauncherPath) -eq $directHashBefore) "Direct Mode launcher bytes unchanged by Router CLI lifecycle"

    $bytesAfterDisable = Get-Content -Raw -LiteralPath $configPath
    $generationAfterDisable = [int](Get-RouterCliState).generation
    Disable-RouterCli -Force | Out-Null
    Assert-True ((Get-Content -Raw -LiteralPath $configPath) -eq $bytesAfterDisable) "Repeated disable is a no-op"
    Assert-True ([int](Get-RouterCliState).generation -eq $generationAfterDisable) "Repeated disable does not bump generation"

    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    Disable-RouterCli -Force | Out-Null
    Assert-True ((Get-Content -Raw -LiteralPath $configPath) -eq $originalOnDiskText) "Enable/disable cycle restores exact bytes"
    Assert-True (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) "Enable/disable cycle removes profile file"

    $configBeforeCorrupt = Get-Content -Raw -LiteralPath $configPath
    Set-Content -LiteralPath $statePath -Value "{ this is not json" -Encoding UTF8
    $corruptStateCaught = $false
    try {
        [void](Get-RouterCliState)
    }
    catch {
        $corruptStateCaught = ($_.Exception.Message -match "corrupt")
    }
    Assert-True $corruptStateCaught "Corrupt Router CLI state fails closed with a clear error"
    Assert-True ((Get-Content -Raw -LiteralPath $configPath) -eq $configBeforeCorrupt) "Corrupt state never changes Codex config"
    Set-Content -LiteralPath $statePath -Value (@{ schema_version = 1; mode = "direct"; generation = 0; selected_model = ""; reasoning_effort = "medium"; host = "127.0.0.1"; port = 47821; provider_id = "mm_local_router"; token_env = "CODEX_LOCAL_ROUTER_TOKEN"; backup_receipt = ""; first_backup_receipt = ""; enabled_at = $null; updated_at = $null } | ConvertTo-Json) -Encoding UTF8

    Set-Content -LiteralPath $routerConfigPath -Value "{ bad router json" -Encoding UTF8
    $enableFailedOnCorrupt = $false
    try {
        Enable-RouterCli -Model "deepseek-v4-pro" -Force | Out-Null
    }
    catch {
        $enableFailedOnCorrupt = $true
    }
    Assert-True $enableFailedOnCorrupt "Enable fails safely when Router config is corrupt"
    Write-RouterConfigFixture 47821

    Enable-RouterCli -Model "deepseek-v4-pro" -Effort "high" -Force | Out-Null
    Remove-Item Env:CODEX_LOCAL_ROUTER_TOKEN -ErrorAction SilentlyContinue
    $script:Lr12UserEnvLookup = @{}
    $gateFailures2 = @(Get-LaunchGateFailures)
    Assert-True (($gateFailures2 | Where-Object { $_ -match "token env" }).Count -gt 0) "Missing local token fails the Router launch gate"
    $env:CODEX_LOCAL_ROUTER_TOKEN = "test-process-token-never-logged"
    $script:Lr12UserEnvLookup = @{ "CODEX_LOCAL_ROUTER_TOKEN" = "fixture-user-token-never-written-to-user-env" }

    $routerCfg = Get-Content -Raw -LiteralPath $routerConfigPath | ConvertFrom-Json
    $routerCfg.local_router.enabled = $false
    $routerCfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $routerConfigPath -Encoding UTF8
    $gateFailures3 = @(Get-LaunchGateFailures)
    Assert-True (($gateFailures3 | Where-Object { $_ -match "not enabled" }).Count -gt 0) "Router disabled fails the Router launch gate"

    $stateFinal = Get-RouterCliState
    Assert-True ($stateFinal.mode -eq "router") "Router CLI state remains explicit after launch-gate failures"
    Assert-True (Test-Path -LiteralPath $directLauncherPath -PathType Leaf) "Direct Mode launcher remains present while Router gate fails"

    $receipt = Get-RouterCliReceipt ([string]$stateFinal.first_backup_receipt)
    Assert-True ($null -ne $receipt) "Enable produced a backup receipt"
    $codexEntry = @($receipt.files | Where-Object { $_.kind -eq "codex_config" } | Select-Object -First 1)
    if ($codexEntry.Count -eq 1 -and [bool]$codexEntry[0].existed -and (Test-Path -LiteralPath ([string]$codexEntry[0].backup_path) -PathType Leaf)) {
        Assert-True ((Get-FileSha256 ([string]$codexEntry[0].backup_path)) -eq [string]$codexEntry[0].before_sha256) "Backup receipt preserves exact original config hash"
    }
    else {
        Fail "Backup receipt is missing the codex_config entry"
    }
}
catch {
    Fail "LR-12 runtime validation failed: $($_.Exception.Message)"
}
finally {
    $script:Lr12UserEnvLookup = $null
    Restore-ProcessEnvSnapshot $envBefore
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$envAfter = Save-ProcessEnvSnapshot
$envDifferences = @(Compare-ProcessEnvSnapshot $envBefore $envAfter)
Assert-True ($envDifferences.Count -eq 0) "Validator Process environment snapshot is restored exactly (before == after)"

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Local Router Codex CLI validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "Local Router Codex CLI validation PASSED" -ForegroundColor Green
exit 0
