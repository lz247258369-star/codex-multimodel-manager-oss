#Requires -Version 7.2
<#
  Automated tests for tools/oss-workflow (tiered verification, receipts, LR-14
  candidate generator, identity privacy gate, evidence report).

  Every mutating test runs in throw-away fixture repositories under the temp
  directory. The real repository is only read (git log/diff/show) or cloned.
  Fixture identities that must be rejected are synthetic and the tests assert
  they never appear in any tool output.
#>
param([string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$toolDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $toolDir 'OssWorkflow.psm1') -Force

$script:Passes = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()
function Pass([string]$m) { $script:Passes++; Write-Output "PASS  $m" }
function Fail([string]$m) { $script:Failures.Add($m); Write-Output "FAIL  $m" }
function Assert([bool]$c, [string]$m) { if ($c) { Pass $m } else { Fail $m } }

$pwsh = (Get-Process -Id $PID).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('oss-workflow-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
$null = New-Item -ItemType Directory -Path $temp
$policy = Get-OwApprovedIdentities
$okName = [string]$policy.author[0].name
$okMail = [string]$policy.author[0].email
# Synthetic identity that must always be rejected and never echoed.
$badName = 'Fixture Person'
$badMail = 'fixture.person@corp.test'
$leakNeedles = @($badName, $badMail, 'fixture.person', 'corp.test')

function G([string]$Dir, [string[]]$A) { return , @((Invoke-OwGit -Root $Dir -Arguments $A).Lines) }
function Write-Text([string]$Dir, [string]$Rel, [string]$Text) {
    $p = Join-Path $Dir $Rel
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent)
    [IO.File]::WriteAllText($p, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}
function New-Fixture([string]$Name) {
    $d = Join-Path $temp $Name
    $null = New-Item -ItemType Directory -Path $d
    $null = G $d @('init', '-q', '-b', 'main')
    $null = G $d @('config', 'user.name', $okName)
    $null = G $d @('config', 'user.email', $okMail)
    $null = G $d @('config', 'core.autocrlf', 'false')
    return $d
}
function Save([string]$Dir, [string]$Message, [string]$AName = $okName, [string]$AMail = $okMail, [string]$CName = $null, [string]$CMail = $null) {
    $null = G $Dir @('add', '-A')
    $old = @{ n = $env:GIT_COMMITTER_NAME; e = $env:GIT_COMMITTER_EMAIL }
    try {
        if ($CName) { $env:GIT_COMMITTER_NAME = $CName; $env:GIT_COMMITTER_EMAIL = $CMail }
        $null = G $Dir @('-c', "user.name=$AName", '-c', "user.email=$AMail", 'commit', '-q', '--allow-empty', '-m', $Message)
    }
    finally { $env:GIT_COMMITTER_NAME = $old.n; $env:GIT_COMMITTER_EMAIL = $old.e }
    return (G $Dir @('rev-parse', 'HEAD'))[0]
}
function Run([string]$Tool, [string[]]$A, [hashtable]$Env = @{}, [string]$FromToolDir = $toolDir) {
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); Set-OwEnvironmentVariable $k $Env[$k] }
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    # Decode the tools' output as UTF-8 on any runner (CI runners have no console code page).
    $previousEncoding = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); $out = @(& $pwsh -NoLogo -NoProfile -File (Join-Path $FromToolDir $Tool) @A 2>&1 | ForEach-Object { [string]$_ }); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous; [Console]::OutputEncoding = $previousEncoding; foreach ($k in $saved.Keys) { Set-OwEnvironmentVariable $k $saved[$k] } }
    return [pscustomobject]@{ Code = $code; Text = ($out -join "`n") }
}
function No-Leak([string]$Text) { foreach ($n in $leakNeedles) { if ($Text.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false } }; return $true }
function Get-Receipts([string]$Dir) { $r = Join-Path (Get-OwGitDirectory $Dir) 'oss-workflow/receipts'; if (Test-Path $r) { return @(Get-ChildItem $r -Filter *.json | Sort-Object Name) } else { return @() } }

$fakeGate = @'
param([string]$RepositoryRoot = (Get-Location).Path, [string]$Base = "")
$script:GateFiles = @(
    "tests/validate-local-router-lr14-scope.ps1")
$script:RegisteredSlices = @(
)
Write-Output "PASS  fixture LR-14 gate"
exit 0
'@
$sampleValidator = @'
param([string]$RepositoryRoot = (Get-Location).Path)
Write-Output "PASS  sample validator ok"
exit 0
'@
$ciYml = @'
name: Fixture Gate
on:
  push:
jobs:
  gate:
    runs-on: windows-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Sample validator
        shell: pwsh
        run: ./tests/validate-sample.ps1 -RepositoryRoot $PWD
      - name: Block step
        shell: pwsh
        run: |
          Write-Output "PASS  block line one"
          Write-Output "PASS  block line two"
'@

try {
    # =====================================================================
    # A. Change classification and level policy (unit, real policy)
    # =====================================================================
    $p = Get-OwVerificationPlan @('docs/guide.md', 'README.md'); Assert ($p.recommended -eq 'L1') 'A1 documentation-only change recommends L1'
    $p = Get-OwVerificationPlan @('tools/oss-workflow/OssWorkflow.psm1'); Assert ($p.recommended -eq 'L2') 'A2 workflow-tool change recommends L2'
    $p = Get-OwVerificationPlan @('local-router/src/Router.ProviderAdapters.OpenAI/OpenAIProviderAdapter.cs', 'local-router/tests/Router.ProviderAdapters.OpenAI.Tests/OpenAIRequestMappingTests.cs')
    Assert ($p.recommended -eq 'L2' -and $p.modules.Count -eq 1) 'A3 a router project with its own test project is one module at L2'
    $p = Get-OwVerificationPlan @('local-router/src/Router.ProviderAdapters.OpenAI/A.cs', 'local-router/src/Router.ProviderAdapters.MiMo/B.cs')
    Assert ($p.recommended -eq 'L3' -and ($p.reasons -join ' ') -match 'cross-module') 'A4 a cross-module change upgrades to L3'
    $p = Get-OwVerificationPlan @('some/unknown/path.bin'); Assert ($p.recommended -eq 'L3' -and ($p.reasons -join ' ') -match 'unknown') 'A5 an unknown path defaults to L3'
    foreach ($sec in @('.github/workflows/ci.yml', 'global.json', 'local-router/global.json', 'local-router/Directory.Build.props', 'tests/validate-local-router-lr14-scope.ps1', 'tests/shared/oss-genesis.ps1', 'tests/validate-dsr7c-apply-patch-file-authorization.ps1', 'installer/scripts/router-host-release.psm1', 'skill/codex-multimodel-manager/SKILL.md', 'local-router/src/Router.Host/Program.cs', 'local-router/config/router.defaults.json')) {
        Assert ((Get-OwVerificationPlan @($sec)).recommended -eq 'L3') "A6 security-critical surface requires L3: $sec"
    }
    $p = Get-OwVerificationPlan @('docs/a.md', 'installer/setup.ps1'); Assert ($p.recommended -eq 'L3') 'A7 mixing documentation with a security surface never lowers the level'
    $p = Get-OwVerificationPlan @(); Assert ($p.recommended -eq 'L1') 'A8 an empty change set is L1'
    # Real history (read-only): the four OSS slices of this repository.
    $hist = [ordered]@{
        '776c0ab8529a4ab3330a6c582e0c5b5e79696ff6' = 'L1'   # README Chinese section
        '0344c0c292a2b31245d58295fd8cc6c3109019eb' = 'L3'   # FIX1 (gates, tests, docs)
        'd7160d911979bba3639c7d431b9c39f62fbb621a' = 'L3'   # CA2026: six test projects
        '804b202a51b43b2d1c13ce423f8a739faf87cb19' = 'L3'   # SDK pin
    }
    foreach ($c in $hist.Keys) {
        if ((Invoke-OwGit -Root $RepositoryRoot -Arguments @('cat-file', '-e', "$c^{commit}") -AllowFailure).Code -ne 0) { Fail "A9 historical commit $($c.Substring(0,7)) is not available"; continue }
        $files = G $RepositoryRoot @('diff', '--name-only', '--no-renames', "$c^1", $c)
        $lvl = (Get-OwVerificationPlan $files).recommended
        Assert ($lvl -eq $hist[$c]) "A9 real slice $($c.Substring(0,7)) ($($files.Count) files) is classified $lvl (expected $($hist[$c]))"
    }
    $tp = @(Get-OwAffectedTestProjects $RepositoryRoot @('Router.ProviderAdapters.OpenAI'))
    Assert ($tp -contains 'local-router/tests/Router.ProviderAdapters.OpenAI.Tests/Router.ProviderAdapters.OpenAI.Tests.csproj') 'A10 the real project graph maps an adapter to its test project'
    $tpCore = @(Get-OwAffectedTestProjects $RepositoryRoot @('Router.Core'))
    Assert ($tpCore.Count -ge 10) "A10 a change to Router.Core reaches its dependent test projects through the real graph ($($tpCore.Count))"

    # LR-14 registration: only a proven append-only change of RegisteredSlices
    # is a registration (L2); any other edit of the gate stays L3.
    $rx = New-Fixture 'registration'
    $entry = "    [pscustomobject]@{`n        Name      = `"EXISTING-SLICE`"`n        Base      = `"$('1' * 40)`"`n        Tip       = `"$('2' * 40)`"`n        Artifacts = @(`n            `"src/x.txt`")`n        Markers   = @{`n            `"src/x.txt`" = `"existing marker`"`n        }`n    }`n"
    $gate0 = $fakeGate.Replace("`$script:RegisteredSlices = @(`n)", "`$script:RegisteredSlices = @(`n$entry)")
    Write-Text $rx 'tests/validate-local-router-lr14-scope.ps1' $gate0
    Write-Text $rx 'tests/validate-local-router-lr14-scope-regression.ps1' "Write-Output 'PASS  fixture LR-14 regression'`nexit 0`n"
    Write-Text $rx 'src/x.txt' "x`n"
    $r0 = Save $rx 'init'
    $null = G $rx @('update-ref', 'refs/remotes/origin/main', $r0)
    $newEntry = $entry.Replace('EXISTING-SLICE', 'NEW-SLICE').Replace('existing marker', 'new marker')
    $gateFile = 'tests/validate-local-router-lr14-scope.ps1'
    $cases = [ordered]@{
        'an appended entry is a registration (L2)'                 = @($gate0.Replace("$entry)", "$entry$newEntry)"), 'L2')
        'a change to gate logic outside the list stays L3'          = @($gate0.Replace('fixture LR-14 gate', 'fixture LR-14 gate (edited)'), 'L3')
        'an edited existing entry stays L3'                        = @($gate0.Replace('existing marker', 'weakened'), 'L3')
        'an append combined with a logic change stays L3'          = @($gate0.Replace("$entry)", "$entry$newEntry)").Replace('exit 0', 'exit 0 # edited'), 'L3')
    }
    Assert ($gate0.Contains('EXISTING-SLICE')) 'A11 fixture: the base gate carries one registered entry'
    foreach ($k in $cases.Keys) {
        Assert ($cases[$k][0] -cne $gate0) "A11 fixture: the case really changes the gate ($k)"
        Write-Text $rx $gateFile $cases[$k][0]
        $lvl = (Get-OwVerificationPlan @($gateFile) $rx $r0).recommended
        Assert ($lvl -eq $cases[$k][1]) "A11 $k (got $lvl)"
    }
    Write-Text $rx $gateFile $gate0.Replace("$entry)", "$entry$newEntry)")
    Write-Text $rx 'tests/validate-other.ps1' "Write-Output 'PASS  other'`nexit 0`n"
    $lvl = (Get-OwVerificationPlan @($gateFile, 'tests/validate-other.ps1') $rx $r0).recommended
    Assert ($lvl -eq 'L2') "A11 a slice's own registration does not count as a second module (got $lvl)"
    Remove-Item (Join-Path $rx 'tests/validate-other.ps1')

    # A12: only pure-data registration entries may be classified as a registration.
    $sha1 = 'a' * 40; $sha2 = 'b' * 40
    function New-Entry([string]$Body) { return "    [pscustomobject]@{`n$Body`n    }`n" }
    $okBody = "        Name      = `"NEW-SLICE`"`n        Base      = `"$sha1`"`n        Tip       = `"$sha2`"`n        Artifacts = @(`n            `"src/x.txt`")`n        Markers   = @{`n            `"src/x.txt`" = `"new marker`"`n        }"
    $hardening = [ordered]@{
        'a commented, well-formed entry is a registration'                = @(("    # NEW-SLICE: reviewed entry`n" + (New-Entry $okBody)), 'L2')
        'an executable statement inside the list is rejected'             = @(((New-Entry $okBody) + "    Remove-Item -LiteralPath ./src/x.txt -WhatIf`n"), 'L3')
        'a sub-expression inside an entry is rejected'                    = @((New-Entry $okBody.Replace('"NEW-SLICE"', '"$(Get-Date)"')), 'L3')
        'an expandable string (variable) is rejected'                     = @((New-Entry $okBody.Replace("`"$sha1`"", '"$env:FIXTURE_BASE"')), 'L3')
        'a variable value is rejected'                                    = @((New-Entry $okBody.Replace("`"$sha2`"", '$script:Lr14SliceCommit')), 'L3')
        'a method call is rejected'                                       = @((New-Entry $okBody.Replace('"NEW-SLICE"', '"new-slice".ToUpper()')), 'L3')
        'a missing Markers key is rejected'                               = @((New-Entry ($okBody -replace "(?s)`n        Markers.*$", '')), 'L3')
        'an extra key is rejected'                                        = @((New-Entry ($okBody + "`n        Applies   = `"always`"")), 'L3')
        'Artifacts that are not an array are rejected'                    = @((New-Entry $okBody.Replace("@(`n            `"src/x.txt`")", '"src/x.txt"')), 'L3')
        'a hashtable instead of pscustomobject is rejected'               = @((New-Entry $okBody).Replace('[pscustomobject]', '[hashtable]'), 'L3')
        'a Base that is not a 40-hex commit id is rejected'               = @((New-Entry $okBody.Replace($sha1, 'HEAD~1')), 'L3')
        'a marker for a file outside Artifacts is rejected'               = @((New-Entry $okBody.Replace('"src/x.txt" = "new marker"', '"src/y.txt" = "new marker"')), 'L3')
        'an entry spliced into an existing statement is rejected'         = @($null, 'L3')
    }
    foreach ($k in $hardening.Keys) {
        $text = if ($null -eq $hardening[$k][0]) { $gate0.Replace("    }`n)", "    },`n" + (New-Entry $okBody).TrimEnd("`n") + "`n)") } else { $gate0.Replace("$entry)", "$entry$($hardening[$k][0]))") }
        Assert ($text -cne $gate0) "A12 fixture: the case really changes the gate ($k)"
        Write-Text $rx $gateFile $text
        $lvl = (Get-OwVerificationPlan @($gateFile) $rx $r0).recommended
        Assert ($lvl -eq $hardening[$k][1]) "A12 $k (got $lvl)"
    }
    Write-Text $rx $gateFile $gate0.Replace("$entry)", "$entry$newEntry)")
    $null = Save $rx 'register new slice'
    $r = Run 'Invoke-TieredVerification.ps1' @('-RepositoryRoot', $rx)
    Assert ($r.Code -eq 0 -and $r.Text -match 'level=L2 required=L2 status=PASS' -and $r.Text -match 'PASS\s+l2:lr14-scope-regression' -and $r.Text -match 'PASS\s+l2:lr14-scope') 'A11 a registration runs the LR-14 gate and its regression at L2'

    # =====================================================================
    # B. Receipts (unit)
    # =====================================================================
    $rd = Join-Path $temp 'receipts-unit'
    $base = [ordered]@{ schema = $OwReceiptSchema; receipt_sha256 = ''; level_executed = 'L1'; status = 'PASS'; commit_sha = ('a' * 40); tree_sha = ('b' * 40); merge_base_sha = ('c' * 40)
        worktree = [ordered]@{ clean = $true; entries = 0; fingerprint = $null }; environment = [ordered]@{ os = 'x'; pwsh = '7'; dotnet_sdk_at_repository_root = '10.0.400' }; tool = [ordered]@{ sha256 = 'tool-1' } }
    $path = Write-OwReceipt $base $rd
    Assert ((Read-OwReceipt $path).Intact) 'B1 a written receipt verifies its self-hash'
    $txt = [IO.File]::ReadAllText($path); [IO.File]::WriteAllText($path, $txt.Replace('"status": "PASS"', '"status": "PASS "'))
    Assert (-not (Read-OwReceipt $path).Intact) 'B2 any edit of a receipt breaks its self-hash'
    $r = (Get-Content -Raw (Write-OwReceipt $base $rd) | ConvertFrom-Json -DateKind String)
    $cur = [ordered]@{ commit_sha = ('a' * 40); tree_sha = ('b' * 40); merge_base_sha = ('c' * 40); worktree = [ordered]@{ clean = $true; fingerprint = $null }; environment = [ordered]@{ os = 'x'; pwsh = '7'; dotnet_sdk_at_repository_root = '10.0.400' }; tool = [ordered]@{ sha256 = 'tool-1' } }
    Assert (@(Get-OwReceiptStaleReasons $r $cur).Count -eq 0) 'B3 a receipt matching the current state is not stale'
    foreach ($case in @(
            @{ k = 'commit_sha'; v = ('d' * 40); want = 'commit changed' },
            @{ k = 'tree_sha'; v = ('e' * 40); want = 'tree changed' },
            @{ k = 'merge_base_sha'; v = ('f' * 40); want = 'base changed' })) {
        $c2 = [ordered]@{}; foreach ($x in $cur.Keys) { $c2[$x] = $cur[$x] }; $c2[$case.k] = $case.v
        Assert ((@(Get-OwReceiptStaleReasons $r $c2) -join ',') -match $case.want) "B4 receipt is stale when $($case.want)"
    }
    $c2 = [ordered]@{}; foreach ($x in $cur.Keys) { $c2[$x] = $cur[$x] }; $c2.worktree = [ordered]@{ clean = $false; fingerprint = '1234' }
    Assert ((@(Get-OwReceiptStaleReasons $r $c2) -join ',') -match 'uncommitted') 'B4 receipt is stale when uncommitted changes differ'
    $c2 = [ordered]@{}; foreach ($x in $cur.Keys) { $c2[$x] = $cur[$x] }; $c2.environment = [ordered]@{ os = 'x'; pwsh = '7'; dotnet_sdk_at_repository_root = '11.0.100' }
    Assert ((@(Get-OwReceiptStaleReasons $r $c2) -join ',') -match 'dotnet_sdk') 'B4 receipt is stale when the SDK differs'
    $c2 = [ordered]@{}; foreach ($x in $cur.Keys) { $c2[$x] = $cur[$x] }; $c2.tool = [ordered]@{ sha256 = 'tool-2' }
    Assert ((@(Get-OwReceiptStaleReasons $r $c2) -join ',') -match 'tool') 'B4 receipt is stale when the verification tool changes'

    # =====================================================================
    # A/B integration: tiered runner on a fixture repository
    # =====================================================================
    $fx = New-Fixture 'runner'
    Write-Text $fx 'docs/guide.md' "# Guide`n"
    Write-Text $fx 'tests/validate-sample.ps1' $sampleValidator
    Write-Text $fx 'tests/validate-local-router-lr14-scope.ps1' $fakeGate
    Write-Text $fx '.github/workflows/ci.yml' $ciYml
    $c0 = Save $fx 'fixture: initial'
    $null = G $fx @('update-ref', 'refs/remotes/origin/main', $c0)
    $V = 'Invoke-TieredVerification.ps1'

    Write-Text $fx 'docs/guide.md' "# Guide`nOne more line.`n"
    $r = Run $V @('-RepositoryRoot', $fx)
    Assert ($r.Code -eq 0 -and $r.Text -match 'level=L1 required=L1 status=PASS') 'R1 a documentation change runs L1 and passes'
    Assert ($r.Text -match 'LOCAL-PARTIAL \(not a CI result\)' -and $r.Text -notmatch 'CI PASS') 'R1 an L1 result is labelled partial and never claims a CI pass'
    $rc = @(Get-Receipts $fx)
    $first = Get-Content -Raw $rc[-1].FullName | ConvertFrom-Json -DateKind String
    Assert ($rc.Count -eq 1 -and (Read-OwReceipt $rc[-1].FullName).Intact) 'R1 a self-hashed receipt is written inside the Git directory'
    Assert ($first.commit_sha -eq $c0 -and $first.tree_sha -match '^[0-9a-f]{40}$' -and $first.worktree.clean -eq $false -and $first.worktree.fingerprint -match '^[0-9a-f]{64}$') 'R1 the receipt records commit, tree and the uncommitted-change fingerprint'
    Assert ($first.ci_equivalent -eq $false -and $first.level_executed -eq 'L1' -and @($first.checks).Count -ge 4 -and $first.environment.pwsh -and $first.environment.git -and $null -ne $first.duration_seconds) 'R1 the receipt records level, checks, tool versions, environment and duration'
    Assert ((G $fx @('status', '--porcelain')).Count -eq 1) 'R1 receipts never dirty the working tree'

    $r = Run $V @('-RepositoryRoot', $fx, '-ReuseReceipt')
    Assert ($r.Code -eq 0 -and $r.Text -match 'REUSED') 'R2 an identical state reuses the PASS receipt'
    Write-Text $fx 'docs/guide.md' "# Guide`nA different line.`n"
    $r = Run $V @('-RepositoryRoot', $fx, '-ReuseReceipt')
    Assert ($r.Code -eq 0 -and $r.Text -notmatch 'REUSED') 'R3 a changed working tree is verified again, not reused'
    $r = Run $V @('-RepositoryRoot', $fx, '-ReuseReceipt') @{ ImageVersion = 'fixture-image-2' }
    Assert ($r.Text -notmatch 'REUSED') 'R4 a different environment (runner image) is verified again, not reused'
    $latest = @(Get-Receipts $fx | Where-Object { (Get-Content -Raw $_.FullName | ConvertFrom-Json -DateKind String).environment.image_version -eq [string]$env:ImageVersion -and $null -eq (Get-Content -Raw $_.FullName | ConvertFrom-Json -DateKind String).reused_from })[-1]
    $t = [IO.File]::ReadAllText($latest.FullName); [IO.File]::WriteAllText($latest.FullName, $t.Replace('"duration_seconds": ', '"duration_seconds":  '))
    $r = Run $V @('-RepositoryRoot', $fx, '-ReuseReceipt')
    Assert ($r.Text -notmatch 'REUSED' -and -not (Read-OwReceipt $latest.FullName).Intact) 'R5 an altered receipt is never reused'

    Write-Text $fx 'tests/validate-sample.ps1' ($sampleValidator + "# changed`n")
    $r = Run $V @('-RepositoryRoot', $fx)
    Assert ($r.Code -eq 3 -and $r.Text -match 'level=L2' -and $r.Text -match 'status=INCOMPLETE' -and $r.Text -match 'SKIP\s+l2:lr14-scope') 'R6 a SKIP (no committed delta for LR-14) makes L2 INCOMPLETE, never PASS'
    $c1 = Save $fx 'fixture: docs and validator'
    $r = Run $V @('-RepositoryRoot', $fx)
    Assert ($r.Code -eq 0 -and $r.Text -match 'level=L2 required=L2 status=PASS' -and $r.Text -match 'l2:validator:validate-sample' -and $r.Text -match 'PASS\s+l2:lr14-scope') 'R7 a committed validator change runs L2 with the validator and the LR-14 gate'
    # FIX2: an identical L2 PASS receipt exists, but L2 runtime checks are never reused.
    $r = Run $V @('-RepositoryRoot', $fx, '-ReuseReceipt')
    $n1 = Get-Content -Raw @(Get-Receipts $fx)[-1].FullName | ConvertFrom-Json -DateKind String
    Assert ($r.Code -eq 0 -and $r.Text -match 'reuse: not permitted at L2' -and $r.Text -cnotmatch 'REUSED' -and $r.Text -match 'PASS\s+l2:validator:validate-sample \(') 'N1 L2 with -ReuseReceipt executes every runtime check again'
    Assert ($null -eq $n1.reused_from -and $null -ne $n1.historical_receipt -and $n1.historical_receipt.status -eq 'PASS' -and @($n1.checks | Where-Object { $_.reused -ne $false }).Count -eq 0) 'N1 the identical L2 receipt is recorded as history only and every check is marked as executed'
    $r = Run $V @('-RepositoryRoot', $fx, '-ListReceipts')
    Assert ($r.Code -eq 0 -and $r.Text -match 'OSS_VERIFY_RECEIPTS count=' -and $r.Text -match 'history: ' -and $r.Text -match 'describes the current state' -and $r.Text -match 'historical: ') 'N1 -ListReceipts shows stored receipts and separates current from historical results'
    Write-Text $fx 'tests/validate-sample.ps1' "param([string]`$RepositoryRoot)`nWrite-Output 'PROBE_ERROR diagnostic noise'`nWrite-Output 'FAIL  sample broke'`nexit 1`n"
    $null = Save $fx 'fixture: break validator'
    $r = Run $V @('-RepositoryRoot', $fx)
    Assert ($r.Code -eq 1 -and $r.Text -match 'status=FAIL') 'R8 a failing validator makes L2 FAIL'
    $failed = @((Get-Content -Raw @(Get-Receipts $fx)[-1].FullName | ConvertFrom-Json -DateKind String).checks | Where-Object { $_.status -eq 'FAIL' })[0]
    Assert ($failed.failures[0] -eq 'FAIL  sample broke') 'R8 the receipt records the explicit FAIL line before diagnostic noise'
    Write-Text $fx 'tests/validate-sample.ps1' $sampleValidator
    $c3 = Save $fx 'fixture: repair validator'

    Write-Text $fx '.github/workflows/ci.yml' ($ciYml + "`n# comment`n")
    $r = Run $V @('-RepositoryRoot', $fx, '-Level', 'L1')
    Assert ($r.Code -eq 3 -and $r.Text -match 'below the minimum L3') 'R9 a CI-workflow change refuses L1 (no downgrade)'
    $r = Run $V @('-RepositoryRoot', $fx, '-Level', 'L2')
    Assert ($r.Code -eq 3 -and $r.Text -match 'status=BLOCKED') 'R9 a CI-workflow change refuses L2 (no downgrade)'
    $null = G $fx @('checkout', '--', '.github/workflows/ci.yml')

    $r = Run $V @('-RepositoryRoot', $fx, '-Level', 'L3')
    Assert ($r.Code -eq 0 -and $r.Text -match 'level=L3' -and $r.Text -match 'status=PASS' -and $r.Text -match 'ci:02:Sample validator' -and $r.Text -match 'ci:03:Block step') 'R10 L3 runs every run-step of the real ci.yml'
    Assert ($r.Text -match 'LOCAL-FULL-REPRODUCTION \(GitHub CI still required\)') 'R10 an L3 result still states that GitHub CI is required'
    $l3 = Get-Content -Raw @(Get-Receipts $fx)[-1].FullName | ConvertFrom-Json -DateKind String
    Assert (@($l3.not_executed | Where-Object { $_.item -match 'Checkout' }).Count -eq 1 -and @($l3.not_executed | Where-Object { $_.item -eq 'GitHub Development Gate' }).Count -eq 1) 'R10 GitHub-only steps and the GitHub gate are recorded as not executed'
    $r = Run $V @('-RepositoryRoot', $fx, '-Level', 'L3', '-ReuseReceipt')
    $n2 = Get-Content -Raw @(Get-Receipts $fx)[-1].FullName | ConvertFrom-Json -DateKind String
    Assert ($r.Code -eq 0 -and $r.Text -match 'reuse: not permitted at L3' -and $r.Text -cnotmatch 'REUSED' -and $r.Text -match 'PASS\s+ci:02:Sample validator \(' -and $null -eq $n2.reused_from -and $null -ne $n2.historical_receipt) 'N2 L3 with -ReuseReceipt executes every CI step again; the identical receipt is history only'

    # Evidence report on the same fixture (valid L3 receipt for HEAD).
    $E = 'New-EvidenceReport.ps1'
    $r = Run $E @('-RepositoryRoot', $fx)
    Assert ($r.Code -eq 0 -and $r.Text.Contains($c3) -and $r.Text.Contains((G $fx @('rev-parse', 'HEAD^{tree}'))[0])) 'E1 the report shows the real HEAD and tree'
    Assert ($r.Text -match 'L3：PASS' -and $r.Text -match 'LR-14 scope 闸门：\*\*PASS' -and $r.Text -match '结果：\*\*PASS') 'E1 the report shows receipt, LR-14 and privacy results from real runs'
    Assert ($r.Text -match '本地证据不等于 GitHub CI' -and $r.Text -match 'GitHub Development Gate：需在 PR 上确认' -and $r.Text -notmatch 'CI PASS') 'E1 the report never presents local evidence as a CI result'
    $old = @(Get-Receipts $fx)[0].FullName
    $r = Run $E @('-RepositoryRoot', $fx, '-Receipt', $old)
    Assert ($r.Text -match '已排除的收据' -and $r.Text -match 'stale: commit changed') 'E2 a receipt for an older commit is excluded as stale'
    $r = Run $E @('-RepositoryRoot', $fx, '-Receipt', $latest.FullName)
    Assert ($r.Text -match 'self-hash or schema mismatch') 'E3 an altered receipt is excluded'

    Write-Text $fx '.github/workflows/ci.yml' ($ciYml + "`n      - name: Expression step`n        shell: pwsh`n        run: Write-Output `"`${{ github.sha }}`"`n")
    $null = Save $fx 'fixture: expression step'
    $r = Run $V @('-RepositoryRoot', $fx)
    Assert ($r.Code -eq 3 -and $r.Text -match 'level=L3 required=L3 status=BLOCKED' -and $r.Text -match 'BLOCKED\s+ci:04:Expression step') 'R11 a step that cannot run locally is BLOCKED, never PASS'
    $r = Run $E @('-RepositoryRoot', $fx)
    Assert ($r.Text -match 'ci:04:Expression step：BLOCKED' -and $r.Text -match 'L3 ci:04:Expression step：BLOCKED') 'E4 BLOCKED checks appear under not executed and open issues'
    $r = Run $V @('-RepositoryRoot', $fx, '-Level', 'L4')
    Assert ($r.Code -eq 3 -and $r.Text -match 'L4 runs only on a clean checkout') 'R12 L4 refuses a checkout that is not the base tip'

    # -----------------------------------------------------------------
    # FIX1: receipt reuse can never bypass identity privacy or a moving state
    # -----------------------------------------------------------------
    $ux = New-Fixture 'reuse-identity'
    Write-Text $ux 'docs/guide.md' "# Guide`n"
    Write-Text $ux 'tests/validate-local-router-lr14-scope.ps1' $fakeGate
    $u0 = Save $ux 'init'
    $null = G $ux @('update-ref', 'refs/remotes/origin/main', $u0)
    Write-Text $ux 'docs/guide.md' "# Guide`nchanged`n"
    $r = Run $V @('-RepositoryRoot', $ux)
    Assert ($r.Code -eq 0 -and $r.Text -match 'status=PASS') 'U1 setup: a PASS receipt exists for the documentation change'
    $r = Run $V @('-RepositoryRoot', $ux, '-ReuseReceipt')
    $reused = Get-Content -Raw @(Get-Receipts $ux)[-1].FullName | ConvertFrom-Json -DateKind String
    $idc = @($reused.checks | Where-Object { $_.id -eq 'l1:identity-privacy' })[0]
    Assert ($r.Code -eq 0 -and $r.Text -match 'identity privacy re-checked live' -and $idc.reused -eq $false -and @($reused.checks | Where-Object { $_.reused -eq $true }).Count -ge 3) 'U1 every reuse re-runs the identity privacy check live (only the other checks are reused)'
    $null = G $ux @('config', 'user.email', $badMail)
    $r = Run $V @('-RepositoryRoot', $ux, '-ReuseReceipt')
    $last = Get-Content -Raw @(Get-Receipts $ux)[-1].FullName
    Assert ($r.Code -eq 1 -and $r.Text -match 'status=FAIL' -and $r.Text -notmatch 'status=PASS' -and (No-Leak $r.Text) -and (No-Leak $last)) 'U2 after the local identity changes, -ReuseReceipt fails and neither output nor receipt carries the identity'
    Assert ((ConvertFrom-Json $last -DateKind String).environment.identity_local_config -eq 'not-approved') 'U2 the receipt records only the identity verdict label'
    $null = G $ux @('config', 'user.email', $okMail)
    $r = Run $V @('-RepositoryRoot', $ux, '-ReuseReceipt') @{ GIT_AUTHOR_NAME = $badName; GIT_AUTHOR_EMAIL = $badMail }
    Assert ($r.Code -eq 1 -and $r.Text -match 'status=FAIL' -and (No-Leak $r.Text)) 'U3 a GIT_AUTHOR_* override cannot pass through -ReuseReceipt'
    Assert ($null -eq [Environment]::GetEnvironmentVariable('GIT_AUTHOR_NAME') -and $null -eq [Environment]::GetEnvironmentVariable('GIT_AUTHOR_EMAIL')) 'U3 a temporary override is removed afterwards, not left as an empty variable'
    $r = Run $V @('-RepositoryRoot', $ux, '-ReuseReceipt')
    Assert ($r.Code -eq 0 -and $r.Text -match 'REUSED') 'U3 with the approved identity restored, the earlier PASS receipt is reusable again'
    $l1r = Get-Content -Raw @(Get-Receipts $ux)[-1].FullName | ConvertFrom-Json -DateKind String
    Assert ($l1r.level_executed -eq 'L1' -and $null -ne $l1r.reused_from -and @($l1r.checks | Where-Object { $_.reused -eq $true -and $_.kind -ne 'static' }).Count -eq 0) 'N0 L1 reuse covers static checks only (identity is live)'
    $r = Run $E @('-RepositoryRoot', $ux)
    Assert ($r.Text -match '复用历史（L1）' -and $r.Text -match '\| l1:identity-privacy \| 本次执行 \|') 'N0 the evidence report separates reused history from checks executed in this run'
    # Unreliable environment: no dotnet on PATH.
    $gitDir = Split-Path (Get-Command git).Source -Parent
    $bare = @{ PATH = "$gitDir;$env:SystemRoot\System32"; DOTNET_ROOT = '' }
    $r = Run $V @('-RepositoryRoot', $ux) $bare
    $ur = Get-Content -Raw @(Get-Receipts $ux)[-1].FullName | ConvertFrom-Json -DateKind String
    Assert ($ur.environment.reliable -eq $false -and $ur.environment.dotnet_sdk_at_repository_root -eq 'unavailable') 'U4 an environment without a resolvable SDK is recorded as not reliable'
    $r = Run $V @('-RepositoryRoot', $ux, '-ReuseReceipt') $bare
    Assert ($r.Text -match 'reuse: refused' -and $r.Text -notmatch 'REUSED') 'U4 receipts are never reused when the environment cannot be determined reliably'
    # The state changes while checks run: no valid PASS.
    Write-Text $ux 'tests/validate-mutating.ps1' "param([string]`$RepositoryRoot)`nAdd-Content -LiteralPath (Join-Path `$RepositoryRoot 'docs/guide.md') -Value 'written during verification'`nWrite-Output 'PASS  mutating validator'`nexit 0`n"
    $null = G $ux @('checkout', '--', 'docs/guide.md')
    $null = Save $ux 'add mutating validator'
    $r = Run $V @('-RepositoryRoot', $ux)
    $dr = Get-Content -Raw @(Get-Receipts $ux)[-1].FullName | ConvertFrom-Json -DateKind String
    Assert ($r.Code -eq 3 -and $r.Text -match 'BLOCKED\s+integrity:state-stable' -and $dr.status -eq 'BLOCKED') 'U5 a working tree changed during verification yields BLOCKED, never a PASS receipt'
    $null = G $ux @('checkout', '--', 'docs/guide.md')

    # -----------------------------------------------------------------
    # FIX1: higher levels never run less; uncovered changes upgrade to L3
    # -----------------------------------------------------------------
    $kx = New-Fixture 'coverage'
    Write-Text $kx 'tests/validate-sample.ps1' $sampleValidator
    Write-Text $kx 'tests/validate-extra.ps1' "param([string]`$RepositoryRoot)`nWrite-Output 'PASS  extra validator'`nexit 0`n"
    Write-Text $kx 'tests/validate-local-router-lr14-scope.ps1' $fakeGate
    Write-Text $kx 'tools/oss-workflow/tests/Test-OssWorkflowTools.ps1' "Write-Output 'OSS_WORKFLOW_TOOLS_SUMMARY PASS=1 FAIL=0'`nexit 0`n"
    Write-Text $kx '.github/workflows/ci.yml' $ciYml
    $k0 = Save $kx 'init'
    $null = G $kx @('update-ref', 'refs/remotes/origin/main', $k0)
    Write-Text $kx 'tools/oss-workflow/README.md' "# tools`n"
    $null = Save $kx 'tool change'
    $r = Run $V @('-RepositoryRoot', $kx, '-Level', 'L3')
    Assert ($r.Code -eq 0 -and $r.Text -match 'PASS\s+l3:workflow-tools-tests') 'K1 L3 runs the workflow-tool tests when the tools change'
    Write-Text $kx 'tests/validate-extra.ps1' "param([string]`$RepositoryRoot)`nWrite-Output 'PASS  extra validator v2'`nexit 0`n"
    $null = Save $kx 'extra validator change'
    $r = Run $V @('-RepositoryRoot', $kx, '-Level', 'L3')
    Assert ($r.Text -match 'PASS\s+l3:validator:validate-extra' -and $r.Text -notmatch 'l3:validator:validate-sample') 'K2 L3 adds a selected validator that ci.yml does not run (and does not repeat one it runs)'
    $p = Get-OwVerificationPlan @('local-router/src/Router.Unknown/Thing.cs') $kx $k0
    Assert ($p.recommended -eq 'L3' -and ($p.reasons -join ' ') -match 'not in the .NET project graph') 'K3 a project that cannot be resolved upgrades to L3'
    $p = Get-OwVerificationPlan @('tests/fixtures/orphan/data.json') $kx $k0
    Assert ($p.recommended -eq 'L3' -and ($p.reasons -join ' ') -match 'no validator references this fixture') 'K4 a fixture no validator references upgrades to L3'
    $p = Get-OwVerificationPlan @('tests/validate-removed.ps1') $kx $k0
    Assert ($p.recommended -eq 'L3' -and ($p.reasons -join ' ') -match 'validator itself was removed') 'K5 a removed validator upgrades to L3'
    $p = Get-OwVerificationPlan @('local-router/src/Router.ProviderAdapters.OpenAI/OpenAIProviderAdapter.cs') $RepositoryRoot (G $RepositoryRoot @('rev-parse', 'HEAD'))[0]
    Assert ($p.recommended -eq 'L2') 'K6 a real project with a covering test project stays L2'
    # FIX2: L4 never reuses either (clean checkout of the base tip).
    $null = G $kx @('update-ref', 'refs/remotes/origin/main', (G $kx @('rev-parse', 'HEAD'))[0])
    $r = Run $V @('-RepositoryRoot', $kx, '-Level', 'L4')
    Assert ($r.Code -eq 0 -and $r.Text -match 'level=L4' -and $r.Text -match 'status=PASS') 'N3 setup: L4 passes on a clean checkout of the base tip'
    $r = Run $V @('-RepositoryRoot', $kx, '-Level', 'L4', '-ReuseReceipt')
    $n3 = Get-Content -Raw @(Get-Receipts $kx)[-1].FullName | ConvertFrom-Json -DateKind String
    Assert ($r.Code -eq 0 -and $r.Text -match 'reuse: not permitted at L4' -and $r.Text -cnotmatch 'REUSED' -and $null -eq $n3.reused_from -and $null -ne $n3.historical_receipt -and @($n3.checks | Where-Object { $_.reused -ne $false }).Count -eq 0) 'N3 L4 with -ReuseReceipt executes everything again; the identical receipt is history only'

    # FIX2: the base reference or the tool fingerprint changing during a run is BLOCKED.
    $bx = New-Fixture 'base-drift'
    Write-Text $bx 'tests/validate-local-router-lr14-scope.ps1' $fakeGate
    $b0 = Save $bx 'init'
    $null = G $bx @('update-ref', 'refs/remotes/origin/main', $b0)
    Write-Text $bx 'tests/validate-move-base.ps1' "param([string]`$RepositoryRoot)`n& git -C `$RepositoryRoot update-ref refs/remotes/origin/main HEAD`nWrite-Output 'PASS  moved the base reference'`nexit 0`n"
    $null = Save $bx 'validator that moves the base'
    $r = Run $V @('-RepositoryRoot', $bx)
    $n4 = Get-Content -Raw @(Get-Receipts $bx)[-1].FullName | ConvertFrom-Json -DateKind String
    Assert ($r.Code -eq 3 -and $r.Text -match 'BLOCKED\s+integrity:state-stable' -and $r.Text -match 'base reference changed' -and $r.Text -match 'merge base changed' -and $n4.status -eq 'BLOCKED') 'N4 a base reference moved during verification yields BLOCKED'
    $copy = Join-Path $temp 'tool-copy'
    $null = New-Item -ItemType Directory -Path $copy
    Get-ChildItem $toolDir -File | Copy-Item -Destination $copy
    $tx = New-Fixture 'tool-drift'
    Write-Text $tx 'tests/validate-local-router-lr14-scope.ps1' $fakeGate
    $t0 = Save $tx 'init'
    $null = G $tx @('update-ref', 'refs/remotes/origin/main', $t0)
    Write-Text $tx 'tests/validate-touch-tool.ps1' "param([string]`$RepositoryRoot)`nSet-Content -LiteralPath (Join-Path `$env:OW_TEST_TOOL_COPY 'drift-marker.json') -Value '{}'`nWrite-Output 'PASS  touched the tool'`nexit 0`n"
    $null = Save $tx 'validator that changes the tool'
    $r = Run $V @('-RepositoryRoot', $tx) @{ OW_TEST_TOOL_COPY = $copy } $copy
    $n5 = Get-Content -Raw @(Get-Receipts $tx)[-1].FullName | ConvertFrom-Json -DateKind String
    Assert ($r.Code -eq 3 -and $r.Text -match 'BLOCKED\s+integrity:state-stable' -and $r.Text -match 'verification tool changed' -and $n5.status -eq 'BLOCKED') 'N5 a verification-tool change during verification yields BLOCKED'
    Assert (-not (Test-Path (Join-Path $toolDir 'drift-marker.json'))) 'N5 the real tool directory was not touched'

    # =====================================================================
    # C. LR-14 candidate generator
    # =====================================================================
    $C = 'New-Lr14RegistrationCandidate.ps1'
    $gx = New-Fixture 'lr14'
    Write-Text $gx 'tests/validate-local-router-lr14-scope.ps1' $fakeGate
    Write-Text $gx 'src/a.txt' "alpha`n"
    Write-Text $gx 'src/b.txt' "bravo`n"
    Write-Text $gx 'docs/untouched.md' "# untouched`n"
    $g0 = Save $gx 'init'
    Write-Text $gx 'src/a.txt' "alpha`nthis unique marker line belongs to slice one`n"
    Write-Text $gx 'src/c.txt' "charlie file added by the slice with a long line`n"
    Remove-Item (Join-Path $gx 'src/b.txt')
    $g1 = Save $gx 'impl one'
    $gateText = $fakeGate.Replace("`$script:RegisteredSlices = @(`n)", "`$script:RegisteredSlices = @(`n    [pscustomobject]@{`n        Name      = `"EXISTING-SLICE`"`n        Base      = `"$g0`"`n        Tip       = `"$g1`"`n        Artifacts = @(`n            `"src/a.txt`")`n        Markers   = @{`n            `"src/a.txt`" = `"this unique marker line`"`n        }`n    }`n)")
    Write-Text $gx 'tests/validate-local-router-lr14-scope.ps1' $gateText
    $g2 = Save $gx 'register one'
    Write-Text $gx 'src/a.txt' "alpha`nthis unique marker line belongs to slice one`nsecond slice adds this distinctive line`n"
    Write-Text $gx 'src/short.txt' "a`nb`n"
    $g3 = Save $gx 'impl two'
    $null = G $gx @('update-ref', 'refs/remotes/origin/main', $g0)
    $gateHash = Get-OwSha256File (Join-Path $gx 'tests/validate-local-router-lr14-scope.ps1')

    $r = Run $C @('-RepositoryRoot', $gx, '-Tip', $g1)
    $j = $r.Text | ConvertFrom-Json
    Assert ($r.Code -eq 0 -and $j.status -eq 'CANDIDATE_NOT_REGISTERED' -and $j.base -eq $g0 -and $j.base_reason -eq 'root commit') 'C1 base is inferred from real history (root)'
    Assert ((@($j.artifacts) -join ',') -eq 'src/a.txt,src/c.txt' -and (@($j.deleted_files) -join ',') -eq 'src/b.txt') 'C1 artifacts are the files changed and present at the tip; deletions are listed apart'
    Assert ($j.markers.'src/a.txt' -eq 'this unique marker line belongs to slice one' -and @($j.marker_details | Where-Object { $_.path -eq 'src/a.txt' })[0].source -eq 'added-line') 'C1 markers are real added lines with their provenance'
    Assert (@($j.warnings) -join ' ' -match 'already registered as EXISTING-SLICE') 'C1 an already registered range is reported'
    $r = Run $C @('-RepositoryRoot', $gx, '-Tip', $g3, '-Name', 'NEW-SLICE')
    $j = $r.Text | ConvertFrom-Json
    Assert ($r.Code -eq 0 -and $j.base -eq $g2 -and $j.base_reason -match 'registration commit') 'C2 base stops at the nearest registration commit'
    Assert ($null -eq $j.markers.'src/short.txt' -and @($j.warnings) -join ' ' -match "no mechanical marker for 'src/short.txt'" -and $null -eq $j.entry_preview) 'C3 no marker is invented when no added line qualifies'
    Assert ((Get-OwSha256File (Join-Path $gx 'tests/validate-local-router-lr14-scope.ps1')) -eq $gateHash -and (G $gx @('rev-parse', 'HEAD'))[0] -eq $g3 -and (G $gx @('status', '--porcelain')).Count -eq 0) 'C4 the generator changes no file, makes no commit and leaves the tree clean'
    $neg = [ordered]@{
        'INVALID_REVISION (garbage)'       = @(@('-Tip', 'zzzz'), 'INVALID_REVISION')
        'INVALID_REVISION (unknown sha)'   = @(@('-Tip', ('0123456789abcdef' * 3).Substring(0, 40)), 'INVALID_REVISION')
        'WRONG_ANCESTRY (reversed range)'  = @(@('-Base', $g3, '-Tip', $g1), 'WRONG_ANCESTRY')
        'WRONG_ANCESTRY (empty range)'     = @(@('-Base', $g1, '-Tip', $g1), 'WRONG_ANCESTRY')
        'OUT_OF_RANGE_FILE'                = @(@('-Base', $g0, '-Tip', $g1, '-Artifact', 'docs/untouched.md'), 'OUT_OF_RANGE_FILE')
        'MISSING_ARTIFACT'                 = @(@('-Base', $g0, '-Tip', $g1, '-Artifact', 'src/b.txt'), 'MISSING_ARTIFACT')
        'WRONG_MARKER'                     = @(@('-Base', $g0, '-Tip', $g1, '-Marker', 'src/a.txt=text that is not in the file'), 'WRONG_MARKER')
        'DUPLICATE_NAME'                   = @(@('-Tip', $g3, '-Name', 'EXISTING-SLICE'), 'DUPLICATE_NAME')
    }
    foreach ($k in $neg.Keys) {
        $r = Run $C (@('-RepositoryRoot', $gx) + $neg[$k][0])
        Assert ($r.Code -eq 2 -and $r.Text -match "REFUSED code=$($neg[$k][1])") "C5 refuses: $k"
    }
    Write-Text $gx 'src/a.txt' "dirty`n"
    $r = Run $C @('-RepositoryRoot', $gx, '-Tip', $g3)
    Assert ($r.Code -eq 2 -and $r.Text -match 'REFUSED code=DIRTY_WORKTREE') 'C5 refuses: DIRTY_WORKTREE'
    $null = G $gx @('checkout', '--', 'src/a.txt')
    $r = Run $C @('-RepositoryRoot', $gx, '-Base', $g0, '-Tip', $g1, '-Marker', 'src/a.txt=alpha')
    Assert ($r.Code -eq 0 -and @(($r.Text | ConvertFrom-Json).warnings) -join ' ' -match 'pre-existing content') 'C6 a given marker from pre-existing content is flagged for the reviewer'
    $mfile = Join-Path $temp 'markers-ok.json'
    [IO.File]::WriteAllText($mfile, (@{ 'src/a.txt' = 'this unique marker line belongs to slice one'; 'src/c.txt' = 'charlie file added' } | ConvertTo-Json))
    $r = Run $C @('-RepositoryRoot', $gx, '-Base', $g0, '-Tip', $g1, '-MarkersFile', $mfile)
    $j = $r.Text | ConvertFrom-Json
    Assert ($r.Code -eq 0 -and $j.markers.'src/c.txt' -eq 'charlie file added' -and @($j.marker_details | Where-Object { $_.source -eq 'given' }).Count -eq 2) 'C6 reviewed markers from a markers file are validated and used'
    [IO.File]::WriteAllText($mfile, (@{ 'src/a.txt' = 'not present anywhere' } | ConvertTo-Json))
    $r = Run $C @('-RepositoryRoot', $gx, '-Base', $g0, '-Tip', $g1, '-MarkersFile', $mfile)
    Assert ($r.Code -eq 2 -and $r.Text -match 'REFUSED code=WRONG_MARKER') 'C6 a wrong marker in a markers file is refused'
    [IO.File]::WriteAllText($mfile, (@{ 'docs/untouched.md' = 'untouched' } | ConvertTo-Json))
    $r = Run $C @('-RepositoryRoot', $gx, '-Base', $g0, '-Tip', $g1, '-MarkersFile', $mfile)
    Assert ($r.Code -eq 2 -and $r.Text -match 'REFUSED code=OUT_OF_RANGE_FILE') 'C6 a marker for a file outside the range is refused'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $toolDir $C), [ref]$null, [ref]$null)
    $params = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $src = Get-Content -Raw (Join-Path $toolDir $C)
    Assert (-not ($params | Where-Object { $_ -match '(?i)apply|commit|register|approve|write' }) -and $src -notmatch "'commit'|'push'|Set-Content|Add-Content|Out-File") 'C7 the generator has no apply, register, approve or commit capability'

    # Field-level reproduction of real registrations (clean clone, read-only).
    $clone = Join-Path $temp 'repo-clone'
    $null = G $temp @('clone', '-q', '--no-local', $RepositoryRoot, $clone)
    $srcMain = Invoke-OwGit -Root $RepositoryRoot -Arguments @('rev-parse', '--verify', '--quiet', 'refs/remotes/origin/main^{commit}') -AllowFailure
    if ($srcMain.Code -eq 0) { $null = G $clone @('update-ref', 'refs/remotes/origin/main', $srcMain.Lines[0]) }
    $reg = Get-OwLr14Registry $clone
    $reproduced = 0
    foreach ($s in $reg.Slices) {
        if ((Invoke-OwGit -Root $clone -Arguments @('cat-file', '-e', "$($s.Tip)^{commit}") -AllowFailure).Code -ne 0) { continue }
        $r = Run $C @('-RepositoryRoot', $clone, '-Tip', $s.Tip)
        if ($r.Code -ne 0) { Fail "C8 $($s.Name): generator refused ($($r.Text))"; continue }
        $j = $r.Text | ConvertFrom-Json
        $artOk = ((@($j.artifacts) | Sort-Object) -join '|') -ceq ((@($s.Artifacts) | Sort-Object) -join '|')
        $markerOk = $true; $markerAdded = 0
        foreach ($k in $s.Markers.Keys) {
            $content = (G $clone @('show', "$($s.Tip):$k")) -join "`n"
            if (-not $content.Contains([string]$s.Markers[$k])) { $markerOk = $false }
            $added = (G $clone @('diff', '-U0', $s.Base, $s.Tip, '--', $k)) -join "`n"
            if ($added.Contains([string]$s.Markers[$k])) { $markerAdded++ }
        }
        Assert ($j.base -ceq $s.Base -and $j.tip -ceq $s.Tip -and $artOk -and $markerOk) ("C8 {0}: base inferred={1} tip={2} artifacts {3}/{4} reproduced; registered markers present at tip ({5}/{6} in added lines)" -f $s.Name, ($j.base -ceq $s.Base), ($j.tip -ceq $s.Tip), @($j.artifacts).Count, @($s.Artifacts).Count, $markerAdded, $s.Markers.Count)
        if ($j.base -ceq $s.Base -and $artOk -and $markerOk) { $reproduced++ }
    }
    Assert ($reproduced -ge 4) "C8 at least four real registrations are reproduced field by field ($reproduced); name, comment and marker text are reviewer choices and are not claimed as reproduced"

    # =====================================================================
    # D. Identity privacy gate
    # =====================================================================
    $P = 'Test-CommitIdentityPrivacy.ps1'
    $px = New-Fixture 'privacy'
    Write-Text $px 'f.txt' "0`n"; $p0 = Save $px 'init'
    Write-Text $px 'f.txt' "1`n"; $p1 = Save $px 'approved change'
    $cfgHash = Get-OwSha256File (Join-Path $px '.git/config')
    $hooks = @(Get-ChildItem (Join-Path $px '.git/hooks') -File | ForEach-Object Name) -join ','
    $r = Run $P @('-RepositoryRoot', $px, '-BaseRef', $p0)
    Assert ($r.Code -eq 0 -and $r.Text -match 'PRIVACY_GATE PASS commits=1 failures=0') 'D1 approved identities pass'
    $null = G $px @('switch', '-q', '-c', 'bad-author', $p1); Write-Text $px 'f.txt' "2`n"; $null = Save $px 'bad author' $badName $badMail
    $r = Run $P @('-RepositoryRoot', $px, '-BaseRef', $p1, '-HeadRef', 'bad-author')
    Assert ($r.Code -eq 1 -and $r.Text -match 'FAIL .* author\s+not-approved' -and (No-Leak $r.Text)) 'D2 an unapproved author fails without printing the identity'
    $null = G $px @('switch', '-q', '-c', 'bad-committer', $p1); Write-Text $px 'f.txt' "3`n"; $null = Save $px 'bad committer' $okName $okMail $badName $badMail
    $r = Run $P @('-RepositoryRoot', $px, '-BaseRef', $p1, '-HeadRef', 'bad-committer')
    Assert ($r.Code -eq 1 -and $r.Text -match 'committer\s+not-approved' -and $r.Text -match 'author\s+project-noreply' -and (No-Leak $r.Text)) 'D3 an unapproved committer fails on its own'
    $null = G $px @('switch', '-q', '-c', 'github-nonmerge', $p1); Write-Text $px 'f.txt' "4`n"; $null = Save $px 'web edit' $okName $okMail 'GitHub' 'noreply@github.com'
    $r = Run $P @('-RepositoryRoot', $px, '-BaseRef', $p1, '-HeadRef', 'github-nonmerge')
    Assert ($r.Code -eq 1 -and $r.Text -match 'committer\s+not-approved') 'D4 the GitHub committer is rejected on a non-merge commit'
    $null = G $px @('switch', '-q', '-c', 'side', $p1); Write-Text $px 's.txt' "side`n"; $null = Save $px 'side'
    $null = G $px @('switch', '-q', '-c', 'github-merge', $p1); Write-Text $px 'm.txt' "main`n"; $null = Save $px 'main side'
    $old = @{ n = $env:GIT_COMMITTER_NAME; e = $env:GIT_COMMITTER_EMAIL }
    try { $env:GIT_COMMITTER_NAME = 'GitHub'; $env:GIT_COMMITTER_EMAIL = 'noreply@github.com'; $null = G $px @('merge', '-q', '--no-ff', '--no-edit', 'side') } finally { $env:GIT_COMMITTER_NAME = $old.n; $env:GIT_COMMITTER_EMAIL = $old.e }
    $r = Run $P @('-RepositoryRoot', $px, '-BaseRef', $p1, '-HeadRef', 'github-merge')
    Assert ($r.Code -eq 0 -and $r.Text -match 'committer\s+github-web-merge') 'D4 the GitHub committer is accepted only on a merge by an approved author'
    $null = G $px @('switch', '-q', '-c', 'bad-message', $p1); Write-Text $px 'f.txt' "5`n"; $null = Save $px "fix`n`nReported-by: $badMail"
    $r = Run $P @('-RepositoryRoot', $px, '-BaseRef', $p1, '-HeadRef', 'bad-message')
    Assert ($r.Code -eq 1 -and $r.Text -match 'message\s+unapproved-address-count=1' -and (No-Leak $r.Text)) 'D5 an unapproved address in a commit message fails without printing it'
    $null = G $px @('switch', '-q', 'main')
    $r = Run $P @('-RepositoryRoot', $px, '-BaseRef', $p0) @{ GIT_AUTHOR_NAME = $badName; GIT_AUTHOR_EMAIL = $badMail }
    Assert ($r.Code -eq 1 -and $r.Text -match 'env-author\s+not-approved' -and (No-Leak $r.Text)) 'D6 an unapproved GIT_AUTHOR_* override fails'
    $null = G $px @('config', 'user.email', $badMail)
    $r = Run $P @('-RepositoryRoot', $px, '-BaseRef', $p0)
    Assert ($r.Code -eq 1 -and $r.Text -match 'git-config\s+not-approved' -and (No-Leak $r.Text)) 'D7 an unapproved local Git identity fails'
    $r = Run $P @('-RepositoryRoot', $px, '-BaseRef', $p0, '-Json')
    Assert ($r.Code -eq 1 -and (No-Leak $r.Text) -and ($r.Text | ConvertFrom-Json).status -eq 'FAIL') 'D7 the JSON output withholds identity values'
    $null = G $px @('config', 'user.email', $okMail)
    $r = Run $P @('-RepositoryRoot', $px, '-BaseRef', 'no-such-ref')
    Assert ($r.Code -eq 2 -and $r.Text -match 'PRIVACY_GATE BLOCKED') 'D8 an unusable base blocks instead of passing'
    $null = G $px @('config', 'user.email', $okMail)
    Assert ((Get-OwSha256File (Join-Path $px '.git/config')) -eq $cfgHash) 'D9 the fixture identity is restored before the no-write checks'
    $r = Run $P @('-RepositoryRoot', $px, '-BaseRef', $p0)
    Assert ((@(Get-ChildItem (Join-Path $px '.git/hooks') -File | ForEach-Object Name) -join ',') -eq $hooks) 'D9 the gate installs no Git hook'
    $before = Get-OwSha256File (Join-Path $px '.git/config'); $null = Run $P @('-RepositoryRoot', $px, '-BaseRef', $p0); Assert ((Get-OwSha256File (Join-Path $px '.git/config')) -eq $before) 'D9 the gate never changes Git configuration'
    # Code tokens only (comments excluded): no credential access and no Git config writes.
    $codeText = (Get-ChildItem $toolDir -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') } | ForEach-Object {
            $tk = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tk, [ref]$null)
            @($tk | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '
        }) -join "`n"
    $configWrites = [regex]::Matches($codeText, "'config'\s*,\s*'(?!--get\b)[^']+'").Count
    Assert ($codeText -notmatch '(?i)auth\.json|credential|gh\s+auth|hooksPath|--global' -and $configWrites -eq 0) "D10 the tools access no credentials or auth.json and every git config call is a read (--get); writes found: $configWrites"
    $r = Run $E @('-RepositoryRoot', $px, '-BaseRef', $p0)
    $null = G $px @('switch', '-q', 'bad-author')
    $r = Run $E @('-RepositoryRoot', $px, '-BaseRef', $p1)
    Assert ($r.Text -match '结果：\*\*FAIL' -and (No-Leak $r.Text)) 'E5 the evidence report shows a privacy FAIL without the identity'

    # =====================================================================
    # P. CI commit-range mode (OSS-M4-2): exactly the commits an event introduces
    # =====================================================================
    $cx = New-Fixture 'ci-range'
    Write-Text $cx 'f.txt' "0`n"; $q0 = Save $cx 'init'
    Write-Text $cx 'f.txt' "1`n"; $q1 = Save $cx 'main one'
    Write-Text $cx 'f.txt' "2`n"; $q2 = Save $cx 'main two'
    $null = G $cx @('switch', '-q', '-c', 'pr', $q0)
    Write-Text $cx 'p.txt' "p1`n"; $null = Save $cx 'pr one'
    Write-Text $cx 'p.txt' "p2`n"; $p2 = Save $cx 'pr two'
    # GitHub-style synthetic merge of the PR into main, made by an unapproved identity: never in range.
    $old = @{ n = $env:GIT_COMMITTER_NAME; e = $env:GIT_COMMITTER_EMAIL }
    try { $env:GIT_COMMITTER_NAME = $badName; $env:GIT_COMMITTER_EMAIL = $badMail; $synthetic = (G $cx @('-c', "user.name=$badName", '-c', "user.email=$badMail", 'commit-tree', "$p2^{tree}", '-p', $q2, '-p', $p2, '-m', 'Merge pr into main'))[0] } finally { Set-OwEnvironmentVariable 'GIT_COMMITTER_NAME' $old.n; Set-OwEnvironmentVariable 'GIT_COMMITTER_EMAIL' $old.e }
    $null = G $cx @('switch', '-q', '--detach', $synthetic)
    function Write-Event([string]$Name, [object]$Body) { $f = Join-Path $temp ("event-$Name-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json'); [IO.File]::WriteAllText($f, ($Body | ConvertTo-Json -Depth 5)); return $f }
    function RunCi([string]$Root, [string]$EventName, [string]$EventFile, [hashtable]$Env = @{}) { return (Run $P @('-RepositoryRoot', $Root, '-CommitRangeFromGitHubEvent', '-EventName', $EventName, '-EventPath', $EventFile) $Env) }
    $prEvent = Write-Event 'pr' @{ pull_request = @{ base = @{ sha = $q2 }; head = @{ sha = $p2 } } }
    $r = RunCi $cx 'pull_request' $prEvent
    Assert ($r.Code -eq 0 -and $r.Text -match 'PRIVACY_GATE PASS commits=2 failures=0' -and $r.Text -match 'mode=ci-commit-range event=pull_request' -and $r.Text -notmatch $synthetic.Substring(0, 12) -and (No-Leak $r.Text)) 'P1 pull_request checks exactly base.sha..head.sha, never the synthetic merge commit'
    $null = G $cx @('switch', '-q', '-c', 'pr-bad', $p2); Write-Text $cx 'p.txt' "bad`n"; $pb = Save $cx 'bad pr commit' $badName $badMail
    $r = RunCi $cx 'pull_request' (Write-Event 'prbad' @{ pull_request = @{ base = @{ sha = $q2 }; head = @{ sha = $pb } } })
    Assert ($r.Code -eq 1 -and $r.Text -match 'author\s+not-approved' -and (No-Leak $r.Text)) 'P2 an unapproved commit inside the pull request range fails without printing the identity'
    $null = G $cx @('switch', '-q', '--detach', $q2)
    $r = RunCi $cx 'push' (Write-Event 'push' @{ before = $q0; after = $q2 })
    Assert ($r.Code -eq 0 -and $r.Text -match 'PRIVACY_GATE PASS commits=2' -and $r.Text -match 'event=push') 'P3 push checks exactly before..after'
    $r = RunCi $cx 'push' (Write-Event 'pushmismatch' @{ before = $q0; after = $q1 })
    Assert ($r.Code -eq 2 -and $r.Text -match 'code=HEAD_MISMATCH') 'P4 a push whose after is not the checked-out HEAD is BLOCKED'
    $r = RunCi $cx 'push' (Write-Event 'pushzero' @{ before = ('0' * 40); after = $q2 })
    Assert ($r.Code -eq 2 -and $r.Text -match 'code=NEW_REF_NO_BASE') 'P5 an all-zero before is BLOCKED instead of trusting the whole history'
    $r = RunCi $cx 'push' (Write-Event 'pushempty' @{ before = $q2; after = $q2 })
    Assert ($r.Code -eq 2 -and $r.Text -match 'code=EMPTY_RANGE' -and $r.Text -notmatch 'PRIVACY_GATE PASS') 'P6 an empty range (base already at HEAD) is BLOCKED, never a PASS'
    $r = RunCi $cx 'pull_request' (Write-Event 'prmissing' @{ pull_request = @{ base = @{ sha = ('1234567890abcdef' * 3).Substring(0, 40) }; head = @{ sha = $p2 } } })
    Assert ($r.Code -eq 2 -and $r.Text -match 'code=MISSING_RANGE_COMMIT') 'P7 a range commit missing from the checkout is BLOCKED'
    $r = Run $P @('-RepositoryRoot', $cx, '-CommitRangeFromGitHubEvent', '-EventName', '', '-EventPath', '')
    Assert ($r.Code -eq 2 -and $r.Text -match 'code=NO_GITHUB_EVENT') 'P8 commit-range mode without a GitHub event is BLOCKED'
    $r = RunCi $cx 'issues' (Write-Event 'issues' @{ action = 'opened' })
    Assert ($r.Code -eq 2 -and $r.Text -match 'code=UNSUPPORTED_EVENT') 'P9 an unsupported event is BLOCKED'
    # GitHub web merge on main: approved author, GitHub committer, a real merge.
    $null = G $cx @('switch', '-q', '-C', 'main', $q2)
    $old = @{ n = $env:GIT_COMMITTER_NAME; e = $env:GIT_COMMITTER_EMAIL }
    try { $env:GIT_COMMITTER_NAME = 'GitHub'; $env:GIT_COMMITTER_EMAIL = 'noreply@github.com'; $null = G $cx @('-c', "user.name=$okName", '-c', "user.email=$okMail", 'merge', '-q', '--no-ff', '--no-edit', 'pr') } finally { Set-OwEnvironmentVariable 'GIT_COMMITTER_NAME' $old.n; Set-OwEnvironmentVariable 'GIT_COMMITTER_EMAIL' $old.e }
    $webMerge = (G $cx @('rev-parse', 'HEAD'))[0]
    $r = RunCi $cx 'push' (Write-Event 'pushmerge' @{ before = $q2; after = $webMerge })
    Assert ($r.Code -eq 0 -and $r.Text -match 'PRIVACY_GATE PASS commits=3' -and $r.Text -match 'committer\s+github-web-merge') 'P10 a push of a GitHub web merge checks the merge and the merged commits'
    $r = RunCi $cx 'workflow_dispatch' (Write-Event 'dispatch' @{ ref = 'refs/heads/main' })
    Assert ($r.Code -eq 0 -and $r.Text -match 'PRIVACY_GATE PASS commits=3' -and $r.Text -match 'event=workflow_dispatch') 'P11 workflow_dispatch checks the commits introduced by HEAD'
    $null = G $cx @('switch', '-q', '--detach', $q0)
    $r = RunCi $cx 'schedule' (Write-Event 'schedule' @{ schedule = '17 3 * * 1' })
    Assert ($r.Code -eq 2 -and $r.Text -match 'code=MISSING_RANGE_COMMIT') 'P11 a scheduled run on a root commit is BLOCKED (no introduced range)'
    $null = G $cx @('switch', '-q', 'main')
    # Boundary: CI history mode never evaluates, and never vouches for, the local identity.
    $null = G $cx @('config', 'user.email', $badMail)
    $pushMergeEvent = Write-Event 'pushmerge2' @{ before = $q2; after = $webMerge }
    $r = RunCi $cx 'push' $pushMergeEvent
    Assert ($r.Code -eq 0 -and $r.Text -match 'NOTE  local Git identity not checked in commit-range mode' -and $r.Text -notmatch 'git-config' -and (No-Leak $r.Text)) 'P12 commit-range mode leaves the local identity out and says so'
    $r = Run $P @('-RepositoryRoot', $cx, '-BaseRef', $q2) @{ GITHUB_EVENT_NAME = 'push'; GITHUB_EVENT_PATH = $pushMergeEvent; GITHUB_ACTIONS = 'true' }
    Assert ($r.Code -eq 1 -and $r.Text -match 'git-config\s+not-approved' -and (No-Leak $r.Text)) 'P12 GitHub environment variables alone never switch off the local identity check'
    $r = Run $P @('-RepositoryRoot', $cx, '-CommitRangeFromGitHubEvent', '-EventName', 'push', '-EventPath', $pushMergeEvent, '-Json')
    $pj = $r.Text | ConvertFrom-Json
    Assert ($pj.mode -eq 'ci-commit-range' -and $pj.local_identity -match 'not checked' -and $pj.status -eq 'PASS' -and (No-Leak $r.Text)) 'P13 JSON output states the mode and that the local identity was not checked'
    $null = G $cx @('config', 'user.email', $okMail)

    # =====================================================================
    # M. Mirror drift locator (OSS-M4-2): rules come from the existing validators
    # =====================================================================
    $M = 'Test-MirrorParity.ps1'
    $mx = New-Fixture 'mirror'
    $mirrorFiles = @('tests/validate-stealth-registry.ps1', 'tests/validate-health-check.ps1', 'tests/validate-profile-v2.ps1')
    foreach ($n in @('sync-stealth-registry.ps1', 'record-stealth-reveal.ps1', 'launch-stealth-model.ps1', 'stealth-model-center.ps1', 'health-check.ps1', 'migrate-profile-v2.ps1')) { $mirrorFiles += "installer/scripts/$n"; $mirrorFiles += "skill/codex-multimodel-manager/scripts/$n" }
    foreach ($f in $mirrorFiles) { $dst = Join-Path $mx $f; $null = New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent); Copy-Item -LiteralPath (Join-Path $RepositoryRoot $f) -Destination $dst }
    $null = Save $mx 'mirror fixture'
    $r = Run $M @('-RepositoryRoot', $mx)
    Assert ($r.Code -eq 0 -and $r.Text -match 'MIRROR_PARITY status=PASS pairs=6 drift=0') 'M1 the six declared mirror pairs are read from the existing validators and found identical'
    $stealth = Join-Path $mx 'skill/codex-multimodel-manager/scripts/launch-stealth-model.ps1'
    $lines = [IO.File]::ReadAllLines($stealth); $lines[2] = $lines[2] + ' # drift'; [IO.File]::WriteAllLines($stealth, $lines)
    $r = Run $M @('-RepositoryRoot', $mx)
    Assert ($r.Code -eq 1 -and $r.Text -match 'MIRROR DRIFT  installer/scripts/launch-stealth-model\.ps1 <-> skill/codex-multimodel-manager/scripts/launch-stealth-model\.ps1 \[sha256' -and $r.Text -match 'first difference at line 3' -and $r.Text -match 'skill    : .*# drift') 'M2 a drifted copy fails with the exact pair and first differing line'
    $null = G $mx @('checkout', '--', '.')
    # Toggle the line endings of one copy per pair (CRLF <-> LF), nothing else.
    function Switch-LineEndings([string]$Path) {
        $t = [IO.File]::ReadAllText($Path)
        $n = if ($t.Contains("`r`n")) { $t.Replace("`r`n", "`n") } else { $t.Replace("`n", "`r`n") }
        [IO.File]::WriteAllText($Path, $n)
        return ($n -cne $t)
    }
    $hc = Join-Path $mx 'skill/codex-multimodel-manager/scripts/health-check.ps1'
    $pv = Join-Path $mx 'skill/codex-multimodel-manager/scripts/migrate-profile-v2.ps1'
    Assert ((Switch-LineEndings $hc) -and (Switch-LineEndings $pv)) 'M3 fixture: the line endings of both copies really changed'
    $r = Run $M @('-RepositoryRoot', $mx)
    Assert ($r.Text -match 'MIRROR IDENTICAL  installer/scripts/health-check\.ps1' -and $r.Text -match 'migrate-profile-v2\.ps1 \[text; .* same lines, bytes differ' -and $r.Code -eq 1) 'M3 each pair keeps its own validator rule (health-check ignores line endings, profile-v2 does not)'
    $null = G $mx @('checkout', '--', '.')
    Remove-Item (Join-Path $mx 'skill/codex-multimodel-manager/scripts/record-stealth-reveal.ps1')
    $r = Run $M @('-RepositoryRoot', $mx)
    Assert ($r.Code -eq 1 -and $r.Text -match 'record-stealth-reveal\.ps1 \[sha256; .*missing skill/codex-multimodel-manager/scripts/record-stealth-reveal\.ps1') 'M4 a missing mirror copy is reported as drift'
    $null = G $mx @('checkout', '--', '.')
    $sr = Join-Path $mx 'tests/validate-stealth-registry.ps1'
    $orig = [IO.File]::ReadAllText($sr)
    [IO.File]::WriteAllText($sr, ($orig -replace '(?s)\$shared = @\(.*?\)', '$shared = @(Get-ChildItem -Name)'))
    $r = Run $M @('-RepositoryRoot', $mx)
    Assert ($r.Code -eq 2 -and $r.Text -match 'MIRROR_PARITY status=BLOCKED code=MIRROR_RULES_UNREADABLE') 'M5 a mirror list that is not a constant is BLOCKED, never guessed'
    Remove-Item (Join-Path $mx 'tests/validate-profile-v2.ps1')
    [IO.File]::WriteAllText($sr, $orig)
    $r = Run $M @('-RepositoryRoot', $mx)
    Assert ($r.Code -eq 2 -and $r.Text -match 'validate-profile-v2\.ps1 is missing') 'M5 a missing parity validator is BLOCKED'
    $null = G $mx @('checkout', '--', '.')
    $before = (G $mx @('status', '--porcelain')).Count
    $null = Run $M @('-RepositoryRoot', $mx)
    Assert ($before -eq 0 -and (G $mx @('status', '--porcelain')).Count -eq 0) 'M6 the locator is read-only (no file is fixed, synced or written)'
    $src = Get-Content -Raw (Join-Path $toolDir $M)
    Assert ($src -notmatch "(?i)'(commit|push|add)'|Set-Content|Add-Content|Out-File|WriteAll|Copy-Item|Move-Item|Remove-Item") 'M6 the locator has no write, sync, commit or push path'

    # =====================================================================
    # W. Workflow structure (OSS-M4-2): real .github/workflows files
    # =====================================================================
    $baselineCommit = 'd3648a3f5f9b58fb8e28a6b8ce9770406055a67a'
    $ciText = [IO.File]::ReadAllText((Join-Path $RepositoryRoot '.github/workflows/ci.yml'))
    $steps = @(Get-OwWorkflowSteps $RepositoryRoot)
    Assert ($steps.Count -eq ([regex]::Matches($ciText, '(?m)^\s+- name:')).Count -and $ciText -notmatch "`t") 'W1 ci.yml: every step is parsed and no tab characters are used'
    Assert (@($steps | Where-Object { [bool]$_.run -eq [bool]$_.uses }).Count -eq 0) 'W1 ci.yml: every step has exactly one of run or uses'
    Assert (@($steps | Where-Object { $_.uses -and $_.uses -notmatch '@[0-9a-f]{40}(\s|$)' }).Count -eq 0) 'W1 ci.yml: every action is pinned to a full commit SHA'
    Assert (@($steps | Where-Object { $_.run -and $_.run.Contains('${{') }).Count -eq 0) 'W1 ci.yml: no step interpolates a GitHub expression into a run script'
    $baseYml = (G $RepositoryRoot @('show', "${baselineCommit}:.github/workflows/ci.yml")) -join "`n"
    $baseDir = Join-Path $temp 'baseline-ci'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $baseDir '.github/workflows')
    [IO.File]::WriteAllText((Join-Path $baseDir '.github/workflows/ci.yml'), $baseYml + "`n")
    $baseSteps = @(Get-OwWorkflowSteps $baseDir)
    $prefixOk = $baseSteps.Count -gt 0 -and $steps.Count -ge $baseSteps.Count
    for ($i = 0; $prefixOk -and $i -lt $baseSteps.Count; $i++) {
        foreach ($k in @('name', 'run', 'uses', 'shell', 'condition')) { if ([string]$steps[$i].$k -cne [string]$baseSteps[$i].$k) { $prefixOk = $false } }
    }
    Assert $prefixOk "W2 all $($baseSteps.Count) steps defined at $($baselineCommit.Substring(0, 7)) are an unchanged, in-order prefix of ci.yml"
    $headerNow = ($ciText.Replace("`r`n", "`n") -split "`n      - name:")[0]
    $headerBase = ($baseYml.Replace("`r`n", "`n") -split "`n      - name:")[0]
    Assert ($headerNow -ceq $headerBase) 'W2 triggers, permissions, concurrency, job name, runner and timeout are unchanged'
    $added = @($steps | Select-Object -Skip $baseSteps.Count | ForEach-Object { $_.name })
    Assert (($added -join '|') -ceq 'Run commit identity privacy validation|Run model candidate intake validation|Run OSS workflow tools regression') "W2 exactly the three OSS-M4-2 steps are appended ($($added.Count))"
    Assert ($ciText.Contains('./tools/oss-workflow/Test-CommitIdentityPrivacy.ps1 -RepositoryRoot $PWD -CommitRangeFromGitHubEvent') -and $ciText -notmatch '(?m)^\s+continue-on-error\s*:') 'W2 the identity step uses the explicit commit-range mode and no step sets continue-on-error'
    $mdPath = Join-Path $RepositoryRoot '.github/workflows/mirror-drift.yml'
    $md = [IO.File]::ReadAllText($mdPath)
    $mdDir = Join-Path $temp 'mirror-wf'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $mdDir '.github/workflows')
    Copy-Item $mdPath (Join-Path $mdDir '.github/workflows/ci.yml')
    $mdSteps = @(Get-OwWorkflowSteps $mdDir)
    $mdOn = ([regex]::Match($md.Replace("`r`n", "`n"), '(?ms)^on:\n(.*?)\n\S')).Groups[1].Value
    Assert ($mdOn -match '(?m)^  schedule:' -and $mdOn -match '(?m)^  workflow_dispatch:' -and $mdOn -notmatch '(?m)^  (push|pull_request)') 'W3 mirror-drift runs weekly and on manual dispatch only'
    Assert ($md -match '(?m)^permissions:\n?\s+contents: read\s*$' -and $md -notmatch '(?i):\s*write\b' -and $md -notmatch 'secrets\.') 'W3 mirror-drift is read-only (contents: read, no write permission, no secrets)'
    $ciCheckout = @($steps | Where-Object { $_.uses -like 'actions/checkout@*' })[0].uses
    Assert (@($mdSteps | Where-Object { $_.uses }).Count -eq 1 -and @($mdSteps | Where-Object { $_.uses })[0].uses -ceq $ciCheckout -and $md -match 'persist-credentials: false') 'W3 mirror-drift uses the same pinned checkout without persisted credentials'
    $mdRuns = @($mdSteps | Where-Object { $_.run } | ForEach-Object { $_.run })
    Assert (($mdRuns -join '|') -ceq './tools/oss-workflow/Test-MirrorParity.ps1 -RepositoryRoot $PWD|./tests/validate-stealth-registry.ps1 -RepositoryRoot $PWD|./tests/validate-health-check.ps1 -RepositoryRoot $PWD|./tests/validate-profile-v2.ps1 -RepositoryRoot $PWD') 'W3 mirror-drift runs only the locator and the three existing parity validators'
    Assert ($md -notmatch '(?i)git\s+(push|commit)|gh\s|curl|Invoke-WebRequest' -and $md -match 'timeout-minutes:') 'W3 mirror-drift never pushes, commits or calls external services, and has a timeout'
}
catch {
    Fail ("unexpected error: " + (ConvertTo-OwSafeText $_.Exception.Message $temp) + ' @ ' + $_.InvocationInfo.ScriptLineNumber)
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ("OSS_WORKFLOW_TOOLS_SUMMARY PASS={0} FAIL={1}" -f $script:Passes, $script:Failures.Count)
if ($script:Failures.Count -gt 0) { exit 1 }
Write-Output 'OSS workflow tools validation PASSED'
exit 0
