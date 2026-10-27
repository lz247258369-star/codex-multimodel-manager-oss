param([string]$RepositoryRoot = (Get-Location).Path)
# OSS-GENESIS: the LR-14 scope gate's genesis mode on real clones of this
# repository. The gate under test is THIS checkout's validator; every history
# shape is built with real Git objects in a throw-away clone. Genesis mode must
# accept only the single pinned import root and must keep failing closed for a
# forged root, a second root and any unregistered commit.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$gate = Join-Path $RepositoryRoot 'tests/validate-local-router-lr14-scope.ps1'
$hostPath = (Get-Process -Id $PID).Path
$passes = 0; $failures = [Collections.Generic.List[string]]::new(); $script:LastGate = $null
function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passes++; Write-Host "PASS  $Message" }
    else {
        $failures.Add($Message); Write-Host "FAIL  $Message"
        if ($script:LastGate) { @($script:LastGate.text -split "`n" | Where-Object { $_ -match '^(FAIL|OSS-GENESIS)' }) | Select-Object -First 8 | ForEach-Object { Write-Host "      gate: $_" } }
    }
}
function Invoke-Git([string]$Repo, [string[]]$Arguments) {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& git -C $Repo -c user.name=oss-genesis-test -c user.email=oss-genesis-test@example.invalid @Arguments 2>&1); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "git $($Arguments -join ' ') failed: $($out -join ' ')" }
    return (@($out | Where-Object { $_ -is [string] }) -join "`n").Trim()
}
function Invoke-Gate([string]$Repo, [string]$Base) {
    # Run the clone's copy: the gate under test (copied in) plus any registration
    # committed in the clone, exactly as CI runs a pull request head's validator.
    $cloneGate = Join-Path $Repo 'tests/validate-local-router-lr14-scope.ps1'
    $out = @(& $hostPath -NoLogo -NoProfile -File $cloneGate -RepositoryRoot $Repo -Base $Base 2>&1)
    $result = [pscustomobject]@{ code = $LASTEXITCODE; text = ($out -join "`n") }
    $script:LastGate = $result
    return $result
}
function New-Clone {
    $script:Counter++
    $clone = Join-Path $temp "c$($script:Counter)"
    $null = Invoke-Git $temp @('clone', '--no-hardlinks', '--quiet', $RepositoryRoot, $clone)
    return $clone
}
function Add-Feature([string]$Repo, [string]$Name) {
    $file = Join-Path $Repo "docs/$Name.md"
    Set-Content -LiteralPath $file -Value "# $Name`n`nOSS-GENESIS test feature $Name" -Encoding utf8NoBOM
    $null = Invoke-Git $Repo @('add', "docs/$Name.md")
    $null = Invoke-Git $Repo @('commit', '-q', '-m', "test: $Name")
    return (Invoke-Git $Repo @('rev-parse', 'HEAD'))
}
function Add-Registration([string]$Repo, [string]$Name, [string]$Base, [string]$Tip) {
    $path = Join-Path $Repo 'tests/validate-local-router-lr14-scope.ps1'
    $text = [IO.File]::ReadAllText($path)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $anchor = "        }$nl    }$nl)$nl$nl`$lr14SliceCommits"
    if (([regex]::Matches($text, [regex]::Escape($anchor))).Count -ne 1) { throw 'RegisteredSlices end anchor not found exactly once' }
    $entry = @(
        '        }', '    }', "    # $Name (oss-genesis test registration)", '    [pscustomobject]@{',
        "        Name      = `"$Name`"", "        Base      = `"$Base`"", "        Tip       = `"$Tip`"",
        "        Artifacts = @(`"docs/$Name.md`")", '        Markers   = @{', "            `"docs/$Name.md`" = `"OSS-GENESIS test feature $Name`"",
        '        }', '    }', ')', '', '$lr14SliceCommits') -join $nl
    [IO.File]::WriteAllText($path, $text.Replace($anchor, $entry))
    $null = Invoke-Git $Repo @('add', 'tests/validate-local-router-lr14-scope.ps1')
    $null = Invoke-Git $Repo @('commit', '-q', '-m', "test(scope): register $Name")
}
function Copy-GateIntoClone([string]$Repo) {
    # The clone carries the committed gate; the gate under test is this checkout's.
    Copy-Item -LiteralPath $gate -Destination (Join-Path $Repo 'tests/validate-local-router-lr14-scope.ps1') -Force
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('oss-genesis-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $temp
$script:Counter = 0
try {
    $roots = @((Invoke-Git $RepositoryRoot @('rev-list', '--max-parents=0', 'HEAD')) -split "`n" | Where-Object { $_ })
    $rootTree = Invoke-Git $RepositoryRoot @('rev-parse', "$($roots[0])^{tree}")
    $pinned = ([regex]::Match((Get-Content -Raw -LiteralPath $gate), '\$script:OssGenesisTree = "([0-9a-f]{40})"')).Groups[1].Value
    if ($roots.Count -ne 1 -or $rootTree -cne $pinned) {
        Write-Host "OSS_GENESIS_SUMMARY BLOCKED: this checkout is not the pinned genesis history (roots=$($roots.Count)); nothing was run"
        exit 1
    }
    Assert-True $true "fixture: real history with single root $($roots[0].Substring(0, 12)) and pinned tree $($pinned.Substring(0, 12))"

    # 1. Empty delta on the genesis history.
    $c = New-Clone; Copy-GateIntoClone $c
    $null = Invoke-Git $c @('commit', '-q', '-a', '--allow-empty', '-m', 'test: gate under test')
    $head = Invoke-Git $c @('rev-parse', 'HEAD')
    $r = Invoke-Gate $c $head
    Assert-True ($r.code -eq 0 -and $r.text.Contains('OSS-GENESIS: verified single root') -and $r.text.Contains('N/A 1 (OSS-GENESIS)')) '1 genesis history with an empty delta passes in verified genesis mode'

    # 2. Registered feature delta passes.
    $base = $head
    $tip = Add-Feature $c 'oss-genesis-registered'
    Add-Registration $c 'oss-genesis-registered' $base $tip
    $r = Invoke-Gate $c $base
    Assert-True ($r.code -eq 0 -and $r.text.Contains('N/A 2: every commit of this delta belongs to a registered reviewed slice')) '2 registered feature + registration commit pass (registration resolves in this history)'

    # 3. Unregistered feature fails closed.
    $base = Invoke-Git $c @('rev-parse', 'HEAD')
    $null = Add-Feature $c 'oss-genesis-unregistered'
    $r = Invoke-Gate $c $base
    Assert-True ($r.code -ne 0 -and $r.text.Contains('is not covered by any registered reviewed slice')) '3 unregistered commit on the genesis history fails closed'

    # 4. Forged root: same history shape, different root tree.
    $c = New-Clone; Copy-GateIntoClone $c
    $null = Invoke-Git $c @('commit', '-q', '-a', '--allow-empty', '-m', 'test: gate under test')
    $readme = Join-Path $c 'README.md'; Add-Content -LiteralPath $readme -Value 'forged'
    $blob = Invoke-Git $c @('hash-object', '-w', 'README.md')
    $null = Invoke-Git $c @('checkout', '-q', '--', 'README.md')
    $env:GIT_INDEX_FILE = Join-Path $temp 'forged.index'
    try {
        $null = Invoke-Git $c @('read-tree', $roots[0])
        $null = Invoke-Git $c @('update-index', '--cacheinfo', "100644,$blob,README.md")
        $forgedTree = Invoke-Git $c @('write-tree')
    }
    finally { Remove-Item Env:\GIT_INDEX_FILE; [IO.File]::Delete((Join-Path $temp 'forged.index')) }
    $forgedRoot = Invoke-Git $c @('commit-tree', $forgedTree, '-m', 'forged root')
    $replayed = Invoke-Git $c @('commit-tree', 'HEAD^{tree}', '-p', $forgedRoot, '-m', 'replayed head on forged root')
    $null = Invoke-Git $c @('checkout', '-q', '--detach', $replayed)
    $base = $replayed
    $tip = Add-Feature $c 'oss-genesis-forged'
    Add-Registration $c 'oss-genesis-forged' $base $tip
    $r = Invoke-Gate $c $base
    Assert-True ($forgedTree -cne $pinned -and $r.code -ne 0 -and $r.text.Contains('OSS-GENESIS: not applicable') -and -not $r.text.Contains('OSS-GENESIS: verified')) '4 forged root tree is never accepted as genesis; the strict gate fails closed'

    # 5. A second, unrelated root merged into the history.
    $c = New-Clone; Copy-GateIntoClone $c
    $null = Invoke-Git $c @('commit', '-q', '-a', '--allow-empty', '-m', 'test: gate under test')
    $env:GIT_INDEX_FILE = Join-Path $temp 'orphan.index'
    try {
        $orphanBlob = Invoke-Git $c @('hash-object', '-w', 'README.md')
        $null = Invoke-Git $c @('update-index', '--add', '--cacheinfo', "100644,$orphanBlob,ORPHAN.txt")
        $orphanTree = Invoke-Git $c @('write-tree')
    }
    finally { Remove-Item Env:\GIT_INDEX_FILE; [IO.File]::Delete((Join-Path $temp 'orphan.index')) }
    $orphan = Invoke-Git $c @('commit-tree', $orphanTree, '-m', 'unrelated root')
    $merge = Invoke-Git $c @('commit-tree', 'HEAD^{tree}', '-p', 'HEAD', '-p', $orphan, '-m', 'merge unrelated history')
    $null = Invoke-Git $c @('checkout', '-q', '--detach', $merge)
    $base = $merge
    $tip = Add-Feature $c 'oss-genesis-tworoots'
    Add-Registration $c 'oss-genesis-tworoots' $base $tip
    $r = Invoke-Gate $c $base
    Assert-True ($r.code -ne 0 -and $r.text.Contains('OSS-GENESIS: not applicable (roots=2)')) '5 a second root disables genesis mode; the strict gate fails closed'

    # 6. Control: when the validator-introducing commit has a parent (ordinary
    #    histories, including the private development repository), genesis mode
    #    never engages.
    $c = New-Clone; Copy-GateIntoClone $c
    $null = Invoke-Git $c @('commit', '-q', '-a', '--allow-empty', '-m', 'test: gate under test')
    $env:GIT_INDEX_FILE = Join-Path $temp 'parent.index'
    try { $emptyTree = Invoke-Git $c @('write-tree') }
    finally { Remove-Item Env:\GIT_INDEX_FILE; if (Test-Path (Join-Path $temp 'parent.index')) { [IO.File]::Delete((Join-Path $temp 'parent.index')) } }
    $parent = Invoke-Git $c @('commit-tree', $emptyTree, '-m', 'earlier history')
    $child = Invoke-Git $c @('commit-tree', 'HEAD^{tree}', '-p', $parent, '-m', 'validator introduced with a parent')
    $null = Invoke-Git $c @('checkout', '-q', '--detach', $child)
    $r = Invoke-Gate $c $child
    Assert-True (-not $r.text.Contains('OSS-GENESIS')) '6 control: a parented validator commit never enters genesis mode'

    Write-Host "OSS_GENESIS_SUMMARY PASS=$passes FAIL=$($failures.Count) real_git_histories=5 mocks=0"
    if ($failures.Count) { exit 1 }
    Write-Host 'OSS genesis validation PASSED'
}
finally {
    if (Test-Path Env:\GIT_INDEX_FILE) { Remove-Item Env:\GIT_INDEX_FILE }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
