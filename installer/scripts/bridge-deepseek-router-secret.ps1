param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Check", "Apply", "Rollback")]
    [string]$Action = "Check"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_registry.ps1")

# DSR3 - DeepSeek real secret bridge + local readiness gate.
#
# The user's Direct Mode DeepSeek provider already works with an inline
# experimental_bearer_token. This script COPIES that credential (in memory only)
# into the Windows User environment as DEEPSEEK_API_KEY so the Local Router can
# reference the same credential, enables the Manager's direct DeepSeek provider
# state, and stops there: no approval, no Router Initialize, and no provider
# request of any kind. The inline Direct Mode token is never read from disk
# outside the [model_providers.deepseek] section and is never removed.
#
# The secret value is never printed, hashed, logged, backed up, or written to any
# file. Comparison with an existing DEEPSEEK_API_KEY is a memory-only ordinal
# equality check.

$script:Lr3TargetEnv = "DEEPSEEK_API_KEY"
$script:Lr3ProviderSection = "model_providers.deepseek"
$script:Lr3RequiredHost = "api.deepseek.com"
$script:Lr3ReceiptName = "deepseek-router-bridge-receipt.json"
$script:Lr3ReceiptSchemaVersion = 1
$script:Lr3SafeToBridge = "SAFE_TO_BRIDGE"
$script:Lr3AlreadyBridged = "ALREADY_BRIDGED"
$script:Lr3SecretConflict = "SECRET_CONFLICT"
$script:Lr3SourceMissing = "SOURCE_SECRET_MISSING"
$script:Lr3SafeToSyncScope = "SAFE_TO_SYNC_SCOPE"

# Injectable seams: validators replace these so a test never reads or writes the
# real User-scope environment and never touches the real credential.
$script:Lr3UserEnvWriter = $null
$script:Lr3UserEnvLookup = $null
$script:Lr3ProcessEnvLookup = $null

# Test-only file-backed environment seam. When LR3_USER_ENV_FILE is set the
# bridge reads and writes each scope through that JSON file
# ({ "user": {...}, "process": {...} }), so the validator can exercise the real
# script end to end - with the two scopes tracked separately - without touching
# the real environment. Production runs never set this variable.
function Get-Lr3EnvFilePath { return [string]$env:LR3_USER_ENV_FILE }
function Get-Lr3EnvFileDocument {
    $path = Get-Lr3EnvFilePath
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}
function Get-Lr3ScopedStore([string]$Scope) {
    $store = @{}
    $document = Get-Lr3EnvFileDocument
    if ($null -ne $document -and $null -ne $document.PSObject.Properties[$Scope] -and $null -ne $document.$Scope) {
        foreach ($property in $document.$Scope.PSObject.Properties) { $store[$property.Name] = [string]$property.Value }
    }
    return $store
}
function Save-Lr3ScopedStore([string]$Scope, $Store) {
    $path = Get-Lr3EnvFilePath
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $userStore = if ($Scope -eq "user") { $Store } else { Get-Lr3ScopedStore "user" }
    $processStore = if ($Scope -eq "process") { $Store } else { Get-Lr3ScopedStore "process" }
    ([ordered]@{ user = $userStore; process = $processStore } | ConvertTo-Json -Depth 5) |
        Set-Content -LiteralPath $path -Encoding UTF8
}
function Remove-Lr3ScopedValue([string]$Scope) {
    if (-not [string]::IsNullOrWhiteSpace((Get-Lr3EnvFilePath))) {
        $store = Get-Lr3ScopedStore $Scope
        if ($store.ContainsKey($script:Lr3TargetEnv)) {
            $store.Remove($script:Lr3TargetEnv) | Out-Null
            Save-Lr3ScopedStore $Scope $store
        }
        return
    }
    if ($null -ne $script:Lr3UserEnvWriter) {
        $script:Lr3UserEnvWriter.Remove($script:Lr3TargetEnv) | Out-Null
        return
    }
    $target = if ($Scope -eq "user") { [EnvironmentVariableTarget]::User } else { [EnvironmentVariableTarget]::Process }
    [Environment]::SetEnvironmentVariable($script:Lr3TargetEnv, $null, $target)
}

function Write-Lr3UserEnvironmentValue([string]$Name, [string]$Value) {
    if (-not [string]::IsNullOrWhiteSpace((Get-Lr3EnvFilePath))) {
        $store = Get-Lr3ScopedStore "user"
        $store[$Name] = $Value
        Save-Lr3ScopedStore "user" $store
        return
    }
    if ($null -ne $script:Lr3UserEnvWriter) {
        $script:Lr3UserEnvWriter[$Name] = $Value
        return
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, [EnvironmentVariableTarget]::User)
}

function Write-Lr3ProcessEnvironmentValue([string]$Name, [string]$Value) {
    if (-not [string]::IsNullOrWhiteSpace((Get-Lr3EnvFilePath))) {
        $store = Get-Lr3ScopedStore "process"
        $store[$Name] = $Value
        Save-Lr3ScopedStore "process" $store
        return
    }
    if ($null -ne $script:Lr3UserEnvWriter) {
        $script:Lr3UserEnvWriter[$Name] = $Value
        return
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, [EnvironmentVariableTarget]::Process)
}

function Get-Lr3CodexConfigPath { return (Join-Path (Get-CodexHome) "config.toml") }
function Get-Lr3StatePath { return (Get-RegistryPath "state.json") }
function Get-Lr3CandidatesPath { return (Get-RegistryPath "candidates.json") }
function Get-Lr3ReceiptPath { return (Get-RegistryPath $script:Lr3ReceiptName) }
function Get-Lr3BackupRoot { return (Join-Path (Get-CodexHome) "backups") }

function Get-Lr3MemoryValue([string]$Name, [string]$Target) {
    if (-not [string]::IsNullOrWhiteSpace((Get-Lr3EnvFilePath))) {
        $scopeName = if ($Target -eq "User") { "user" } else { "process" }
        $store = Get-Lr3ScopedStore $scopeName
        if ($store.ContainsKey($Name)) { return [string]$store[$Name] }
        return $null
    }
    if ($Target -eq "User" -and $null -ne $script:Lr3UserEnvLookup) {
        if ($script:Lr3UserEnvLookup.ContainsKey($Name)) { return [string]$script:Lr3UserEnvLookup[$Name] }
        return $null
    }
    if ($Target -eq "Process" -and $null -ne $script:Lr3ProcessEnvLookup) {
        if ($script:Lr3ProcessEnvLookup.ContainsKey($Name)) { return [string]$script:Lr3ProcessEnvLookup[$Name] }
        return $null
    }
    return [Environment]::GetEnvironmentVariable($Name, $Target)
}

function Get-Lr3TargetPresence {
    $userValue = Get-Lr3MemoryValue $script:Lr3TargetEnv "User"
    $processValue = Get-Lr3MemoryValue $script:Lr3TargetEnv "Process"
    return [pscustomobject]@{
        UserValue = $userValue
        ProcessValue = $processValue
        UserPresent = -not [string]::IsNullOrWhiteSpace($userValue)
        ProcessPresent = -not [string]::IsNullOrWhiteSpace($processValue)
    }
}

# Section-scoped parse of [model_providers.deepseek]. Full-file regex scanning is
# forbidden: another provider's bearer token must never be mistaken for this one.
function Read-Lr3DirectProvider([string]$Path) {
    $result = [pscustomobject]@{
        Present = $false
        BaseUrl = ""
        WireApi = ""
        Token = $null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "FAIL_CLOSED: Codex config is missing: $Path"
    }

    $lines = @(Get-Content -LiteralPath $Path)
    $headers = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[([^\]]+)\]\s*$') {
            $headers.Add([pscustomobject]@{ Name = $Matches[1].Trim(); Index = $i })
        }
    }

    $sections = @($headers | Where-Object { $_.Name -eq $script:Lr3ProviderSection })
    if ($sections.Count -eq 0) { return $result }
    if ($sections.Count -gt 1) {
        throw "FAIL_CLOSED: duplicate [$($script:Lr3ProviderSection)] sections; refusing to guess which credential is live."
    }

    $start = $sections[0].Index + 1
    $following = @($headers | Where-Object { $_.Index -gt $sections[0].Index } | Sort-Object Index)
    $end = if ($following.Count -gt 0) { $following[0].Index - 1 } else { $lines.Count - 1 }
    if ($end -lt $start) { $end = $start - 1 }
    $body = if ($end -ge $start) { @($lines[$start..$end]) } else { @() }
    $result.Present = $true

    $baseUrls = @($body | ForEach-Object { if ($_ -match '^\s*base_url\s*=\s*"([^"]*)"') { $Matches[1] } })
    $wireApis = @($body | ForEach-Object { if ($_ -match '^\s*wire_api\s*=\s*"([^"]*)"') { $Matches[1] } })
    $tokens = @($body | ForEach-Object { if ($_ -match '^\s*experimental_bearer_token\s*=\s*"([^"]*)"') { $Matches[1] } })
    $inlineTokens = @($body | ForEach-Object { if ($_ -match '^\s*experimental_bearer_token\s*=') { $_ } })

    if ($baseUrls.Count -gt 1) { throw "FAIL_CLOSED: duplicate base_url inside [$($script:Lr3ProviderSection)]." }
    if ($wireApis.Count -gt 1) { throw "FAIL_CLOSED: duplicate wire_api inside [$($script:Lr3ProviderSection)]." }
    if ($inlineTokens.Count -gt 1) { throw "FAIL_CLOSED: duplicate experimental_bearer_token inside [$($script:Lr3ProviderSection)]." }
    if ($inlineTokens.Count -eq 1 -and $tokens.Count -eq 0) {
        throw "FAIL_CLOSED: experimental_bearer_token inside [$($script:Lr3ProviderSection)] is not a quoted string; refusing to parse it."
    }

    if ($baseUrls.Count -eq 1) { $result.BaseUrl = [string]$baseUrls[0] }
    if ($wireApis.Count -eq 1) { $result.WireApi = [string]$wireApis[0] }
    if ($tokens.Count -eq 1) { $result.Token = [string]$tokens[0] }
    return $result
}

function Test-Lr3BaseUrlIsValid([string]$BaseUrl) {
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { return $false }
    $trimmed = $BaseUrl.Trim().TrimEnd('/')
    return [string]::Equals($trimmed, "https://" + $script:Lr3RequiredHost, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-Lr3Classification {
    $provider = Read-Lr3DirectProvider (Get-Lr3CodexConfigPath)
    $target = Get-Lr3TargetPresence
    $sourcePresent = -not [string]::IsNullOrWhiteSpace([string]$provider.Token)

    # DSR3-FIX1: each scope is compared against the source independently. A
    # matching User scope must never mask a missing or conflicting Process scope.
    $userMatches = $false
    $processMatches = $false
    $state = $script:Lr3SourceMissing
    if ($sourcePresent) {
        $source = [string]$provider.Token
        $userPresent = [bool]$target.UserPresent
        $processPresent = [bool]$target.ProcessPresent
        $userMatches = $userPresent -and [string]::Equals([string]$target.UserValue, $source, [System.StringComparison]::Ordinal)
        $processMatches = $processPresent -and [string]::Equals([string]$target.ProcessValue, $source, [System.StringComparison]::Ordinal)
        $userConflicts = $userPresent -and -not $userMatches
        $processConflicts = $processPresent -and -not $processMatches

        if ($userConflicts -or $processConflicts) {
            # A scope holding a different value is always a conflict, regardless
            # of the other scope's state; neither value is ever overwritten.
            $state = $script:Lr3SecretConflict
        }
        elseif (-not $userPresent -and -not $processPresent) {
            $state = $script:Lr3SafeToBridge
        }
        elseif ($userMatches -and $processMatches) {
            $state = $script:Lr3AlreadyBridged
        }
        else {
            # Exactly one scope is present and matches the source: only the
            # missing scope may be created, the matching one is never rewritten.
            $state = $script:Lr3SafeToSyncScope
        }
    }

    return [pscustomobject]@{
        Provider = $provider
        ProviderPresent = [bool]$provider.Present
        BaseUrlValid = Test-Lr3BaseUrlIsValid ([string]$provider.BaseUrl)
        WireApiValid = [string]::Equals([string]$provider.WireApi, "responses", [System.StringComparison]::OrdinalIgnoreCase)
        SourcePresent = $sourcePresent
        TargetUserPresent = [bool]$target.UserPresent
        TargetProcessPresent = [bool]$target.ProcessPresent
        TargetUserMatches = $userMatches
        TargetProcessMatches = $processMatches
        Classification = $state
    }
}

function Write-Lr3CheckReport($Report) {
    Write-Host ("Direct provider present: {0}" -f $(if ($Report.ProviderPresent) { "YES" } else { "NO" }))
    Write-Host ("Base URL: {0}" -f $(if ($Report.BaseUrlValid) { "VALID" } else { "INVALID" }))
    Write-Host ("Wire API: {0}" -f $(if ($Report.WireApiValid) { "RESPONSES" } else { "INVALID" }))
    Write-Host ("Direct secret: {0}" -f $(if ($Report.SourcePresent) { "PRESENT" } else { "MISSING" }))
    Write-Host ("{0}: {1}" -f $script:Lr3TargetEnv, $(if ($Report.TargetUserPresent -or $Report.TargetProcessPresent) { "PRESENT" } else { "MISSING" }))
    Write-Host ("Bridge state: {0}" -f $Report.Classification)
}

function New-Lr3BackupDirectory {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $directory = Join-Path (Get-Lr3BackupRoot) ("deepseek-router-bridge-" + $stamp)
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    return $directory
}

function Write-Lr3StateWithDeepSeekEnabled([string]$Path, [bool]$Enabled) {
    $current = @{}
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $parsed = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
        foreach ($property in $parsed.PSObject.Properties) { $current[$property.Name] = $property.Value }
    }
    $current["deepseek_enabled"] = $Enabled

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temp = Join-Path $directory ("state." + [guid]::NewGuid().ToString("N") + ".tmp")
    ($current | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $temp -Encoding UTF8
    $null = Get-Content -Raw -LiteralPath $temp | ConvertFrom-Json
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function New-Lr3Receipt([string]$BackupDirectory, [bool]$UserEnvCreated, [bool]$ProcessEnvCreated, [bool]$StateChanged, [bool]$CandidatesChanged) {
    $receipt = [ordered]@{
        schema_version = $script:Lr3ReceiptSchemaVersion
        applied_at = (Get-Date -Format "o")
        source = "direct_deepseek_config"
        target_env = $script:Lr3TargetEnv
        user_env_created_by_dsr3 = $UserEnvCreated
        process_env_created_by_dsr3 = $ProcessEnvCreated
        # Compatibility aggregate: true when DSR3 created at least one scope.
        env_created_by_dsr3 = ($UserEnvCreated -or $ProcessEnvCreated)
        state_changed = $StateChanged
        candidates_changed = $CandidatesChanged
        backup_directory = $BackupDirectory
        branch = (& git -C (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) rev-parse --abbrev-ref HEAD 2>$null)
        head = (& git -C (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) rev-parse HEAD 2>$null)
    }
    Save-JsonFile (Get-Lr3ReceiptPath) $receipt
}

if ($Action -eq "Check") {
    Write-Lr3CheckReport (Get-Lr3Classification)
    exit 0
}

if ($Action -eq "Apply") {
    $report = Get-Lr3Classification
    if (-not $report.ProviderPresent) { throw "FAIL_CLOSED: [model_providers.deepseek] section is missing." }
    if (-not $report.BaseUrlValid) { throw "FAIL_CLOSED: direct DeepSeek base_url is not the approved https://api.deepseek.com endpoint." }
    if (-not $report.WireApiValid) { throw "FAIL_CLOSED: direct DeepSeek wire_api is not responses." }
    if ($report.Classification -eq $script:Lr3SourceMissing) { throw "FAIL_CLOSED: SOURCE_SECRET_MISSING - the direct DeepSeek credential is not present." }
    if ($report.Classification -eq $script:Lr3SecretConflict) { throw "FAIL_CLOSED: SECRET_CONFLICT - $($script:Lr3TargetEnv) already exists with a different value; neither value is overwritten." }

    $userCreated = $false
    $processCreated = $false
    if ($report.Classification -eq $script:Lr3SafeToBridge -or $report.Classification -eq $script:Lr3SafeToSyncScope) {
        $secret = [string]$report.Provider.Token
        if (-not $report.TargetUserMatches) {
            Write-Lr3UserEnvironmentValue $script:Lr3TargetEnv $secret
            $userCreated = $true
        }

        if (-not $report.TargetProcessMatches) {
            Write-Lr3ProcessEnvironmentValue $script:Lr3TargetEnv $secret
            $processCreated = $true
        }

        $secret = $null
        Write-Host ("Bridge state: {0}" -f $report.Classification)
        Write-Host "NO_CHANGE_REQUIRED_TO_SOURCE"
    }
    else {
        Write-Host ("Bridge state: {0}" -f $script:Lr3AlreadyBridged)
        Write-Host "NO_CHANGE_REQUIRED"
    }

    $backupDirectory = New-Lr3BackupDirectory
    $statePath = Get-Lr3StatePath
    $stateExisted = Test-Path -LiteralPath $statePath -PathType Leaf
    if ($stateExisted) { Copy-Item -LiteralPath $statePath -Destination (Join-Path $backupDirectory "state.json") -Force }
    else { Write-Host "STATE_PREVIOUSLY_MISSING" }

    $candidatesPath = Get-Lr3CandidatesPath
    $candidatesExisted = Test-Path -LiteralPath $candidatesPath -PathType Leaf
    if ($candidatesExisted) { Copy-Item -LiteralPath $candidatesPath -Destination (Join-Path $backupDirectory "candidates.json") -Force }
    else { Write-Host "CANDIDATES_PREVIOUSLY_MISSING" }

    Write-Lr3StateWithDeepSeekEnabled $statePath $true
    Write-Host "deepseek_enabled: true"
    Write-Host ("Backup directory: {0}" -f $backupDirectory)

    New-Lr3Receipt $backupDirectory $userCreated $processCreated $true $false
    exit 0
}

# Rollback: undo only what DSR3 itself changed.
$receiptPath = Get-Lr3ReceiptPath
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    throw ("FAIL_CLOSED: no DSR3 receipt was found at {0}; refusing to guess what to undo." -f $receiptPath)
}
$receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json

# DSR3-FIX1: per-scope ownership. A legacy schema-v1 receipt that only carries
# env_created_by_dsr3 keeps its original whole-variable behaviour.
$receiptFields = @($receipt.PSObject.Properties.Name)
if ($receiptFields -contains "user_env_created_by_dsr3" -or $receiptFields -contains "process_env_created_by_dsr3") {
    $userOwned = [bool]$receipt.user_env_created_by_dsr3
    $processOwned = [bool]$receipt.process_env_created_by_dsr3
}
else {
    $userOwned = [bool]$receipt.env_created_by_dsr3
    $processOwned = [bool]$receipt.env_created_by_dsr3
}

if ($userOwned) {
    Remove-Lr3ScopedValue "user"
    Write-Host ("Removed {0} from the User scope (created by DSR3)." -f $script:Lr3TargetEnv)
}
else {
    Write-Host ("Kept pre-existing {0} in the User scope (not created by DSR3)." -f $script:Lr3TargetEnv)
}

if ($processOwned) {
    Remove-Lr3ScopedValue "process"
    Write-Host ("Removed {0} from the Process scope (created by DSR3)." -f $script:Lr3TargetEnv)
}
else {
    Write-Host ("Kept pre-existing {0} in the Process scope (not created by DSR3)." -f $script:Lr3TargetEnv)
}

$backupDirectory = [string]$receipt.backup_directory
if (-not [string]::IsNullOrWhiteSpace($backupDirectory) -and (Test-Path -LiteralPath $backupDirectory)) {
    foreach ($name in @("state.json", "candidates.json")) {
        $source = Join-Path $backupDirectory $name
        $target = if ($name -eq "state.json") { Get-Lr3StatePath } else { Get-Lr3CandidatesPath }
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination $target -Force
            Write-Host ("Restored {0}." -f $name)
        }
        elseif (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force
            Write-Host ("Removed {0} (it did not exist before DSR3)." -f $name)
        }
    }
}

Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue
Write-Host "Rollback complete. Direct Mode config.toml, models.json, and the inline bearer token were never touched."
exit 0
