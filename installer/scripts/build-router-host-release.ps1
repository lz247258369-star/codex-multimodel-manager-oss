param(
    [string]$SourceRoot='', [string]$SourceCommit='', [string]$OutputRoot='',
    [string]$Version='', [string]$TargetRuntime='win-x64',
    [switch]$Verify, [string]$VerifyTarget='',
    [string]$ExpectedManifestSha256='', [string]$ExpectedPackageSha256=''
)
# LR15-PR9: independent compiled Host release; does not install/start a service.
$ErrorActionPreference='Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'router-host-release.psm1')
    if ($Verify) {
        $result=Get-VerifiedRouterHostRelease -ReleaseRoot $VerifyTarget -ExpectedManifestSha256 $ExpectedManifestSha256 -ExpectedPackageSha256 $ExpectedPackageSha256 -ExpectedVersion $Version -ExpectedSourceCommit $SourceCommit -ExpectedTargetRuntime $TargetRuntime
        Write-Host "Router Host release verified: $($result.files.Count) files; installation_permitted=False"
    }
    else { New-RouterHostRelease -SourceRoot $SourceRoot -SourceCommit $SourceCommit -OutputRoot $OutputRoot -Version $Version -TargetRuntime $TargetRuntime | ConvertTo-Json -Depth 8 }
    exit 0
}
catch { Write-Host "Router Host release refused: $($_.Exception.Message)"; exit 6 }
