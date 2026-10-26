#requires -Version 7
param(
    [Parameter(Mandatory = $false)]
    [int]$Port = 0,

    [Parameter(Mandatory = $false)]
    [string]$RecordPath = "",

    [Parameter(Mandatory = $false)]
    [string]$PortFilePath = "",

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

if ($Port -eq 0) {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
}
else {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
}
$listener.Start()
$boundPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
if (-not [string]::IsNullOrWhiteSpace($PortFilePath)) {
    Set-Content -LiteralPath $PortFilePath -Value ([string]$boundPort) -Encoding UTF8
}

if (-not $Quiet) {
    Write-Host ("FAKE_ROUTER_PORT=" + $boundPort)
}

$records = New-Object System.Collections.Generic.List[object]
$tokenExpected = [Environment]::GetEnvironmentVariable("CODEX_LOCAL_ROUTER_TOKEN", [EnvironmentVariableTarget]::Process)
$deadline = [DateTime]::UtcNow.AddSeconds(45)

function Send-Text([System.Net.Sockets.NetworkStream]$Stream, [string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Send-SseResponse([System.Net.Sockets.NetworkStream]$Stream, [string]$ModelId, [string]$RequestId) {
    $events = @'
event: response.created
data: {"type":"response.created","response":{"id":"resp_fake_lr12","object":"response","status":"in_progress","model":"MODEL_PLACEHOLDER","output":[]}}

event: response.output_item.added
data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg_fake_lr12","type":"message","role":"assistant","content":[]}}

event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_fake_lr12","output_index":0,"content_index":0,"delta":"LR12_OK"}

event: response.output_text.done
data: {"type":"response.output_text.done","item_id":"msg_fake_lr12","output_index":0,"content_index":0,"text":"LR12_OK"}

event: response.output_item.done
data: {"type":"response.output_item.done","output_index":0,"item":{"id":"msg_fake_lr12","type":"message","role":"assistant","content":[{"type":"output_text","text":"LR12_OK","annotations":[]}]}}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_fake_lr12","object":"response","status":"completed","model":"MODEL_PLACEHOLDER","output":[],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}

'@
    $events = $events.Replace("MODEL_PLACEHOLDER", $ModelId)
    $head = "HTTP/1.1 200 OK`r`nContent-Type: text/event-stream`r`nCache-Control: no-cache`r`nConnection: close`r`n`r`n"
    Send-Text $Stream $head
    Send-Text $Stream $events
    $Stream.Flush()
    Start-Sleep -Milliseconds 500
    $Stream.Close()
}

function Save-Records([string]$Path, [int]$Port, $Items) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $output = [pscustomobject]@{
        port = $Port
        records = @($Items.ToArray())
    }
    $output | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Send-Health([System.Net.Sockets.NetworkStream]$Stream) {
    $body = '{"schema_version":1,"lifecycle":"READY","ready":true}'
    $head = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
    Send-Text $Stream $head
    Send-Text $Stream $body
    $Stream.Close()
}

while ([DateTime]::UtcNow -lt $deadline) {
    if (-not $listener.Pending()) {
        Start-Sleep -Milliseconds 100
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

        $contentLength = 0
        $authorization = ""
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line -or $line.Length -eq 0) { break }
            if ($line -match '^Content-Length:\s*(\d+)\s*$') {
                $contentLength = [int]$Matches[1]
            }
            elseif ($line -match '^Authorization:\s*(.+)$') {
                $authorization = $Matches[1].Trim()
            }
        }

        $bodyText = ""
        if ($contentLength -gt 0) {
            $buffer = [char[]]::new($contentLength)
            $read = $reader.Read($buffer, 0, $contentLength)
            if ($read -gt 0) {
                $bodyText = ([string]::new($buffer, 0, $read))
            }
        }

        $modelId = ""
        $requestId = ""
        if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
            try {
                $bodyJson = $bodyText | ConvertFrom-Json
                $modelId = [string]$bodyJson.model
                $requestId = [string]$bodyJson.request_id
            }
            catch { }
        }

        $authMatches = (-not [string]::IsNullOrWhiteSpace($authorization)) -and
            ($authorization -eq ("Bearer " + $tokenExpected))

        $record = [pscustomobject]@{
            method = $method
            path = $path
            authorization_matches_expected = $authMatches
            model = $modelId
            request_id = $requestId
        }
        $records.Add($record)
        Save-Records $RecordPath $boundPort $records

        if ($path -eq "/health" -and $method -eq "GET") {
            Send-Health $stream
        }
        elseif ($path -eq "/v1/responses" -and $method -eq "POST") {
            Send-SseResponse $stream $modelId $requestId
        }
        else {
            $head = "HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
            Send-Text $stream $head
            $stream.Close()
        }
    }
    catch {
        try { $client.Close() } catch { }
    }
}

$listener.Stop()

Save-Records $RecordPath $boundPort $records

if (-not $Quiet) {
    Write-Host ("FAKE_ROUTER_STOPPED port=" + $boundPort + " requests=" + $records.Count)
}
