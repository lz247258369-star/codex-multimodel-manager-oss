. (Join-Path $PSScriptRoot "_registry.ps1")

function Get-RegistryRecords {
    $path = Get-RegistryPath "stealth-models.json"
    if (-not (Test-Path $path)) {
        & (Join-Path $PSScriptRoot "sync-stealth-registry.ps1") -Quiet
    }
    if (-not (Test-Path $path)) { return @() }
    return @(Load-JsonFile $path @())
}

function Show-Registry {
    $records = Get-RegistryRecords
    if ($records.Count -eq 0) {
        Write-Host "Stealth registry 为空。" -ForegroundColor Yellow
        return @()
    }

    Write-Host ""
    Write-Host "Stealth Model Registry" -ForegroundColor Cyan
    $i = 1
    foreach ($record in $records) {
        $resolved = if ([string]::IsNullOrWhiteSpace([string]$record.resolved_id)) { "(none)" } else { [string]$record.resolved_id }
        $official = if ([string]::IsNullOrWhiteSpace([string]$record.official_name)) { "(unknown)" } else { [string]$record.official_name }
        Write-Host ("{0,3}. {1} | {2}" -f $i, $record.alias, $record.status)
        Write-Host ("     original={0}" -f $record.original_id)
        Write-Host ("     current ={0}" -f $record.current_id)
        Write-Host ("     resolved={0}" -f $resolved)
        Write-Host ("     official={0}" -f $official)
        if (@($record.suspected_replacements).Count -gt 0) {
            Write-Host "     suspects:" -ForegroundColor Yellow
            foreach ($suspect in @($record.suspected_replacements)) {
                Write-Host ("       - {0} :: {1}" -f $suspect.id, $suspect.name)
            }
        }
        $i++
    }
    return $records
}

while ($true) {
    Clear-Host
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Codex Multi-Model Manager V3.3"
    Write-Host " Stealth Model Registry"
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " 1. 同步匿名模型状态（只读 OpenRouter /models）"
    Write-Host " 2. 查看匿名模型注册表"
    Write-Host " 3. 记录官方揭晓 / 新模型 ID（需 MIGRATE 确认）"
    Write-Host " 4. 通过 alias 启动模型"
    Write-Host " 5. 查看最近迁移/状态历史"
    Write-Host " 0. 退出"
    $choice = Read-Host "选择"

    switch ($choice) {
        "1" {
            & (Join-Path $PSScriptRoot "sync-stealth-registry.ps1")
            Read-Host "回车继续" | Out-Null
        }
        "2" {
            Show-Registry | Out-Null
            Read-Host "回车继续" | Out-Null
        }
        "3" {
            $records = Show-Registry
            if ($records.Count -gt 0) {
                $n = [int](Read-Host "选择要记录揭晓的编号")
                if ($n -ge 1 -and $n -le $records.Count) {
                    $record = $records[$n - 1]
                    $newId = Read-Host "输入 OpenRouter 正式/替代 model ID"
                    if (-not [string]::IsNullOrWhiteSpace($newId)) {
                        $officialName = Read-Host "输入正式名称（可回车让脚本读取模型名称）"
                        & (Join-Path $PSScriptRoot "record-stealth-reveal.ps1") -Alias $record.key -NewModelId $newId.Trim() -OfficialName $officialName.Trim()
                    }
                }
            }
            Read-Host "回车继续" | Out-Null
        }
        "4" {
            $records = Show-Registry
            if ($records.Count -gt 0) {
                $n = [int](Read-Host "选择要启动的编号")
                if ($n -ge 1 -and $n -le $records.Count) {
                    $record = $records[$n - 1]
                    & (Join-Path $PSScriptRoot "launch-stealth-model.ps1") -Alias $record.key -ConfirmationCode "STEALTH"
                }
            }
            Read-Host "回车继续" | Out-Null
        }
        "5" {
            $historyPath = Get-RegistryPath "stealth-model-history.jsonl"
            if (Test-Path $historyPath) {
                Get-Content $historyPath | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
            } else {
                Write-Host "暂无 stealth history。" -ForegroundColor Yellow
            }
            Read-Host "回车继续" | Out-Null
        }
        "0" { break }
        default {
            Write-Host "无效选择。" -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}
