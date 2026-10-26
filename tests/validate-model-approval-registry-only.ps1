param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR5 - REGISTRY-ONLY MODEL APPROVAL validation.
#
# approve-model.ps1 used to always project an approval into Codex config: it
# wrote a legacy AUTO MODELS block into config.toml, then migrated that block
# into Profile V2 dedicated *.config.toml files. The Local Router bootstrap only
# needs the formal approved-model registry record, so the entry point now takes
# an explicit -RegistryOnly switch that keeps every admission check and every
# registry write and skips only the Codex-config/profile side effects.
#
# Everything below is offline and fixture only: every scenario runs against a
# throw-away CODEX_HOME with synthetic state/candidate/config/models fixtures,
# no provider request is issued anywhere, and the real ~/.codex is never read
# or written.

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

$script:ApproveScriptPath = Join-Path $RepositoryRoot "installer/scripts/approve-model.ps1"

function Get-FileSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "<missing>" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CandidatesFilePath([string]$CodexHome) {
    return (Join-Path $CodexHome "multimodel-manager/candidates.json")
}

function Get-ApprovedFilePath([string]$CodexHome) {
    return (Join-Path $CodexHome "multimodel-manager/approved-models.json")
}

function Get-ConfigPath([string]$CodexHome) { return (Join-Path $CodexHome "config.toml") }
function Get-ModelsPath([string]$CodexHome) { return (Join-Path $CodexHome "models.json") }
function Get-ProfileManifestPath([string]$CodexHome) {
    return (Join-Path $CodexHome "multimodel-manager/profile-v2-files.json")
}

function Get-CandidateRecords([string]$CodexHome) {
    $path = Get-CandidatesFilePath $CodexHome
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    return @(Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}

function Get-ApprovedRecords([string]$CodexHome) {
    $path = Get-ApprovedFilePath $CodexHome
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    return @(Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}

function Get-Candidate([string]$CodexHome, [string]$ProviderId, [string]$ModelId) {
    return @(Get-CandidateRecords $CodexHome |
        Where-Object { [string]$_.provider_id -eq $ProviderId -and [string]$_.model_id -eq $ModelId }) |
        Select-Object -First 1
}

function Get-Approved([string]$CodexHome, [string]$ProviderId, [string]$ModelId) {
    return @(Get-ApprovedRecords $CodexHome |
        Where-Object { [string]$_.provider_id -eq $ProviderId -and [string]$_.model_id -eq $ModelId }) |
        Select-Object -First 1
}

# The Direct DeepSeek config shape: root model keys plus the direct provider
# block. Registry-only approval must leave all of this byte-identical.
$script:DirectConfigToml = @'
# user-config-sentinel: must survive every approval mode
model = "deepseek-chat"
model_provider = "deepseek"
model_catalog_json = "models.json"

[model_providers.deepseek]
name = "DeepSeek (Direct Mode)"
base_url = "https://api.deepseek.com"
wire_api = "responses"
'@

$script:NativeModelsJson = @'
{
  "models": [
    { "slug": "deepseek-v4-flash", "display_name": "DeepSeek V4.1 Flash" },
    { "slug": "deepseek-v4-pro", "display_name": "DeepSeek V4 Pro" },
    { "slug": "deepseek-v4-flash-vision-exp", "display_name": "DeepSeek V4.1 Flash Vision" }
  ]
}
'@

function New-ApprovalSandbox {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-mm-approve-" + [guid]::NewGuid().ToString("N"))
    $codexHome = Join-Path $root "codex-home"
    $managerHome = Join-Path $codexHome "multimodel-manager"
    New-Item -ItemType Directory -Force -Path $managerHome | Out-Null

    $state = [ordered]@{
        openrouter_enabled = $true
        openrouter_default_model = ""
        mimo_enabled = $true
        mimo_base_url = "https://example.invalid/v1"
        aliyun_enabled = $true
        aliyun_base_url = "https://example.invalid/compatible-mode/v1"
        deepseek_enabled = $true
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $managerHome "state.json") -Encoding UTF8

    # Fixture candidates: the two direct DeepSeek targets already passed their
    # live basic probe, the Model Studio duplicate never ran a probe, and one
    # record deliberately failed its probe so the fail-closed path is real.
    $candidates = @(
        [ordered]@{
            key = "deepseek::deepseek-flash"; provider_id = "deepseek"; model_id = "deepseek-flash"
            provider_name = "DeepSeek Official"; name = "DeepSeek V4.1 Flash"
            status = "RESPONSES_PASS"; basic_probe = "PASS"; tool_probe = "NOT_RUN"; approved = $false; notes = ""
        },
        [ordered]@{
            key = "deepseek::deepseek-v4-pro"; provider_id = "deepseek"; model_id = "deepseek-v4-pro"
            provider_name = "DeepSeek Official"; name = "DeepSeek V4 Pro"
            status = "RESPONSES_PASS"; basic_probe = "PASS"; tool_probe = "NOT_RUN"; approved = $false; notes = ""
        },
        [ordered]@{
            key = "mm_modelstudio::deepseek-v4-pro"; provider_id = "mm_modelstudio"; model_id = "deepseek-v4-pro"
            provider_name = "Alibaba Model Studio"; name = "DeepSeek V4 Pro"
            # Fixture only: this record carries the same model id as the direct
            # DeepSeek target so case F can prove the two provider scopes never
            # overwrite each other.
            status = "RESPONSES_PASS"; basic_probe = "PASS"; tool_probe = "NOT_RUN"; approved = $false; notes = ""
        },
        [ordered]@{
            key = "deepseek::deepseek-unverified"; provider_id = "deepseek"; model_id = "deepseek-unverified"
            provider_name = "DeepSeek Official"; name = "DeepSeek Unverified"
            status = "PROBE_FAILED"; basic_probe = "FAIL"; tool_probe = "NOT_RUN"; approved = $false; notes = "fixture"
        }
    )
    ConvertTo-Json -InputObject $candidates -Depth 10 |
        Set-Content -LiteralPath (Join-Path $managerHome "candidates.json") -Encoding UTF8

    Set-Content -LiteralPath (Join-Path $codexHome "config.toml") -Value $script:DirectConfigToml -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $codexHome "models.json") -Value $script:NativeModelsJson -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $managerHome "profile-v2-files.json") -Value '["mm_gpt56_chatgpt"]' -Encoding UTF8

    return [pscustomobject]@{ Root = $root; CodexHome = $codexHome }
}

function Invoke-Approval {
    param(
        [string]$ProviderId,
        [string]$ModelId,
        [string]$DisplayName = "",
        [switch]$RegistryOnly
    )
    $arguments = @{ ProviderId = $ProviderId; ModelId = $ModelId }
    if (-not [string]::IsNullOrWhiteSpace($DisplayName)) { $arguments["DisplayName"] = $DisplayName }
    if ($RegistryOnly.IsPresent) { $arguments["RegistryOnly"] = $true }
    return (& $script:ApproveScriptPath @arguments *>&1 | Out-String)
}

if (-not (Test-Path -LiteralPath $script:ApproveScriptPath -PathType Leaf)) {
    Fail "Formal approval entry point is missing: $script:ApproveScriptPath"
    Write-Host ""
    Write-Host "Registry-only model approval validation FAILED (missing script)" -ForegroundColor Red
    exit 1
}

$approveText = Get-Content -Raw -LiteralPath $script:ApproveScriptPath

# --- Static contract --------------------------------------------------------
Assert-True ($approveText -match '\[switch\]\$RegistryOnly') "RegistryOnly: the entry point declares an explicit -RegistryOnly switch"
Assert-True ($approveText -notmatch '\[switch\]\$RegistryOnly\s*=\s*\$true') "RegistryOnly: the switch is not enabled by default"
Assert-True (-not $approveText.Contains("Invoke-RestMethod")) "RegistryOnly: the approval entry point issues no HTTP request (Invoke-RestMethod)"
Assert-True (-not $approveText.Contains("Invoke-WebRequest")) "RegistryOnly: the approval entry point issues no HTTP request (Invoke-WebRequest)"
Assert-True (-not ($approveText -match '&\s*\(Join-Path[^\r\n]*probe-model\.ps1')) "RegistryOnly: approval never launches the live probe entry point"
Assert-True (-not ($approveText -match '&\s*\(Join-Path[^\r\n]*discover-models\.ps1')) "RegistryOnly: approval never launches the discovery entry point"
Assert-True ($approveText.Contains("# >>> CODEX AUTO MODELS BEGIN")) "H: the legacy AUTO MODELS projection is still implemented"
Assert-True ($approveText.Contains("migrate-profile-v2.ps1")) "H: the legacy Profile V2 migration call is still implemented"
Assert-True ($approveText.Contains("Approval mode: REGISTRY_ONLY")) "RegistryOnly: the mode is stated explicitly in the output"
Assert-True ($approveText.Contains("Approval mode: LEGACY_PROFILE")) "H: the legacy mode is stated explicitly in the output"

$envBefore = Save-ProcessEnvSnapshot
$sandboxes = New-Object System.Collections.Generic.List[object]
try {
    # --- A + B + C + E + F + G: registry-only approval ----------------------
    $sandbox = New-ApprovalSandbox
    $sandboxes.Add($sandbox)
    $env:CODEX_HOME = $sandbox.CodexHome

    $configPath = Get-ConfigPath $sandbox.CodexHome
    $modelsPath = Get-ModelsPath $sandbox.CodexHome
    $manifestPath = Get-ProfileManifestPath $sandbox.CodexHome
    $candidatesPath = Get-CandidatesFilePath $sandbox.CodexHome
    $approvedPath = Get-ApprovedFilePath $sandbox.CodexHome

    $configBefore = Get-FileSha256 $configPath
    $modelsBefore = Get-FileSha256 $modelsPath
    $manifestBefore = Get-FileSha256 $manifestPath
    $tomlFilesBefore = @(Get-ChildItem -LiteralPath $sandbox.CodexHome -File -Filter "*.config.toml").Count
    Assert-True (-not (Test-Path -LiteralPath $approvedPath -PathType Leaf)) "Sandbox starts without an approved-model registry"

    # A. deepseek-flash
    $outputFlash = Invoke-Approval -ProviderId "deepseek" -ModelId "deepseek-flash" -DisplayName "DeepSeek V4.1 Flash" -RegistryOnly
    Assert-True ($outputFlash -match "Approval mode: REGISTRY_ONLY") "A: the run reports the REGISTRY_ONLY approval mode"
    $flashApproved = Get-Approved $sandbox.CodexHome "deepseek" "deepseek-flash"
    Assert-True ($null -ne $flashApproved) "A: deepseek::deepseek-flash lands in the approved registry"
    Assert-True ([string]$flashApproved.provider_id -eq "deepseek") "A: the approved record keeps provider_id=deepseek"
    Assert-True ([string]$flashApproved.model_id -eq "deepseek-flash") "A: the approved record keeps model_id=deepseek-flash"
    Assert-True ([string]$flashApproved.display_name -eq "DeepSeek V4.1 Flash") "A: the explicit display name is recorded"
    $flashCandidate = Get-Candidate $sandbox.CodexHome "deepseek" "deepseek-flash"
    Assert-True ([string]$flashCandidate.status -eq "APPROVED") "A: the flash candidate becomes status=APPROVED"
    Assert-True ([bool]$flashCandidate.approved -eq $true) "A: the flash candidate becomes approved=true"
    Assert-True ([string]$flashCandidate.basic_probe -eq "PASS") "A: basic_probe stays PASS"

    # B. deepseek-v4-pro
    $outputPro = Invoke-Approval -ProviderId "deepseek" -ModelId "deepseek-v4-pro" -DisplayName "DeepSeek V4 Pro" -RegistryOnly
    Assert-True ($outputPro -match "Approval mode: REGISTRY_ONLY") "B: the pro run reports the REGISTRY_ONLY approval mode"
    $proApproved = Get-Approved $sandbox.CodexHome "deepseek" "deepseek-v4-pro"
    Assert-True ($null -ne $proApproved) "B: deepseek::deepseek-v4-pro lands in the approved registry"
    $proCandidate = Get-Candidate $sandbox.CodexHome "deepseek" "deepseek-v4-pro"
    Assert-True ([string]$proCandidate.status -eq "APPROVED" -and [bool]$proCandidate.approved -eq $true) "B: the pro candidate becomes APPROVED"
    Assert-True ([string]$proCandidate.basic_probe -eq "PASS") "B: the pro basic probe result is preserved"

    # C. tool_probe=NOT_RUN must not block approval and must never be upgraded
    Assert-True ([string]$flashApproved.tool_probe -eq "NOT_RUN") "C: tool_probe=NOT_RUN does not block approval (flash)"
    Assert-True ([string]$proApproved.tool_probe -eq "NOT_RUN") "C: tool_probe=NOT_RUN does not block approval (pro)"
    Assert-True ([string]$flashCandidate.tool_probe -eq "NOT_RUN") "C: approval never upgrades tool_probe to PASS (flash)"
    Assert-True ([string]$proCandidate.tool_probe -eq "NOT_RUN") "C: approval never upgrades tool_probe to PASS (pro)"
    Assert-True ([string]$flashApproved.basic_probe -eq "PASS") "C: the approved record carries the real basic probe result"

    # E. repeated registry-only approval is idempotent
    $approvedBytesBefore = Get-FileSha256 $approvedPath
    $candidatesBytesBefore = Get-FileSha256 $candidatesPath
    $flashApprovedAt = [string]$flashApproved.approved_at
    $repeat = Invoke-Approval -ProviderId "deepseek" -ModelId "deepseek-flash" -DisplayName "DeepSeek V4.1 Flash" -RegistryOnly
    Assert-True ($repeat -match "Approval mode: REGISTRY_ONLY") "E: the repeated approval still runs in REGISTRY_ONLY mode"
    $flashRecords = @(Get-ApprovedRecords $sandbox.CodexHome | Where-Object { [string]$_.provider_id -eq "deepseek" -and [string]$_.model_id -eq "deepseek-flash" })
    Assert-True ($flashRecords.Count -eq 1) "E: a repeated approval creates no duplicate approved record"
    Assert-True ((Get-FileSha256 $approvedPath) -eq $approvedBytesBefore) "E: the repeated approval leaves the approved registry bytes unchanged"
    Assert-True ([string](Get-Approved $sandbox.CodexHome "deepseek" "deepseek-flash").approved_at -eq $flashApprovedAt) "E: the original approved_at timestamp is preserved"
    Assert-True (@(Get-ApprovedRecords $sandbox.CodexHome).Count -eq 2) "E: the registry holds exactly the two direct records"

    # F. provider-scoped identity: a Model Studio approval never overwrites the
    # direct DeepSeek record (and vice versa)
    $null = Invoke-Approval -ProviderId "mm_modelstudio" -ModelId "deepseek-v4-pro" -DisplayName "DeepSeek V4 Pro (Model Studio)" -RegistryOnly
    $directPro = Get-Approved $sandbox.CodexHome "deepseek" "deepseek-v4-pro"
    $studioPro = Get-Approved $sandbox.CodexHome "mm_modelstudio" "deepseek-v4-pro"
    Assert-True ($null -ne $directPro -and $null -ne $studioPro) "F: both provider-scoped approvals coexist"
    Assert-True (@(Get-ApprovedRecords $sandbox.CodexHome).Count -eq 3) "F: the two provider scopes are recorded as distinct entries"
    Assert-True ([string]$directPro.provider_id -eq "deepseek") "F: the direct record keeps provider_id=deepseek"
    Assert-True ([string]$studioPro.provider_id -eq "mm_modelstudio") "F: the Model Studio record keeps provider_id=mm_modelstudio"
    Assert-True ([string](Get-Candidate $sandbox.CodexHome "deepseek" "deepseek-v4-pro").status -eq "APPROVED") "F: the direct candidate is unaffected by the Model Studio approval"
    Assert-True ([string](Get-Candidate $sandbox.CodexHome "mm_modelstudio" "deepseek-v4-pro").status -eq "APPROVED") "F: the Model Studio candidate is approved only under its own scope"
    Assert-True ((Get-FileSha256 $candidatesPath) -ne $candidatesBytesBefore) "F: approving a second scope still writes the candidate registry"

    # G. registry-only approval never touches Codex config or the picker catalog
    Assert-True ((Get-FileSha256 $configPath) -eq $configBefore) "G: config.toml is byte-identical after registry-only approvals"
    Assert-True ((Get-FileSha256 $modelsPath) -eq $modelsBefore) "G: models.json is byte-identical after registry-only approvals"
    Assert-True ((Get-FileSha256 $manifestPath) -eq $manifestBefore) "G: profile-v2-files.json is unchanged after registry-only approvals"
    Assert-True (@(Get-ChildItem -LiteralPath $sandbox.CodexHome -File -Filter "*.config.toml").Count -eq $tomlFilesBefore) "G: no new *.config.toml profile file is generated"
    Assert-True (@(Get-ChildItem -LiteralPath $sandbox.CodexHome -File -Filter "mm_auto_*.config.toml").Count -eq 0) "G: no approval profile is generated for the approved models"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sandbox.CodexHome "backups"))) "G: no auto-models config backup is created"
    $configText = Get-Content -Raw -LiteralPath $configPath
    Assert-True (-not $configText.Contains("CODEX AUTO MODELS BEGIN")) "G: config.toml receives no AUTO MODELS block"
    Assert-True ($configText.Contains("user-config-sentinel")) "G: unrelated config content is preserved"

    # --- D. admission stays fail-closed --------------------------------------
    $caseD = New-ApprovalSandbox
    $sandboxes.Add($caseD)
    $env:CODEX_HOME = $caseD.CodexHome
    $dCandidatesPath = Get-CandidatesFilePath $caseD.CodexHome
    $dCandidatesBefore = Get-FileSha256 $dCandidatesPath
    Assert-ThrowsMatch { Invoke-Approval -ProviderId "deepseek" -ModelId "deepseek-unverified" -RegistryOnly } "probe-model" "D: a candidate without basic_probe=PASS fails closed"
    Assert-True (-not (Test-Path -LiteralPath (Get-ApprovedFilePath $caseD.CodexHome) -PathType Leaf)) "D: the fail-closed approval writes no approved registry"
    Assert-True ((Get-FileSha256 $dCandidatesPath) -eq $dCandidatesBefore) "D: the fail-closed approval leaves the candidate registry untouched"
    Assert-True ([string](Get-Candidate $caseD.CodexHome "deepseek" "deepseek-unverified").status -eq "PROBE_FAILED") "D: the unverified candidate is not downgraded or approved"

    # --- H. the default legacy contract is preserved -------------------------
    $caseH = New-ApprovalSandbox
    $sandboxes.Add($caseH)
    $env:CODEX_HOME = $caseH.CodexHome
    $legacyOutput = Invoke-Approval -ProviderId "deepseek" -ModelId "deepseek-flash" -DisplayName "DeepSeek V4.1 Flash"
    Assert-True ($legacyOutput -match "Approval mode: LEGACY_PROFILE") "H: the default call path still reports the legacy profile mode"
    $hApproved = Get-Approved $caseH.CodexHome "deepseek" "deepseek-flash"
    Assert-True ($null -ne $hApproved) "H: the legacy path still writes the approved registry"
    Assert-True ([string](Get-Candidate $caseH.CodexHome "deepseek" "deepseek-flash").status -eq "APPROVED") "H: the legacy path still approves the candidate"
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $caseH.CodexHome "backups") -Directory -Filter "auto-models-*" -ErrorAction SilentlyContinue).Count -eq 1) "H: the legacy path still creates its auto-models config backup"
    # Sanitize-ProfileId normalizes the hyphen: deepseek + deepseek-flash ->
    # mm_auto_deepseek_deepseek_flash.
    Assert-True (Test-Path -LiteralPath (Join-Path $caseH.CodexHome "mm_auto_deepseek_deepseek_flash.config.toml") -PathType Leaf) "H: the legacy path still generates the Profile V2 file"
    $manifestText = Get-Content -Raw -LiteralPath (Get-ProfileManifestPath $caseH.CodexHome)
    Assert-True ($manifestText.Contains("mm_auto_deepseek_deepseek_flash")) "H: the legacy path still records the profile in profile-v2-files.json"
    $legacyConfigText = Get-Content -Raw -LiteralPath (Get-ConfigPath $caseH.CodexHome)
    Assert-True ($legacyConfigText.Contains("user-config-sentinel")) "H: the legacy path preserves unrelated config content"
    Assert-True (-not $legacyConfigText.Contains("CODEX AUTO MODELS BEGIN")) "H: the legacy block is still migrated out of the base config"
}
finally {
    Restore-ProcessEnvSnapshot $envBefore
    $tempRoot = [System.IO.Path]::GetTempPath()
    foreach ($sandbox in $sandboxes) {
        # Only ever clean up the throw-away sandbox roots this validator created
        # under the OS temp directory.
        if ($null -ne $sandbox -and $sandbox.Root.StartsWith($tempRoot) -and (Test-Path -LiteralPath $sandbox.Root)) {
            Remove-Item -LiteralPath $sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$envAfter = Save-ProcessEnvSnapshot
$envMatch = $true
foreach ($name in $envBefore.Keys) {
    if ([string]$envBefore[$name] -ne [string]$envAfter[$name]) { $envMatch = $false }
}
Assert-True $envMatch "Validator Process environment snapshot is restored exactly (before == after)"

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "Registry-only model approval validation PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "Registry-only model approval validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
exit 1
