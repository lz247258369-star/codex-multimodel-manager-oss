param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot ".." )).Path
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]
function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { Write-Host "FAIL  $Message" -ForegroundColor Red; $failures.Add($Message) | Out-Null }

$motionPath = Join-Path $RepositoryRoot "installer\scripts\visual-motion-system.ps1"
$entryPath = Join-Path $RepositoryRoot "installer\scripts\visual-console-entry.ps1"
$sourcePath = Join-Path $RepositoryRoot "installer\scripts\visual-console.ps1"

if (Test-Path -LiteralPath $motionPath) { Pass "Motion v1 remains available for future experimental work" }
else { Fail "Motion runtime missing" }

if (Test-Path -LiteralPath $motionPath) {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($motionPath,[ref]$null,[ref]$parseErrors) | Out-Null
    if (@($parseErrors).Count -eq 0) { Pass "Motion runtime parses" }
    else { Fail ("Motion runtime parse errors: " + (@($parseErrors | ForEach-Object Message) -join "; ")) }
}

$entryText = Get-Content -Raw -LiteralPath $entryPath
$sourceText = Get-Content -Raw -LiteralPath $sourcePath
if ($entryText -notmatch 'visual-motion-system\.ps1') { Pass "Production V4 entrypoint does not load experimental Motion v1" }
else { Fail "Production V4 entrypoint still loads experimental Motion v1" }

foreach ($token in @('visual-hierarchy-runtime.ps1','visual-commercial-effects.ps1','[ScriptBlock]::Create($sourceText)')) {
    if ($entryText.Contains($token)) { Pass "Known-good production entrypoint keeps: $token" }
    else { Fail "Known-good production entrypoint missing: $token" }
}

if ($sourceText.Contains('$window.ShowDialog()')) { Pass "V4 source still reaches Window.ShowDialog" }
else { Fail "V4 source missing Window.ShowDialog" }

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Motion production-safety validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Motion production-safety validation PASSED" -ForegroundColor Green
