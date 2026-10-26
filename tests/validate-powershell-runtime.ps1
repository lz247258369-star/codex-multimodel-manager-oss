param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Fail([string]$Message) {
    $failures.Add($Message)
    Write-Host "FAIL  $Message" -ForegroundColor Red
}

function Pass([string]$Message) {
    Write-Host "PASS  $Message" -ForegroundColor Green
}

# PowerShell variable names are case-insensitive. $HOME is a read-only automatic variable,
# so assigning to $home / $Home / $HOME fails at runtime under PowerShell 7.
$psFiles = @(Get-ChildItem -Path $RepositoryRoot -Recurse -File -Filter "*.ps1" | Where-Object {
    $_.FullName -notmatch '[\\/]\.git[\\/]'
})

foreach ($file in $psFiles) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )

    $assignments = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true)

    foreach ($assignment in $assignments) {
        $left = $assignment.Left
        if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $name = $left.VariablePath.UserPath
            if ($name -ieq "home") {
                Fail "Reserved automatic variable assignment in $($file.FullName.Substring($RepositoryRoot.Length + 1)): $($assignment.Extent.Text)"
            }
        }
    }
}

if ($failures.Count -eq 0) {
    Pass "No script assigns to the read-only HOME automatic variable"
}

# Runtime smoke test the exact path that previously failed.
$oldCodexHome = $env:CODEX_HOME
$tempCodexHome = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-mm-ci-" + [guid]::NewGuid().ToString("N"))
try {
    $env:CODEX_HOME = $tempCodexHome
    . (Join-Path $RepositoryRoot "installer/scripts/_common.ps1")
    $statePath = Get-StatePath
    $expected = Join-Path $tempCodexHome "multimodel-manager/state.json"
    if ([System.IO.Path]::GetFullPath($statePath) -eq [System.IO.Path]::GetFullPath($expected)) {
        Pass "Get-StatePath runtime smoke test"
    } else {
        Fail "Get-StatePath returned unexpected path: $statePath"
    }
}
catch {
    Fail "PowerShell runtime smoke test failed: $($_.Exception.Message)"
}
finally {
    if ($null -eq $oldCodexHome) {
        Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_HOME = $oldCodexHome
    }
    Remove-Item -Recurse -Force $tempCodexHome -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "PowerShell runtime validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "PowerShell runtime validation PASSED" -ForegroundColor Green
exit 0
