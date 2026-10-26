$ErrorActionPreference = "Stop"

function Get-CodexHome {
    if ($env:CODEX_HOME -and -not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return $env:CODEX_HOME
    }
    return (Join-Path $HOME ".codex")
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-StatePath {
    $codexHome = Get-CodexHome
    $dir = Join-Path $codexHome "multimodel-manager"
    Ensure-Directory $dir
    return (Join-Path $dir "state.json")
}

function Load-State {
    $path = Get-StatePath
    if (Test-Path $path) {
        try {
            return (Get-Content -Raw -Path $path | ConvertFrom-Json)
        } catch {
            throw "无法读取状态文件：$path`n$($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{}
}

function Save-State($State) {
    $path = Get-StatePath
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
}

function Set-StateValue($State, [string]$Name, $Value) {
    $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-StateValue($State, [string]$Name, $Default = $null) {
    $p = $State.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Read-YesNo([string]$Prompt, [bool]$Default = $false) {
    $suffix = if ($Default) { " [Y/n]" } else { " [y/N]" }
    $v = Read-Host ($Prompt + $suffix)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return ($v.Trim().ToLowerInvariant() -in @("y","yes","1","true","是"))
}

function Read-NonEmpty([string]$Prompt, [string]$Default = "") {
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { "" }
        $v = Read-Host ($Prompt + $suffix)
        if ([string]::IsNullOrWhiteSpace($v)) {
            if ($Default) { return $Default }
        } else {
            return $v.Trim()
        }
        Write-Host "不能为空。" -ForegroundColor Yellow
    }
}

function Set-UserSecretEnv([string]$Name, [string]$Label) {
    $secure = Read-Host "$Label（输入时不会显示）" -AsSecureString
    if ($secure.Length -eq 0) {
        Write-Host "未输入 Key，跳过。" -ForegroundColor Yellow
        return $false
    }

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [Environment]::SetEnvironmentVariable($Name, $plain, [EnvironmentVariableTarget]::User)
        Set-Item -Path "Env:$Name" -Value $plain
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $plain = $null
    }
    Write-Host "已保存到 Windows 用户环境变量：$Name（不会写入项目或 config.toml）" -ForegroundColor Green
    return $true
}

function Backup-CodexConfig {
    $codexHome = Get-CodexHome
    Ensure-Directory $codexHome
    $config = Join-Path $codexHome "config.toml"
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupDir = Join-Path $codexHome "backups\multimodel-manager-$stamp"
    Ensure-Directory $backupDir

    if (Test-Path $config) {
        Copy-Item $config (Join-Path $backupDir "config.toml") -Force
    }
    $state = Get-StatePath
    if (Test-Path $state) {
        Copy-Item $state (Join-Path $backupDir "state.json") -Force
    }

    Write-Host "配置备份：$backupDir" -ForegroundColor DarkGray
    return $backupDir
}

function Escape-TomlString([string]$Value) {
    if ($null -eq $Value) { return "" }
    return $Value.Replace('\','\\').Replace('"','\"')
}

function Build-ManagedBlock($State) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# >>> CODEX MULTIMODEL MANAGER BEGIN")
    $lines.Add("# 此区域由 Codex Multi-Model Manager 管理。API Key 不会写入此文件。")
    $lines.Add("")

    $lines.Add("[profiles.mm_gpt56_chatgpt]")
    $lines.Add('model_provider = "openai"')
    $lines.Add('model_reasoning_effort = "high"')
    $lines.Add("")

    if (Get-StateValue $State "openai_api_enabled" $false) {
        $lines.Add("[model_providers.mm_openai_api]")
        $lines.Add('name = "OpenAI API (MultiModel Manager)"')
        $lines.Add('base_url = "https://api.openai.com/v1"')
        $lines.Add('env_key = "CODEX_OPENAI_API_KEY"')
        $lines.Add('wire_api = "responses"')
        $lines.Add("")
        $lines.Add("[profiles.mm_gpt56_api]")
        $lines.Add('model = "gpt-5.6"')
        $lines.Add('model_provider = "mm_openai_api"')
        $lines.Add('model_reasoning_effort = "high"')
        $lines.Add("")
        $lines.Add("[profiles.mm_gpt56_terra_api]")
        $lines.Add('model = "gpt-5.6-terra"')
        $lines.Add('model_provider = "mm_openai_api"')
        $lines.Add('model_reasoning_effort = "high"')
        $lines.Add("")
        $lines.Add("[profiles.mm_gpt56_luna_api]")
        $lines.Add('model = "gpt-5.6-luna"')
        $lines.Add('model_provider = "mm_openai_api"')
        $lines.Add("")
    }

    if (Get-StateValue $State "mimo_enabled" $false) {
        $base = Escape-TomlString (Get-StateValue $State "mimo_base_url" "https://api.xiaomimimo.com/v1")
        $lines.Add("[model_providers.mm_mimo]")
        $lines.Add('name = "Xiaomi MiMo (MultiModel Manager)"')
        $lines.Add('base_url = "' + $base + '"')
        $lines.Add('env_key = "MIMO_API_KEY"')
        $lines.Add('wire_api = "responses"')
        $lines.Add("")
        $lines.Add("[profiles.mm_mimo_v25_pro]")
        $lines.Add('model = "mimo-v2.5-pro"')
        $lines.Add('model_provider = "mm_mimo"')
        $lines.Add('model_reasoning_effort = "high"')
        $lines.Add("")
        $lines.Add("[profiles.mm_mimo_v25]")
        $lines.Add('model = "mimo-v2.5"')
        $lines.Add('model_provider = "mm_mimo"')
        $lines.Add('model_reasoning_effort = "high"')
        $lines.Add("")
    }

    if (Get-StateValue $State "aliyun_enabled" $false) {
        $base = Escape-TomlString (Get-StateValue $State "aliyun_base_url" "")
        $lines.Add("[model_providers.mm_modelstudio]")
        $lines.Add('name = "Alibaba Model Studio Responses (MultiModel Manager)"')
        $lines.Add('base_url = "' + $base + '"')
        $lines.Add('env_key = "CODEX_DASHSCOPE_API_KEY"')
        $lines.Add('wire_api = "responses"')
        $lines.Add("")
        foreach ($pair in @(
            @("mm_qwen38_max","qwen3.8-max"),
            @("mm_qwen3_coder_plus","qwen3-coder-plus"),
            @("mm_qwen3_coder_next","qwen3-coder-next"),
            @("mm_deepseek_v4_pro_aliyun","deepseek-v4-pro"),
            @("mm_deepseek_v4_flash_aliyun","deepseek-v4-flash")
        )) {
            $lines.Add("[profiles.$($pair[0])]")
            $lines.Add('model = "' + $pair[1] + '"')
            $lines.Add('model_provider = "mm_modelstudio"')
            $lines.Add("")
        }
    }

    if (Get-StateValue $State "xai_enabled" $false) {
        $model = Escape-TomlString (Get-StateValue $State "xai_model" "grok-4.6")
        $lines.Add("[model_providers.mm_xai]")
        $lines.Add('name = "xAI Responses (MultiModel Manager)"')
        $lines.Add('base_url = "https://api.x.ai/v1"')
        $lines.Add('env_key = "XAI_API_KEY"')
        $lines.Add('wire_api = "responses"')
        $lines.Add("")
        $lines.Add("[profiles.mm_grok]")
        $lines.Add('model = "' + $model + '"')
        $lines.Add('model_provider = "mm_xai"')
        $lines.Add("")
    }

    if (Get-StateValue $State "groq_enabled" $false) {
        $model = Escape-TomlString (Get-StateValue $State "groq_model" "openai/gpt-oss-20b")
        $lines.Add("[model_providers.mm_groq]")
        $lines.Add('name = "Groq Responses (MultiModel Manager)"')
        $lines.Add('base_url = "https://api.groq.com/openai/v1"')
        $lines.Add('env_key = "GROQ_API_KEY"')
        $lines.Add('wire_api = "responses"')
        $lines.Add("")
        $lines.Add("[profiles.mm_groq_default]")
        $lines.Add('model = "' + $model + '"')
        $lines.Add('model_provider = "mm_groq"')
        $lines.Add("")
    }

    if (Get-StateValue $State "openrouter_enabled" $false) {
        $lines.Add("[model_providers.mm_openrouter]")
        $lines.Add('name = "OpenRouter Responses (MultiModel Manager)"')
        $lines.Add('base_url = "https://openrouter.ai/api/v1"')
        $lines.Add('env_key = "OPENROUTER_API_KEY"')
        $lines.Add('wire_api = "responses"')
        $lines.Add("")
        $defaultModel = Get-StateValue $State "openrouter_default_model" ""
        if (-not [string]::IsNullOrWhiteSpace($defaultModel)) {
            $m = Escape-TomlString $defaultModel
            $lines.Add("[profiles.mm_openrouter_default]")
            $lines.Add('model = "' + $m + '"')
            $lines.Add('model_provider = "mm_openrouter"')
            $lines.Add("")
        }
    }

    $lines.Add("# <<< CODEX MULTIMODEL MANAGER END")
    return ($lines -join "`r`n")
}

function Apply-ManagedConfig($State) {
    $codexHome = Get-CodexHome
    Ensure-Directory $codexHome
    $config = Join-Path $codexHome "config.toml"
    if (Test-Path $config) {
        $text = Get-Content -Raw -Path $config
    } else {
        $text = ""
    }

    $block = Build-ManagedBlock $State
    $pattern = '(?s)# >>> CODEX MULTIMODEL MANAGER BEGIN.*?# <<< CODEX MULTIMODEL MANAGER END'
    if ([regex]::IsMatch($text, $pattern)) {
        $newText = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 1)
    } else {
        if (-not [string]::IsNullOrWhiteSpace($text) -and -not $text.EndsWith("`n")) {
            $text += "`r`n"
        }
        $newText = $text + "`r`n" + $block + "`r`n"
    }

    Set-Content -Path $config -Value $newText -Encoding UTF8
    Write-Host "已更新：$config" -ForegroundColor Green
    Write-Host "只修改了 MultiModel Manager 管理区；原有 Codex/DeepSeek 等配置保留。" -ForegroundColor Green
}

function Test-CodexInstalled {
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        Write-Host "未检测到 codex 命令。请先安装：npm install -g @openai/codex" -ForegroundColor Yellow
        return $false
    }
    try {
        $ver = & codex --version 2>&1
        Write-Host "Codex: $ver" -ForegroundColor DarkGray
    } catch {}
    return $true
}
