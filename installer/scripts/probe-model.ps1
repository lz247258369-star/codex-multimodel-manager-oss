param(
    [Parameter(Mandatory=$true)][string]$ProviderId,
    [Parameter(Mandatory=$true)][string]$ModelId,
    [switch]$RunToolProbe
)

. (Join-Path $PSScriptRoot "_registry.ps1")

$providers = Get-ProviderMap
if (-not $providers.Contains($ProviderId)) {
    throw "Provider 未配置：$ProviderId"
}
$p = $providers[$ProviderId]
$key = Get-UserEnv $p.env_key
if ([string]::IsNullOrWhiteSpace($key)) {
    throw "缺少环境变量 $($p.env_key)"
}

Write-Host "注意：兼容性测试会产生极少量 API 调用/费用。" -ForegroundColor Yellow
Write-Host "Provider: $($p.name)"
Write-Host "Model: $ModelId"

$headers = @{
    "Authorization" = "Bearer $key"
    "Content-Type" = "application/json"
}
$url = $p.base_url.TrimEnd('/') + "/responses"

$basic = "FAIL"
$tool = "NOT_RUN"
$basicError = ""
$toolError = ""

try {
    $body = @{
        model = $ModelId
        input = "Reply with exactly: OK"
        max_output_tokens = 16
    } | ConvertTo-Json -Depth 10
    $r = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -TimeoutSec 60
    if ($null -ne $r) {
        $basic = "PASS"
    }
} catch {
    $basicError = $_.Exception.Message
}

if ($RunToolProbe -and $basic -eq "PASS") {
    try {
        $body2 = @{
            model = $ModelId
            input = "Use the ping function exactly once. Do not answer with normal text."
            max_output_tokens = 64
            tools = @(
                @{
                    type = "function"
                    name = "ping"
                    description = "A harmless compatibility test."
                    parameters = @{
                        type = "object"
                        properties = @{}
                        additionalProperties = $false
                    }
                }
            )
        } | ConvertTo-Json -Depth 20

        $r2 = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body2 -TimeoutSec 60
        $raw = $r2 | ConvertTo-Json -Depth 20 -Compress
        if ($raw -match '"type"\s*:\s*"function_call"' -or $raw -match '"name"\s*:\s*"ping"') {
            $tool = "PASS"
        } else {
            $tool = "INCONCLUSIVE"
        }
    } catch {
        $tool = "FAIL"
        $toolError = $_.Exception.Message
    }
}

$candidatesPath = Get-RegistryPath "candidates.json"
$candidates = @(Load-JsonFile $candidatesPath @())
foreach ($c in $candidates) {
    if ($c.provider_id -eq $ProviderId -and $c.model_id -eq $ModelId) {
        $c.basic_probe = $basic
        $c.tool_probe = $tool
        $c.status = if ($basic -eq "PASS" -and $tool -eq "PASS") { "VERIFIED" }
                    elseif ($basic -eq "PASS") { "RESPONSES_PASS" }
                    else { "PROBE_FAILED" }
        $c.notes = (($basicError + " " + $toolError).Trim())
    }
}
Save-JsonFile $candidatesPath $candidates

Write-Host ""
Write-Host "Basic Responses: $basic" -ForegroundColor $(if ($basic -eq "PASS") {"Green"} else {"Red"})
Write-Host "Tool probe: $tool" -ForegroundColor $(if ($tool -eq "PASS") {"Green"} elseif ($tool -eq "NOT_RUN") {"DarkGray"} else {"Yellow"})
if ($basicError) { Write-Host "Basic error: $basicError" -ForegroundColor Yellow }
if ($toolError) { Write-Host "Tool error: $toolError" -ForegroundColor Yellow }
