# OSS-GENESIS shared baseline for history-dependent security validators.
#
# The open-source history starts at ONE sanitized import commit of the private
# development repository's main (1bc5985cc961). Validators whose evidence used to
# be private commit objects (FIX5 chain, earlier reviewed blobs) may fall back to
# genesis evidence ONLY when Get-OssGenesisRoot returns the verified root: the
# history has exactly one root commit and that root's tree is byte-for-byte the
# reviewed import tree pinned below. Evidence is then checked against the
# genesis root's own Git objects, never against the working tree alone. Any other
# shape (a parented history, a second root, a forged root tree) returns "" and
# every caller keeps its original fail-closed behaviour.
#
# The LR-14 scope gate carries the same pin inline; tests/validate-oss-genesis.ps1
# requires both pins to stay identical.

$script:OssGenesisTreePin = "8dd01f4f772e95fbcbb140d3850c8814a4d71f3e"
$script:OssGenesisSourceCommit = "1bc5985cc9614c93f9a46261f9b8e0d9c87a7229"

function Get-OssGenesisGitLines {
    param([string]$RepositoryRoot, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& git -C $RepositoryRoot @Arguments 2>$null)
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return @($output | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ([string]$_).Trim() })
}

# Returns the verified genesis root commit, or "" when this is not exactly the
# reviewed genesis history.
function Get-OssGenesisRoot {
    param([string]$RepositoryRoot)
    $roots = @(Get-OssGenesisGitLines $RepositoryRoot @("rev-list", "--max-parents=0", "HEAD"))
    if ($roots.Count -ne 1) { return "" }
    $tree = @(Get-OssGenesisGitLines $RepositoryRoot @("rev-parse", "--verify", "--quiet", "$($roots[0])^{tree}"))
    if ($tree.Count -ne 1 -or $tree[0] -cne $script:OssGenesisTreePin) { return "" }
    return [string]$roots[0]
}

# Blob object id of a path in a commit, or "" when absent.
function Get-OssGenesisBlob {
    param([string]$RepositoryRoot, [string]$Commit, [string]$Path)
    $blob = @(Get-OssGenesisGitLines $RepositoryRoot @("rev-parse", "--verify", "--quiet", "$($Commit):$Path"))
    if ($blob.Count -ne 1) { return "" }
    return [string]$blob[0]
}
