$ErrorActionPreference = "Stop"

# Give the PowerShell-hosted WPF process its own Windows application identity.
# Without an explicit AppUserModelID, Windows groups the running window under
# pwsh.exe/PowerShell even though the shortcut and WPF window use our brand icon.
# Identity is cosmetic/shell metadata only; failure must never block V4 startup.
$appIdentityHelper = Join-Path $PSScriptRoot "windows-app-identity.ps1"
if (Test-Path -LiteralPath $appIdentityHelper) {
    try {
        . $appIdentityHelper
        Set-ManagerCurrentProcessAppIdentity
    }
    catch {
        # Keep launcher fail-open for shell branding. Core V4 startup is more important.
    }
}

# Process-level guard for the V4 Visual Console.
# The legacy VBS launcher can only detect an already-visible window. During a
# rapid double-click, the second launcher may run before the first WPF window is
# visible. A named mutex closes that startup race without touching project/Git or
# Codex configuration.

$mutexName = "Local\CodexMultiModelManagerV4"
$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)

if (-not $createdNew) {
    # A V4 process is already starting or running. Best-effort activate its
    # window; if it is still starting, wait briefly for the title to appear.
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        for ($attempt = 0; $attempt -lt 12; $attempt++) {
            if ($shell.AppActivate("Codex Multi-Model Manager V4")) { break }
            Start-Sleep -Milliseconds 100
        }
    }
    catch {
        # Activation failure must never spawn a duplicate instance.
    }
    finally {
        if ($null -ne $shell) {
            try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } catch {}
        }
        $mutex.Dispose()
    }
    exit 0
}

$entryPath = Join-Path $PSScriptRoot "visual-console-entry.ps1"
if (-not (Test-Path -LiteralPath $entryPath)) {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
    throw "Visual Console entrypoint not found: $entryPath"
}

try {
    & $entryPath
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
