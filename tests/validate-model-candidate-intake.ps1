param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# NPG1-CANDIDATE-INTAKE validation.
#
# The intake entry point exists to bring a model that is ALREADY present in the
# canonical installer/model-catalog.json into the review chain, because
# discover-models.ps1 only ever candidates models that appear after a discovery
# baseline exists.
#
# Everything below is offline and fixture only: each scenario runs against a
# throw-away CODEX_HOME with a synthetic state.json, the intake script performs
# no network access at all, and the user's real ~/.codex is never read or
# written.

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Pass $Message } else { Fail $Message }
}

function Assert-ThrowsMatch([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $matched = $false
    try { & $Action | Out-Null } catch { $matched = ($_.Exception.Message -match $Pattern) }
    Assert-True $matched $Message
}

function Save-ProcessEnvSnapshot {
    $names = @("CODEX_HOME", "RUNNER_TEMP") | Sort-Object -Unique
    $snapshot = [ordered]@{}
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        $snapshot[$name] = if ($null -eq $value) { $null } else { [string]$value }
    }
    return $snapshot
}

function Restore-ProcessEnvSnapshot($Snapshot) {
    foreach ($entry in $Snapshot.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            Remove-Item -Path ("Env:" + $entry.Key) -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -Path ("Env:" + $entry.Key) -Value ([string]$entry.Value) -ErrorAction SilentlyContinue
        }
    }
}

$script:IntakeScriptPath = Join-Path $RepositoryRoot "installer/scripts/intake-model-candidate.ps1"

function New-IntakeSandbox {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-mm-intake-" + [guid]::NewGuid().ToString("N"))
    $codexHome = Join-Path $root "codex-home"
    New-Item -ItemType Directory -Force -Path (Join-Path $codexHome "multimodel-manager") | Out-Null
    # Only mm_modelstudio, mm_mimo and mm_openrouter are enabled; mm_xai and
    # mm_openai_api stay absent so the "provider not enabled" scenario is real.
    $state = [ordered]@{
        openrouter_enabled = $true
        openrouter_default_model = ""
        mimo_enabled = $true
        mimo_base_url = "https://example.invalid/v1"
        mimo_mode = "payg"
        aliyun_enabled = $true
        aliyun_base_url = "https://example.invalid/compatible-mode/v1"
        aliyun_mode = "trial-beijing"
        # DSR2: the direct DeepSeek provider is a first-class Manager provider
        # identity. It stays gated on this explicit flag and is never discovered.
        deepseek_enabled = $true
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $codexHome "multimodel-manager/state.json") -Encoding UTF8
    return [pscustomobject]@{ Root = $root; CodexHome = $codexHome }
}

function Get-CandidatesFilePath([string]$CodexHome) {
    return (Join-Path $CodexHome "multimodel-manager/candidates.json")
}

function Get-ApprovedFilePath([string]$CodexHome) {
    return (Join-Path $CodexHome "multimodel-manager/approved-models.json")
}

function Get-CandidateRecords([string]$CodexHome) {
    $path = Get-CandidatesFilePath $CodexHome
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    return @(Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-Intake([string]$ProviderId, [string]$ModelId, [string]$DisplayName = "") {
    $arguments = @{ ProviderId = $ProviderId; ModelId = $ModelId }
    if (-not [string]::IsNullOrWhiteSpace($DisplayName)) { $arguments["DisplayName"] = $DisplayName }
    return (& $script:IntakeScriptPath @arguments *>&1 | Out-String)
}

if (-not (Test-Path -LiteralPath $script:IntakeScriptPath -PathType Leaf)) {
    Fail "Formal intake entry point is missing: $script:IntakeScriptPath"
    Write-Host ""
    Write-Host "Local Router model candidate intake validation FAILED (missing script)" -ForegroundColor Red
    exit 1
}

$intakeText = Get-Content -Raw -LiteralPath $script:IntakeScriptPath

# --- K. The intake entry point is offline by construction --------------------
# The check is deliberately mention-level rather than call-level: the intake
# script must not name the network primitives or the discovery/probe/approval
# entry points at all, so the guarantee never depends on parsing invocation
# syntax correctly.
$forbiddenMarkers = [ordered]@{
    "Invoke-RestMethod" = "HTTP request"
    "Invoke-WebRequest" = "HTTP request"
    "Invoke-ModelsEndpoint" = "provider model-list discovery"
    "discover-models.ps1" = "discovery entry point"
    "probe-model.ps1" = "live probe entry point"
    "approve-model.ps1" = "approval entry point"
}
foreach ($marker in $forbiddenMarkers.GetEnumerator()) {
    Assert-True (-not $intakeText.Contains($marker.Key)) "K: intake contains no $($marker.Key) ($($marker.Value))"
}
Assert-True ($intakeText.Contains('_registry.ps1')) "K: intake reuses the shared registry helper module"

# --- L. A canonical catalog status is never turned into a probe result -------
Assert-True (-not ($intakeText -match 'basic_probe\s*=\s*"PASS"')) "L: intake never writes basic_probe=PASS"
Assert-True ($intakeText -match 'basic_probe\s*=\s*"NOT_RUN"') "L: intake always starts a candidate at basic_probe=NOT_RUN"
Assert-True ($intakeText -match 'tool_probe\s*=\s*"NOT_RUN"') "L: intake always starts a candidate at tool_probe=NOT_RUN"
Assert-True (-not ($intakeText -match '\$catalogModel\.status[^\r\n]*basic_probe')) "L: catalog status is never mapped onto basic_probe"
Assert-True ($intakeText.Contains("model-catalog.json")) "Intake resolves the canonical catalog"
Assert-True ($intakeText.Contains('Convert-ControllerProviderId')) "Intake reuses the canonical provider mapping"
Assert-True ($intakeText.Contains('"::"')) "Intake keeps the provider_id::model_id candidate key"
Assert-True (-not ($intakeText -match '(?i)deepseek')) "Intake carries no model-specific bypass"

$envBefore = Save-ProcessEnvSnapshot
$sandbox = $null
try {
    $sandbox = New-IntakeSandbox
    $env:CODEX_HOME = $sandbox.CodexHome
    $candidatesFilePath = Get-CandidatesFilePath $sandbox.CodexHome

    Assert-True (-not (Test-Path -LiteralPath $candidatesFilePath -PathType Leaf)) "Sandbox starts without a candidate registry"

    # --- A + C. Canonical modelstudio model is added as a NEW candidate -------
    $outputPro = Invoke-Intake "mm_modelstudio" "deepseek-v4-pro" "DeepSeek-V4-Pro"
    Assert-True ($outputPro -match "ADDED") "A: canonical mm_modelstudio/deepseek-v4-pro is added"
    Assert-True (Test-Path -LiteralPath $candidatesFilePath -PathType Leaf) "A: intake creates the candidate registry"
    $records = Get-CandidateRecords $sandbox.CodexHome
    Assert-True (@($records).Count -eq 1) "A: exactly one candidate record was written"
    $pro = @($records | Where-Object { [string]$_.key -eq "mm_modelstudio::deepseek-v4-pro" }) | Select-Object -First 1
    Assert-True ($null -ne $pro) "A: candidate key is provider_id::model_id"
    Assert-True ([string]$pro.provider_id -eq "mm_modelstudio" -and [string]$pro.model_id -eq "deepseek-v4-pro") "A: provider and model ids are recorded verbatim"
    Assert-True ([string]$pro.provider_name -eq "Alibaba Model Studio") "A: provider_name comes from the configured provider map"
    Assert-True ([string]$pro.name -eq "DeepSeek-V4-Pro") "A: the explicit display name is recorded"
    Assert-True ([string]$pro.notes -match "canonical-catalog intake") "A: notes mark the intake source"
    Assert-True ([bool]$pro.approved -eq $false) "C: a new candidate is not approved"
    Assert-True ([string]$pro.status -eq "NEW") "C: a new candidate starts at status=NEW"
    Assert-True ([string]$pro.basic_probe -eq "NOT_RUN") "C: basic_probe stays NOT_RUN even though the catalog says verified"
    Assert-True ([string]$pro.tool_probe -eq "NOT_RUN") "C: tool_probe starts at NOT_RUN"

    # --- B. The second canonical target is added as well ---------------------
    $outputFlash = Invoke-Intake "mm_modelstudio" "deepseek-v4-flash" "DeepSeek-V4-Flash"
    Assert-True ($outputFlash -match "ADDED") "B: canonical mm_modelstudio/deepseek-v4-flash is added"
    $records = Get-CandidateRecords $sandbox.CodexHome
    Assert-True (@($records).Count -eq 2) "B: both targets exist in the registry"
    $flash = @($records | Where-Object { [string]$_.key -eq "mm_modelstudio::deepseek-v4-flash" }) | Select-Object -First 1
    Assert-True ($null -ne $flash) "B: the flash candidate is present"
    Assert-True ([string]$flash.status -eq "NEW" -and [string]$flash.basic_probe -eq "NOT_RUN" -and [string]$flash.tool_probe -eq "NOT_RUN") "B: the flash candidate starts unprobed"
    Assert-True ([bool]$flash.approved -eq $false) "B: the flash candidate is not approved"

    # --- D. Repeated intake is a no-op and never rewrites the registry -------
    $bytesBeforeRepeat = Get-FileSha256 $candidatesFilePath
    $outputRepeat = Invoke-Intake "mm_modelstudio" "deepseek-v4-pro" "DeepSeek-V4-Pro"
    Assert-True ($outputRepeat -match "ALREADY_CANDIDATE") "D: a repeated intake reports ALREADY_CANDIDATE"
    Assert-True ((Get-FileSha256 $candidatesFilePath) -eq $bytesBeforeRepeat) "D: a repeated intake leaves the registry bytes unchanged"
    Assert-True (@(Get-CandidateRecords $sandbox.CodexHome).Count -eq 2) "D: a repeated intake adds no duplicate record"

    # --- E. Additive merge preserves every other candidate -------------------
    $seeded = @(Get-CandidateRecords $sandbox.CodexHome)
    $seeded += [pscustomobject]@{
        key = "mm_openrouter::stealth/ox-alpha"
        provider_id = "mm_openrouter"
        provider_name = "OpenRouter"
        model_id = "stealth/ox-alpha"
        name = "Ox Alpha"
        first_seen = "2026-01-01T00:00:00Z"
        status = "VERIFIED"
        basic_probe = "PASS"
        tool_probe = "PASS"
        approved = $true
        notes = "pre-existing approved record"
    }
    ConvertTo-Json -InputObject @($seeded) -Depth 20 | Set-Content -LiteralPath $candidatesFilePath -Encoding UTF8
    $outputThird = Invoke-Intake "mm_modelstudio" "qwen3-coder-plus" "Qwen3 Coder Plus"
    Assert-True ($outputThird -match "ADDED") "E: intake adds another canonical model additively"
    $recordsAfter = Get-CandidateRecords $sandbox.CodexHome
    Assert-True (@($recordsAfter).Count -eq 4) "E: every existing candidate is preserved (3 before + 1 added)"
    Assert-True (@($recordsAfter | Where-Object { [string]$_.key -eq "mm_openrouter::stealth/ox-alpha" }).Count -eq 1) "E: the pre-existing record survives the merge"
    Assert-True (@($recordsAfter | Where-Object { [string]$_.key -eq "mm_modelstudio::deepseek-v4-pro" }).Count -eq 1) "E: earlier intake records survive the merge"
    Assert-True (@($recordsAfter | Where-Object { [string]$_.key -eq "mm_modelstudio::qwen3-coder-plus" }).Count -eq 1) "E: the newly added record is present exactly once"

    # --- F. An approved candidate is never downgraded ------------------------
    $bytesBeforeApproved = Get-FileSha256 $candidatesFilePath
    $outputApproved = Invoke-Intake "mm_openrouter" "stealth/ox-alpha" "Ox Alpha"
    Assert-True ($outputApproved -match "ALREADY_APPROVED") "F: an approved candidate reports ALREADY_APPROVED"
    Assert-True ((Get-FileSha256 $candidatesFilePath) -eq $bytesBeforeApproved) "F: an approved candidate leaves the registry bytes unchanged"
    $ox = @(Get-CandidateRecords $sandbox.CodexHome | Where-Object { [string]$_.key -eq "mm_openrouter::stealth/ox-alpha" }) | Select-Object -First 1
    Assert-True ([string]$ox.status -eq "VERIFIED") "F: an approved record is not downgraded to NEW"
    Assert-True ([bool]$ox.approved) "F: the approved flag is preserved"

    # --- G. A model that is not canonical fails closed -----------------------
    Assert-ThrowsMatch { Invoke-Intake "mm_modelstudio" "no-such-model-xyz" } "not in the canonical catalog" "G: an unknown model fails closed"
    Assert-True ((Get-FileSha256 $candidatesFilePath) -eq $bytesBeforeApproved) "G: the failed intake leaves the registry untouched"

    # --- H. A canonical model under the wrong provider fails closed ----------
    Assert-ThrowsMatch { Invoke-Intake "mm_openrouter" "deepseek-v4-pro" } "Provider/model mismatch" "H: a canonical model claimed by the wrong provider fails closed"
    Assert-True ((Get-FileSha256 $candidatesFilePath) -eq $bytesBeforeApproved) "H: the mismatched intake leaves the registry untouched"

    # --- I. A provider that is not enabled fails closed ----------------------
    Assert-ThrowsMatch { Invoke-Intake "mm_xai" "grok-4" } "not configured or not enabled" "I: a provider that is not enabled fails closed"
    Assert-True ((Get-FileSha256 $candidatesFilePath) -eq $bytesBeforeApproved) "I: the disabled-provider intake leaves the registry untouched"

    # --- J. A corrupt registry fails closed and is never rebuilt ------------
    $corruptText = "{ this is not json"
    Set-Content -LiteralPath $candidatesFilePath -Value $corruptText -Encoding UTF8
    $corruptBefore = Get-Content -Raw -LiteralPath $candidatesFilePath
    Assert-ThrowsMatch { Invoke-Intake "mm_modelstudio" "deepseek-v4-pro" } "cannot be parsed" "J: a corrupt candidate registry fails closed"
    Assert-True ((Get-Content -Raw -LiteralPath $candidatesFilePath) -eq $corruptBefore) "J: the corrupt registry is neither rebuilt nor overwritten"

    # --- DSR2: the direct DeepSeek provider is a first-class intake target ----
    $dsr2Sandbox = New-IntakeSandbox
    $env:CODEX_HOME = $dsr2Sandbox.CodexHome
    foreach ($modelId in @("deepseek-flash", "deepseek-v4-pro")) {
        $outputDsr2 = Invoke-Intake "deepseek" $modelId ""
        Assert-True ($outputDsr2 -match "ADDED") "DSR2 intake: canonical direct DeepSeek model $modelId is added"
    }
    $outputProviderScoped = Invoke-Intake "mm_modelstudio" "deepseek-v4-pro" ""
    Assert-True ($outputProviderScoped -match "ADDED") "DSR2 intake: the same model id is intaken separately under mm_modelstudio"

    $dsr2Records = Get-CandidateRecords $dsr2Sandbox.CodexHome
    Assert-True (@($dsr2Records).Count -eq 3) "DSR2 intake: every provider-scoped candidate is recorded independently"
    foreach ($pair in @(@("deepseek", "deepseek-flash"), @("deepseek", "deepseek-v4-pro"), @("mm_modelstudio", "deepseek-v4-pro"))) {
        $record = @($dsr2Records | Where-Object { [string]$_.key -eq ($pair[0] + "::" + $pair[1]) }) | Select-Object -First 1
        Assert-True ($null -ne $record) "DSR2 intake: candidate key is $($pair[0])::$($pair[1])"
        if ($null -ne $record) {
            Assert-True ([string]$record.provider_id -eq $pair[0]) "DSR2 intake: provider scope stays $($pair[0])"
            Assert-True ([string]$record.status -eq "NEW" -and [string]$record.basic_probe -eq "NOT_RUN" -and [string]$record.tool_probe -eq "NOT_RUN") "DSR2 intake: $($pair[1]) under $($pair[0]) starts unprobed"
            Assert-True ([bool]$record.approved -eq $false) "DSR2 intake: $($pair[1]) under $($pair[0]) is not auto-approved"
        }
    }
    Assert-True (-not (Test-Path -LiteralPath (Get-ApprovedFilePath $dsr2Sandbox.CodexHome) -PathType Leaf)) "DSR2 intake: no approval record is created"
    Remove-Item -LiteralPath $dsr2Sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue

    # --- The intake never approves on its own --------------------------------
    Assert-True (-not (Test-Path -LiteralPath (Get-ApprovedFilePath $sandbox.CodexHome) -PathType Leaf)) "Intake never creates or approves approved-models.json"
}
catch {
    Fail "Local Router model candidate intake validation failed: $($_.Exception.Message)"
}
finally {
    Restore-ProcessEnvSnapshot $envBefore
    if ($null -ne $sandbox) { Remove-Item -LiteralPath $sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

$envAfter = Save-ProcessEnvSnapshot
$differences = New-Object System.Collections.Generic.List[string]
foreach ($entry in $envBefore.GetEnumerator()) {
    $after = $envAfter[$entry.Key]
    if ($null -eq $entry.Value -and $null -eq $after) { continue }
    if ($null -ne $entry.Value -and $null -ne $after -and $entry.Value -eq $after) { continue }
    $differences.Add($entry.Key)
}
Assert-True ($differences.Count -eq 0) "Validator Process environment snapshot is restored exactly (before == after)"

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Local Router model candidate intake validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}
Write-Host "Local Router model candidate intake validation PASSED" -ForegroundColor Green
exit 0
