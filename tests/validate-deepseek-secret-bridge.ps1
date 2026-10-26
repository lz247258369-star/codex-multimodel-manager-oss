param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR3 validation - DeepSeek real secret bridge.
#
# Every scenario runs the real bridge script in a child process against an
# isolated temp CODEX_HOME and a file-backed environment seam
# (LR3_USER_ENV_FILE), so no scenario ever reads or writes the real User
# environment and no real credential is involved. The fake secret is synthetic.

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }
function Assert-True([bool]$Condition, [string]$Message) { if ($Condition) { Pass $Message } else { Fail $Message } }

$bridgePath = Join-Path $RepositoryRoot "installer/scripts/bridge-deepseek-router-secret.ps1"
if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) {
    Fail "Bridge script is missing: $bridgePath"
    Write-Host "DeepSeek secret bridge validation FAILED (missing script)" -ForegroundColor Red
    exit 1
}

$bridgeText = Get-Content -Raw -LiteralPath $bridgePath
$fakeSecret = "fixture-fake-deepseek-credential-value"
$otherSecret = "fixture-other-deepseek-credential-value"

function New-BridgeSandbox {
    param([string]$ConfigToml, [hashtable]$State, [string]$CandidatesJson = "", [string]$EnvStoreJson = '{ "user": {}, "process": {} }')
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("dsr3-" + [guid]::NewGuid().ToString("N"))
    $codexHome = Join-Path $root "codex-home"
    New-Item -ItemType Directory -Force -Path (Join-Path $codexHome "multimodel-manager") | Out-Null
    Set-Content -LiteralPath (Join-Path $codexHome "config.toml") -Value $ConfigToml -Encoding UTF8
    if ($null -ne $State) {
        ($State | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $codexHome "multimodel-manager/state.json") -Encoding UTF8
    }
    if (-not [string]::IsNullOrWhiteSpace($CandidatesJson)) {
        Set-Content -LiteralPath (Join-Path $codexHome "multimodel-manager/candidates.json") -Value $CandidatesJson -Encoding UTF8
    }
    $envFile = Join-Path $root "env-store.json"
    Set-Content -LiteralPath $envFile -Value $EnvStoreJson -Encoding UTF8
    return [pscustomobject]@{ Root = $root; CodexHome = $codexHome; EnvFile = $envFile }
}

function Invoke-Bridge([string]$Action, $Sandbox) {
    $previousHome = $env:CODEX_HOME
    $previousEnvFile = $env:LR3_USER_ENV_FILE
    try {
        $env:CODEX_HOME = $Sandbox.CodexHome
        $env:LR3_USER_ENV_FILE = $Sandbox.EnvFile
        $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $bridgePath -Action $Action 2>&1 | Out-String
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $output }
    }
    finally {
        $env:CODEX_HOME = $previousHome
        $env:LR3_USER_ENV_FILE = $previousEnvFile
    }
}

function Get-ScopeStore($Sandbox, [string]$Scope) {
    $document = Get-Content -Raw -LiteralPath $Sandbox.EnvFile | ConvertFrom-Json
    if ($null -eq $document.PSObject.Properties[$Scope] -or $null -eq $document.$Scope) { return @{} }
    return $document.$Scope
}

function Test-ScopeHasKey($Sandbox, [string]$Scope, [string]$Name) {
    $store = Get-ScopeStore $Sandbox $Scope
    return ($store.PSObject.Properties.Name -contains $Name)
}

function Get-ScopeValue($Sandbox, [string]$Scope, [string]$Name) {
    $store = Get-ScopeStore $Sandbox $Scope
    if ($store.PSObject.Properties.Name -contains $Name) { return [string]$store.$Name }
    return $null
}

function Get-EnvStoreJson([string]$UserValue, [string]$ProcessValue) {
    $user = if ($null -eq $UserValue) { "{}" } else { "{`"DEEPSEEK_API_KEY`":`"$UserValue`"}" }
    $process = if ($null -eq $ProcessValue) { "{}" } else { "{`"DEEPSEEK_API_KEY`":`"$ProcessValue`"}" }
    return ("{ `"user`": $user, `"process`": $process }")
}

function Get-DeepSeekToml {
    param([string]$BaseUrl = "https://api.deepseek.com", [string]$WireApi = "responses", [string]$Token = "fixture-fake-deepseek-credential-value")
    $tokenLine = if ([string]::IsNullOrWhiteSpace($Token)) { "" } else { "experimental_bearer_token = `"$Token`"`n" }
    return @"
model = "deepseek-chat"
model_provider = "deepseek"

[model_providers.deepseek]
name = "DeepSeek (Direct Mode)"
base_url = "$BaseUrl"
wire_api = "$WireApi"
$tokenLine
[model_providers.mm_mimo]
base_url = "https://api.xiaomimimo.com/v1"
env_key = "MIMO_API_KEY"
wire_api = "responses"
"@
}

function Get-StandardState {
    return @{
        openrouter_enabled = $true
        mimo_enabled = $true
        aliyun_enabled = $true
        aliyun_mode = "trial-beijing"
        custom_keep_me = "user-value"
    }
}

$sandboxes = New-Object System.Collections.Generic.List[object]
try {
    # --- Static no-leak contract --------------------------------------------
    foreach ($forbidden in @('Write-Host $secret', 'Write-Output $secret', 'ConvertTo-Json $secret')) {
        Assert-True (-not $bridgeText.Contains($forbidden)) "Bridge never writes the secret via $forbidden"
    }
    Assert-True (-not ($bridgeText -match 'Set-Content[^\r\n]*\$secret')) "Bridge never writes the secret to a file"
    Assert-True (-not ($bridgeText -match 'Add-Content[^\r\n]*\$secret')) "Bridge never appends the secret to a file"
    Assert-True (-not ($bridgeText -match '(Sha256|Get-FileHash)[^\r\n]*secret')) "Bridge never hashes the secret"
    Assert-True ($bridgeText.Contains('$secret = $null')) "Bridge clears the in-memory secret after Apply"

    # --- CASE A: SAFE_TO_BRIDGE ---------------------------------------------
    $caseA = New-BridgeSandbox -ConfigToml (Get-DeepSeekToml) -State (Get-StandardState)
    $sandboxes.Add($caseA)
    $checkA = Invoke-Bridge "Check" $caseA
    Assert-True ($checkA.Exit -eq 0) "CASE A: Check exits 0"
    Assert-True ($checkA.Output -match "SAFE_TO_BRIDGE") "CASE A: Check reports SAFE_TO_BRIDGE"
    Assert-True ($checkA.Output -match "Direct provider present: YES") "CASE A: Check reports the direct provider present"
    Assert-True ($checkA.Output -match "Base URL: VALID" -and $checkA.Output -match "Wire API: RESPONSES") "CASE A: Check reports valid endpoint and wire api"
    Assert-True ($checkA.Output -match "Direct secret: PRESENT") "CASE A: Check reports the direct secret present"
    Assert-True (-not $checkA.Output.Contains($fakeSecret)) "CASE A: Check never prints the secret"

    # --- Apply ---------------------------------------------------------------
    $configBefore = Get-Content -Raw -LiteralPath (Join-Path $caseA.CodexHome "config.toml")
    $applyA = Invoke-Bridge "Apply" $caseA
    Assert-True ($applyA.Exit -eq 0) "Apply exits 0 on SAFE_TO_BRIDGE"
    Assert-True ((Get-ScopeValue $caseA "user" "DEEPSEEK_API_KEY") -eq $fakeSecret) "Apply writes the bridged secret to the User scope"
    Assert-True ((Get-ScopeValue $caseA "process" "DEEPSEEK_API_KEY") -eq $fakeSecret) "Apply writes the bridged secret to the Process scope"
    Assert-True (-not $applyA.Output.Contains($fakeSecret)) "Apply never prints the secret"
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $caseA.CodexHome "config.toml")) -eq $configBefore) "Apply leaves config.toml byte-identical"
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $caseA.CodexHome "config.toml")).Contains("experimental_bearer_token")) "Apply never removes the inline Direct Mode credential"

    $stateText = Get-Content -Raw -LiteralPath (Join-Path $caseA.CodexHome "multimodel-manager/state.json")
    $stateDoc = $stateText | ConvertFrom-Json
    Assert-True ($stateDoc.deepseek_enabled -eq $true) "Apply sets deepseek_enabled=true"
    Assert-True ([string]$stateDoc.custom_keep_me -eq "user-value" -and [string]$stateDoc.aliyun_mode -eq "trial-beijing" -and $stateDoc.mimo_enabled -eq $true) "Apply preserves every unrelated state field"
    Assert-True (-not $stateText.Contains($fakeSecret)) "state.json never contains the secret"

    $receiptPath = Join-Path $caseA.CodexHome "multimodel-manager/deepseek-router-bridge-receipt.json"
    Assert-True (Test-Path -LiteralPath $receiptPath -PathType Leaf) "Apply writes a bridge receipt"
    $receiptText = Get-Content -Raw -LiteralPath $receiptPath
    $receipt = $receiptText | ConvertFrom-Json
    Assert-True (-not $receiptText.Contains($fakeSecret)) "receipt never contains the secret"
    Assert-True ($receiptText -notmatch '(?i)sha|hash|length|token|authorization') "receipt carries no hash/length/token/authorization field"
    Assert-True ($receipt.env_created_by_dsr3 -eq $true) "receipt keeps the compatibility aggregate (true)"
    Assert-True ($receipt.user_env_created_by_dsr3 -eq $true -and $receipt.process_env_created_by_dsr3 -eq $true) "receipt records per-scope creation for SAFE_TO_BRIDGE"
    Assert-True ($receipt.state_changed -eq $true) "receipt records the state change"
    Assert-True ((Test-Path -LiteralPath ([string]$receipt.backup_directory) -PathType Container)) "receipt points at an existing backup directory"
    Assert-True (Test-Path -LiteralPath (Join-Path ([string]$receipt.backup_directory) "state.json") -PathType Leaf) "the backup holds the pre-change state"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $caseA.CodexHome "multimodel-manager/approved-models.json"))) "Apply never creates approved-models.json"

    # --- CASE B: ALREADY_BRIDGED (idempotent) -------------------------------
    $caseB = New-BridgeSandbox -ConfigToml (Get-DeepSeekToml) -State (Get-StandardState) -EnvStoreJson (Get-EnvStoreJson $fakeSecret $fakeSecret)
    $sandboxes.Add($caseB)
    $checkB = Invoke-Bridge "Check" $caseB
    Assert-True ($checkB.Output -match "ALREADY_BRIDGED") "CASE B: Check reports ALREADY_BRIDGED for an identical value"
    $applyB = Invoke-Bridge "Apply" $caseB
    Assert-True ($applyB.Output -match "NO_CHANGE_REQUIRED") "CASE B: Apply reports NO_CHANGE_REQUIRED"
    Assert-True ((Get-ScopeValue $caseB "user" "DEEPSEEK_API_KEY") -eq $fakeSecret -and (Get-ScopeValue $caseB "process" "DEEPSEEK_API_KEY") -eq $fakeSecret) "CASE B: both scopes keep their existing value (no rewrite)"

    # --- CASE C: SECRET_CONFLICT -------------------------------------------
    $caseC = New-BridgeSandbox -ConfigToml (Get-DeepSeekToml) -State (Get-StandardState) -EnvStoreJson (Get-EnvStoreJson $otherSecret $null)
    $sandboxes.Add($caseC)
    $checkC = Invoke-Bridge "Check" $caseC
    Assert-True ($checkC.Output -match "SECRET_CONFLICT") "CASE C: Check reports SECRET_CONFLICT"
    $applyC = Invoke-Bridge "Apply" $caseC
    Assert-True ($applyC.Exit -ne 0) "CASE C: Apply fails closed"
    Assert-True ((Get-ScopeValue $caseC "user" "DEEPSEEK_API_KEY") -eq $otherSecret) "CASE C: the existing target value is never overwritten"

    # --- CASE D: SOURCE_SECRET_MISSING -------------------------------------
    $caseD = New-BridgeSandbox -ConfigToml (Get-DeepSeekToml -Token "") -State (Get-StandardState)
    $sandboxes.Add($caseD)
    $checkD = Invoke-Bridge "Check" $caseD
    Assert-True ($checkD.Output -match "SOURCE_SECRET_MISSING") "CASE D: Check reports SOURCE_SECRET_MISSING"
    Assert-True ((Invoke-Bridge "Apply" $caseD).Exit -ne 0) "CASE D: Apply fails closed"

    # --- Invalid endpoint / wire api ---------------------------------------
    $caseBase = New-BridgeSandbox -ConfigToml (Get-DeepSeekToml -BaseUrl "https://api.deepseek.com.evil.example") -State (Get-StandardState)
    $sandboxes.Add($caseBase)
    $checkBase = Invoke-Bridge "Check" $caseBase
    Assert-True ($checkBase.Output -match "Base URL: INVALID") "An unapproved base_url is reported INVALID"
    Assert-True ((Invoke-Bridge "Apply" $caseBase).Exit -ne 0) "An unapproved base_url fails closed"
    Assert-True (-not (Test-ScopeHasKey $caseBase "user" "DEEPSEEK_API_KEY") -and -not (Test-ScopeHasKey $caseBase "process" "DEEPSEEK_API_KEY")) "No bridging happens on an unapproved base_url"

    $caseWire = New-BridgeSandbox -ConfigToml (Get-DeepSeekToml -WireApi "chat") -State (Get-StandardState)
    $sandboxes.Add($caseWire)
    Assert-True ((Invoke-Bridge "Check" $caseWire).Output -match "Wire API: INVALID") "A non-responses wire_api is reported INVALID"
    Assert-True ((Invoke-Bridge "Apply" $caseWire).Exit -ne 0) "A non-responses wire_api fails closed"

    # --- Duplicate section / duplicate token field -------------------------
    $duplicateSection = (Get-DeepSeekToml) + "`n[model_providers.deepseek]`nbase_url = `"https://api.deepseek.com`"`n"
    $caseSection = New-BridgeSandbox -ConfigToml $duplicateSection -State (Get-StandardState)
    $sandboxes.Add($caseSection)
    $checkSection = Invoke-Bridge "Check" $caseSection
    Assert-True ($checkSection.Exit -ne 0) "A duplicate [model_providers.deepseek] section fails closed"
    Assert-True ($checkSection.Output -match "FAIL_CLOSED") "The duplicate-section failure is an explicit FAIL_CLOSED"

    $duplicateToken = Get-DeepSeekToml -Token $fakeSecret
    $duplicateToken = $duplicateToken.Replace("wire_api = `"responses`"", ("wire_api = `"responses`"`nexperimental_bearer_token = `"$fakeSecret`""))
    $caseToken = New-BridgeSandbox -ConfigToml $duplicateToken -State (Get-StandardState)
    $sandboxes.Add($caseToken)
    $checkToken = Invoke-Bridge "Check" $caseToken
    Assert-True ($checkToken.Exit -ne 0) "A duplicate experimental_bearer_token fails closed"
    Assert-True ($checkToken.Output -match "FAIL_CLOSED") "The duplicate-token failure is an explicit FAIL_CLOSED"

    # --- E1..E6: per-scope consistency (DSR3-FIX1) --------------------------
    # E1: User matches the source but Process holds a different value.
    $caseE1 = New-BridgeSandbox -ConfigToml (Get-DeepSeekToml) -State (Get-StandardState) -EnvStoreJson (Get-EnvStoreJson $fakeSecret $otherSecret)
    $sandboxes.Add($caseE1)
    $checkE1 = Invoke-Bridge "Check" $caseE1
    Assert-True ($checkE1.Output -match "SECRET_CONFLICT") "E1: User==SOURCE with a different Process value is SECRET_CONFLICT"
    Assert-True (-not ($checkE1.Output -match "ALREADY_BRIDGED")) "E1: the matching User scope never masks a conflicting Process scope"
    Assert-True ((Invoke-Bridge "Apply" $caseE1).Exit -ne 0) "E1: Apply fails closed"
    Assert-True ((Get-ScopeValue $caseE1 "user" "DEEPSEEK_API_KEY") -eq $fakeSecret -and (Get-ScopeValue $caseE1 "process" "DEEPSEEK_API_KEY") -eq $otherSecret) "E1: neither scope is modified"

    # E2: Process matches the source but User holds a different value.
    $caseE2 = New-BridgeSandbox -ConfigToml (Get-DeepSeekToml) -State (Get-StandardState) -EnvStoreJson (Get-EnvStoreJson $otherSecret $fakeSecret)
    $sandboxes.Add($caseE2)
    $checkE2 = Invoke-Bridge "Check" $caseE2
    Assert-True ($checkE2.Output -match "SECRET_CONFLICT") "E2: Process==SOURCE with a different User value is SECRET_CONFLICT"
    Assert-True ((Invoke-Bridge "Apply" $caseE2).Exit -ne 0) "E2: Apply fails closed"

    # E3: User matches, Process missing -> sync only the missing scope.
    $caseE3 = New-BridgeSandbox -ConfigToml (Get-DeepSeekToml) -State (Get-StandardState) -EnvStoreJson (Get-EnvStoreJson $fakeSecret $null)
    $sandboxes.Add($caseE3)
    $checkE3 = Invoke-Bridge "Check" $caseE3
    Assert-True ($checkE3.Output -match "SAFE_TO_SYNC_SCOPE") "E3: User==SOURCE with a missing Process scope is SAFE_TO_SYNC_SCOPE"
    Assert-True (-not ($checkE3.Output -match "ALREADY_BRIDGED")) "E3: a partial scope is never reported as ALREADY_BRIDGED"
    Assert-True ((Invoke-Bridge "Apply" $caseE3).Exit -eq 0) "E3: Apply succeeds"
    Assert-True ((Get-ScopeValue $caseE3 "user" "DEEPSEEK_API_KEY") -eq $fakeSecret) "E3: the matching User scope is not rewritten"
    Assert-True ((Get-ScopeValue $caseE3 "process" "DEEPSEEK_API_KEY") -eq $fakeSecret) "E3: the missing Process scope is created"
    $receiptE3 = Get-Content -Raw -LiteralPath (Join-Path $caseE3.CodexHome "multimodel-manager/deepseek-router-bridge-receipt.json") | ConvertFrom-Json
    Assert-True ($receiptE3.user_env_created_by_dsr3 -eq $false -and $receiptE3.process_env_created_by_dsr3 -eq $true) "E3: receipt records per-scope ownership false/true"
    Assert-True ($receiptE3.env_created_by_dsr3 -eq $true) "E3: the compatibility aggregate stays true"
    [void](Invoke-Bridge "Rollback" $caseE3)
    Assert-True ((Get-ScopeValue $caseE3 "user" "DEEPSEEK_API_KEY") -eq $fakeSecret) "E3: Rollback keeps the pre-existing User scope"
    Assert-True (-not (Test-ScopeHasKey $caseE3 "process" "DEEPSEEK_API_KEY")) "E3: Rollback removes only the Process scope"

    # E4: Process matches, User missing -> sync only the missing scope.
    $caseE4 = New-BridgeSandbox -ConfigToml (Get-DeepSeekToml) -State (Get-StandardState) -EnvStoreJson (Get-EnvStoreJson $null $fakeSecret)
    $sandboxes.Add($caseE4)
    $checkE4 = Invoke-Bridge "Check" $caseE4
    Assert-True ($checkE4.Output -match "SAFE_TO_SYNC_SCOPE") "E4: Process==SOURCE with a missing User scope is SAFE_TO_SYNC_SCOPE"
    Assert-True ((Invoke-Bridge "Apply" $caseE4).Exit -eq 0) "E4: Apply succeeds"
    Assert-True ((Get-ScopeValue $caseE4 "user" "DEEPSEEK_API_KEY") -eq $fakeSecret) "E4: the missing User scope is created"
    Assert-True ((Get-ScopeValue $caseE4 "process" "DEEPSEEK_API_KEY") -eq $fakeSecret) "E4: the matching Process scope is not rewritten"
    $receiptE4 = Get-Content -Raw -LiteralPath (Join-Path $caseE4.CodexHome "multimodel-manager/deepseek-router-bridge-receipt.json") | ConvertFrom-Json
    Assert-True ($receiptE4.user_env_created_by_dsr3 -eq $true -and $receiptE4.process_env_created_by_dsr3 -eq $false) "E4: receipt records per-scope ownership true/false"
    [void](Invoke-Bridge "Rollback" $caseE4)
    Assert-True (Test-ScopeHasKey $caseE4 "process" "DEEPSEEK_API_KEY") "E4: Rollback keeps the pre-existing Process scope"
    Assert-True (-not (Test-ScopeHasKey $caseE4 "user" "DEEPSEEK_API_KEY")) "E4: Rollback removes only the User scope"

    # E5: both scopes already match -> nothing is written.
    $caseE5 = New-BridgeSandbox -ConfigToml (Get-DeepSeekToml) -State (Get-StandardState) -EnvStoreJson (Get-EnvStoreJson $fakeSecret $fakeSecret)
    $sandboxes.Add($caseE5)
    $checkE5 = Invoke-Bridge "Check" $caseE5
    Assert-True ($checkE5.Output -match "ALREADY_BRIDGED") "E5: both scopes matching the source is ALREADY_BRIDGED"
    $applyE5 = Invoke-Bridge "Apply" $caseE5
    Assert-True ($applyE5.Output -match "NO_CHANGE_REQUIRED") "E5: Apply reports NO_CHANGE_REQUIRED"
    Assert-True ((Get-ScopeValue $caseE5 "user" "DEEPSEEK_API_KEY") -eq $fakeSecret -and (Get-ScopeValue $caseE5 "process" "DEEPSEEK_API_KEY") -eq $fakeSecret) "E5: neither scope is written"
    $receiptE5 = Get-Content -Raw -LiteralPath (Join-Path $caseE5.CodexHome "multimodel-manager/deepseek-router-bridge-receipt.json") | ConvertFrom-Json
    Assert-True ($receiptE5.user_env_created_by_dsr3 -eq $false -and $receiptE5.process_env_created_by_dsr3 -eq $false -and $receiptE5.env_created_by_dsr3 -eq $false) "E5: receipt records that DSR3 created nothing"

    # E6: both scopes missing -> create both, and roll both back.
    $caseE6 = New-BridgeSandbox -ConfigToml (Get-DeepSeekToml) -State (Get-StandardState) -EnvStoreJson (Get-EnvStoreJson $null $null)
    $sandboxes.Add($caseE6)
    $checkE6 = Invoke-Bridge "Check" $caseE6
    Assert-True ($checkE6.Output -match "SAFE_TO_BRIDGE") "E6: both scopes missing is SAFE_TO_BRIDGE"
    [void](Invoke-Bridge "Apply" $caseE6)
    Assert-True ((Get-ScopeValue $caseE6 "user" "DEEPSEEK_API_KEY") -eq $fakeSecret -and (Get-ScopeValue $caseE6 "process" "DEEPSEEK_API_KEY") -eq $fakeSecret) "E6: Apply creates both scopes"
    [void](Invoke-Bridge "Rollback" $caseE6)
    Assert-True (-not (Test-ScopeHasKey $caseE6 "user" "DEEPSEEK_API_KEY") -and -not (Test-ScopeHasKey $caseE6 "process" "DEEPSEEK_API_KEY")) "E6: Rollback removes both scopes"

    # --- Rollback ------------------------------------------------------------
    $rollbackCreated = Invoke-Bridge "Rollback" $caseA
    Assert-True ($rollbackCreated.Exit -eq 0) "Rollback exits 0"
    Assert-True (-not (Test-ScopeHasKey $caseA "user" "DEEPSEEK_API_KEY") -and -not (Test-ScopeHasKey $caseA "process" "DEEPSEEK_API_KEY")) "Rollback removes both scopes DSR3 created"
    $restoredState = Get-Content -Raw -LiteralPath (Join-Path $caseA.CodexHome "multimodel-manager/state.json") | ConvertFrom-Json
    Assert-True ($restoredState.PSObject.Properties.Name -notcontains "deepseek_enabled") "Rollback restores the pre-DSR3 state file"
    Assert-True ([string]$restoredState.custom_keep_me -eq "user-value") "Rollback keeps unrelated state fields"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $caseA.CodexHome "multimodel-manager/deepseek-router-bridge-receipt.json"))) "Rollback clears the receipt"
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $caseA.CodexHome "config.toml")) -eq $configBefore) "Rollback never touches config.toml"

    $rollbackPreExisting = Invoke-Bridge "Rollback" $caseB
    Assert-True ($rollbackPreExisting.Exit -eq 0) "Rollback on a pre-existing variable exits 0"
    Assert-True ((Get-ScopeValue $caseB "user" "DEEPSEEK_API_KEY") -eq $fakeSecret -and (Get-ScopeValue $caseB "process" "DEEPSEEK_API_KEY") -eq $fakeSecret) "Rollback never removes a pre-existing DEEPSEEK_API_KEY"
    Assert-True ($rollbackPreExisting.Output -match "Kept pre-existing") "Rollback reports that it kept the pre-existing scope"

    # --- Legacy schema-v1 receipt compatibility -----------------------------
    foreach ($legacyCreated in @($true, $false)) {
        $caseLegacy = New-BridgeSandbox -ConfigToml (Get-DeepSeekToml) -State (Get-StandardState) -EnvStoreJson (Get-EnvStoreJson $fakeSecret $fakeSecret)
        $sandboxes.Add($caseLegacy)
        $legacyBackup = Join-Path $caseLegacy.Root "legacy-backup"
        New-Item -ItemType Directory -Force -Path $legacyBackup | Out-Null
        $legacyReceipt = [ordered]@{
            schema_version = 1
            applied_at = (Get-Date -Format "o")
            source = "direct_deepseek_config"
            target_env = "DEEPSEEK_API_KEY"
            env_created_by_dsr3 = $legacyCreated
            state_changed = $true
            candidates_changed = $false
            backup_directory = $legacyBackup
        }
        ($legacyReceipt | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $caseLegacy.CodexHome "multimodel-manager/deepseek-router-bridge-receipt.json") -Encoding UTF8
        $rollbackLegacy = Invoke-Bridge "Rollback" $caseLegacy
        Assert-True ($rollbackLegacy.Exit -eq 0) "Legacy receipt (env_created_by_dsr3=$legacyCreated) rolls back without error"
        if ($legacyCreated) {
            Assert-True (-not (Test-ScopeHasKey $caseLegacy "user" "DEEPSEEK_API_KEY") -and -not (Test-ScopeHasKey $caseLegacy "process" "DEEPSEEK_API_KEY")) "Legacy receipt with env_created_by_dsr3=true removes both scopes"
        }
        else {
            Assert-True ((Get-ScopeValue $caseLegacy "user" "DEEPSEEK_API_KEY") -eq $fakeSecret -and (Get-ScopeValue $caseLegacy "process" "DEEPSEEK_API_KEY") -eq $fakeSecret) "Legacy receipt with env_created_by_dsr3=false keeps both scopes"
        }
    }
}
catch {
    Fail "DeepSeek secret bridge validation failed: $($_.Exception.Message)"
}
finally {
    foreach ($sandbox in $sandboxes) {
        Remove-Item -LiteralPath $sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "DeepSeek secret bridge validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}
Write-Host "DeepSeek secret bridge validation PASSED" -ForegroundColor Green
exit 0
