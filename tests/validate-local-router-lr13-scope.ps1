param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

. (Join-Path $RepositoryRoot "tests/shared/protected-file-scope.ps1")

$routeScript = Join-Path $RepositoryRoot "installer/scripts/desktop-chat-route.ps1"
$adapter = Join-Path $RepositoryRoot "installer/scripts/desktop-router-route.ps1"
$sharedHelper = Join-Path $RepositoryRoot "tests/shared/protected-file-scope.ps1"

if (-not (Test-Path -LiteralPath $routeScript -PathType Leaf)) { Fail "Missing desktop-chat-route.ps1 for scope check." }
if (-not (Test-Path -LiteralPath $adapter -PathType Leaf)) { Fail "Missing desktop-router-route.ps1 for scope check." }
if (-not (Test-Path -LiteralPath $sharedHelper -PathType Leaf)) { Fail "Missing shared protected-file-scope helper." }

$scopeErrors = @(Get-DesktopChatRouteScopeErrors $RepositoryRoot)
if ($scopeErrors.Count -eq 0) {
    Pass "desktop-chat-route.ps1 matches the approved LR-13 delta (golden normalized sha256)"
}
else {
    foreach ($error in $scopeErrors) { Fail "LR-13 scope: $error" }
}

$authorized = Test-Lr13ProtectedFileChangeAuthorized $RepositoryRoot "installer/scripts/desktop-chat-route.ps1"
if ($authorized) {
    Pass "Protected-file policy authorizes the exact approved LR-13 desktop-chat-route delta"
}
else {
    Fail "Protected-file policy rejected the approved LR-13 delta"
}

# A future unauthorized change anywhere in desktop-chat-route.ps1 must fail.
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("lr13-scope-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    $mutatedPath = Join-Path $tempRoot "desktop-chat-route.ps1"
    $original = Get-Content -Raw -LiteralPath $routeScript
    $mutated = $original + "`n# UNAUTHORIZED LR13 MUTATION MARKER`n"
    [System.IO.File]::WriteAllText($mutatedPath, $mutated, [System.Text.UTF8Encoding]::new($false))
    $mutatedErrors = @(Get-DesktopChatRouteScopeErrors $RepositoryRoot $mutatedPath)
    if ($mutatedErrors.Count -gt 0) {
        Pass "Unauthorized future desktop-chat-route mutation fails the LR-13 scope gate"
    }
    else {
        Fail "Unauthorized future desktop-chat-route mutation was not detected"
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Historical validators must not contain the weak string-presence exemption.
$historical = @(
    "validate-local-router-provider.ps1",
    "validate-local-router-openrouter.ps1",
    "validate-local-router-modelstudio.ps1",
    "validate-local-router-openai.ps1",
    "validate-local-router-mimo.ps1",
    "validate-local-router-protocol.ps1",
    "validate-local-router-observability.ps1",
    "validate-local-router-metering.ps1",
    "validate-local-router-policy.ps1"
)
$weakFound = @()
foreach ($name in $historical) {
    $text = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "tests/$name")
    if ($text.Contains("authorizedDesktopHook")) { $weakFound += $name }
}
if ($weakFound.Count -eq 0) {
    Pass "No historical validator keeps the weak whole-file string exemption"
}
else {
    Fail "Weak whole-file exemption still present in: $($weakFound -join ', ')"
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "LR-13 scope validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}
Write-Host "LR-13 scope validation PASSED" -ForegroundColor Green
exit 0
