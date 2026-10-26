param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path $env:LOCALAPPDATA "Codex Multi-Model Manager\CodexManager.exe")
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$sourcePath = Join-Path $repoRoot "installer\launcher\CodexManagerLauncher.cs"
$brandingHelper = Join-Path $repoRoot "installer\scripts\branding-assets.ps1"

if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Native launcher source not found: $sourcePath"
}
if (-not (Test-Path -LiteralPath $brandingHelper)) {
    throw "Branding helper not found: $brandingHelper"
}

. $brandingHelper
$iconPath = Get-ManagerBrandIconPath
if (-not (Test-Path -LiteralPath $iconPath)) {
    throw "Brand icon not found: $iconPath"
}

$candidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$csc = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($csc)) {
    throw "Windows .NET Framework C# compiler not found. Expected csc.exe under %WINDIR%\Microsoft.NET\Framework*."
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$tempOutput = Join-Path $outputDirectory ("CodexManager." + [Guid]::NewGuid().ToString("N") + ".exe")
try {
    $compilerArgs = @(
        "/nologo",
        "/target:winexe",
        "/platform:anycpu",
        "/optimize+",
        "/reference:System.Windows.Forms.dll",
        "/reference:System.Drawing.dll",
        ("/win32icon:{0}" -f $iconPath),
        ("/out:{0}" -f $tempOutput),
        $sourcePath
    )

    $compilerOutput = @(& $csc @compilerArgs 2>&1)
    $compilerExitCode = $LASTEXITCODE
    if ($compilerExitCode -ne 0 -or -not (Test-Path -LiteralPath $tempOutput)) {
        $diagnostics = ($compilerOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($diagnostics)) { $diagnostics = "(no compiler diagnostics)" }
        throw "Native launcher compile failed with exit code $compilerExitCode.`n$diagnostics"
    }

    Move-Item -LiteralPath $tempOutput -Destination $OutputPath -Force
}
finally {
    if (Test-Path -LiteralPath $tempOutput) {
        Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
    }
}

$exe = Get-Item -LiteralPath $OutputPath
if ($exe.Length -lt 4096) {
    throw "Native launcher output is unexpectedly small: $($exe.Length) bytes"
}

Write-Output $exe.FullName
