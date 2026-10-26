. (Join-Path $PSScriptRoot "_registry.ps1")

function Load-Candidates {
    return @(Load-JsonFile (Get-RegistryPath "candidates.json") @())
}

function Show-Candidates {
    $list = Load-Candidates
    if ($list.Count -eq 0) {
        Write-Host "当前没有候选模型。先运行 CHECK_NEW_MODELS.cmd。" -ForegroundColor Yellow
        return @()
    }

    Write-Host ""
    Write-Host "候选模型：" -ForegroundColor Cyan
    $i = 1
    foreach ($c in $list) {
        Write-Host ("{0,3}. [{1}] {2} :: {3} | Responses={4} Tools={5}" -f $i, $c.status, $c.provider_name, $c.model_id, $c.basic_probe, $c.tool_probe)
        $i++
    }
    return $list
}

while ($true) {
    Clear-Host
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Codex Multi-Model Manager - 模型更新中心"
    Write-Host " 自动发现 -> 测试 -> 人工确认 -> 注册/迁移"
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " 1. 立即检查新模型"
    Write-Host " 2. 查看候选模型"
    Write-Host " 3. 基本 Responses 测试（会产生极少量 API 调用）"
    Write-Host " 4. Responses + Tool Calling 测试（会产生少量 API 调用）"
    Write-Host " 5. 批准一个已通过基本测试的模型"
    Write-Host " 6. 查看已批准动态模型"
    Write-Host " 7. 重新建立发现基线"
    Write-Host " 8. 打开 Stealth Model Registry"
    Write-Host " 0. 退出"
    $choice = Read-Host "选择"

    switch ($choice) {
        "1" {
            & (Join-Path $PSScriptRoot "discover-models.ps1")
            Read-Host "回车继续" | Out-Null
        }
        "2" {
            Show-Candidates | Out-Null
            Read-Host "回车继续" | Out-Null
        }
        "3" {
            $list = Show-Candidates
            if ($list.Count -gt 0) {
                $n = [int](Read-Host "输入编号")
                if ($n -ge 1 -and $n -le $list.Count) {
                    $c = $list[$n-1]
                    $ok = Read-Host "该测试会产生极少量 API 调用。输入 YES 继续"
                    if ($ok -eq "YES") {
                        & (Join-Path $PSScriptRoot "probe-model.ps1") -ProviderId $c.provider_id -ModelId $c.model_id
                    }
                }
            }
            Read-Host "回车继续" | Out-Null
        }
        "4" {
            $list = Show-Candidates
            if ($list.Count -gt 0) {
                $n = [int](Read-Host "输入编号")
                if ($n -ge 1 -and $n -le $list.Count) {
                    $c = $list[$n-1]
                    $ok = Read-Host "该测试会产生少量 API 调用。输入 YES 继续"
                    if ($ok -eq "YES") {
                        & (Join-Path $PSScriptRoot "probe-model.ps1") -ProviderId $c.provider_id -ModelId $c.model_id -RunToolProbe
                    }
                }
            }
            Read-Host "回车继续" | Out-Null
        }
        "5" {
            $list = Show-Candidates
            if ($list.Count -gt 0) {
                $n = [int](Read-Host "输入编号")
                if ($n -ge 1 -and $n -le $list.Count) {
                    $c = $list[$n-1]
                    if ($c.basic_probe -ne "PASS") {
                        Write-Host "不能批准：尚未通过基本 Responses 测试。" -ForegroundColor Yellow
                    } else {
                        $ok = Read-Host "确认把 $($c.model_id) 注册到 Codex？输入 APPROVE"
                        if ($ok -eq "APPROVE") {
                            & (Join-Path $PSScriptRoot "approve-model.ps1") -ProviderId $c.provider_id -ModelId $c.model_id -DisplayName $c.name
                        }
                    }
                }
            }
            Read-Host "回车继续" | Out-Null
        }
        "6" {
            $approved = @(Load-JsonFile (Get-RegistryPath "approved-models.json") @())
            if ($approved.Count -eq 0) {
                Write-Host "暂无动态批准模型。" -ForegroundColor Yellow
            } else {
                foreach ($a in $approved) {
                    Write-Host "- $($a.provider_name) :: $($a.model_id) -> $($a.profile_id)"
                }
            }
            Read-Host "回车继续" | Out-Null
        }
        "7" {
            $ok = Read-Host "重新建基线会把当前所有已发现模型视为“已知”，不会删除已批准模型。输入 REBASELINE"
            if ($ok -eq "REBASELINE") {
                & (Join-Path $PSScriptRoot "discover-models.ps1") -ForceRebaseline
            }
            Read-Host "回车继续" | Out-Null
        }
        "8" {
            & (Join-Path $PSScriptRoot "stealth-model-center.ps1")
        }
        "0" { break }
    }
}
