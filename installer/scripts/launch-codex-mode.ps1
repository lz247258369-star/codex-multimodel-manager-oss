#requires -Version 7
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [Parameter(Mandatory = $false)]
    [string]$Target = "",

    [Parameter(Mandatory = $false)]
    [string]$Provider = "",

    [Parameter(Mandatory = $false)]
    [string]$ModelId = "",

    [Parameter(Mandatory = $false)]
    [string]$ReasoningEffort = ""
)

$ErrorActionPreference = "Stop"

# LR-12 ModeSelector: DIRECT is the default launch path. ROUTER is opt-in and
# only selected after an explicit backup-preserving enable action. This script
# never rewrites Direct Mode definitions; it only dispatches to the existing
# Direct launcher (unchanged) or to the Router-owned Codex launch path.
. (Join-Path $PSScriptRoot "router-codex-cli.ps1")

$mode = (Get-RouterCliState).mode
if ([string]::IsNullOrWhiteSpace([string]$mode)) { $mode = "direct" }

Write-Host ("ModeSelector: {0}" -f $mode) -ForegroundColor DarkGray

if ($mode -eq "router") {
    $launchArgs = @(
        "-Action", "Launch",
        "-ProjectPath", $ProjectPath,
        "-Ping"
    )
    if (-not [string]::IsNullOrWhiteSpace($ModelId)) {
        $launchArgs += @("-Model", $ModelId)
    }
    if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) {
        $launchArgs += @("-ReasoningEffort", $ReasoningEffort)
    }
    & (Join-Path $PSScriptRoot "router-codex-cli.ps1") @launchArgs
    exit $LASTEXITCODE
}

$directLauncher = Join-Path $PSScriptRoot "launch-controller-model.ps1"
$directArgs = @("-ProjectPath", $ProjectPath)
if (-not [string]::IsNullOrWhiteSpace($Target)) { $directArgs += @("-Target", $Target) }
if (-not [string]::IsNullOrWhiteSpace($Provider)) { $directArgs += @("-Provider", $Provider) }
if (-not [string]::IsNullOrWhiteSpace($ModelId)) { $directArgs += @("-ModelId", $ModelId) }
if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) { $directArgs += @("-ReasoningEffort", $ReasoningEffort) }
& $directLauncher @directArgs
exit $LASTEXITCODE
