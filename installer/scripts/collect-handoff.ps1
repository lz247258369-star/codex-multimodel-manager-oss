param([string]$TargetModel = "")
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
$branch = GitText -GitArgs @("branch","--show-current")
$head = GitText -GitArgs @("rev-parse","HEAD")
$status = GitText -GitArgs @("status","--short")
$statusHash = Sha $status
$repoHash = (Sha $repo.ToLowerInvariant()).Substring(0,16)

$dir = Join-Path (Get-CodexHome) "handoffs"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$file = Join-Path $dir "$repoHash-latest.json"

$obj = [ordered]@{
    saved_at = (Get-Date -Format "o")
    repo = $repo
    branch = $branch
    head = $head
    status_hash = $statusHash
    status = $status
    target_model = $TargetModel
}
$obj | ConvertTo-Json -Depth 5 | Set-Content $file -Encoding UTF8
Write-Host "HANDOFF PREPARED" -ForegroundColor Green
Write-Host "Repo: $repo"
Write-Host "Branch: $branch"
Write-Host "HEAD: $head"
Write-Host "Worktree: $(if ([string]::IsNullOrWhiteSpace($status)) {'CLEAN'} else {'DIRTY'})"
Write-Host "Snapshot: $file"
