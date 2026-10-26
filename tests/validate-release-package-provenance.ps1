param(
    [Parameter(Mandatory = $false)][string]$RepositoryRoot = (Get-Location).Path
)

# LR15-PR6: offline proof for the release package builder and its provenance.
#
# Covered scenarios:
#   A  build PASS                        G  tampered package FAIL
#   B  -Verify PASS                      H  unsafe / traversal path FAIL
#   C  source commit invalid or          I  sensitive file inclusion FAIL
#      not the build source FAIL         J  temp artifacts cleaned
#   D  manifest file missing FAIL        K  offline (no network primitive)
#   E  packaged content modified FAIL    L  no real Provider involvement
#   F  SHA256 / digest mismatch FAIL
#
# Everything runs in throw-away temp directories against a synthetic git
# repository. No network, no provider, no user configuration, no real keys are
# ever touched. Verification re-reads the packaged bytes and recomputes every
# hash; a manifest that merely *contains* a SHA256 string can never pass.

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]
function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }
function Assert-True([bool]$Condition, [string]$Message) { if ($Condition) { Pass $Message } else { Fail $Message } }

$builder = Join-Path $RepositoryRoot "installer/scripts/build-release-package.ps1"
$validatorSource = Get-Content -Raw -LiteralPath $PSCommandPath
Assert-True (Test-Path -LiteralPath $builder -PathType Leaf) "the release package builder exists"

$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

# The builder is invoked as a child process (-File) so its real exit code is
# observable: `-Command` collapses nested `exit N` into a generic failure code.
function Invoke-Builder([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $pwsh -NoProfile -ExecutionPolicy Bypass -File $builder @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ ExitCode = $code; Output = ($out | Out-String) }
}

function New-SyntheticSource([string]$Root, [hashtable]$Files) {
    foreach ($relative in $Files.Keys) {
        $full = Join-Path $Root ($relative.Replace('/', '\'))
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full)
        [System.IO.File]::WriteAllText($full, [string]$Files[$relative], [System.Text.UTF8Encoding]::new($false))
    }

    $null = & git -C $Root init -q 2>&1
    $null = & git -C $Root -c user.name=release-test -c user.email=release-test@local add -A 2>&1
    $null = & git -C $Root -c user.name=release-test -c user.email=release-test@local commit -q -m "synthetic product" 2>&1
    return ([string](& git -C $Root rev-parse HEAD)).Trim()
}

$tempBase = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
$tempRoot = Join-Path $tempBase ("lr15-pr6-release-" + [guid]::NewGuid().ToString("N"))
$source = Join-Path $tempRoot "source"
$output = Join-Path $tempRoot "out"
$null = New-Item -ItemType Directory -Force -Path $source, $output

try {
    $syntheticFiles = @{
        "README.md"                              = "# product`n"
        "manifest.json"                          = "{`"name`":`"Codex Multi-Model Manager`",`"version`":`"3.8.0`"}`n"
        "installer/ONE_CLICK_SETUP.cmd"          = "@echo off`r`n"
        "installer/setup.ps1"                    = "Write-Host 'setup'`n"
        "skill/codex-multimodel-manager/SKILL.md" = "# skill`n"
        "docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md"   = "# roadmap`n"
        ".github/workflows/ci.yml"               = "name: not-in-package`n"
    }
    $realCommit = New-SyntheticSource $source $syntheticFiles

    # --- A: build ---------------------------------------------------------------
    $build = Invoke-Builder @("-SourceRoot", $source, "-OutputRoot", $output, "-Version", "4.0.0", "-EntryPoints", "installer/ONE_CLICK_SETUP.cmd")
    Assert-True ($build.ExitCode -eq 0) "A: the release package builds (exit 0)"
    $packageDir = (Get-ChildItem -LiteralPath $output -Directory | Select-Object -First 1).FullName
    $manifestPath = Join-Path $packageDir "release-manifest.json"
    Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) "A: the package carries release-manifest.json"
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json

    # --- file manifest / SHA256 / package digest --------------------------------
    $listed = @($manifest.files | ForEach-Object { $_.path })
    $actual = @(Get-ChildItem -LiteralPath $packageDir -Recurse -File |
            Where-Object { $_.Name -ne "release-manifest.json" } |
            ForEach-Object { $_.FullName.Substring($packageDir.Length).TrimStart('\', '/').Replace('\', '/') })
    Assert-True ((($listed | Sort-Object) -join ',') -eq (($actual | Sort-Object) -join ',')) "FILE_MANIFEST: the manifest lists exactly the packaged files ($($listed.Count))"
    Assert-True ($listed -notcontains ".github/workflows/ci.yml") "FILE_MANIFEST: a non-allow-listed tracked file is not packaged"
    $hashOk = $true
    foreach ($entry in @($manifest.files)) {
        $probe = Join-Path $packageDir $entry.path
        if ((Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$entry.sha256) { $hashOk = $false }
        if ((Get-Item -LiteralPath $probe).Length -ne [long]$entry.size) { $hashOk = $false }
    }
    Assert-True $hashOk "FILE_SHA256: every packaged file matches its recorded size and SHA256"
    Assert-True ([string]$manifest.package_sha256 -match '^[0-9a-f]{64}$') "PACKAGE_SHA256: a package-wide digest is recorded"
    Assert-True ([string]$manifest.version -eq "4.0.0") "A: the product version is recorded"
    Assert-True ([string]$manifest.source_commit -eq $realCommit) "SOURCE_COMMIT_VALIDATION: the manifest records the real build commit"
    Assert-True (-not [bool]$manifest.source_dirty) "SOURCE_COMMIT_VALIDATION: the build source is recorded as clean"

    # --- B: verify --------------------------------------------------------------
    $verify = Invoke-Builder @("-Verify", "-VerifyTarget", $packageDir)
    Assert-True ($verify.ExitCode -eq 0) "B: -Verify passes on the untouched package"
    $verifyWithSource = Invoke-Builder @("-Verify", "-VerifyTarget", $packageDir, "-VerifySourceRoot", $source)
    Assert-True ($verifyWithSource.ExitCode -eq 0) "B: -Verify resolves the recorded source commit in the source repository"

    # --- C: source commit provenance -------------------------------------------
    $notGit = Join-Path $tempRoot "notgit"
    $null = New-Item -ItemType Directory -Force -Path $notGit
    [System.IO.File]::WriteAllText((Join-Path $notGit "file.txt"), "x`n", [System.Text.UTF8Encoding]::new($false))
    $plain = Invoke-Builder @("-SourceRoot", $notGit, "-OutputRoot", $output, "-Version", "4.0.0")
    Assert-True ($plain.ExitCode -eq 3) "C: a plain directory without a commit is refused (exit 3)"
    Assert-True ($plain.Output -match 'not a git checkout') "C: the refusal names the missing provenance"

    $malformed = Invoke-Builder @("-SourceRoot", $source, "-OutputRoot", $output, "-Version", "4.0.0", "-SourceCommit", "deadbeef")
    Assert-True ($malformed.ExitCode -eq 3) "C: a malformed source commit is refused (exit 3)"
    $wrongCommit = Invoke-Builder @("-SourceRoot", $source, "-OutputRoot", $output, "-Version", "4.0.0", "-SourceCommit", "0000000000000000000000000000000000000000")
    Assert-True ($wrongCommit.ExitCode -eq 3) "C: a well-formed but unresolvable commit is refused (exit 3)"
    Assert-True ($wrongCommit.Output -match 'does not resolve') "C: the refusal names the unresolved commit"

    $other = Join-Path $tempRoot "other"
    $null = New-Item -ItemType Directory -Force -Path $other
    $otherCommit = New-SyntheticSource $other @{ "README.md" = "# other`n" }
    $foreign = Invoke-Builder @("-SourceRoot", $source, "-OutputRoot", $output, "-Version", "4.0.0", "-SourceCommit", $otherCommit)
    Assert-True ($foreign.ExitCode -eq 3) "C: a 40-hex commit from another repository is refused (exit 3)"
    Assert-True ($foreign.Output -match 'does not resolve') "C: the refusal explains that the commit does not resolve in this source repository"

    # A commit that resolves here but is not the checkout HEAD must still be
    # refused: a package may not claim a state that is not the build source.
    [System.IO.File]::WriteAllText((Join-Path $source "SECOND.md"), "# second`n", [System.Text.UTF8Encoding]::new($false))
    $null = & git -C $source -c user.name=release-test -c user.email=release-test@local add -A 2>&1
    $null = & git -C $source -c user.name=release-test -c user.email=release-test@local commit -q -m "second commit" 2>&1
    $newHead = ([string](& git -C $source rev-parse HEAD)).Trim()
    Assert-True ($newHead -ne $realCommit) "C setup: the source repository now has a newer HEAD"
    $stale = Invoke-Builder @("-SourceRoot", $source, "-OutputRoot", $output, "-Version", "4.0.0", "-SourceCommit", $realCommit)
    Assert-True ($stale.ExitCode -eq 3) "C: a resolvable commit that is not the checkout HEAD is refused (exit 3)"
    Assert-True ($stale.Output -match 'not the checkout HEAD') "C: the refusal explains that another state cannot be labelled the build source"

    # --- D/E/F/G: content, hash and tamper negatives ----------------------------
    $victim = Join-Path $packageDir "README.md"
    $original = [System.IO.File]::ReadAllText($victim)

    [System.IO.File]::Delete($victim)
    $deleted = Invoke-Builder @("-Verify", "-VerifyTarget", $packageDir)
    Assert-True ($deleted.ExitCode -eq 6 -and $deleted.Output -match 'missing file') "D: a missing packaged file fails verification (exit 6)"
    [System.IO.File]::WriteAllText($victim, $original, [System.Text.UTF8Encoding]::new($false))

    [System.IO.File]::AppendAllText($victim, "tampered`n")
    $modified = Invoke-Builder @("-Verify", "-VerifyTarget", $packageDir)
    Assert-True ($modified.ExitCode -eq 6 -and $modified.Output -match 'content mismatch') "E: modified packaged content fails verification"
    [System.IO.File]::WriteAllText($victim, $original, [System.Text.UTF8Encoding]::new($false))

    $manifestBefore = Get-Content -Raw -LiteralPath $manifestPath
    $forged = $manifestBefore -replace '(?<="sha256": ")[0-9a-f]{64}(?=")', ('a' * 64)
    Set-Content -LiteralPath $manifestPath -Value $forged -Encoding UTF8 -NoNewline
    $shaForged = Invoke-Builder @("-Verify", "-VerifyTarget", $packageDir)
    Assert-True ($shaForged.ExitCode -eq 6 -and $shaForged.Output -match 'content mismatch') "F: a forged per-file SHA256 fails verification against the real bytes"
    Set-Content -LiteralPath $manifestPath -Value $manifestBefore -Encoding UTF8 -NoNewline

    [System.IO.File]::WriteAllText((Join-Path $packageDir "extra.txt"), "extra`n", [System.Text.UTF8Encoding]::new($false))
    $tampered = Invoke-Builder @("-Verify", "-VerifyTarget", $packageDir)
    Assert-True ($tampered.ExitCode -eq 6 -and $tampered.Output -match 'not listed in the manifest') "G: an unlisted packaged file fails verification"
    Remove-Item -LiteralPath (Join-Path $packageDir "extra.txt") -Force

    # --- H: unsafe / traversal paths -------------------------------------------
    $traversal = @{
        schema_version = 1
        product        = "codex-multimodel-manager"
        version        = "4.0.0"
        source_commit  = $realCommit
        file_count     = 1
        package_sha256 = ('b' * 64)
        files          = @(@{ path = "../outside.txt"; size = 1; sha256 = ('c' * 64) })
    }
    ($traversal | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $escaped = Invoke-Builder @("-Verify", "-VerifyTarget", $packageDir)
    Assert-True ($escaped.ExitCode -eq 6 -and $escaped.Output -match 'unsafe manifest path') "H: a traversal path in the manifest is refused"
    Set-Content -LiteralPath $manifestPath -Value $manifestBefore -Encoding UTF8 -NoNewline

    # --- I: sensitive file inclusion -------------------------------------------
    $unsafeSource = Join-Path $tempRoot "unsafe-source"
    $null = New-Item -ItemType Directory -Force -Path $unsafeSource
    $null = New-SyntheticSource $unsafeSource @{
        "installer/ONE_CLICK_SETUP.cmd" = "@echo off`r`n"
        "installer/auth.json"           = "{`"token`":`"not-a-real-token`"}`n"
    }
    $sensitive = Invoke-Builder @("-SourceRoot", $unsafeSource, "-OutputRoot", $output, "-Version", "4.0.0")
    Assert-True ($sensitive.ExitCode -eq 4) "I: a sensitive file inside the allow list refuses the build (exit 4)"
    Assert-True ($sensitive.Output -match 'auth\.json') "I: the refusal names the sensitive path"

    # --- J: temp artifacts cleaned ---------------------------------------------
    $leftover = @(Get-ChildItem -LiteralPath $output -Force | Where-Object { $_.Name -like ".release-*" })
    Assert-True ($leftover.Count -eq 0) "J: the builder leaves no archive or extraction directory behind"

    # --- K/L: offline and provider-free ---------------------------------------
    $networkPrimitives = @(("Invoke-" + "RestMethod"), ("Invoke-" + "WebRequest"), ("System.Net.Http." + "HttpClient"), ("Start-" + "BITS" + "Transfer"))
    $offline = $true
    foreach ($primitive in $networkPrimitives) {
        $builderSource = Get-Content -Raw -LiteralPath $builder
        if ($builderSource.Contains($primitive) -or $validatorSource.Contains($primitive)) { $offline = $false }
    }
    Assert-True $offline "K: neither the builder nor this validator contains a network primitive (offline)"

    $providerEndpoints = @(("api." + "deepseek.com"), ("open" + "router.ai"), ("api.openai" + ".com"), ("xiaomi" + "mimo"))
    $providerFree = $true
    foreach ($endpoint in $providerEndpoints) {
        if ($validatorSource.Contains($endpoint)) { $providerFree = $false }
    }
    Assert-True $providerFree "L: no real Provider endpoint is referenced or called"
    Assert-True (-not ($listed -match 'auth\.json|\.env$')) "L: the package carries no credential-bearing file"
}
finally {
    if ($tempRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $tempRoot).StartsWith("lr15-pr6-release-", [System.StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Release package provenance validation FAILED ($($failures.Count) failure(s))" -ForegroundColor Red
    exit 1
}

Write-Host "Release package provenance validation PASSED (A-L)" -ForegroundColor Green
exit 0
