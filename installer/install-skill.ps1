$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $RepoRoot "skill\codex-multimodel-manager"
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$skillsHome = Join-Path $codexHome "skills"
$dest = Join-Path $skillsHome "codex-multimodel-manager"

if (-not (Test-Path (Join-Path $source "SKILL.md"))) {
    throw "Skill source not found: $source"
}

New-Item -ItemType Directory -Force -Path $skillsHome | Out-Null

if (Test-Path $dest) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = "$dest.backup-$stamp"
    Move-Item $dest $backup
    Write-Host "旧 Skill 已备份：$backup"
}

Copy-Item $source $dest -Recurse -Force
Write-Host "安装完成：$dest" -ForegroundColor Green
Write-Host "重启 Codex 后可调用：`$codex-multimodel-manager" -ForegroundColor Cyan
