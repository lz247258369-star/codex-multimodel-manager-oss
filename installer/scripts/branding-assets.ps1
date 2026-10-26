$ErrorActionPreference = "Stop"

$script:BrandIconSha256 = "09ff6e48d0efe2af7621c9ccaa8e386251ae53cfe81a4254ff84a229af4fd471"

function Get-ManagerBrandIconPath {
    $payloadPath = Join-Path $PSScriptRoot "..\assets\codex-manager.ico.b64"
    if (-not (Test-Path -LiteralPath $payloadPath)) {
        throw "Brand icon payload not found: $payloadPath"
    }

    $managerRoot = Join-Path (Join-Path $HOME ".codex") "multimodel-manager"
    $assetRoot = Join-Path $managerRoot "assets"
    if (-not (Test-Path -LiteralPath $assetRoot)) {
        New-Item -ItemType Directory -Force -Path $assetRoot | Out-Null
    }

    $iconPath = Join-Path $assetRoot "codex-manager.ico"
    $needsWrite = $true

    if (Test-Path -LiteralPath $iconPath) {
        try {
            $existingHash = (Get-FileHash -LiteralPath $iconPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($existingHash -eq $script:BrandIconSha256) { $needsWrite = $false }
        }
        catch { $needsWrite = $true }
    }

    if ($needsWrite) {
        $encoded = (Get-Content -Raw -LiteralPath $payloadPath).Trim()
        $bytes = [Convert]::FromBase64String($encoded)
        [IO.File]::WriteAllBytes($iconPath, $bytes)

        $writtenHash = (Get-FileHash -LiteralPath $iconPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($writtenHash -ne $script:BrandIconSha256) {
            throw "Brand icon materialization hash mismatch."
        }
    }

    return $iconPath
}
