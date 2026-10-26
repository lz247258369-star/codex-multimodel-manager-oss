# Shared fail-closed policy for files protected by earlier Local Router
# slices that LR-13 is explicitly authorized to touch in a tiny, reviewed way.
#
# The authorization is delta-exact: the current desktop-chat-route.ps1 must
# match an approved normalized SHA-256. A string-presence check alone is never
# sufficient. Any future change to desktop-chat-route.ps1 fails the gate until
# a new approved delta is reviewed and the golden hash is updated.
#
# HS1B-RB1 (Local Router bootstrap gate) is the third such authorization: it
# adds the Initialize bootstrap to router-codex-cli.ps1, which every earlier
# slice protects. The authorization stays delta-exact and additionally requires
# the HS1B-RB1 scope validator to exist, so deleting the scope review revokes
# the authorization instead of widening it.

$script:Lr13ApprovedDesktopChatRouteSha256 = "7f6f630067c378cf59bafd4290933c4a8f594c76d6e3e3a74f435315b6b888e6"
$script:Lr14ApprovedV4Sha256 = [ordered]@{
    # HS-1B stage 4A (S4A) reviewed delta: the V4 Local Router page gains the
    # Observed Codex Threads section (thread list, dual-truth copy, approved-model
    # combo reusing the existing model source, switch/restore/clear-all/identify
    # controls), the runtime gains background thread reads plus bounded capture
    # polling, and the console registers the new control names. Any further change
    # to these files fails this gate until a new exact delta is reviewed.
    "installer/ui/visual-console.xaml" = "270c3ced49a8f6292b8fe0a312fa3806223f8010abf507af4e8b4a3fa9e57191"
    "installer/scripts/visual-console.ps1" = "829dbfa8fe182306230c5b4fbb0bbf9ee4d53ce73b4e4f3b8f0af97f9f2ee463"
    "installer/scripts/visual-console-entry.ps1" = "86bb0ec31b4a3e72b51b59fac5723133ea592e5938cad1096f89198ba4d58dbd"
    "installer/scripts/visual-router-runtime.ps1" = "e8e41ca6ebc3f77099f1c703343abe7989086e390a0220bcf4b1a9ea3d4f9e69"
}
# HS1B-RB1 reviewed delta: router-codex-cli.ps1 gains the Initialize bootstrap
# (action, declarative provider/client tables, effective-document merge, schema
# validation, route plan, entity builders, backup receipts, secure local client
# token bootstrap) plus the Doctor bootstrap ladder. The Initialize action never
# starts Codex, never performs a provider request, and never modifies
# config.toml; only the explicit Enable action writes the Router provider block.
#
# HS1B-RB1-FIX1 reviewed delta: the Doctor bootstrap ladder counted the route
# projections with @($routeConfig.X).Count, which reports 1 for $null, so a
# router.config.json with no routes at all displayed a fabricated 1/1/1. The
# three counts now go through one null-safe helper (null/empty -> 0, otherwise
# the exact element count). Reporting only: route eligibility, route generation,
# approval semantics, Initialize/Enable and Direct Mode behaviour are unchanged.
# DSR2 reviewed delta re-pin: the direct DeepSeek official provider joins the
# Router bootstrap (verifiable catalog provider, eligible provider, secret env,
# bootstrap table entry, explicit model aliases) and the previously active
# DEEPSEEK_ROUTER_GAP is retired. The Doctor route-count fix from HS1B-RB1-FIX1
# is unchanged.
#
# DSR7-B-FIX1 reviewed delta re-pin: the bootstrap additionally generates a
# dedicated control-plane client ("client.control_plane", auth_scope
# "router:control-plane") next to the execution client, plus a guard that refuses
# to generate two clients with the same auth scope. The new client owns no model
# route and receives no second credential; the Router Control Plane authorizes by
# scope alone. The DSR2 delta above is unchanged by this re-pin.
$script:Hs1bRb1ApprovedRouterCliSha256 = "95c9f82c3e2e0ea29fe8560b3ca7b1e0114ec705130fd068b889d3b1079c9468"

# HS1C-INSTALLER-CONFIG-COMPAT reviewed delta: a second, independent exact pin.
# The bootstrap merge admits exactly one optional thread_selection field,
# quota_failover_enabled (absent = false); the schema check requires a JSON
# boolean and thread_selection.enabled=true when it is true (mirroring
# RouterConfigValidator); the target/canonical documents copy an explicit value
# unchanged and never add one. The DSR7-B-FIX1 pin above stays approved and
# unchanged; this pin authorizes only the reviewed HS-1C version, only while the
# HS1B-RB1 scope review exists, and only while the HS-1C markers below are
# present. Any other content still fails closed.
$script:Hs1cInstallerApprovedRouterCliSha256 = "f903f9114c9ceac09ca12be758309810e84a1608ac636efe222e9a45c7b771b3"

function Get-RouterCliHs1cInstallerDeltaErrors([string]$Text) {
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $Text.Contains('$optionalNested = @{ thread_selection = @("quota_failover_enabled") }')) { $errors.Add("HS-1C installer delta requires the exact optional thread_selection allowlist.") }
    if (-not $Text.Contains('-not $base.Contains($nestedKey) -and $nestedKey -cnotin $optional')) { $errors.Add("HS-1C installer delta requires unknown thread_selection fields to keep failing.") }
    if (-not $Text.Contains('"local_router.thread_selection.quota_failover_enabled must be a boolean."')) { $errors.Add("HS-1C installer delta requires the strict boolean check.") }
    if (-not $Text.Contains('quota_failover_enabled=true requires local_router.thread_selection.enabled=true.')) { $errors.Add("HS-1C installer delta requires the thread_selection.enabled dependency.") }
    if (-not $Text.Contains('function Copy-RouterBootstrapQuotaFailoverSetting')) { $errors.Add("HS-1C installer delta requires the explicit-setting copy helper.") }
    if ($Text.Contains('quota_failover_enabled = [bool]')) { $errors.Add("HS-1C installer delta must not mask the setting with a [bool] cast.") }
    if ($Text.Contains('quota_failover_enabled = $true')) { $errors.Add("HS-1C installer delta must never enable quota failover by itself.") }
    return @($errors.ToArray())
}

# DSR2 also touches two Router-owned helper scripts outside the HS1B-RB1 file:
# desktop-router-route.ps1 (Router effort ValidateSet gains "max" without losing
# "xhigh") and visual-hierarchy-runtime.ps1 (the Router performance selector now
# accepts, labels, ranks, and offers "max"). Authorization stays delta-exact and
# additionally requires the DSR2 scope authority to exist, so deleting that
# review revokes the authorization instead of widening it.
$script:Dsr2ApprovedFiles = [ordered]@{
    # DSR7-A reviewed delta re-pin: the forbidden-upstream-secret list gains
    # DEEPSEEK_API_KEY and experimental_bearer_token and the inline regex check is
    # replaced by one shared helper (strictly wider detection, no new secret
    # value is read or written); the remaining lines are console wording only.
    "installer/scripts/desktop-router-route.ps1"     = "959e309c33465b1943883ed22fb2168ac9cf53e9b3088546f5779225aff65c53"
    "installer/scripts/visual-hierarchy-runtime.ps1" = "ce46f72324fe46b81df5485b30dfa39a02cd6382cbe9c8f36f80a46751583448"
    # DSR2 reviewed delta (late registration): Get-ProviderMap gains a
    # deepseek_enabled-gated DeepSeek entry with discovery="none", so no /models
    # request can target DeepSeek before its dedicated gate is enabled. The entry
    # was shipped in the same DSR2 commit but was never registered here.
    "installer/scripts/_registry.ps1"                = "49b9fe29bfcbd0503ba33913d84008cea8349875a3e8bcfba7baf1851630f613"
    # DSR1/DSR2 added the direct DeepSeek provider adapter project. The metering
    # and provider slices protect "local-router/src/Router.ProviderAdapters.*",
    # so the reviewed additions are authorized here as well. DeepSeekCapabilities.cs
    # and DeepSeekProviderAdapter.cs moved to $Fix5ApprovedFiles once FIX5 changed
    # them, so the FIX5 review - not DSR2 - authorizes their current content.
    "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekEndpointValidator.cs" = "aac3c73279330d856477d8d2ac70a6b3c6fc5e041671eb9c3a5bfae32ffcc32a"
    "local-router/src/Router.ProviderAdapters.DeepSeek/packages.lock.json"           = "bc54e46a859d4c10481d7c74e0e43e7358134d915e6a7b1820776bd5687172a2"
    "local-router/src/Router.ProviderAdapters.DeepSeek/Router.ProviderAdapters.DeepSeek.csproj" = "6478f3ed1696622db63b3aed97ca3e3457ff2f448ca13ce6ed47ba70aafc8a22"
    # DSR2 adds the DeepSeek Official provider identity to the canonical catalog.
    "installer/model-catalog.json"                   = "386c4a8cc27c152626e8f69d9949c41823ba0a6d77a05d0687a7dda66a0c3a2e"
}

# FIX5 reviewed delta: the DeepSeek provider declares an explicit apply_patch
# compatibility bridge (capability literal plus the bridge capability set), the
# adapter wires that bridge behind the capability/route gate, and the bridge is
# implemented by three provider-local files. Those five files were shipped and
# reviewed inside the FIX5 chain (5f9a03ca..e702fd4b) but were never registered
# as an approved delta, so the authorization is registered here, is bound to the
# FIX5 file-authorization validator below, and stays delta-exact: any later
# change to any of these files fails the gate until a new delta is reviewed.
$script:Fix5ApprovedFiles = [ordered]@{
    # The shared Responses provider wire (B1a/B1a2) and the shared adapter base
    # (FIX5-A) are part of the same reviewed delta: the function/tool_choice wire
    # projection and the fail-closed rejection of a canonical custom tool.
    "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderRequestWire.cs"       = "eadb40fb57c91943132464dfe40b37eacff80e90561bf1b4b79cca5274133ca2"
    "local-router/src/Router.ProviderAdapters.Responses/ResponsesProviderCodec.cs"             = "43de13074944a80ab3f87630e258614db2239bbc383f03135c4e49ac29a12a35"
    "local-router/src/Router.ProviderAdapters.Responses/ResponsesCompatibleProviderAdapterBase.cs" = "40603e215a40b05d77b409c660a7ca3c9938a25e883d99cecb7891980d005967"
    "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekCapabilities.cs"                 = "d0e419dea84e14057b08b1a9ac51c1a4ca36d65ac27d6417e22369064ed58bf0"
    "local-router/src/Router.ProviderAdapters.DeepSeek/DeepSeekProviderAdapter.cs"              = "c072774478b28e010142d6f2d275ad9c5f4238136045dc07a6be0212e42a58da"
    "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchRequestBridge.cs"              = "16f54d4f4728b56b7dc53940ec1c0d7b5ac1c7fff40bdf84ad0d236d8696bfef"
    "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchResponseBridge.cs"             = "49117399b575d3f6026763a86cad167bc2b848392c66ceed6f05ea5358b0f6eb"
    "local-router/src/Router.ProviderAdapters.DeepSeek/ApplyPatchStreamBridge.cs"               = "e0f1280d014eb1c9293665626cba8032faded9358ccef45ddc4d06e36f730541"
}

function Get-NormalizedFileSha256([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $normalized = $text -replace "`r`n", "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalized))
        return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Test-Lr13ProtectedFileChangeAuthorized([string]$RepositoryRoot, [string]$File) {
    if ($script:Dsr2ApprovedFiles.Contains($File)) {
        $scopeValidator = Join-Path $RepositoryRoot "tests/validate-deepseek-router-bootstrap.ps1"
        if (-not (Test-Path -LiteralPath $scopeValidator -PathType Leaf)) { return $false }
        try {
            $actual = Get-NormalizedFileSha256 (Join-Path $RepositoryRoot $File)
            return ($actual -eq $script:Dsr2ApprovedFiles[$File])
        }
        catch {
            return $false
        }
    }
    if ($script:Fix5ApprovedFiles.Contains($File)) {
        # Deleting the FIX5 file-authorization review revokes this authorization.
        $scopeValidator = Join-Path $RepositoryRoot "tests/validate-dsr7c-apply-patch-file-authorization.ps1"
        if (-not (Test-Path -LiteralPath $scopeValidator -PathType Leaf)) { return $false }
        try {
            $actual = Get-NormalizedFileSha256 (Join-Path $RepositoryRoot $File)
            return ($actual -eq $script:Fix5ApprovedFiles[$File])
        }
        catch {
            return $false
        }
    }
    if ($script:Lr14ApprovedV4Sha256.Contains($File)) {
        $scopeValidator = Join-Path $RepositoryRoot "tests/validate-local-router-lr14-scope.ps1"
        $runtime = Join-Path $RepositoryRoot "installer/scripts/visual-router-runtime.ps1"
        if (-not (Test-Path -LiteralPath $scopeValidator -PathType Leaf)) { return $false }
        if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) { return $false }
        try {
            $actual = Get-NormalizedFileSha256 (Join-Path $RepositoryRoot $File)
            return ($actual -eq $script:Lr14ApprovedV4Sha256[$File])
        }
        catch {
            return $false
        }
    }
    if ($File -eq "installer/scripts/router-codex-cli.ps1") {
        $scopeValidator = Join-Path $RepositoryRoot "tests/validate-local-router-hs1b-rb1-scope.ps1"
        if (-not (Test-Path -LiteralPath $scopeValidator -PathType Leaf)) { return $false }
        try {
            $actual = Get-NormalizedFileSha256 (Join-Path $RepositoryRoot $File)
            if ($actual -eq $script:Hs1bRb1ApprovedRouterCliSha256) { return $true }
            if ($actual -ne $script:Hs1cInstallerApprovedRouterCliSha256) { return $false }
            return (@(Get-RouterCliHs1cInstallerDeltaErrors (Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $File))).Count -eq 0)
        }
        catch {
            return $false
        }
    }
    if ($File -ne "installer/scripts/desktop-chat-route.ps1") { return $false }
    $adapter = Join-Path $RepositoryRoot "installer/scripts/desktop-router-route.ps1"
    $scopeValidator = Join-Path $RepositoryRoot "tests/validate-local-router-lr13-scope.ps1"
    if (-not (Test-Path -LiteralPath $adapter -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $scopeValidator -PathType Leaf)) { return $false }
    try {
        $actual = Get-NormalizedFileSha256 (Join-Path $RepositoryRoot "installer/scripts/desktop-chat-route.ps1")
        return ($actual -eq $script:Lr13ApprovedDesktopChatRouteSha256)
    }
    catch {
        return $false
    }
}

function Get-DesktopChatRouteScopeErrors([string]$RepositoryRoot, [string]$OverridePath = "") {
    $errors = New-Object System.Collections.Generic.List[string]
    $target = if ([string]::IsNullOrWhiteSpace($OverridePath)) {
        (Join-Path $RepositoryRoot "installer/scripts/desktop-chat-route.ps1")
    }
    else {
        $OverridePath
    }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        $errors.Add("desktop-chat-route.ps1 target is missing for LR-13 scope check.")
        return @($errors.ToArray())
    }
    $actual = Get-NormalizedFileSha256 $target
    if ($actual -ne $script:Lr13ApprovedDesktopChatRouteSha256) {
        $errors.Add("desktop-chat-route.ps1 no longer matches the approved LR-13 delta (normalized sha256 $actual).")
    }
    $text = Get-Content -Raw -LiteralPath $target
    if (-not $text.Contains('. (Join-Path $PSScriptRoot "router-codex-cli.ps1")')) {
        $errors.Add("LR-13 approved delta requires the router-codex-cli dot-source.")
    }
    if (-not $text.Contains('function Leave-DesktopRouterOwnerForDirect')) {
        $errors.Add("LR-13 approved delta requires Leave-DesktopRouterOwnerForDirect.")
    }
    if (-not $text.Contains('route_kind = "direct"')) {
        $errors.Add("LR-13 approved delta requires route_kind=direct in Desktop route state.")
    }
    if (-not $text.Contains('schema_version = 1')) {
        $errors.Add("LR-13 approved delta requires schema_version=1 in Desktop route state.")
    }
    return @($errors.ToArray())
}

function Get-RouterCliScopeErrors([string]$RepositoryRoot, [string]$OverridePath = "") {
    $errors = New-Object System.Collections.Generic.List[string]
    $target = if ([string]::IsNullOrWhiteSpace($OverridePath)) {
        (Join-Path $RepositoryRoot "installer/scripts/router-codex-cli.ps1")
    }
    else {
        $OverridePath
    }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        $errors.Add("router-codex-cli.ps1 target is missing for HS1B-RB1 scope check.")
        return @($errors.ToArray())
    }
    $actual = Get-NormalizedFileSha256 $target
    if ($actual -ne $script:Hs1bRb1ApprovedRouterCliSha256 -and $actual -ne $script:Hs1cInstallerApprovedRouterCliSha256) {
        $errors.Add("router-codex-cli.ps1 no longer matches the approved HS1B-RB1 bootstrap delta (normalized sha256 $actual).")
    }
    $text = Get-Content -Raw -LiteralPath $target
    if ($actual -eq $script:Hs1cInstallerApprovedRouterCliSha256) {
        foreach ($hs1cError in @(Get-RouterCliHs1cInstallerDeltaErrors $text)) { $errors.Add($hs1cError) }
    }
    if (-not $text.Contains('function Initialize-RouterCli')) {
        $errors.Add("HS1B-RB1 approved delta requires Initialize-RouterCli.")
    }
    if (-not $text.Contains('"Initialize" {')) {
        $errors.Add("HS1B-RB1 approved delta requires the Initialize dispatch arm.")
    }
    if (-not $text.Contains('New-RouterCliSecureLocalClientToken')) {
        $errors.Add("HS1B-RB1 approved delta requires the secure local client token generator.")
    }
    if ($text.Contains('DEEPSEEK_ROUTER_GAP')) {
        $errors.Add("HS1B-RB1/DSR2 approved delta must not keep an active DeepSeek Router gap code.")
    }
    if (-not $text.Contains('"deepseek" = [ordered]@{')) {
        $errors.Add("DSR2 approved delta requires the direct DeepSeek bootstrap provider table entry.")
    }
    if (-not $text.Contains('"deepseek::deepseek-flash" = @("deepseek-v4-flash", "deepseek-v4-flash-vision-exp")')) {
        $errors.Add("DSR2 approved delta requires the explicit DeepSeek flash alias table.")
    }
    if (-not $text.Contains('Get-RouterBootstrapModelAliases')) {
        $errors.Add("DSR2 approved delta requires bootstrap model routes to resolve aliases from the explicit table.")
    }
    if (-not $text.Contains('UPSTREAM_SECRET_REFERENCE_MISSING')) {
        $errors.Add("HS1B-RB1 approved delta requires the upstream secret reference gap code.")
    }
    if (-not $text.Contains('STOPPED - no approved Router-supported model')) {
        $errors.Add("HS1B-RB1 approved delta requires the route bootstrap to stop instead of fabricating a route.")
    }
    if (-not $text.Contains('function Get-RouterCollectionCount')) {
        $errors.Add("HS1B-RB1 approved delta requires the null-safe route collection count helper.")
    }
    if ($text.Contains('wire_api = "chat"')) {
        $errors.Add("HS1B-RB1 approved delta must not reintroduce the legacy Chat wire mode.")
    }
    return @($errors.ToArray())
}
