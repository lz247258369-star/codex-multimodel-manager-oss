#requires -Version 7
param(
    [Parameter(Mandatory = $false)][int]$Port = 0,

    [Parameter(Mandatory = $false)][string]$PortFilePath = "",

    [Parameter(Mandatory = $false)][string]$StateFilePath = "",

    [Parameter(Mandatory = $false)][string]$FixtureDir = "",

    [Parameter(Mandatory = $false)][string]$ExpectedToken = "",

    [Parameter(Mandatory = $false)][string]$ConflictFilePath = "",

    [Parameter(Mandatory = $false)][int]$DelayMs = 0,

    [Parameter(Mandatory = $false)][int]$LifetimeSeconds = 120,

    [Parameter(Mandatory = $false)][switch]$FailStatus,

    # Test-only response gate. When both gates are supplied the worker holds the
    # FIRST matching request open: it signals $RequestEnteredGate as soon as the
    # request has been read (so the test knows a real HTTP request is in flight)
    # and only sends the response after $ResponseReleaseGate is set. The bounded
    # wait exists purely to stop a broken test from hanging forever; a timeout is
    # recorded as gate_timed_out = true so the test can FAIL instead of passing.
    # Gates are shared in-process objects; the gates are never disposed here.
    [Parameter(Mandatory = $false)][object]$RequestEnteredGate = $null,

    [Parameter(Mandatory = $false)][object]$ResponseReleaseGate = $null,

    [Parameter(Mandatory = $false)][int]$GateTimeoutMs = 20000,

    [Parameter(Mandatory = $false)][string]$GatePath = "/v1/router/control-plane/status"
)

# LR-14 V4 test double for the LR-14P Control Plane. It speaks the real
# versioned JSON shapes from local-router/schemas/control-plane-*.v1.schema.json
# over 127.0.0.1 only: status, usage, requests, policy, and the
# generation-aware PUT policy/feature mutations. Every request is counted so a
# test can assert "no mutation on read", "no provider/legacy status call", and
# "no automatic mutation retry after a 409".
$ErrorActionPreference = "Stop"

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
$boundPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
if (-not [string]::IsNullOrWhiteSpace($PortFilePath)) {
    Set-Content -LiteralPath $PortFilePath -Value ([string]$boundPort) -Encoding UTF8
}

$generation = "1111111111111111111111111111111111111111111111111111111111111111"
$enabled = $true
$sequence = 0
$readCount = 0
$policyPutCount = 0
$featurePutCount = 0
$legacyStatusCount = 0
$providerCount = 0
$unknownPathCount = 0
$conflictCount = 0
$unauthorizedCount = 0
$gateUsed = $false
$gateReleased = $false
$gateTimedOut = $false
$gatePathSeen = ""
$mutationAttempts = New-Object System.Collections.Generic.List[object]
$seenPaths = New-Object System.Collections.Generic.List[string]

function Save-FakeControlPlaneState {
    if ([string]::IsNullOrWhiteSpace($StateFilePath)) { return }
    $state = [ordered]@{
        generation = $generation
        enabled = $enabled
        read_count = $readCount
        policy_put_count = $policyPutCount
        feature_put_count = $featurePutCount
        legacy_status_count = $legacyStatusCount
        provider_count = $providerCount
        unknown_path_count = $unknownPathCount
        conflict_count = $conflictCount
        unauthorized_count = $unauthorizedCount
        gate_enabled = ($null -ne $RequestEnteredGate -and $null -ne $ResponseReleaseGate)
        gate_path = $GatePath
        gate_timeout_ms = $GateTimeoutMs
        gate_used = $gateUsed
        gate_released = $gateReleased
        gate_timed_out = $gateTimedOut
        gate_path_seen = $gatePathSeen
        mutation_attempts = @($mutationAttempts.ToArray())
        seen_paths = @($seenPaths.ToArray())
    }
    $temp = $StateFilePath + ".tmp"
    ($state | ConvertTo-Json -Depth 8 -Compress) | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $StateFilePath -Force
}

function Get-FixtureText([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($FixtureDir)) { return $null }
    $path = Join-Path $FixtureDir $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return (Get-Content -Raw -LiteralPath $path -Encoding UTF8)
}

function Send-FakeResponse($Stream, [int]$StatusCode, [string]$Reason, [string]$Body) {
    $head = "HTTP/1.1 {0} {1}`r`nContent-Type: application/json`r`nContent-Length: {2}`r`nConnection: close`r`n`r`n" -f $StatusCode, $Reason, ([System.Text.Encoding]::UTF8.GetByteCount($Body))
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($head + $Body)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Get-NextFakeGeneration([string]$Current, [int]$Step) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Current + ":" + [string]$Step)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

# Test-only response gate. It is a no-op unless the owning test supplied both
# gates, and it can fire at most once per server instance, so every existing
# fixture scenario keeps its current behaviour.
function Invoke-FakeResponseGate([string]$Path) {
    if ($null -eq $RequestEnteredGate -or $null -eq $ResponseReleaseGate) { return }
    if ($gateUsed) { return }
    if (-not [string]::IsNullOrWhiteSpace($GatePath) -and $Path -ne $GatePath) { return }

    $script:gateUsed = $true
    $script:gatePathSeen = $Path
    # Publish "a real request is here and still unanswered" before signalling, so
    # the test can read the counter while the response is provably withheld.
    Save-FakeControlPlaneState
    try { [void]$RequestEnteredGate.Set() } catch { }

    $script:gateReleased = [bool]$ResponseReleaseGate.Wait($GateTimeoutMs)
    $script:gateTimedOut = -not $script:gateReleased
    Save-FakeControlPlaneState
}

function Get-FakeStatusBody {
    $text = Get-FixtureText "control-plane-status.json"
    if ($null -eq $text) {
        $text = '{"schema_version":1,"lifecycle":"READY","ready":true,"in_flight_count":0,"local_router_enabled":true,"supported_control_plane_contracts":[],"metering_availability":{"available":true,"reason_code":null},"recent_request_availability":{"available":true,"reason_code":null},"policy_mutation_available":true,"feature_mutation_available":true,"health_summary":{"available":false,"reason_code":"HEALTH_SNAPSHOT_NOT_COMPOSED","generated_at":null,"route_count":null,"healthy_count":null,"degraded_count":null,"unhealthy_count":null,"unknown_count":null},"circuit_breaker":{"effective_state":"disabled","configured":null,"mutation_available":false,"reason_code":"CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP"},"lifecycle_control":{"start_stop_available":false,"reason_code":"LIFECYCLE_CONTROL_GAP"}}'
    }
    $payload = $text | ConvertFrom-Json
    $payload.config_generation = $generation
    $payload.local_router_enabled = $enabled
    return ($payload | ConvertTo-Json -Depth 8 -Compress)
}

function Get-FakePolicyBody {
    $text = Get-FixtureText "control-plane-policy.json"
    if ($null -eq $text) { return $null }
    $payload = $text | ConvertFrom-Json
    $payload.config_generation = $generation
    return ($payload | ConvertTo-Json -Depth 8 -Compress)
}

$deadline = [DateTime]::UtcNow.AddSeconds($LifetimeSeconds)
Save-FakeControlPlaneState

while ([DateTime]::UtcNow -lt $deadline) {
    if (-not $listener.Pending()) {
        Start-Sleep -Milliseconds 25
        continue
    }

    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $false, 4096, $true)
        $requestLine = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($requestLine)) {
            $client.Close()
            continue
        }

        $parts = $requestLine -split " "
        $method = $parts[0]
        $path = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $authorization = ""
        $contentLength = 0
        $expectContinue = $false
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line -or $line.Length -eq 0) { break }
            if ($line -match '^Authorization:\s*(.+)$') { $authorization = $Matches[1].Trim() }
            elseif ($line -match '^Content-Length:\s*(\d+)$') { $contentLength = [int]$Matches[1] }
            elseif ($line -match '^Expect:\s*100-continue') { $expectContinue = $true }
        }

        if ($expectContinue) {
            $continueBytes = [System.Text.Encoding]::UTF8.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
            $stream.Write($continueBytes, 0, $continueBytes.Length)
            $stream.Flush()
        }

        $body = ""
        if ($contentLength -gt 0) {
            $buffer = [char[]]::new($contentLength)
            $read = 0
            while ($read -lt $contentLength) {
                $chunk = $reader.Read($buffer, $read, $contentLength - $read)
                if ($chunk -le 0) { break }
                $read += $chunk
            }
            if ($read -gt 0) { $body = -join $buffer[0..($read - 1)] }
        }

        $seenPaths.Add(($method + " " + $path)) | Out-Null
        if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }

        # The request target may carry a query string (for example
        # /v1/router/control-plane/usage?limit=20); route on the path only.
        $normalizedPath = ($path -split "\?")[0]
        $isControlPlanePath = $normalizedPath -in @(
            "/v1/router/control-plane/status",
            "/v1/router/control-plane/usage",
            "/v1/router/control-plane/requests",
            "/v1/router/control-plane/policy",
            "/v1/router/control-plane/feature",
            # HS-1B thread-scoped model selection surface: still control-plane
            # reads, never provider/model requests.
            "/v1/router/control-plane/thread-selection-feature",
            "/v1/router/control-plane/threads"
        )

        if (-not $isControlPlanePath) {
            if ($normalizedPath -eq "/v1/router/status") { $legacyStatusCount++ }
            elseif ($normalizedPath -like "/v1/*" -or $normalizedPath -like "/models*") { $providerCount++ }
            else { $unknownPathCount++ }
            Save-FakeControlPlaneState
            Send-FakeResponse $stream 404 "Not Found" '{"error":{"type":"router_error","code":"unknown_route","message":"not found"}}'
            $stream.Close()
            continue
        }

        $authorized = (-not [string]::IsNullOrWhiteSpace($ExpectedToken)) -and
            ($authorization -eq ("Bearer " + $ExpectedToken))
        if (-not $authorized) {
            $unauthorizedCount++
            Save-FakeControlPlaneState
            Send-FakeResponse $stream 401 "Unauthorized" '{"error":{"type":"router_error","code":"authentication_invalid","message":"Authentication is invalid."}}'
            $stream.Close()
            continue
        }

        switch ("$method $normalizedPath") {
            "GET /v1/router/control-plane/status" {
                $readCount++
                Save-FakeControlPlaneState
                Invoke-FakeResponseGate $normalizedPath
                if ($FailStatus) {
                    Send-FakeResponse $stream 503 "Service Unavailable" '{"error":{"type":"router_error","code":"control_read_unavailable","message":"unavailable"}}'
                }
                else {
                    Send-FakeResponse $stream 200 "OK" (Get-FakeStatusBody)
                }
            }
            "GET /v1/router/control-plane/usage" {
                $readCount++
                Save-FakeControlPlaneState
                $text = Get-FixtureText "control-plane-usage.json"
                if ($null -eq $text) {
                    Send-FakeResponse $stream 503 "Service Unavailable" '{"error":{"type":"router_error","code":"control_read_unavailable","message":"unavailable"}}'
                }
                else {
                    Send-FakeResponse $stream 200 "OK" $text
                }
            }
            "GET /v1/router/control-plane/requests" {
                $readCount++
                Save-FakeControlPlaneState
                $text = Get-FixtureText "control-plane-requests.json"
                if ($null -eq $text) {
                    Send-FakeResponse $stream 503 "Service Unavailable" '{"error":{"type":"router_error","code":"control_read_unavailable","message":"unavailable"}}'
                }
                else {
                    Send-FakeResponse $stream 200 "OK" $text
                }
            }
            "GET /v1/router/control-plane/policy" {
                $readCount++
                Save-FakeControlPlaneState
                $text = Get-FakePolicyBody
                if ($null -eq $text) {
                    Send-FakeResponse $stream 503 "Service Unavailable" '{"error":{"type":"router_error","code":"control_read_unavailable","message":"unavailable"}}'
                }
                else {
                    Send-FakeResponse $stream 200 "OK" $text
                }
            }
            "PUT /v1/router/control-plane/policy" {
                $policyPutCount++
                $expected = ""
                $kind = ""
                try {
                    $request = $body | ConvertFrom-Json
                    $expected = [string]$request.expected_generation
                    foreach ($candidate in @("retry", "timeout", "failover")) {
                        if ($null -ne $request.PSObject.Properties[$candidate]) { $kind = $candidate }
                    }
                }
                catch {
                    $expected = ""
                }

                $conflictRequested = (-not [string]::IsNullOrWhiteSpace($ConflictFilePath)) -and (Test-Path -LiteralPath $ConflictFilePath -PathType Leaf)
                if ($conflictRequested) {
                    Remove-Item -LiteralPath $ConflictFilePath -Force -ErrorAction SilentlyContinue
                }

                if ($conflictRequested -or $expected -ne $generation) {
                    $conflictCount++
                    $mutationAttempts.Add([pscustomobject]@{ kind = "policy"; sub_kind = $kind; expected_generation = $expected; accepted = $false }) | Out-Null
                    Save-FakeControlPlaneState
                    Send-FakeResponse $stream 409 "Conflict" '{"error":{"type":"router_error","code":"control_generation_conflict","message":"The expected config generation is stale."}}'
                }
                else {
                    $sequence++
                    $generation = Get-NextFakeGeneration $generation $sequence
                    $mutationAttempts.Add([pscustomobject]@{ kind = "policy"; sub_kind = $kind; expected_generation = $expected; accepted = $true }) | Out-Null
                    Save-FakeControlPlaneState
                    Send-FakeResponse $stream 200 "OK" ("{0}" -f ([ordered]@{
                                schema_version = 1
                                result_code = "applied"
                                policy_id = "policy.default"
                                config_generation = $generation
                                cross_model_fallback = "HARD_OFF"
                                policy = [ordered]@{ policy_id = "policy.default"; version = 1 }
                            } | ConvertTo-Json -Depth 6 -Compress))
                }
            }
            "PUT /v1/router/control-plane/feature" {
                $featurePutCount++
                $expected = ""
                $requestedEnabled = $null
                try {
                    $request = $body | ConvertFrom-Json
                    $expected = [string]$request.expected_generation
                    $requestedEnabled = [bool]$request.enabled
                }
                catch {
                    $expected = ""
                }

                $conflictRequested = (-not [string]::IsNullOrWhiteSpace($ConflictFilePath)) -and (Test-Path -LiteralPath $ConflictFilePath -PathType Leaf)
                if ($conflictRequested) {
                    Remove-Item -LiteralPath $ConflictFilePath -Force -ErrorAction SilentlyContinue
                }

                if ($conflictRequested -or $expected -ne $generation) {
                    $conflictCount++
                    $mutationAttempts.Add([pscustomobject]@{ kind = "feature"; sub_kind = ""; expected_generation = $expected; accepted = $false }) | Out-Null
                    Save-FakeControlPlaneState
                    Send-FakeResponse $stream 409 "Conflict" '{"error":{"type":"router_error","code":"control_generation_conflict","message":"The expected config generation is stale."}}'
                }
                else {
                    $sequence++
                    $generation = Get-NextFakeGeneration $generation $sequence
                    $enabled = [bool]$requestedEnabled
                    $mutationAttempts.Add([pscustomobject]@{ kind = "feature"; sub_kind = ""; expected_generation = $expected; accepted = $true }) | Out-Null
                    Save-FakeControlPlaneState
                    Send-FakeResponse $stream 200 "OK" ("{0}" -f ([ordered]@{
                                schema_version = 1
                                result_code = "applied"
                                local_router_enabled = $enabled
                                config_generation = $generation
                                start_stop_available = $false
                                lifecycle_reason_code = "LIFECYCLE_CONTROL_GAP"
                            } | ConvertTo-Json -Depth 6 -Compress))
                }
            }
            default {
                $unknownPathCount++
                Save-FakeControlPlaneState
                Send-FakeResponse $stream 404 "Not Found" '{"error":{"type":"router_error","code":"unknown_route","message":"not found"}}'
            }
        }

        $stream.Close()
    }
    catch {
        try { $client.Close() } catch { }
    }
}

$listener.Stop()
