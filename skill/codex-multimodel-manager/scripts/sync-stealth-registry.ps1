param(
    [switch]$Quiet
)

. (Join-Path $PSScriptRoot "_registry.ps1")

$registryPath = Get-RegistryPath "stealth-models.json"
$historyPath = Get-RegistryPath "stealth-model-history.jsonl"

function Set-RecordField($Record, [string]$Name, $Value) {
    $Record | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function New-StealthSeed {
    return @(
        [pscustomobject][ordered]@{
            key = "ox-alpha"
            alias = "Ox Alpha"
            aliases = @("Ox Alpha", "ox-alpha")
            provider_id = "mm_openrouter"
            original_id = "stealth/ox-alpha"
            current_id = "stealth/ox-alpha"
            replacement_id = ""
            official_name = ""
            status = "TRACKING"
            resolved_id = "stealth/ox-alpha"
            first_seen = "2026-08-20"
            revealed_at = ""
            last_checked = ""
            last_seen = ""
            suspected_replacements = @()
        }
    )
}

function Get-StealthRegistry {
    $records = @()
    if (Test-Path $registryPath) {
        $records = @(Load-JsonFile $registryPath @())
    }

    $seed = New-StealthSeed
    foreach ($default in $seed) {
        $exists = @($records | Where-Object { $_.key -eq $default.key })
        if ($exists.Count -eq 0) {
            $records += $default
        }
    }

    Save-JsonFile $registryPath $records
    return @($records)
}

function Get-ModelText($Model) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @("id", "name", "description")) {
        $property = $Model.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            $parts.Add([string]$property.Value)
        }
    }
    return (($parts -join " ").ToLowerInvariant())
}

$records = Get-StealthRegistry
$key = Get-UserEnv "OPENROUTER_API_KEY"
$headers = @{}
if (-not [string]::IsNullOrWhiteSpace($key)) {
    $headers["Authorization"] = "Bearer $key"
}

try {
    $catalog = Invoke-RestMethod -Method Get -Uri "https://openrouter.ai/api/v1/models" -Headers $headers -TimeoutSec 30
    $models = @($catalog.data)
}
catch {
    if (-not $Quiet) {
        Write-Host "Stealth Registry 无法读取 OpenRouter 模型目录：$($_.Exception.Message)" -ForegroundColor Yellow
    }
    return
}

$catalogById = @{}
foreach ($model in $models) {
    if (-not [string]::IsNullOrWhiteSpace([string]$model.id)) {
        $catalogById[[string]$model.id] = $model
    }
}

$now = Get-Date -Format "o"
$statusChanges = 0

foreach ($record in $records) {
    $oldStatus = [string]$record.status
    $currentId = [string]$record.current_id
    $replacementId = [string]$record.replacement_id

    $currentPresent = (-not [string]::IsNullOrWhiteSpace($currentId)) -and $catalogById.ContainsKey($currentId)
    $replacementPresent = (-not [string]::IsNullOrWhiteSpace($replacementId)) -and $catalogById.ContainsKey($replacementId)

    $resolvedId = ""
    $status = "MISSING_NEEDS_REVIEW"

    if (-not [string]::IsNullOrWhiteSpace($replacementId)) {
        if ($replacementPresent) {
            $resolvedId = $replacementId
            $status = "REVEALED_ACTIVE"
        }
        elseif ($currentPresent) {
            $resolvedId = $currentId
            $status = "REVEAL_RECORDED_OLD_ID_ACTIVE"
        }
        else {
            $status = "REPLACEMENT_MISSING"
        }
    }
    elseif ($currentPresent) {
        $resolvedId = $currentId
        $status = "ACTIVE_STEALTH"
    }

    $terms = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace([string]$record.alias)) {
        $terms.Add(([string]$record.alias).ToLowerInvariant())
    }
    foreach ($term in @($record.aliases)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$term)) {
            $normalized = ([string]$term).ToLowerInvariant()
            if (-not $terms.Contains($normalized)) {
                $terms.Add($normalized)
            }
        }
    }

    $suspects = @()
    if (-not $currentPresent -and [string]::IsNullOrWhiteSpace($replacementId)) {
        foreach ($model in $models) {
            $modelId = [string]$model.id
            if ($modelId -eq $currentId) { continue }

            $haystack = Get-ModelText $model
            $matched = $false
            foreach ($term in $terms) {
                if ($term.Length -ge 4 -and $haystack.Contains($term)) {
                    $matched = $true
                    break
                }
            }

            if ($matched) {
                $modelName = if ($null -ne $model.PSObject.Properties["name"]) { [string]$model.name } else { $modelId }
                $suspects += [pscustomobject]@{ id = $modelId; name = $modelName }
                if ($suspects.Count -ge 10) { break }
            }
        }
    }

    [object[]]$suspectArray = $suspects
    Set-RecordField $record "status" $status
    Set-RecordField $record "resolved_id" $resolvedId
    Set-RecordField $record "last_checked" $now
    Set-RecordField $record "suspected_replacements" $suspectArray
    if (-not [string]::IsNullOrWhiteSpace($resolvedId)) {
        Set-RecordField $record "last_seen" $now
    }

    if ($oldStatus -ne $status) {
        $statusChanges++
        $event = [pscustomobject][ordered]@{
            at = $now
            event = "status_change"
            key = $record.key
            alias = $record.alias
            from = $oldStatus
            to = $status
            current_id = $currentId
            replacement_id = $replacementId
            resolved_id = $resolvedId
        }
        Add-Content -Path $historyPath -Value ($event | ConvertTo-Json -Compress)
    }
}

Save-JsonFile $registryPath $records

if (-not $Quiet) {
    Write-Host "Stealth Model Registry" -ForegroundColor Cyan
    foreach ($record in $records) {
        $resolved = if ([string]::IsNullOrWhiteSpace([string]$record.resolved_id)) { "(none)" } else { [string]$record.resolved_id }
        Write-Host ("- {0}: {1} | current={2} | resolved={3}" -f $record.alias, $record.status, $record.current_id, $resolved)
        if (@($record.suspected_replacements).Count -gt 0) {
            Write-Host "  发现疑似替代项（不会自动迁移）：" -ForegroundColor Yellow
            foreach ($suspect in @($record.suspected_replacements)) {
                Write-Host ("    - {0} :: {1}" -f $suspect.id, $suspect.name)
            }
        }
    }
    Write-Host "状态变化：$statusChanges"
    Write-Host "Registry: $registryPath" -ForegroundColor DarkGray
}

return
