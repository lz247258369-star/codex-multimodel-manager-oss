param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$entryPath = Join-Path $RepositoryRoot "installer/scripts/visual-console-entry.ps1"
$sourcePath = Join-Path $RepositoryRoot "installer/scripts/visual-console.ps1"

if (-not (Test-Path -LiteralPath $entryPath)) { throw "Missing Visual Console entrypoint" }
if (-not (Test-Path -LiteralPath $sourcePath)) { throw "Missing Visual Console source" }

$entry = Get-Content -Raw -LiteralPath $entryPath
$source = Get-Content -Raw -LiteralPath $sourcePath
$anchor = '$script:loadingRoute = $false'

if ($entry.Contains('$sourceText.Replace($uiUsabilityAnchor, $uiUsabilityPatch)')) {
    throw "Global anchor replacement would duplicate Desktop controls"
}

foreach ($needle in @(
    '$sourceText.IndexOf($uiUsabilityAnchor, [System.StringComparison]::Ordinal)',
    '$sourceText.Substring(0, $uiAnchorIndex)',
    '$sourceText.Substring($uiAnchorIndex + $uiUsabilityAnchor.Length)'
)) {
    if (-not $entry.Contains($needle)) { throw "Missing single-anchor injection behavior: $needle" }
}

$anchorCount = [regex]::Matches($source, [regex]::Escape($anchor)).Count
if ($anchorCount -lt 1) { throw "Visual Console source has no runtime injection anchor" }

$marker = '<DESKTOP_ROUTE_CONTROLS_ONCE>'
$index = $source.IndexOf($anchor, [System.StringComparison]::Ordinal)
$simulated = $source.Substring(0, $index) + $marker + $source.Substring($index + $anchor.Length)
$markerCount = [regex]::Matches($simulated, [regex]::Escape($marker)).Count
if ($markerCount -ne 1) { throw "Desktop route controls would be injected $markerCount times" }

Write-Host "PASS  V4 Desktop route controls inject exactly once (source anchors: $anchorCount)" -ForegroundColor Green
exit 0
