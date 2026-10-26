#requires -Version 7
param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path

$codexCommand = Get-Command codex -ErrorAction SilentlyContinue
if ($null -eq $codexCommand) {
    Write-Host "CODEX LOOPBACK COMPAT = NOT RUN / CODEX CLI UNAVAILABLE"
    exit 0
}
$codexVersion = (& codex --version 2>$null | Select-Object -First 1)

$modulePath = Join-Path $RepositoryRoot "installer/scripts/router-codex-cli.ps1"
$fakeRouterPath = Join-Path $PSScriptRoot "fake-router.ps1"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("lr12-codex-compat-" + [guid]::NewGuid().ToString("N"))
$codexHome = Join-Path $tempRoot "codex-home"
$recordPath = Join-Path $tempRoot "record.json"
$fakeOut = Join-Path $tempRoot "fake.out"
$fakeErr = Join-Path $tempRoot "fake.err"
$portFilePath = Join-Path $tempRoot "fake.port"
$codexOut = Join-Path $tempRoot "codex.out"
$codexErr = Join-Path $tempRoot "codex.err"
$fakeProcess = $null
$codexProcess = $null

function Stop-ProcessTree([System.Diagnostics.Process]$Process) {
    if ($null -eq $Process) { return }
    try { $Process.Kill() } catch { }
    try { $null = $Process.WaitForExit(2000) } catch { }
    if (-not $Process.HasExited) {
        try { & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null } catch { }
    }
}

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $codexHome "multimodel-manager/local-router") | Out-Null
    $env:CODEX_HOME = $codexHome
    $env:CODEX_LOCAL_ROUTER_TOKEN = "lr12-compat-token-not-real"

    $fakeProcess = Start-Process -FilePath "pwsh" -ArgumentList @(
        "-NoProfile",
        "-File", $fakeRouterPath,
        "-Port", "0",
        "-RecordPath", $recordPath,
        "-PortFilePath", $portFilePath,
        "-Quiet"
    ) -RedirectStandardOutput $fakeOut -RedirectStandardError $fakeErr -WindowStyle Hidden -PassThru

    $port = 0
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $portFilePath -PathType Leaf) {
            $text = Get-Content -Raw -LiteralPath $portFilePath -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $parsed = 0
                if ([int]::TryParse($text.Trim(), [ref]$parsed) -and $parsed -gt 0) {
                    $port = $parsed
                    break
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    if ($port -eq 0) {
        throw "Fake Router did not report a loopback port."
    }

    $modelId = "qwen3-coder-plus"
    $routerConfig = @{
        schema_version = 1
        version = 1
        mode = "router"
        local_router = @{
            enabled = $true
            host = "127.0.0.1"
            port = $port
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
        provider_routes = @(@{
            provider_route_id = "provider-route.modelstudio"
            provider_id = "mm_modelstudio"
            adapter_id = "adapter.provider.mm_modelstudio.responses.v1"
            adapter_version = "1.0"
            enabled = $true
            version = 1
        })
        model_routes = @(@{
            model_route_id = "model-route.modelstudio.qwen3-coder-plus"
            provider_id = "mm_modelstudio"
            client_model_id = $modelId
            model_id = $modelId
            upstream_model_id = $modelId
            identity_verification = "explicit_config"
            enabled = $true
            version = 1
        })
        routes = @(@{
            route_id = "route.modelstudio.qwen3-coder-plus"
            provider_route_id = "provider-route.modelstudio"
            protocol_route_id = "protocol-route.responses"
            model_route_id = "model-route.modelstudio.qwen3-coder-plus"
            enabled = $true
            priority = 0
            weight = 1
            health_state = "UNKNOWN"
            timeout_policy_id = ""
            retry_policy_id = ""
            failover_policy_id = ""
            created_at = "2026-08-27T00:00:00Z"
            updated_at = "2026-08-27T00:00:00Z"
            version = 1
        })
        policies = @()
        updated_at = "2026-08-27T00:00:00Z"
    }
    $routerConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $codexHome "multimodel-manager/local-router/router.config.json") -Encoding UTF8

    . $modulePath
    Enable-RouterCli -Model $modelId -Effort "high" -Force | Out-Null

    $codexArgs = @(
        "exec",
        "-p", "mm_local_router",
        "-m", $modelId,
        "-c", "request_max_retries=0",
        "-c", "stream_max_retries=0",
        "--sandbox", "read-only",
        "Reply with exactly: LR12_OK"
    )
    $codexProcess = $null
    $psi = [System.Diagnostics.ProcessStartInfo]::new("cmd.exe")
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.ArgumentList.Add("/c")
    $psi.ArgumentList.Add("codex")
    foreach ($arg in $codexArgs) { $psi.ArgumentList.Add($arg) }
    foreach ($secretName in @("OPENROUTER_API_KEY", "CODEX_DASHSCOPE_API_KEY", "CODEX_OPENAI_API_KEY", "MIMO_API_KEY")) {
        if ($psi.Environment.ContainsKey($secretName)) {
            [void]$psi.Environment.Remove($secretName)
        }
    }
    $psi.Environment["CODEX_LOCAL_ROUTER_TOKEN"] = [string]$env:CODEX_LOCAL_ROUTER_TOKEN
    $preCodexPids = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @("node.exe", "codex.exe") } |
        ForEach-Object { [int]$_.ProcessId })
    $codexProcess = [System.Diagnostics.Process]::Start($psi)
    $codexExited = $codexProcess.WaitForExit(30000)
    if (-not $codexExited) {
        Stop-ProcessTree $codexProcess
    }

    $records = @()
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
        $payload = Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json
        $records = @($payload.records)
    }

    $responsesHit = @($records | Where-Object { $_.path -eq "/v1/responses" -and $_.method -eq "POST" })
    $authOk = @($responsesHit | Where-Object { $_.authorization_matches_expected -eq $true })
    $modelOk = @($responsesHit | Where-Object { $_.model -eq $modelId })

    Write-Host "CODEX LOOPBACK COMPAT = RUN"
    Write-Host ("CODEX VERSION = " + $codexVersion)
    Write-Host ("LOOPBACK REQUESTS = " + $responsesHit.Count)
    Write-Host ("POST /v1/responses = " + $(if ($responsesHit.Count -gt 0) { "YES" } else { "NO" }))
    Write-Host ("AUTHORIZATION LOCAL TOKEN = " + $(if ($authOk.Count -gt 0) { "YES" } else { "NO" }))
    Write-Host ("MODEL = " + $(if ($modelOk.Count -gt 0) { $modelOk[0].model } else { "NOT SEEN" }))
    Write-Host "LIVE PROVIDER = NO"

    if ($responsesHit.Count -eq 0 -or $authOk.Count -eq 0 -or $modelOk.Count -eq 0) {
        Write-Host "CODEX LOOPBACK COMPAT = FAILED (request/auth/model evidence missing)"
        exit 1
    }
    Write-Host "CODEX LOOPBACK COMPAT = PASS"
    exit 0
}
catch {
    Write-Host "CODEX LOOPBACK COMPAT = ERROR: $($_.Exception.Message)"
    exit 1
}
finally {
    Stop-ProcessTree $codexProcess
    Stop-ProcessTree $fakeProcess
    try {
        $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while ([DateTime]::UtcNow -lt $cleanupDeadline) {
            $stray = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                ($_.Name -in @("node.exe", "codex.exe")) -and
                [int]$_.ProcessId -notin $preCodexPids -and
                $null -ne $_.CommandLine -and
                ($_.CommandLine.Contains($modelId) -or $_.CommandLine.Contains($codexHome))
            })
            if ($stray.Count -eq 0) { break }
            foreach ($process in $stray) {
                try { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
            }
            Start-Sleep -Milliseconds 300
        }
    }
    catch { }
    Start-Sleep -Seconds 2
    Remove-Item Env:CODEX_LOCAL_ROUTER_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
