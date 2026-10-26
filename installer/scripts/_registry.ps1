$ErrorActionPreference = "Stop"

function Get-CodexHome {
    if ($env:CODEX_HOME -and -not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return $env:CODEX_HOME
    }
    return (Join-Path $HOME ".codex")
}

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-ManagerHome {
    $p = Join-Path (Get-CodexHome) "multimodel-manager"
    Ensure-Dir $p
    return $p
}

function Get-RegistryPath([string]$Name) {
    return Join-Path (Get-ManagerHome) $Name
}

function Load-JsonFile([string]$Path, $Default) {
    if (-not (Test-Path $Path)) { return $Default }
    try {
        return (Get-Content -Raw -Path $Path | ConvertFrom-Json)
    } catch {
        throw "JSON 文件损坏：$Path`n$($_.Exception.Message)"
    }
}

function Save-JsonFile([string]$Path, $Value) {
    ConvertTo-Json -InputObject $Value -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

function Get-State {
    $p = Get-RegistryPath "state.json"
    return Load-JsonFile $p ([pscustomobject]@{})
}

function Get-UserEnv([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::User)
    if ([string]::IsNullOrWhiteSpace($v)) {
        $v = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
    }
    return $v
}

function Sha256([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-","").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Sanitize-ProfileId([string]$ProviderId, [string]$ModelId) {
    $raw = ($ProviderId + "_" + $ModelId).ToLowerInvariant()
    $safe = [regex]::Replace($raw, '[^a-z0-9_]+', '_').Trim('_')
    if ($safe.Length -gt 60) {
        $hash = (Sha256 $raw).Substring(0,8)
        $safe = $safe.Substring(0,50).Trim('_') + "_" + $hash
    }
    return "mm_auto_" + $safe
}

function Get-ProviderMap {
    $state = Get-State
    $map = [ordered]@{}

    if ($state.PSObject.Properties["openai_api_enabled"] -and $state.openai_api_enabled) {
        $map["mm_openai_api"] = [pscustomobject]@{
            id="mm_openai_api"; name="OpenAI API"; base_url="https://api.openai.com/v1";
            env_key="CODEX_OPENAI_API_KEY"; discovery="models"; responses=$true; gateway=$false
        }
    }
    if ($state.PSObject.Properties["mimo_enabled"] -and $state.mimo_enabled) {
        $map["mm_mimo"] = [pscustomobject]@{
            id="mm_mimo"; name="Xiaomi MiMo"; base_url=$state.mimo_base_url;
            env_key="MIMO_API_KEY"; discovery="models"; responses=$true; gateway=$false
        }
    }
    if ($state.PSObject.Properties["aliyun_enabled"] -and $state.aliyun_enabled) {
        $map["mm_modelstudio"] = [pscustomobject]@{
            id="mm_modelstudio"; name="Alibaba Model Studio"; base_url=$state.aliyun_base_url;
            env_key="CODEX_DASHSCOPE_API_KEY"; discovery="models"; responses=$true; gateway=$false
        }
    }
    if ($state.PSObject.Properties["xai_enabled"] -and $state.xai_enabled) {
        $map["mm_xai"] = [pscustomobject]@{
            id="mm_xai"; name="xAI"; base_url="https://api.x.ai/v1";
            env_key="XAI_API_KEY"; discovery="models"; responses=$true; gateway=$false
        }
    }
    if ($state.PSObject.Properties["groq_enabled"] -and $state.groq_enabled) {
        $map["mm_groq"] = [pscustomobject]@{
            id="mm_groq"; name="Groq"; base_url="https://api.groq.com/openai/v1";
            env_key="GROQ_API_KEY"; discovery="models"; responses=$true; gateway=$false
        }
    }
    if ($state.PSObject.Properties["openrouter_enabled"] -and $state.openrouter_enabled) {
        $map["mm_openrouter"] = [pscustomobject]@{
            id="mm_openrouter"; name="OpenRouter"; base_url="https://openrouter.ai/api/v1";
            env_key="OPENROUTER_API_KEY"; discovery="openrouter"; responses=$true; gateway=$true
        }
    }
    # DSR2: the DeepSeek Official direct provider is a first-class Manager
    # provider identity (catalog id == Router provider id == "deepseek"). It is
    # gated on an explicit state flag and is never auto-discovered, so no
    # /models request can be issued to DeepSeek before its dedicated gate.
    if ($state.PSObject.Properties["deepseek_enabled"] -and $state.deepseek_enabled) {
        $map["deepseek"] = [pscustomobject]@{
            id="deepseek"; name="DeepSeek Official"; base_url="https://api.deepseek.com";
            env_key="DEEPSEEK_API_KEY"; discovery="none"; responses=$true; gateway=$false
        }
    }
    return $map
}

function Invoke-ModelsEndpoint($Provider) {
    $headers = @{}
    $key = Get-UserEnv $Provider.env_key
    if (-not [string]::IsNullOrWhiteSpace($key)) {
        $headers["Authorization"] = "Bearer $key"
    }

    if ($Provider.discovery -eq "openrouter") {
        $url = $Provider.base_url.TrimEnd('/') + "/models?output_modalities=text&supported_parameters=tools&sort=newest"
    } else {
        $url = $Provider.base_url.TrimEnd('/') + "/models"
    }

    try {
        $r = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec 30
        if ($null -eq $r.data) { return @() }
        return @($r.data)
    } catch {
        Write-Host "[$($Provider.name)] 模型列表获取失败：$($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }
}

function Is-CodingCandidate([string]$ProviderId, $Model) {
    $id = [string]$Model.id
    if ([string]::IsNullOrWhiteSpace($id)) { return $false }

    $lower = $id.ToLowerInvariant()

    $deny = @("embedding", "whisper", "tts", "audio", "image", "video", "moderation", "guard")
    foreach ($d in $deny) {
        if ($lower -match [regex]::Escape($d)) { return $false }
    }

    return $true
}
