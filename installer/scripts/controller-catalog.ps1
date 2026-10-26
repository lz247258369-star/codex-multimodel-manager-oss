$ErrorActionPreference = "Stop"

function Convert-ControllerProviderId([string]$ProviderId) {
    switch ($ProviderId) {
        "mm_modelstudio" { return "modelstudio" }
        "modelstudio" { return "modelstudio" }
        "mm_openrouter" { return "openrouter" }
        "openrouter" { return "openrouter" }
        "mm_mimo" { return "mimo" }
        "mimo" { return "mimo" }
        # DeepSeek Official direct provider: manager id and catalog id are the
        # same explicit identity. It must never be folded into modelstudio.
        "deepseek" { return "deepseek" }
        default { return "" }
    }
}

function Get-ControllerModelBrand([string]$ModelId, [string]$DisplayName = "") {
    $text = ("$ModelId $DisplayName").ToLowerInvariant()
    if ($text -match 'deepseek') { return "DeepSeek" }
    if ($text -match 'qwen') { return "Qwen" }
    if ($text -match 'glm|z-ai') { return "GLM" }
    if ($text -match 'mimo') { return "MiMo" }
    if ($text -match 'grok') { return "Grok" }
    if ($text -match 'claude') { return "Claude" }
    if ($text -match 'gemini') { return "Gemini" }
    if ($text -match 'kimi|moonshot') { return "Kimi" }
    if ($text -match 'minimax') { return "MiniMax" }
    if ($text -match 'gpt|openai') { return "OpenAI" }
    if ($text -match 'ox-alpha|stealth') { return "Stealth" }
    return "已批准新模型"
}

function Get-ControllerModelHierarchy([string]$ModelId, [string]$DisplayName, [string]$Brand) {
    $text = ("$ModelId $DisplayName").ToLowerInvariant()
    $vendor = $Brand
    $family = $DisplayName
    $variant = "Approved"
    $performance = @("low","medium","high")

    if ($text -match 'gpt-5\.6') {
        $vendor = "OpenAI"; $family = "GPT-5.6"; $performance = @("low","medium","high","xhigh")
        if ($text -match 'sol') { $variant = "Sol" }
        elseif ($text -match 'terra') { $variant = "Terra" }
        elseif ($text -match 'luna') { $variant = "Luna" }
        else { $variant = "Standard" }
    }
    elseif ($text -match 'gpt-5\.5') {
        $vendor = "OpenAI"; $family = "GPT-5.5"; $variant = "Standard"; $performance = @("low","medium","high","xhigh")
    }
    elseif ($text -match 'gpt-5\.4') {
        $vendor = "OpenAI"; $family = "GPT-5.4"
        $variant = if ($text -match 'mini') { "Mini" } elseif ($text -match 'nano') { "Nano" } elseif ($text -match 'pro') { "Pro" } else { "Standard" }
    }
    elseif ($text -match 'qwen3[- ]coder') {
        $vendor = "Alibaba / Qwen"; $family = "Qwen3 Coder"
        $variant = if ($text -match 'next') { "Next" } elseif ($text -match 'plus') { "Plus" } else { "Standard" }
    }
    elseif ($text -match 'qwen[ -]?3\.8') {
        $vendor = "Alibaba / Qwen"; $family = "Qwen 3.8"; $variant = if ($text -match 'max') { "Max" } else { "Standard" }
    }
    elseif ($text -match 'deepseek[- ]?v4') {
        $vendor = "DeepSeek"; $family = "DeepSeek V4"
        $variant = if ($text -match 'flash') { "Flash" } elseif ($text -match 'pro') { "Pro" } else { "Standard" }
    }
    elseif ($text -match 'mimo[- ]?v2\.5') {
        $vendor = "Xiaomi"; $family = "MiMo V2.5"; $variant = if ($text -match 'pro') { "Pro" } else { "Standard" }
    }
    elseif ($text -match 'glm') {
        $vendor = "Z.ai"; $family = "GLM"
        $match = [regex]::Match($DisplayName, '(?i)GLM\s*([0-9.]+)')
        $variant = if ($match.Success) { $match.Groups[1].Value } else { "Approved" }
    }
    elseif ($text -match 'ox-alpha|ox alpha|stealth') {
        $vendor = "Stealth / Unknown"; $family = "Ox Alpha"; $variant = "Experimental"; $performance = @("low","medium","high","xhigh")
    }

    return [pscustomobject]@{
        vendor = $vendor
        family = $family
        variant = $variant
        performance_levels = $performance
    }
}

function Ensure-ControllerModelMetadata($Model) {
    $modelId = [string]$Model.id
    $displayName = [string]$Model.label
    $brand = if ($Model.PSObject.Properties["brand"] -and -not [string]::IsNullOrWhiteSpace([string]$Model.brand)) {
        [string]$Model.brand
    } else {
        Get-ControllerModelBrand -ModelId $modelId -DisplayName $displayName
    }
    if (-not $Model.PSObject.Properties["brand"]) { $Model | Add-Member -NotePropertyName brand -NotePropertyValue $brand }

    $hierarchy = Get-ControllerModelHierarchy -ModelId $modelId -DisplayName $displayName -Brand $brand
    foreach ($pair in @(
        @{Name="vendor"; Value=[string]$hierarchy.vendor},
        @{Name="family"; Value=[string]$hierarchy.family},
        @{Name="variant"; Value=[string]$hierarchy.variant},
        @{Name="performance_levels"; Value=@($hierarchy.performance_levels)},
        @{Name="price_input"; Value=$null},
        @{Name="price_output"; Value=$null},
        @{Name="price_currency"; Value="USD"},
        @{Name="price_source"; Value="unknown"},
        @{Name="price_updated_at"; Value=$null}
    )) {
        if (-not $Model.PSObject.Properties[$pair.Name]) {
            $Model | Add-Member -NotePropertyName $pair.Name -NotePropertyValue $pair.Value
        }
    }
}

function Merge-ControllerCatalog($StaticCatalog, $ApprovedModels) {
    if ($null -eq $StaticCatalog -or $null -eq $StaticCatalog.providers) {
        throw "Controller static catalog is missing providers."
    }

    $catalog = ($StaticCatalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $added = 0
    $existingApproved = 0
    $ignoredProvider = 0
    $ignoredProbe = 0

    foreach ($provider in @($catalog.providers)) {
        foreach ($model in @($provider.models)) {
            if (-not $model.PSObject.Properties["source"]) {
                $model | Add-Member -NotePropertyName source -NotePropertyValue "controlled"
            }
            Ensure-ControllerModelMetadata $model
        }
    }

    foreach ($approved in @($ApprovedModels)) {
        $modelId = [string]$approved.model_id
        if ([string]::IsNullOrWhiteSpace($modelId)) { continue }

        if ([string]$approved.basic_probe -ne "PASS") {
            $ignoredProbe++
            continue
        }

        $routeId = Convert-ControllerProviderId ([string]$approved.provider_id)
        if ([string]::IsNullOrWhiteSpace($routeId)) {
            $ignoredProvider++
            continue
        }

        $provider = @($catalog.providers | Where-Object { [string]$_.id -eq $routeId }) | Select-Object -First 1
        if ($null -eq $provider) {
            $ignoredProvider++
            continue
        }

        $existing = @($provider.models | Where-Object { [string]$_.id -eq $modelId }) | Select-Object -First 1
        if ($null -ne $existing) {
            $existingApproved++
            if (-not $existing.PSObject.Properties["registry_approved"]) {
                $existing | Add-Member -NotePropertyName registry_approved -NotePropertyValue $true
            } else {
                $existing.registry_approved = $true
            }
            Ensure-ControllerModelMetadata $existing
            continue
        }

        $displayName = [string]$approved.display_name
        if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $modelId }
        $brand = Get-ControllerModelBrand -ModelId $modelId -DisplayName $displayName
        $hierarchy = Get-ControllerModelHierarchy -ModelId $modelId -DisplayName $displayName -Brand $brand

        $dynamicModel = [pscustomobject]@{
            id = $modelId
            label = $displayName
            brand = $brand
            vendor = [string]$hierarchy.vendor
            family = [string]$hierarchy.family
            variant = [string]$hierarchy.variant
            performance_levels = @($hierarchy.performance_levels)
            price_input = $null
            price_output = $null
            price_currency = "USD"
            price_source = "approved-registry"
            price_updated_at = $null
            status = "approved"
            source = "approved_registry"
            registry_approved = $true
            approved_at = [string]$approved.approved_at
            basic_probe = [string]$approved.basic_probe
            tool_probe = [string]$approved.tool_probe
            profile_id = [string]$approved.profile_id
        }
        $provider.models = @($provider.models) + @($dynamicModel)
        $added++
    }

    $meta = [pscustomobject]@{
        approved_loaded = @($ApprovedModels).Count
        dynamic_added = $added
        approved_existing = $existingApproved
        ignored_provider = $ignoredProvider
        ignored_probe = $ignoredProbe
    }
    $catalog | Add-Member -NotePropertyName controller_meta -NotePropertyValue $meta -Force
    return $catalog
}

function Get-ControllerCatalog([string]$StaticCatalogPath, [string]$ApprovedModelsPath = "") {
    if (-not (Test-Path -LiteralPath $StaticCatalogPath)) {
        throw "Controller static catalog not found: $StaticCatalogPath"
    }

    $staticCatalog = Get-Content -Raw -LiteralPath $StaticCatalogPath | ConvertFrom-Json
    $approved = @()
    $approvedWarning = ""

    if (-not [string]::IsNullOrWhiteSpace($ApprovedModelsPath) -and (Test-Path -LiteralPath $ApprovedModelsPath)) {
        try {
            $loaded = Get-Content -Raw -LiteralPath $ApprovedModelsPath | ConvertFrom-Json
            $approved = @($loaded)
        }
        catch {
            $approvedWarning = "approved-models.json 读取失败：$($_.Exception.Message)"
        }
    }

    $catalog = Merge-ControllerCatalog -StaticCatalog $staticCatalog -ApprovedModels $approved
    if (-not [string]::IsNullOrWhiteSpace($approvedWarning)) {
        $catalog.controller_meta | Add-Member -NotePropertyName warning -NotePropertyValue $approvedWarning -Force
    }
    return $catalog
}
