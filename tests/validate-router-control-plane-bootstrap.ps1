param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR7-B-FIX1 - ROUTER CONTROL-PLANE BOOTSTRAP validation.
#
# The Router Control Plane (/v1/router/control-plane/*) requires the
# "router:control-plane" scope, and ClientScopeRegistry resolves a required
# scope by looking for exactly one ENABLED client with that auth_scope (there is
# no caller-identity transport). The bootstrap used to generate only
# client.codex_cli / responses:invoke, so every control-plane call failed closed
# with scope_denied. This validator pins the fixed contract:
#
#   A. a fresh Initialize plans client.codex_cli and client.control_plane once each
#   B. exactly one enabled client grants router:control-plane
#   C. exactly one generated client grants responses:invoke
#   D. client.control_plane never owns a model route
#   E. re-running Initialize over a config that already has client.codex_cli
#      adds only client.control_plane and never rewrites the existing client
#   F. a second Initialize is semantic idempotent
#   G. provider/model/full routes do not change because of the control-plane client
#   H. the DeepSeek legacy aliases still resolve uniquely to deepseek-flash
#   I. the control-plane client adds no secret, no second token and no second
#      credential store: the single bearer_env_ref boundary is reused
#   R. an isolated Router instance serves /v1/router/control-plane/status and
#      /usage with 200 instead of scope_denied, while an authorized but
#      unroutable /v1/responses call still resolves the execution identity and
#      never reaches a provider.
#
# Everything is offline: the config scenarios run in-process against a
# throw-away CODEX_HOME with fixture env seams, and the runtime check uses the
# Release host on a free loopback port with a fixture token. No provider request
# is ever issued and the real ~/.codex is never read or written.

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Pass $Message } else { Fail $Message }
}

function Save-ProcessEnvSnapshot {
    $names = @("CODEX_HOME", "DEEPSEEK_API_KEY", "CODEX_LOCAL_ROUTER_TOKEN", "RUNNER_TEMP") | Sort-Object -Unique
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

function Clear-ProcessUpstreamEnv {
    foreach ($name in @("OPENROUTER_API_KEY", "CODEX_DASHSCOPE_API_KEY", "CODEX_OPENAI_API_KEY", "MIMO_API_KEY", "DEEPSEEK_API_KEY")) {
        Remove-Item -Path ("Env:" + $name) -ErrorAction SilentlyContinue
    }
}

$modulePath = Join-Path $RepositoryRoot "installer/scripts/router-codex-cli.ps1"
$fixtureRoot = Join-Path $RepositoryRoot "tests/fixtures/local-router/v1/bootstrap"
$approvedFixturePath = Join-Path $fixtureRoot "approved-models.fixture.json"
$envReferenceFixturePath = Join-Path $fixtureRoot "env.references.json"
$hostDll = Join-Path $RepositoryRoot "local-router/src/Router.Host/bin/Release/net10.0/Router.Host.dll"

foreach ($path in @($modulePath, $approvedFixturePath, $envReferenceFixturePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail "Required control-plane bootstrap file missing: $path" }
}
if ($failures.Count -gt 0) {
    Write-Host "Router control-plane bootstrap validation FAILED (missing files)" -ForegroundColor Red
    exit 1
}

$moduleText = Get-Content -Raw -LiteralPath $modulePath
$validatorText = Get-Content -Raw -LiteralPath $PSCommandPath
$controlPlaneHandlerText = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "local-router/src/Router.Ingress/Handlers/ControlPlaneHandlers.cs")
$fixtureApprovals = @(Get-Content -Raw -LiteralPath $approvedFixturePath | ConvertFrom-Json)
$fixtureEnvTable = (Get-Content -Raw -LiteralPath $envReferenceFixturePath | ConvertFrom-Json).references

# --- Static contract ---------------------------------------------------------
$setEnvApi = "Set" + "EnvironmentVariable"
$userTarget = "EnvironmentVariableTarget]::" + "User"
Assert-True (-not $validatorText.Contains($setEnvApi)) "Validator never calls $setEnvApi (no real User-scope writes)"
Assert-True (-not $validatorText.Contains($userTarget)) "Validator never references the real User-scope environment target"
Assert-True ($controlPlaneHandlerText.Contains('RequiredScope = "router:control-plane"')) "The Control Plane still requires router:control-plane"
Assert-True ($moduleText.Contains('$script:Lr12ControlPlaneClientId = "client.control_plane"')) "Bootstrap declares the control-plane client id"
Assert-True ($moduleText.Contains('$script:Lr12ControlPlaneClientAdapterId = "adapter.client.control_plane.responses.v1"')) "Bootstrap declares the control-plane client adapter id"
Assert-True ($moduleText.Contains('$script:Lr12ControlPlaneClientAuthScope = "router:control-plane"')) "Bootstrap declares the control-plane auth scope"
Assert-True ($moduleText.Contains("function New-RouterBootstrapControlPlaneClientEntry")) "Bootstrap owns a dedicated control-plane client entry builder"
Assert-True ($moduleText.Contains("New-RouterBootstrapControlPlaneClientEntry")) "Bootstrap entity generation adds the control-plane client"
Assert-True (-not $moduleText.Contains("X-Client-Id")) "Bootstrap invents no caller-identity transport header"
Assert-True (-not $moduleText.Contains("X-Router-Client")) "Bootstrap invents no router client hint header"

# H. Legacy DeepSeek aliases still resolve uniquely to deepseek-flash.
Assert-True ($moduleText.Contains('"deepseek::deepseek-flash" = @("deepseek-v4-flash", "deepseek-v4-flash-vision-exp")')) "H: the explicit DeepSeek flash alias table is unchanged"
Assert-True (-not ($moduleText -match 'deepseek-v4-pro"\s*=\s*@\("')) "H: the pro route still declares no aliases"

function New-ControlPlaneSandbox {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-mm-cpb-" + [guid]::NewGuid().ToString("N"))
    $codexHome = Join-Path $root "codex-home"
    New-Item -ItemType Directory -Force -Path (Join-Path $codexHome "multimodel-manager") | Out-Null
    Copy-Item -LiteralPath $approvedFixturePath -Destination (Join-Path $codexHome "multimodel-manager/approved-models.json")
    return [pscustomobject]@{ Root = $root; CodexHome = $codexHome }
}

function Get-RouterConfigPath([string]$CodexHome) {
    return (Join-Path $CodexHome "multimodel-manager/local-router/router.config.json")
}

function Get-RouterConfig([string]$CodexHome) {
    return (Get-Content -Raw -LiteralPath (Get-RouterConfigPath $CodexHome) | ConvertFrom-Json -AsHashtable)
}

function Invoke-InitializeCaptured {
    return (& { Initialize-RouterCli } *>&1 | Out-String)
}

function Get-ServerSlice([string]$CodexHome) {
    $document = Get-RouterConfig $CodexHome
    return (Get-RouterBootstrapComparableJson (ConvertTo-RouterBootstrapCanonicalDocument $document))
}

function New-FreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}

$envBefore = Save-ProcessEnvSnapshot
$sandboxes = New-Object System.Collections.Generic.List[object]
$runtimeProcess = $null
try {
    Clear-ProcessUpstreamEnv
    $sandbox = New-ControlPlaneSandbox
    $sandboxes.Add($sandbox)
    $env:CODEX_HOME = $sandbox.CodexHome
    . $modulePath
    $script:Lr12UserEnvWriter = @{}
    $script:Lr12UserEnvLookup = $script:Lr12UserEnvWriter
    foreach ($property in $fixtureEnvTable.PSObject.Properties) {
        $script:Lr12UserEnvLookup[$property.Name] = [string]$property.Value
    }
    $script:Lr12UserEnvLookup["CODEX_LOCAL_ROUTER_TOKEN"] = $null

    # --- A. fresh Initialize -------------------------------------------------
    $configPath = Get-RouterConfigPath $sandbox.CodexHome
    Assert-True (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) "A: the sandbox starts without a router config"
    $outputA = Invoke-InitializeCaptured
    Assert-True (Test-Path -LiteralPath $configPath -PathType Leaf) "A: Initialize writes the router config"
    $docA = Get-RouterConfig $sandbox.CodexHome
    Assert-True (@($docA.clients | Where-Object { $_.client_id -eq "client.codex_cli" }).Count -eq 1) "A: client.codex_cli is generated exactly once"
    Assert-True (@($docA.clients | Where-Object { $_.client_id -eq "client.control_plane" }).Count -eq 1) "A: client.control_plane is generated exactly once"
    Assert-True (@($docA.clients).Count -eq 2) "A: the bootstrap generates exactly two clients"
    Assert-True (@($docA.clients | Where-Object { $_.client_id -eq "client.codex_cli" })[0].auth_scope -eq "responses:invoke") "A: client.codex_cli keeps auth_scope responses:invoke"

    # --- B + C. scope ownership ---------------------------------------------
    Assert-True (@($docA.clients | Where-Object { [bool]$_.enabled -and $_.auth_scope -eq "router:control-plane" }).Count -eq 1) "B: exactly one enabled client grants router:control-plane"
    Assert-True ((@($docA.clients | Where-Object { [bool]$_.enabled -and $_.auth_scope -eq "router:control-plane" })[0]).client_id -eq "client.control_plane") "B: the control-plane scope belongs to client.control_plane"
    Assert-True ([bool](@($docA.clients | Where-Object { $_.client_id -eq "client.control_plane" })[0]).enabled) "B: the control-plane client is enabled"
    $controlPlaneClientA = @($docA.clients | Where-Object { $_.client_id -eq "client.control_plane" })[0]
    Assert-True (@($controlPlaneClientA.capabilities).Count -gt 0) "B: the control-plane client declares the known bootstrap capabilities the production validator requires"
    Assert-True (-not (@($controlPlaneClientA.capabilities) | Where-Object { $_ -notin @("text","streaming","reasoning","tools","usage","cancellation","responses") }).Count) "B: the control-plane client invents no new capability name"
    Assert-True (-not ($controlPlaneClientA.PSObject.Properties.Name -contains "allowed_route_ids")) "B: the control-plane client declares no route ownership list"
    Assert-True (@($docA.clients | Where-Object { [bool]$_.enabled -and $_.auth_scope -eq "responses:invoke" }).Count -eq 1) "C: exactly one enabled client grants responses:invoke"
    Assert-True ((@($docA.clients | Where-Object { [bool]$_.enabled -and $_.auth_scope -eq "responses:invoke" })[0]).client_id -eq "client.codex_cli") "C: the execution scope belongs to client.codex_cli"
    Assert-True (@($docA.clients | ForEach-Object { $_.auth_scope } | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0) "C: no two generated clients share an auth_scope"

    # --- D. the control-plane client owns no route ---------------------------
    Assert-True (@($docA.routes | Where-Object { @($_.client_ids) -contains "client.control_plane" }).Count -eq 0) "D: client.control_plane appears in no route.client_ids"
    Assert-True (@($docA.routes | Where-Object { -not (@($_.client_ids) -contains "client.codex_cli") }).Count -eq 0) "D: every model route still belongs to client.codex_cli only"
    Assert-True (@($docA.provider_routes | Where-Object { $_.PSObject.Properties.Name -contains "client_ids" }).Count -eq 0) "D: provider routes carry no client ownership at all"

    # --- G. route inventory is untouched by the control-plane client ---------
    Assert-True (@($docA.provider_routes).Count -eq 4) "G: provider routes unchanged (4 fixture providers)"
    Assert-True (@($docA.provider_routes | Where-Object { $_.provider_id -eq "deepseek" }).Count -eq 1) "G: exactly one DeepSeek provider route"
    Assert-True (@($docA.model_routes | Where-Object { $_.provider_id -eq "deepseek" }).Count -eq 2) "G: the two DeepSeek model routes are present"
    Assert-True (@($docA.routes | Where-Object { $_.route_id -like "route.deepseek-*" }).Count -eq 2) "G: the two DeepSeek full routes are present"
    $deepseekRoutesBefore = @($docA.routes | Where-Object { $_.route_id -like "route.deepseek-*" } | ForEach-Object { Get-RouterBootstrapComparableJson $_ })

    # --- F. second Initialize is idempotent ---------------------------------
    $bytesBefore = Get-Content -Raw -LiteralPath $configPath
    $outputF = Invoke-InitializeCaptured
    Assert-True ((Get-Content -Raw -LiteralPath $configPath) -eq $bytesBefore) "F: a repeated Initialize leaves the config bytes unchanged"
    Assert-True ($outputF -match "unchanged \(idempotent\)") "F: a repeated Initialize reports an idempotent no-op"
    $docF = Get-RouterConfig $sandbox.CodexHome
    Assert-True (@($docF.clients | Where-Object { $_.client_id -eq "client.control_plane" }).Count -eq 1) "F: no duplicate client.control_plane is created"
    Assert-True (@($docF.clients | Where-Object { $_.client_id -eq "client.codex_cli" }).Count -eq 1) "F: no duplicate client.codex_cli is created"
    $deepseekRoutesAfter = @($docF.routes | Where-Object { $_.route_id -like "route.deepseek-*" } | ForEach-Object { Get-RouterBootstrapComparableJson $_ })
    Assert-True (($deepseekRoutesAfter -join "|") -eq ($deepseekRoutesBefore -join "|")) "G: DeepSeek full routes are byte-stable across re-initialize"

    # --- I. no extra secret material, one bearer boundary --------------------
    $docText = Get-Content -Raw -LiteralPath $configPath
    Assert-True (-not ($docText -match "fixture-deepseek-reference-value" -or $docText -match "fixture-openrouter-reference-value")) "I: no upstream secret value reaches the router config"
    Assert-True (-not ($docText -match '"(api_key|bearer|token_value)"\s*:')) "I: the router config carries no credential field"
    Assert-True (@($docF.clients | Where-Object { $_.PSObject.Properties.Name -contains "env_key" }).Count -eq 0) "I: no client carries its own env_key"
    $tokenRefs = @($docF.local_router.client_auth.token_ref)
    Assert-True ($tokenRefs.Count -eq 1 -and $tokenRefs[0] -eq "CODEX_LOCAL_ROUTER_TOKEN") "I: the config keeps the single existing bearer env reference"
    Assert-True (@($docF.local_router.PSObject.Properties.Name | Where-Object { $_ -like "*token*" -and $_ -ne "client_auth" }).Count -eq 0) "I: no second token store is introduced"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sandbox.CodexHome "auth.json"))) "I: no credential store file is created"

    # --- E. additive merge over an existing execution-only config ------------
    $caseE = New-ControlPlaneSandbox
    $sandboxes.Add($caseE)
    $env:CODEX_HOME = $caseE.CodexHome
    $configPathE = Get-RouterConfigPath $caseE.CodexHome
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configPathE) | Out-Null
    $executionOnlyClient = @{
        client_id = "client.codex_cli"
        adapter_id = "adapter.client.codex_cli.responses.v1"
        enabled = $true
        auth_scope = "responses:invoke"
        capabilities = @("text")
        version = 1
    }
    $preExisting = [ordered]@{
        schema_version = 1
        version = 1
        mode = "router"
        local_router = @{ enabled = $true; host = "127.0.0.1"; port = 47821 }
        clients = @($executionOnlyClient)
        protocol_routes = @()
        endpoints = @()
        provider_routes = @()
        model_routes = @()
        routes = @()
        policies = @()
        updated_at = "2026-09-20T00:00:00Z"
    }
    ($preExisting | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $configPathE -Encoding UTF8
    $outputE = Invoke-InitializeCaptured
    $docE = Get-RouterConfig $caseE.CodexHome
    Assert-True (@($docE.clients).Count -eq 2) "E: the merge adds exactly one client"
    Assert-True (@($docE.clients | Where-Object { $_.client_id -eq "client.control_plane" }).Count -eq 1) "E: client.control_plane is added"
    Assert-True (@($docE.clients | Where-Object { $_.client_id -eq "client.codex_cli" }).Count -eq 1) "E: client.codex_cli is not duplicated"
    $mergedExecutionClient = @($docE.clients | Where-Object { $_.client_id -eq "client.codex_cli" })[0]
    Assert-True (@($mergedExecutionClient.capabilities).Count -eq 1 -and @($mergedExecutionClient.capabilities)[0] -eq "text") "E: the pre-existing client fields are never rewritten"
    Assert-True (@($docE.clients | Where-Object { $_.auth_scope -eq "router:control-plane" }).Count -eq 1) "E: the merged config grants router:control-plane exactly once"

    # --- R. isolated Router serves the Control Plane -------------------------
    if (Test-Path -LiteralPath $hostDll -PathType Leaf) {
        $caseR = New-ControlPlaneSandbox
        $sandboxes.Add($caseR)
        $env:CODEX_HOME = $caseR.CodexHome
        $freePort = New-FreePort
        $script:Lr12UserEnvLookup["CODEX_LOCAL_ROUTER_TOKEN"] = "control-plane-fixture-token"
        # The bootstrap preserves an existing valid user port, so the isolated
        # instance is pinned to a free loopback port before Initialize runs.
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Get-RouterConfigPath $caseR.CodexHome)) | Out-Null
        ([ordered]@{
            schema_version = 1
            version = 1
            mode = "router"
            local_router = [ordered]@{ enabled = $true; host = "127.0.0.1"; port = $freePort }
        } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Get-RouterConfigPath $caseR.CodexHome) -Encoding UTF8
        [void](Initialize-RouterCli -Force)
        $docR = Get-RouterConfig $caseR.CodexHome
        Assert-True ([int]$docR.local_router.port -eq $freePort) "R: the isolated router binds a free loopback port"
        Assert-True (@($docR.clients | Where-Object { $_.auth_scope -eq "router:control-plane" }).Count -eq 1) "R: the isolated config grants the control-plane scope"

        $runtimeDir = Join-Path $caseR.CodexHome "multimodel-manager/local-router/runtime"
        New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
        $dotnetCandidates = @()
        if (-not [string]::IsNullOrWhiteSpace($env:DOTNET_ROOT)) { $dotnetCandidates += (Join-Path $env:DOTNET_ROOT "dotnet.exe") }
        $dotnetCandidates += (Join-Path $env:USERPROFILE ".dotnet/dotnet.exe")
        $dotnetOnPath = Get-Command dotnet -ErrorAction SilentlyContinue
        if ($null -ne $dotnetOnPath) { $dotnetCandidates += $dotnetOnPath.Source }
        $dotnetHost = $dotnetCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1

        $runtimeProcess = Start-Process -FilePath $dotnetHost -ArgumentList @($hostDll) -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $runtimeDir "cpb-host.stdout.log") `
            -RedirectStandardError (Join-Path $runtimeDir "cpb-host.stderr.log") `
            -Environment @{ CODEX_HOME = $caseR.CodexHome; DOTNET_ROOT = (Split-Path $dotnetHost); CODEX_LOCAL_ROUTER_TOKEN = "control-plane-fixture-token" }

        $headers = @{ Authorization = "Bearer control-plane-fixture-token" }
        $ready = $false
        for ($i = 1; $i -le 15; $i++) {
            Start-Sleep -Seconds 1
            try {
                $health = Invoke-WebRequest -Method Get -Uri "http://127.0.0.1:$freePort/health" -TimeoutSec 2 -UseBasicParsing
                if ($health.StatusCode -eq 200) { $ready = $true; break }
            } catch { }
        }
        Assert-True $ready "R: the isolated router reports READY on loopback health"

        if ($ready) {
            foreach ($endpoint in @("status", "usage")) {
                try {
                    $response = Invoke-WebRequest -Method Get -Uri "http://127.0.0.1:$freePort/v1/router/control-plane/$endpoint" -Headers $headers -TimeoutSec 5 -UseBasicParsing
                    Assert-True ($response.StatusCode -eq 200) "R: GET /v1/router/control-plane/$endpoint returns 200 (not scope_denied)"
                } catch {
                    $status = $null
                    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                    Fail "R: GET /v1/router/control-plane/$endpoint failed (status $status)"
                }
            }

            # An authorized but unroutable Responses call proves the execution
            # scope still resolves: it must fail at model resolution
            # (unknown_model) rather than at authorization (scope_denied), and an
            # unroutable model id can never reach a provider.
            $client = [System.Net.Http.HttpClient]::new()
            try {
                $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", "control-plane-fixture-token")
                $payload = [System.Net.Http.StringContent]::new(
                    (@{ model = "no-such-model-in-this-sandbox"; input = "x" } | ConvertTo-Json -Depth 5),
                    [System.Text.Encoding]::UTF8,
                    "application/json")
                $responses = $client.PostAsync("http://127.0.0.1:$freePort/v1/responses", $payload).GetAwaiter().GetResult()
                $responsesBody = $responses.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                Assert-True ($responsesBody -match '"code"\s*:\s*"unknown_model"') "R: the execution scope resolves and fails closed on an unroutable model (unknown_model)"
                Assert-True (-not ($responsesBody -match "scope_denied")) "R: the execution identity is not rejected for its scope"
            }
            finally {
                $client.Dispose()
            }
        }
    }
    else {
        Fail "R: the Release host build output is required for the isolated control-plane runtime check"
    }
}
finally {
    if ($null -ne $runtimeProcess) {
        # Only ever stop the exact isolated test host this validator started.
        try { if (-not $runtimeProcess.HasExited) { $runtimeProcess.Kill($true) } } catch { }
    }
    Restore-ProcessEnvSnapshot $envBefore
    $tempRoot = [System.IO.Path]::GetTempPath()
    foreach ($sandbox in $sandboxes) {
        if ($null -ne $sandbox -and $sandbox.Root.StartsWith($tempRoot) -and (Test-Path -LiteralPath $sandbox.Root)) {
            Remove-Item -LiteralPath $sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "Router control-plane bootstrap validation PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "Router control-plane bootstrap validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
exit 1
