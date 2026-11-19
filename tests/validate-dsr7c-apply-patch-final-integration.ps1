param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

# DSR7-C-FIX5-FINAL - APPLY_PATCH PROTOCOL BRIDGE FINAL INTEGRATION validation.
#
# This gate does not re-run the unit suites. It verifies that the six FIX5
# commits (FIX5-A, B1a, B1a2, B1b-1, B1b-2, B2) hold together as ONE protocol
# bridge: the canonical contract, the generic upstream wires, the DeepSeek-only
# request transform, the non-stream restore and the streaming bridge all exist,
# the reserved synthetic identity stays centralized, no generic layer or other
# provider gains apply_patch semantics, the protected installer files are
# untouched by the FIX5 range, and the bridge path neither executes nor logs a
# patch.
#
# The validator is offline, read-only and deterministic: it reads repository
# files, runs read-only git queries, and never writes, starts, or contacts
# anything.

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Pass $Message } else { Fail $Message }
}

function Read-SourceText([string]$RelativePath) {
    return (Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $RelativePath))
}

function Test-PathExists([string]$RelativePath) {
    return (Test-Path -LiteralPath (Join-Path $RepositoryRoot $RelativePath) -PathType Leaf)
}

function Get-GitLines([string[]]$Arguments) {
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

$script:Fix5Base = "74482284838b438860f73ba7b83bb6dca83ad773"
$script:Fix5Chain = @(
    @('FIX5-A', '5f9a03ca289d46d33474208bfce94c1e585fae45'),
    @('B1a', '1ec68e0bcf06396076a7defe572501a2c77eece3'),
    @('B1a2', '33514098432cf64ca3879bc6fb891ee4cfb3cbee'),
    @('B1b-1', 'cf543bc9c814d0bd049351117b8fc7b307593602'),
    @('B1b-2', 'd0981d30c4b6162db033803c49da5e98f27a0d59'),
    @('B2', 'e702fd4b51295f0e95269eef6de210f5eb744f0a')
)

$validatorSource = Get-Content -Raw -LiteralPath $PSCommandPath

# --- 1. Six-commit FIX5 chain surfaces present ----------------------------
# LR15-G1: the chain evidence is anchored to the approved FIX5 commits
# themselves, never to HEAD. An earlier revision asserted that
# "$Fix5Base..HEAD" contained exactly six commits, so the evidence decayed with
# every later commit (it counted this gate's own commit and then every commit
# added afterwards). Later, unrelated commits must neither invalidate nor
# restate the FIX5 acceptance evidence.
#
# The commit identities are asserted when the FIX5 base is reachable in this
# clone (CI uses fetch-depth 0). When it is not - a shallow or rewritten clone -
# the file surfaces below still pin the same six slices.
function Test-GitAncestor([string]$Ancestor, [string]$Descendant) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & git -C $RepositoryRoot merge-base --is-ancestor $Ancestor $Descendant 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

$baseCommit = @(Get-GitLines @("rev-parse", "--verify", "--quiet", "$($script:Fix5Base)^{commit}"))
$hasBase = $baseCommit.Count -gt 0

# LR15-G8F: reviewed-identity portability.
#
# The reviewed identity of the FIX5 gate is "original source SHA + stable
# patch-id + exact reviewed file/content proof". When the original chain is
# still an ancestor of HEAD the exact-SHA checks below stay authoritative
# (legacy mode). A pull request that is rebuilt from a new main by cherry-picking
# the same reviewed patches has identical patches but different SHAs; the shared
# resolver then proves the same reviewed identity through stable patch-ids
# (portable mode) and the reviewed FIX5 range becomes
# "equivalent base .. equivalent chain tail" instead of the whole of HEAD.
. (Join-Path $RepositoryRoot "tests/shared/fix5-patch-identity.ps1")
$fix5Identity = Resolve-Fix5ReviewedIdentity -RepositoryRoot $RepositoryRoot -Base $script:Fix5Base -Chain $script:Fix5Chain
$hasBase = ($fix5Identity.Mode -ne "unavailable")
$script:Fix5RangeBase = $script:Fix5Base
$script:Fix5RangeTail = "HEAD"

if ($fix5Identity.Mode -eq "legacy") {
    foreach ($entry in $script:Fix5Chain) {
        $resolved = @(Get-GitLines @("rev-parse", "--verify", "--quiet", "$($entry[1])^{commit}"))
        Assert-True ($resolved.Count -gt 0) "1: $($entry[0]) commit $($entry[1].Substring(0, 8)) is present"
    }

    # (a) The approved range, anchored at the FIX5 chain tail, is exactly the
    # approved chain, in order.
    $chainTail = $script:Fix5Chain[$script:Fix5Chain.Count - 1][1]
    $chain = @(Get-GitLines @("rev-list", "--reverse", "$($script:Fix5Base)..$chainTail"))
    Assert-True ($chain.Count -eq $script:Fix5Chain.Count) "1: the approved FIX5 range contains exactly $($script:Fix5Chain.Count) commits (found $($chain.Count))"
    for ($index = 0; $index -lt [Math]::Min($chain.Count, $script:Fix5Chain.Count); $index++) {
        Assert-True ($chain[$index] -eq $script:Fix5Chain[$index][1]) "1: $($script:Fix5Chain[$index][0]) is commit $($index + 1) in the approved range"
    }

    # (b) Linear topology: each approved commit is the direct child of the
    # previous one, and FIX5-A is the direct child of the approved base.
    $firstParent = @(Get-GitLines @("rev-parse", "--verify", "--quiet", "$($script:Fix5Chain[0][1])^"))
    Assert-True ($firstParent.Count -gt 0 -and $firstParent[0] -eq $script:Fix5Base) "1: FIX5-A is the direct child of the approved FIX5 base"
    for ($index = 1; $index -lt $script:Fix5Chain.Count; $index++) {
        $parent = @(Get-GitLines @("rev-parse", "--verify", "--quiet", "$($script:Fix5Chain[$index][1])^"))
        Assert-True ($parent.Count -gt 0 -and $parent[0] -eq $script:Fix5Chain[$index - 1][1]) "1: $($script:Fix5Chain[$index][0]) is the direct child of $($script:Fix5Chain[$index - 1][0])"
    }

    # (c) Reachability: the approved chain is still part of this tree, so the
    # FIX5 identity survives later, unrelated commits.
    Assert-True (Test-GitAncestor $chainTail "HEAD") "1: the approved FIX5 chain tail is still an ancestor of HEAD"
}
elseif ($fix5Identity.Mode -eq "portable") {
    Write-Host "NOTE  the original FIX5 chain is not an ancestor of HEAD; the reviewed identity is resolved through stable patch-ids (portable cherry-pick construction)." -ForegroundColor Yellow
    Assert-True ($fix5Identity.Errors.Count -eq 0) "1: every reviewed FIX5 patch resolves to exactly one ordered, linear, non-merge equivalent commit"
    foreach ($fix5Error in $fix5Identity.Errors) { Fail "1: $fix5Error" }
    if ($fix5Identity.Errors.Count -eq 0) {
        for ($index = 0; $index -lt $script:Fix5Chain.Count; $index++) {
            Assert-True ([string]$fix5Identity.Equivalents[$index] -ne "") "1: $($script:Fix5Chain[$index][0]) resolves to exactly one patch-equivalent commit"
        }
        Assert-True (Test-GitAncestor $fix5Identity.EffectiveTail "HEAD") "1: the equivalent FIX5 chain tail is an ancestor of HEAD"
        $script:Fix5RangeBase = $fix5Identity.EffectiveBase
        $script:Fix5RangeTail = $fix5Identity.EffectiveTail
        Write-Host "      FIX5 reviewed range: equivalent base $($script:Fix5RangeBase.Substring(0, 8)) .. equivalent tail $($script:Fix5RangeTail.Substring(0, 8))" -ForegroundColor Cyan
    }
    foreach ($mappingLine in $fix5Identity.Mapping) {
        $mappingParts = $mappingLine -split '\|'
        Write-Host "      fix5 identity: $($mappingParts[0])  $(([string]$mappingParts[1]).Substring(0, 8)) -> patch-id $($mappingParts[2]) -> $($mappingParts[3])" -ForegroundColor Cyan
    }
}
elseif ($fix5Identity.Mode -eq "genesis") {
    # OSS-GENESIS: the private FIX5 objects are not part of this history. The
    # recorded review is accepted only for the verified genesis root and is bound
    # to its objects (reviewed blob at genesis root and HEAD, owned by the root).
    Write-Host "NOTE  OSS-GENESIS: the FIX5 chain identity is the recorded review bound to the verified genesis root $($fix5Identity.GenesisRoot.Substring(0, 12))" -ForegroundColor Yellow
    Assert-True ($fix5Identity.Errors.Count -eq 0) "1 (OSS-GENESIS): the FIX5 base/chain pins equal the recorded review in order and every FIX5 surface is the reviewed blob at the verified genesis root"
    foreach ($fix5Error in $fix5Identity.Errors) { Fail "1: $fix5Error" }
    Assert-True (@($fix5Identity.Equivalents | Where-Object { $_ -cmatch '^[0-9a-f]{40}$' }).Count -eq $script:Fix5Chain.Count) "1 (OSS-GENESIS): every reviewed member has a recorded source-main equivalent"
    foreach ($mappingLine in $fix5Identity.Mapping) {
        $mappingParts = $mappingLine -split '\|'
        Write-Host "      fix5 identity: $($mappingParts[0])  $(([string]$mappingParts[1]).Substring(0, 8)) -> patch-id $($mappingParts[2]) -> $($mappingParts[3])" -ForegroundColor Cyan
    }
}
else {
    Write-Host "NOTE  the FIX5 base commit is not reachable in this clone; the chain check falls back to the file surfaces below" -ForegroundColor Yellow
}

$surfaces = @(
    @('FIX5-A', 'local-router/src/Router.ClientAdapters.Responses/ApplyPatchCustomTool.cs'),
    @('B1a', 'local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderRequestWire.cs'),
    @('B1a2', 'local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderRequestWire.cs'),
    @('B1b-1', 'local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchRequestBridge.cs'),
    @('B1b-2', 'local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchResponseBridge.cs'),
    @('B2', 'local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchStreamBridge.cs')
)
foreach ($surface in $surfaces) {
    Assert-True (Test-PathExists $surface[1]) "1: $($surface[0]) surface present: $($surface[1])"
}

# --- 2. Canonical custom tool contract ------------------------------------
$contractSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ApplyPatchCustomTool.cs"
$parserSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ResponsesRequestParser.cs"
$requestSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/CanonicalResponsesRequest.cs"
$responseSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/CanonicalResponsesResponse.cs"
$inputSource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ResponsesInputItem.cs"
Assert-True ($contractSource.Contains('ApplyPatchToolName = "apply_patch"')) "2: the exact apply_patch identity is declared"
Assert-True ($contractSource.Contains('ClientToolType = "custom"')) "2: only the custom tool type is accepted"
Assert-True ($contractSource.Contains('ClientToolCallType = "custom_tool_call"')) "2: the restored call type is declared"
Assert-True ($contractSource.Contains('ClientToolCallOutputType = "custom_tool_call_output"')) "2: the replayed output type is declared"
Assert-True ($contractSource.Contains('RequiredFormatType = "grammar"')) "2: the strict grammar shape is preserved"
Assert-True ($parserSource.Contains("ParseApplyPatchCustomTool")) "2: the parser owns the strict shape"
Assert-True ($parserSource.Contains("SafeCustomToolDiagnostics.ClassifyRejectedCustomToolIdentity(tool)")) "2: unknown custom tools keep the FIX4 fail-closed diagnostic"
Assert-True ($requestSource.Contains("public ApplyPatchCustomToolDefinition? ApplyPatchTool { get; init; }")) "2: the canonical request carries the dedicated slot"
Assert-True ($requestSource.Contains("[JsonIgnore]")) "2: the custom definition never serializes on the canonical wire"
Assert-True ($responseSource.Contains("public sealed record CustomToolCallResponseItem")) "2: the canonical response models the restored call"
Assert-True ($inputSource.Contains("public sealed record CustomToolCallInputItem")) "2: the replayed freeform call is canonical"
Assert-True ($inputSource.Contains("public sealed record CustomToolCallOutputInputItem")) "2: the replayed freeform output is canonical"

# --- 3. Function wire -----------------------------------------------------
$wireSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderRequestWire.cs"
$codecSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderCodec.cs"
Assert-True ($wireSource.Contains('FunctionToolType = "function"')) "3: the fixed function discriminator is present"
Assert-True ($wireSource.Contains("Type = FunctionToolType")) "3: every projected tool takes the fixed type"
Assert-True ($codecSource.Contains("ResponsesProviderRequestWire.FromCanonical(request)")) "3: the outbound body is the provider wire projection"
foreach ($provider in @(
        @('DeepSeek', 'DeepSeekFunctionWireTests.cs'),
        @('MiMo', 'MiMoFunctionWireTests.cs'),
        @('ModelStudio', 'ModelStudioFunctionWireTests.cs'),
        @('OpenRouter', 'OpenRouterFunctionWireTests.cs'),
        @('OpenAI', 'OpenAIFunctionWireTests.cs'))) {
    $path = "local-router/tests/Router.ProviderAdapters.$($provider[0]).Tests/$($provider[1])"
    Assert-True (Test-PathExists $path) "3: $($provider[0]) function wire test present"
    Assert-True ((Read-SourceText $path).Contains('tools[0].GetProperty("type").GetString()')) "3: $($provider[0]) still asserts the function wire"
}

# --- 4. Tool choice wire --------------------------------------------------
Assert-True ($wireSource.Contains("ResponsesToolChoiceWireConverter")) "4: the tool_choice wire converter is present"
Assert-True ($wireSource.Contains('writer.WriteStringValue("auto")')) "4: auto projects to the string form"
Assert-True ($wireSource.Contains('writer.WriteStringValue("none")')) "4: none projects to the string form"
Assert-True ($wireSource.Contains('writer.WriteStringValue("required")')) "4: required projects to the string form"
Assert-True ($wireSource.Contains('writer.WriteString("type", FunctionToolName)')) "4: a named choice projects to {type:function}"
Assert-True (-not ($wireSource -match 'WriteString\("kind"')) "4: the canonical kind is never written upstream"

# --- 5-7. The three DeepSeek bridge halves --------------------------------
$requestBridgeSource = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchRequestBridge.cs"
$responseBridgeSource = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchResponseBridge.cs"
$streamBridgeSource = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchStreamBridge.cs"
$adapterSource = Read-SourceText "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekProviderAdapter.cs"
Assert-True ($requestBridgeSource.Contains("public static class ApplyPatchRequestBridge")) "5: the request bridge exists"
Assert-True ($requestBridgeSource.Contains("Value = request with")) "5: the request transform is immutable"
Assert-True ($requestBridgeSource.Contains("ApplyPatchTool = null,")) "5: the custom tool is cleared only in the clone"
Assert-True ($requestBridgeSource.Contains("tools.Add(new FunctionToolDefinition")) "5: the synthetic function is appended"
Assert-True ($responseBridgeSource.Contains("public static class ApplyPatchResponseBridge")) "6: the non-stream restore exists"
Assert-True ($responseBridgeSource.Contains("public static bool TryDecodePatch(string arguments, out string patch)")) "6: the shared strict decoder exists"
Assert-True ($streamBridgeSource.Contains("public static class ApplyPatchStreamBridge")) "7: the streaming bridge exists"
Assert-True ($streamBridgeSource.Contains("ApplyPatchResponseBridge.TryDecodePatch(arguments, out string patch)")) "7: the streaming bridge reuses the same decoder"
Assert-True ($adapterSource.Contains("ApplyPatchRequestBridge.CreateProviderLocalRequest(invocation.Request)")) "5-7: the adapter wires the request half"
Assert-True ($adapterSource.Contains("ApplyPatchStreamBridge.Apply(providerEvents, bridgeIsActive, cancellationToken)")) "7: the adapter wires the streaming half"
Assert-True ($adapterSource.Contains("ApplyPatchResponseBridge.Apply(result, bridgeIsActive)")) "6: the adapter wires the non-stream half"
Assert-True ($adapterSource.Contains("DeepSeekCapabilities.SupportedCompatibilityBridges")) "5: eligibility uses the declared bridge capability"
Assert-True ($requestBridgeSource.Contains('RequiredRouteCapability = "tools"')) "5: the route tools capability is required"
Assert-True ($requestBridgeSource.Contains('RequiredStreamingCapability = "streaming"')) "5: the route streaming capability is required for a stream"

# --- 8. The reserved synthetic identity is centralized --------------------
$identitySource = Read-SourceText "local-router/src/Router.ClientAdapters.Responses/ApplyPatchCustomTool.cs"
Assert-True ($identitySource.Contains('SyntheticFunctionName = "mm_apply_patch_bridge_v1"')) "8: the reserved identity is declared in the canonical contract"
$productionFiles = @(Get-ChildItem -Path (Join-Path $RepositoryRoot "local-router/src") -Recurse -File -Filter "*.cs")
$identityDeclarations = 0
$identityFiles = New-Object System.Collections.Generic.List[string]
foreach ($file in $productionFiles) {
    $text = Get-Content -Raw -LiteralPath $file.FullName
    if ($text -match 'mm_apply_patch_bridge_v1') {
        $identityDeclarations++
        $identityFiles.Add($file.FullName.Substring($RepositoryRoot.Length + 1).Replace('\', '/'))
    }
}
Assert-True ($identityDeclarations -eq 1) "8: the literal appears exactly once in production code (found $identityDeclarations)"
foreach ($file in $identityFiles) {
    Assert-True ($file -eq "local-router/src/Router.ClientAdapters.Responses/ApplyPatchCustomTool.cs") "8: the literal lives only in the canonical contract ($file)"
}
$bridgeIdentityUsers = @(
    'local-router/src/Router.ClientAdapters.Responses/ResponsesRequestParser.cs',
    'local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchRequestBridge.cs',
    'local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchResponseBridge.cs',
    'local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchStreamBridge.cs'
)
foreach ($file in $bridgeIdentityUsers) {
    $text = Read-SourceText $file
    Assert-True ($text.Contains("ApplyPatchBridgeContract.")) "8: $([System.IO.Path]::GetFileName($file)) uses the contract constant, never a second literal"
}

# --- 9-11. The three earlier gates exist ----------------------------------
Assert-True (Test-PathExists "tests/validate-dsr7c-apply-patch-request-bridge.ps1") "9: the B1b-1 validator exists"
Assert-True (Test-PathExists "tests/validate-dsr7c-apply-patch-response-bridge.ps1") "10: the B1b-2 validator exists"
Assert-True (Test-PathExists "tests/validate-dsr7c-apply-patch-stream-bridge.ps1") "11: the B2 validator exists"

# --- 12. Generic providers gain nothing -----------------------------------
$genericRoots = @(
    "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderRequestWire.cs",
    "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderCodec.cs",
    "local-router/src/Router.ProtocolAdapters.Responses/ResponsesProtocolAdapter.cs",
    "local-router/src/Router.ProtocolAdapters.Responses/CanonicalEventVocabulary.cs",
    "local-router/src/Router.ProtocolAdapters.Abstractions/SemanticLossDetector.cs"
)
foreach ($file in $genericRoots) {
    $text = Read-SourceText $file
    $code = ($text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(///|//)' }) -join "`n"
    Assert-True (-not ($code -match 'ApplyPatch|SyntheticFunctionName|CustomToolCallResponseItem')) "12: $([System.IO.Path]::GetFileName($file)) carries no apply_patch semantics"
}
$baseAdapterSource = Read-SourceText "local-router/src/Router.ProviderAdapters.Responses/ResponsesCompatibleProviderAdapterBase.cs"
Assert-True ($baseAdapterSource.Contains("invocation.Request.ApplyPatchTool is not null")) "12: the shared base only fails closed on a custom tool"
Assert-True ($baseAdapterSource.Contains("ProviderAdapterResult.Failed(RouterError.UnsupportedCapability())")) "12: the shared fail-closed answer is unsupported_capability"
Assert-True (-not ($baseAdapterSource -match 'SyntheticFunctionName|CustomToolCallResponseItem')) "12: the shared base restores nothing"
foreach ($provider in @(
        @('MiMo', 'MiMoProviderAdapter.cs'),
        @('ModelStudio', 'ModelStudioProviderAdapter.cs'),
        @('OpenRouter', 'OpenRouterProviderAdapter.cs'),
        @('OpenAI', 'OpenAIProviderAdapter.cs'))) {
    $source = Read-SourceText "local-router/src/Router.ProviderAdapters.$($provider[0])/$($provider[1])"
    Assert-True (-not ($source -match 'ApplyPatchRequestBridge|ApplyPatchResponseBridge|ApplyPatchStreamBridge|SyntheticFunctionName')) "12: $($provider[0]) shares no bridge state"
}

# --- 13. Protected installer files untouched by the FIX5 range ------------
$protected = @(
    "installer/scripts/router-codex-cli.ps1",
    "installer/scripts/desktop-router-route.ps1",
    "installer/model-catalog.json",
    "installer/scripts/approve-model.ps1",
    "installer/scripts/probe-model.ps1",
    "installer/scripts/launch-controller-model.ps1",
    "installer/scripts/_registry.ps1"
)
if ($fix5Identity.Mode -eq "genesis") {
    # OSS-GENESIS: the FIX5 range lives in the private history. Its changed-file
    # list is pinned (and integrity-checked) so the range predicates are
    # re-evaluated here; byte-identity of the protected files across the range
    # is the recorded result of the private gate and cannot be re-derived.
    $genesisEvidence = $script:Fix5GenesisEvidence
    $rangeFiles = @($genesisEvidence.RangeChangedFiles | Sort-Object)
    $rangeDigest = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($rangeFiles -join "`n") + "`n"))).Replace('-', '').ToLowerInvariant()
    Assert-True ($rangeDigest -ceq $genesisEvidence.RangeChangedFilesSha256 -and $rangeFiles.Count -eq 37) "13 (OSS-GENESIS): the recorded FIX5 range file list is intact (37 files, pinned digest)"
    Assert-True ($genesisEvidence.RangeCommitCount -eq 8 -and $genesisEvidence.RangeProtectedByteIdentical -eq $true) "13 (OSS-GENESIS, recorded): the private FIX5 range $($genesisEvidence.RangeBase.Substring(0, 8))..$($genesisEvidence.RangeTail.Substring(0, 8)) kept every protected installer file byte-identical"
    Assert-True (@($rangeFiles | Where-Object { $protected -contains $_ }).Count -eq 0) "13 (OSS-GENESIS): the FIX5 range modifies no protected installer file"
    Assert-True (@($rangeFiles | Where-Object { $_ -match '^(installer/|skill/|docs/)' }).Count -eq 0) "13 (OSS-GENESIS): the FIX5 range stays out of installer, skill and docs surfaces"
    Assert-True (-not ($rangeFiles | Where-Object { $_ -match '\.(sqlite|db|bin|dll|exe|zip|bak)$' })) "13 (OSS-GENESIS): the FIX5 range adds no binary, state or backup artifact"
    foreach ($file in $protected) {
        Assert-True (Test-PathExists $file) "13: protected file still present: $file"
    }
}
elseif ($hasBase) {
    foreach ($file in $protected) {
        $baseBlob = @(Get-GitLines @("rev-parse", "$($script:Fix5RangeBase):$file"))
        $tailBlob = @(Get-GitLines @("rev-parse", "$($script:Fix5RangeTail):$file"))
        Assert-True ($baseBlob.Count -eq 1 -and $tailBlob.Count -eq 1 -and $baseBlob[0] -eq $tailBlob[0]) "13: $file is byte-identical across the FIX5 range"
    }

    $changedFiles = @(Get-GitLines @("diff", "--name-only", "$($script:Fix5RangeBase)..$($script:Fix5RangeTail)"))
    $changedProtected = @($changedFiles | Where-Object { $protected -contains $_ })
    Assert-True ($changedProtected.Count -eq 0) "13: the FIX5 range modifies no protected installer file"
    $unrelated = @($changedFiles | Where-Object { $_ -match '^(installer/|skill/|docs/)' })
    Assert-True ($unrelated.Count -eq 0) "13: the FIX5 range stays out of installer, skill and docs surfaces"
    Assert-True (-not ($changedFiles | Where-Object { $_ -match '\.(sqlite|db|bin|dll|exe|zip|bak)$' })) "13: the FIX5 range adds no binary, state or backup artifact"
}
else {
    foreach ($file in $protected) {
        Assert-True (Test-PathExists $file) "13: protected file still present: $file"
    }
}

# --- 14. No execution primitives in the bridge path ----------------------
$bridgePath = $requestBridgeSource + $responseBridgeSource + $streamBridgeSource + $adapterSource
foreach ($forbidden in @('Process.Start', 'System.Diagnostics', 'git apply', 'patch.exe', 'powershell', 'PowerShell', 'cmd.exe', 'bash', 'File.WriteAllText', 'File.WriteAllBytes', 'Directory.CreateDirectory', 'CreateDirectory', 'ProcessStartInfo')) {
    Assert-True (-not ($bridgePath.Contains($forbidden))) "14: the bridge path never calls $forbidden"
}

# --- 15. No patch logging sink ------------------------------------------
$observability = @(
    "local-router/src/Router.Observability/SafeRequestRecord.cs",
    "local-router/src/Router.Observability/DurableRequestLog.cs",
    "local-router/src/Router.Observability/SafeFailureDiagnosticLog.cs"
)
foreach ($file in $observability) {
    $text = Read-SourceText $file
    Assert-True (-not ($text -match 'Patch|patch')) "15: $([System.IO.Path]::GetFileName($file)) declares no patch field"
}
$streamCode = ($streamBridgeSource -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(///|//)' }) -join "`n"
foreach ($sink in @('ILogger', 'Console.', 'Debug.', 'Trace.', 'Log(')) {
    Assert-True (-not ($streamCode.Contains($sink))) "15: the streaming bridge writes to no $sink"
    Assert-True (-not (($responseBridgeSource -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(///|//)' }) -join "`n").Contains($sink)) "15: the non-stream restore writes to no $sink"
}
Assert-True ($responseBridgeSource.Contains("Errors carry only a fixed, content-free message")) "15: the restore documents the content-free error contract"
Assert-True ($streamBridgeSource.Contains("ProviderAdapterErrors.InvalidResponse()")) "15: the streaming failure uses the existing content-free error"

# --- 16. No live provider endpoint in the FIX5 tests ----------------------
$fix5Tests = @(
    "local-router/tests/Router.ClientAdapters.Responses.Tests/ApplyPatchContractTests.cs",
    "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchBridgeTests.cs",
    "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchRequestBridgeTests.cs",
    "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchResponseBridgeTests.cs",
    "local-router/tests/Router.ProviderAdapters.DeepSeek.Tests/DeepSeekApplyPatchStreamBridgeTests.cs",
    "local-router/tests/Router.ProviderAdapters.Tests/ResponsesProviderCodecTests.cs"
)
foreach ($file in $fix5Tests) {
    $text = Read-SourceText $file
    Assert-True (-not ($text -match 'api\.deepseek\.com|dashscope|openrouter\.ai|xiaomimimo|api\.openai\.com|aliyuncs')) "16: $([System.IO.Path]::GetFileName($file)) references no live endpoint"
}
$httpPrimitives = @(("Invoke-" + "RestMethod"), ("Invoke-" + "WebRequest"))
foreach ($primitive in $httpPrimitives) {
    Assert-True (-not ($validatorSource.Contains($primitive))) "16: this validator uses no $primitive"
}
foreach ($file in $fix5Tests) {
    $text = Read-SourceText $file
    Assert-True (-not ($text -match 'new Uri\("http')) "16: $([System.IO.Path]::GetFileName($file)) issues no direct HTTP call"
}

# --- 17. This validator mutates nothing ----------------------------------
# The forbid lists are assembled from fragments so the literals never appear
# contiguously in this file; the self-checks below are therefore meaningful.
$writePrimitives = @(
    ('Set' + '-Content'), ('Out' + '-File'), ('Add' + '-Content'), ('New' + '-Item'),
    ('Remove' + '-Item'), ('Copy' + '-Item'), ('Move' + '-Item'), ('Start' + '-Process'),
    ('New' + '-ItemProperty'), ('Set' + '-ItemProperty')
)
foreach ($writePrimitive in $writePrimitives) {
    Assert-True (-not ($validatorSource.Contains($writePrimitive))) "17: this validator never calls $writePrimitive"
}
$mutatingGitCommands = @('checkout', 'reset', 'stash', 'restore', 'rebase', 'commit', 'push', 'worktree')
foreach ($mutatingGit in $mutatingGitCommands) {
    $mutatingGit = 'git ' + $mutatingGit
    Assert-True (-not ($validatorSource.Contains($mutatingGit))) "17: this validator never runs $mutatingGit"
}
$liveStateFiles = @(
    ('auth' + '.json'), ('config' + '.toml'), ('models' + '.json'),
    ('router' + '.config.json'), ('state_5' + '.sqlite')
)
foreach ($liveState in $liveStateFiles) {
    Assert-True (-not ($validatorSource.Contains($liveState))) "17: this validator never touches $liveState"
}
Assert-True (-not ($validatorSource.Contains('mm_local' + '_router'))) "17: this validator never switches the live runtime mode"

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "DSR7-C apply_patch final integration (FIX5) validation PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "DSR7-C apply_patch final integration (FIX5) validation FAILED: $($failures.Count) check(s)" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
exit 1
