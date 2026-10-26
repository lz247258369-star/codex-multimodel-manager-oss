$ErrorActionPreference = "Stop"

function Get-ControllerHealthEnvValue([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $value = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    return [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::User)
}

function Get-ControllerHealthConfigText([string]$ConfigPath) {
    if ([string]::IsNullOrWhiteSpace($ConfigPath) -or -not (Test-Path -LiteralPath $ConfigPath)) { return "" }
    try { return (Get-Content -Raw -LiteralPath $ConfigPath) }
    catch { return "" }
}

function Test-ControllerProviderConfigured([string]$ConfigText, [string]$ProviderId) {
    $section = switch ($ProviderId) {
        "modelstudio" { "mm_modelstudio" }
        "openrouter" { "mm_openrouter" }
        "mimo" { "mm_mimo" }
        default { "" }
    }
    if ([string]::IsNullOrWhiteSpace($section)) { return $true }
    return [regex]::IsMatch($ConfigText, '(?m)^\s*\[model_providers\.' + [regex]::Escape($section) + '\]\s*$')
}

function Get-ControllerChatGPTHealth([switch]$SkipLoginProbe) {
    if ($SkipLoginProbe) {
        return [pscustomobject]@{ status="INFO"; badge="○"; text="登录状态未探测"; detail="本次跳过 codex login status。" }
    }

    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $codex) {
        return [pscustomobject]@{ status="BLOCK"; badge="●"; text="Codex CLI 未找到"; detail="需要先安装/恢复 Codex CLI。" }
    }

    try {
        $loginStatus = (& codex login status 2>&1 | Out-String).Trim()
        if ($loginStatus -match '(?i)not logged in') {
            return [pscustomobject]@{ status="BLOCK"; badge="●"; text="未登录 ChatGPT"; detail="运行 codex login 并选择 ChatGPT 登录。" }
        }
        if ([string]::IsNullOrWhiteSpace($loginStatus)) {
            return [pscustomobject]@{ status="WARN"; badge="▲"; text="登录状态未知"; detail="Codex 未返回可识别的登录状态。" }
        }
        return [pscustomobject]@{ status="PASS"; badge="●"; text="ChatGPT 已登录"; detail=$loginStatus }
    }
    catch {
        return [pscustomobject]@{ status="WARN"; badge="▲"; text="登录状态读取失败"; detail="未执行任何模型推理。" }
    }
}

function Convert-ControllerModelStatus([string]$Status) {
    switch ($Status.ToLowerInvariant()) {
        "recommended" { return [pscustomobject]@{ status="PASS"; badge="●"; text="首选"; color="#197044" } }
        "official" { return [pscustomobject]@{ status="PASS"; badge="●"; text="官方"; color="#197044" } }
        "verified" { return [pscustomobject]@{ status="PASS"; badge="●"; text="已验证"; color="#197044" } }
        "approved" { return [pscustomobject]@{ status="PASS"; badge="●"; text="已批准"; color="#197044" } }
        "configured" { return [pscustomobject]@{ status="INFO"; badge="○"; text="已配置·未实测"; color="#596273" } }
        "experimental" { return [pscustomobject]@{ status="WARN"; badge="◉"; text="实验"; color="#7C3AED" } }
        "credit" { return [pscustomobject]@{ status="WARN"; badge="▲"; text="额度受限"; color="#9A6700" } }
        default { return [pscustomobject]@{ status="INFO"; badge="○"; text=(if ([string]::IsNullOrWhiteSpace($Status)) { "状态未知" } else { $Status }); color="#596273" } }
    }
}

function Get-ControllerHealthColor([string]$Status) {
    switch ($Status) {
        "PASS" { return "#197044" }
        "WARN" { return "#9A6700" }
        "BLOCK" { return "#B42318" }
        default { return "#596273" }
    }
}

function Get-ControllerHealthSnapshot {
    param(
        [Parameter(Mandatory=$true)]$Catalog,
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [switch]$SkipLoginProbe
    )

    $configText = Get-ControllerHealthConfigText $ConfigPath
    $providerHealth = New-Object System.Collections.Generic.List[object]
    $modelHealth = New-Object System.Collections.Generic.List[object]

    foreach ($provider in @($Catalog.providers)) {
        $providerId = [string]$provider.id
        $providerLabel = [string]$provider.label
        $providerState = $null

        if ($providerId -eq "chatgpt") {
            $providerState = Get-ControllerChatGPTHealth -SkipLoginProbe:$SkipLoginProbe
        }
        else {
            $configured = Test-ControllerProviderConfigured -ConfigText $configText -ProviderId $providerId
            $envName = [string]$provider.env_key
            $keyPresent = -not [string]::IsNullOrWhiteSpace((Get-ControllerHealthEnvValue $envName))

            if (-not $configured) {
                $providerState = [pscustomobject]@{ status="BLOCK"; badge="●"; text="Provider 未配置"; detail="运行 Provider 配置。" }
            }
            elseif (-not $keyPresent) {
                $providerState = [pscustomobject]@{ status="BLOCK"; badge="●"; text="缺少 API Key"; detail=("需要 " + $envName + "；值不会显示。") }
            }
            else {
                $providerState = [pscustomobject]@{ status="PASS"; badge="●"; text="Provider + Key 就绪"; detail=("已检测 " + $envName + "；值不显示。") }
            }
        }

        $providerHealth.Add([pscustomobject]@{
            id = $providerId
            label = $providerLabel
            status = [string]$providerState.status
            badge = [string]$providerState.badge
            text = [string]$providerState.text
            detail = [string]$providerState.detail
            color = Get-ControllerHealthColor ([string]$providerState.status)
        })

        foreach ($model in @($provider.models)) {
            $rawStatus = [string]$model.status
            $modelState = Convert-ControllerModelStatus $rawStatus
            $source = if ($model.PSObject.Properties["source"] -and [string]$model.source -eq "approved_registry") { "动态批准" } else { "受控目录" }
            $modelHealth.Add([pscustomobject]@{
                provider_id = $providerId
                provider_label = $providerLabel
                id = [string]$model.id
                label = [string]$model.label
                brand = [string]$model.brand
                raw_status = $rawStatus
                status = [string]$modelState.status
                badge = [string]$modelState.badge
                text = [string]$modelState.text
                color = [string]$modelState.color
                source = $source
            })
        }
    }

    $providerArray = $providerHealth.ToArray()
    $modelArray = $modelHealth.ToArray()
    $blocks = @($providerArray | Where-Object { $_.status -eq "BLOCK" }).Count
    $warns = @($providerArray | Where-Object { $_.status -eq "WARN" }).Count + @($modelArray | Where-Object { $_.status -eq "WARN" }).Count
    $passes = @($providerArray | Where-Object { $_.status -eq "PASS" }).Count + @($modelArray | Where-Object { $_.status -eq "PASS" }).Count

    return [pscustomobject]@{
        generated_at = (Get-Date).ToString("o")
        provider_health = $providerArray
        model_health = $modelArray
        block_count = $blocks
        warn_count = $warns
        pass_count = $passes
        mode = "LOCAL_ONLY"
        note = "本地诊断：不执行付费推理，不查询实时余额。额度受限来自受控目录/已知调用状态。"
    }
}
