#Requires -Version 7.2
<#
.SYNOPSIS
  Builds a concise acceptance-evidence report (Markdown) from real Git state,
  verification receipts, the identity privacy gate and the LR-14 gate.

.DESCRIPTION
  Nothing in the report is typed by hand. Receipts are used only when their
  self-hash is intact and they still describe the current commit, tree,
  uncommitted changes, base, environment and tool; other receipts are listed
  as excluded with the reason. SKIP and BLOCKED checks are reported as not
  executed. The report never prints names or e-mail addresses and never states
  a GitHub CI result: CI evidence comes from the pull request itself.
#>
param(
    [string]$RepositoryRoot = (Get-Location).Path,
    [string]$BaseRef = 'origin/main',
    [string[]]$Receipt,
    [string]$ReceiptDirectory,
    [string]$OutFile
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OssWorkflow.psm1') -Force
# Redirected output (pipes, CI runners) is written as UTF-8 so the Chinese
# report text survives any console code page; an interactive console is left as is.
if ([Console]::IsOutputRedirected) { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) }

try {
    $root = Get-OwRepositoryRoot $RepositoryRoot
    $head = Resolve-OwCommit $root 'HEAD' 'HEAD'
    $tree = Get-OwTree $root $head
    $baseSha = Resolve-OwCommit $root $BaseRef 'base reference'
    $mergeBase = (Invoke-OwGit -Root $root -Arguments @('merge-base', $baseSha, $head)).Lines[0]
    $worktree = Get-OwWorktreeState $root
    $changed = @(Get-OwChangedFiles $root $mergeBase)
    $plan = Get-OwVerificationPlan @($changed | ForEach-Object { $_.path }) $root $mergeBase
    $environment = Get-OwEnvironment $root
    $tool = Get-OwToolFingerprint
}
catch {
    Write-Output ("EVIDENCE_REPORT BLOCKED code={0} :: {1}" -f (Get-OwErrorCode $_), (ConvertTo-OwSafeText ($_.Exception.Message -replace '^OW:[A-Z_]+:\s*', '') $null))
    exit 2
}
$current = [ordered]@{ commit_sha = $head; tree_sha = $tree; merge_base_sha = $mergeBase; worktree = $worktree; environment = $environment; tool = $tool }
$md = [System.Collections.Generic.List[string]]::new()
function Add([string]$Line = '') { $md.Add($Line) }
function Cell([object]$v) { return ([string]$v).Replace('|', '\|').Replace("`n", ' ') }

# --- receipts ---------------------------------------------------------------
$dir = if ($ReceiptDirectory) { $ReceiptDirectory } else { Get-OwReceiptDirectory $root }
$files = if ($Receipt) { @($Receipt) } elseif (Test-Path -LiteralPath $dir) { @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object Name | ForEach-Object FullName) } else { @() }
$valid = [System.Collections.Generic.List[object]]::new()
$excluded = [System.Collections.Generic.List[object]]::new()
$staleCount = 0
foreach ($f in $files) {
    $r = Read-OwReceipt $f
    $name = [IO.Path]::GetFileName($f)
    if (-not $r.Intact) { $excluded.Add([pscustomobject]@{ file = $name; reason = 'self-hash or schema mismatch (altered or not a receipt)' }); continue }
    $reasons = @(Get-OwReceiptStaleReasons $r.Receipt $current)
    if ($reasons.Count -gt 0) {
        if ($Receipt) { $excluded.Add([pscustomobject]@{ file = $name; reason = 'stale: ' + ($reasons -join ', ') }) } else { $staleCount++ }
        continue
    }
    $valid.Add([pscustomobject]@{ file = $name; r = $r.Receipt })
}

# --- live checks --------------------------------------------------------------
$privacy = Invoke-OwPwshFile $root (Join-Path $PSScriptRoot 'Test-CommitIdentityPrivacy.ps1') @('-RepositoryRoot', $root, '-BaseRef', $mergeBase, '-Json')
$privacyObj = $null; try { $privacyObj = ($privacy.Lines -join "`n") | ConvertFrom-Json } catch { $privacyObj = $null }
$gate = Join-Path $root 'tests/validate-local-router-lr14-scope.ps1'
$lr14 = $null
if (Test-Path -LiteralPath $gate -PathType Leaf) { $lr14 = Invoke-OwPwshFile $root $gate @('-RepositoryRoot', $root) }
$registry = $null; try { $registry = Get-OwLr14Registry $root } catch { $registry = $null }

# --- report -------------------------------------------------------------------
Add '# 验收证据报告'
Add ''
Add ('由 tools/oss-workflow/New-EvidenceReport.ps1 生成（{0} UTC）。本地证据不等于 GitHub CI；CI 结果以 PR 为准。' -f [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm'))
Add ''
Add '## 仓库与提交'
Add ''
Add '| 项目 | 值 |'
Add '|---|---|'
Add ("| 仓库 | {0} |" -f (Get-OwRemoteSlug $root))
Add ("| 分支 | {0} |" -f (Get-OwBranch $root))
Add ("| Base（{0}） | ``{1}`` |" -f $BaseRef, $baseSha)
Add ("| Merge base | ``{0}`` |" -f $mergeBase)
Add ("| HEAD | ``{0}`` |" -f $head)
Add ("| Tree | ``{0}`` |" -f $tree)
Add ("| 工作区 | {0} |" -f $(if ($worktree.clean) { '干净' } else { "有 $($worktree.entries) 项未提交变更（指纹 $($worktree.fingerprint.Substring(0, 12))）" }))
Add ("| 环境 | {0}；pwsh {1}；git {2}；根目录 SDK {3}；{4} |" -f $environment.os, $environment.pwsh, $environment.git, $environment.dotnet_sdk_at_repository_root, $environment.runner)
Add ''
Add '## 变更文件及范围'
Add ''
Add ("推荐验证级别：**{0}**（{1}）" -f $plan.recommended, ($plan.reasons -join '；'))
Add ''
Add '| 文件 | 状态 | 来源 | 规则 | 最低级别 |'
Add '|---|---|---|---|---|'
foreach ($c in $changed) {
    $cls = @($plan.files | Where-Object { $_.path -ceq $c.path })[0]
    Add ("| {0} | {1} | {2} | {3} | {4} |" -f (Cell $c.path), $c.status, $c.source, $cls.rule, $cls.level)
}
if ($changed.Count -eq 0) { Add '| （无） | | | | |' }
Add ''
Add '## 本地验证结果（仅采用与当前状态一致且未被修改的收据）'
Add ''
if ($valid.Count -eq 0) { Add '没有可用的验证收据。'; Add '' }
if ($staleCount -gt 0) { Add ("另有 {0} 份收据描述的是其他提交、文件树、工作区、环境或工具版本，已过期，未计入。" -f $staleCount); Add '' }
foreach ($v in $valid) {
    $r = $v.r
    Add ("### {0}：{1}（{2}，耗时 {3} 秒{4}）" -f $r.level_executed, $r.status, $r.scope, $r.duration_seconds, $(if ($r.reused_from) { "，复用收据 $($r.reused_from.file)" } else { '' }))
    Add ''
    Add ("收据 ``{0}``，键 ``{1}``" -f $v.file, $r.receipt_key.Substring(0, 16))
    Add ''
    if ($r.PSObject.Properties.Name -contains 'historical_receipt' -and $null -ne $r.historical_receipt) {
        Add ("历史记录：存在相同的 {0} PASS 收据 ``{1}``，仅作记录，未复用；本收据中的检查均为本次实际执行。" -f $r.historical_receipt.level, $r.historical_receipt.file)
        Add ''
    }
    Add '| 检查 | 来源 | 状态 | 秒 | 摘要 |'
    Add '|---|---|---|---|---|'
    foreach ($c in $r.checks) {
        $source = if ($c.PSObject.Properties.Name -contains 'reused' -and $c.reused -eq $true) { '复用历史（L1）' } else { '本次执行' }
        Add ("| {0} | {1} | {2} | {3} | {4} |" -f (Cell $c.id), $source, $c.status, $c.duration_seconds, (Cell $c.summary))
    }
    Add ''
}
if ($excluded.Count -gt 0) {
    Add '已排除的收据：'
    Add ''
    foreach ($e in $excluded) { Add ("- ``{0}``：{1}" -f $e.file, $e.reason) }
    Add ''
}
Add '## 未执行项目'
Add ''
$notRun = [System.Collections.Generic.List[string]]::new()
foreach ($v in $valid) {
    foreach ($c in $v.r.checks | Where-Object { $_.status -in @('SKIP', 'BLOCKED') }) { $notRun.Add(("{0} {1}：{2}（{3}）" -f $v.r.level_executed, $c.id, $c.status, $c.summary)) }
    foreach ($n in $v.r.not_executed) { $notRun.Add(("{0}：{1}" -f $n.item, $n.reason)) }
}
if ($valid.Count -eq 0) { $notRun.Add('本地验证：没有可用收据，视为未执行') }
foreach ($n in ($notRun | Select-Object -Unique)) { Add "- $n" }
Add ''
Add '## 提交身份隐私'
Add ''
if ($privacyObj -and $privacyObj.PSObject.Properties.Name -contains 'status') {
    Add ("结果：**{0}**；提交 {1} 个，未批准项 {2} 个（只显示标签，不显示姓名或邮箱）。" -f $privacyObj.status, $(if ($privacyObj.PSObject.Properties.Name -contains 'commits') { $privacyObj.commits } else { 0 }), $(if ($privacyObj.PSObject.Properties.Name -contains 'failures') { $privacyObj.failures } else { 'n/a' }))
    if ($privacyObj.PSObject.Properties.Name -contains 'results') {
        foreach ($x in @($privacyObj.results | Where-Object { -not $_.ok })) { Add ("- 未批准：{0} {1}（{2}）" -f $x.commit, $x.field, $x.label) }
    }
}
else { Add ("结果：**BLOCKED**（隐私检查未能运行，退出码 {0}）。" -f $privacy.Code) }
Add ''
Add '## LR-14 登记状态'
Add ''
if ($null -eq $lr14) { Add 'LR-14 闸门不存在：**BLOCKED**。' }
else {
    $p = @($lr14.Lines | Where-Object { $_ -match '^\s*PASS\s' }).Count; $f = @($lr14.Lines | Where-Object { $_ -match '^\s*FAIL\s' }).Count
    Add ("LR-14 scope 闸门：**{0}**（退出码 {1}，PASS {2}，FAIL {3}）。" -f $(if ($lr14.Code -eq 0) { 'PASS' } else { 'FAIL' }), $lr14.Code, $p, $f)
    foreach ($l in @($lr14.Lines | Where-Object { $_ -match '^\s*FAIL\s' } | Select-Object -First 5)) { Add ("- {0}" -f (ConvertTo-OwSafeText $l.Trim() $root)) }
}
Add ''
$commits = @((Invoke-OwGit -Root $root -Arguments @('rev-list', '--reverse', "$mergeBase..$head")).Lines)
if ($commits.Count -gt 0 -and $registry) {
    Add '| 提交 | 覆盖情况（参考信息，以闸门结果为准） |'
    Add '|---|---|'
    foreach ($c in $commits) {
        $cover = $null
        foreach ($s in $registry.Slices) {
            if ((Invoke-OwGit -Root $root -Arguments @('cat-file', '-e', "$($s.Tip)^{commit}") -AllowFailure).Code -ne 0) { continue }
            if (@((Invoke-OwGit -Root $root -Arguments @('rev-list', "$($s.Base)..$($s.Tip)")).Lines) -contains $c) { $cover = "已登记切片 $($s.Name)"; break }
        }
        if (-not $cover) {
            $cf = @(Get-OwCommitFiles $root $c)
            $cover = if ($cf.Count -gt 0 -and @($cf | Where-Object { $_ -notin $registry.GateFiles }).Count -eq 0) { '闸门维护提交（登记本身）' } else { '**未登记**' }
        }
        Add ("| ``{0}`` | {1} |" -f $c.Substring(0, 12), $cover)
    }
    Add ''
}
Add '## 遗留问题'
Add ''
$issues = [System.Collections.Generic.List[string]]::new()
foreach ($v in $valid) { foreach ($c in $v.r.checks | Where-Object { $_.status -ne 'PASS' }) { $issues.Add(("{0} {1}：{2}" -f $v.r.level_executed, $c.id, $c.status)) } }
if (-not $worktree.clean) { $issues.Add('工作区有未提交变更') }
if ($valid.Count -eq 0) { $issues.Add('没有与当前状态一致的验证收据') }
if ((Get-OwLevelIndex $plan.recommended) -gt (Get-OwLevelIndex (($valid | ForEach-Object { $_.r.level_executed } | Sort-Object | Select-Object -Last 1) ?? 'L1')) -or $valid.Count -eq 0) { $issues.Add("尚未在推荐级别 $($plan.recommended) 取得本地收据") }
if ($privacyObj -and $privacyObj.PSObject.Properties.Name -contains 'status' -and $privacyObj.status -ne 'PASS') { $issues.Add("隐私检查 $($privacyObj.status)") }
if ($lr14 -and $lr14.Code -ne 0) { $issues.Add('LR-14 闸门未通过') }
$issues.Add('GitHub Development Gate：需在 PR 上确认，本报告不代替')
foreach ($i in $issues) { Add "- $i" }

$text = ($md -join "`n") + "`n"
if ($OutFile) { [IO.File]::WriteAllText($OutFile, $text, [Text.UTF8Encoding]::new($false)); Write-Output "EVIDENCE_REPORT written $([IO.Path]::GetFileName($OutFile))" } else { Write-Output $text }
exit 0
