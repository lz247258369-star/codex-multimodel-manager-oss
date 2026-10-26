$ErrorActionPreference = "Stop"

function Get-CodexHome {
    if ($env:CODEX_HOME -and -not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return $env:CODEX_HOME
    }
    return (Join-Path $HOME ".codex")
}

function GitText([string[]]$GitArgs) {
    if ($null -eq $GitArgs -or $GitArgs.Count -eq 0) {
        throw "GitText requires at least one git argument."
    }
    $o = & git @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $($o | Out-String)" }
    return (($o | Out-String).TrimEnd())
}
function Sha([string]$Text) {
    $s = [Security.Cryptography.SHA256]::Create()
    try {
        $b = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($s.ComputeHash($b))).Replace("-","").ToLowerInvariant()
    } finally { $s.Dispose() }
}

$repo = (Resolve-Path (GitText -GitArgs @("rev-parse","--show-toplevel"))).Path
$repoHash = (Sha $repo.ToLowerInvariant()).Substring(0,16)
$file = Join-Path (Get-CodexHome) "handoffs\$repoHash-latest.json"
if (-not (Test-Path $file)) { throw "未找到该仓库的 handoff：$file" }
$s = Get-Content -Raw $file | ConvertFrom-Json
$branch = GitText -GitArgs @("branch","--show-current")
$head = GitText -GitArgs @("rev-parse","HEAD")
$status = GitText -GitArgs @("status","--short")
$statusHash = Sha $status

$ok = ($s.repo -eq $repo -and $s.branch -eq $branch -and $s.head -eq $head -and $s.status_hash -eq $statusHash)
if ($ok) {
    Write-Host "HANDOFF SAFE" -ForegroundColor Green
    Write-Host "Repo / Branch / HEAD / Git status 均与切换前一致。"
    exit 0
}
Write-Host "HANDOFF DRIFT" -ForegroundColor Red
Write-Host "Saved branch: $($s.branch) | Current: $branch"
Write-Host "Saved HEAD:   $($s.head) | Current: $head"
Write-Host "Saved status hash: $($s.status_hash)"
Write-Host "Now   status hash: $statusHash"
Write-Host "停止自动继续，请先确认变化来源。" -ForegroundColor Yellow
exit 2
