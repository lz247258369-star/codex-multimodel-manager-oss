param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
$failures = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "PASS  $Message" -ForegroundColor Green }
function Fail([string]$Message) { $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }

$entryPath = Join-Path $RepositoryRoot "installer/scripts/visual-console-entry.ps1"
$sourcePath = Join-Path $RepositoryRoot "installer/scripts/visual-console.ps1"
if (-not (Test-Path -LiteralPath $entryPath)) {
    Fail "Missing Visual Console entrypoint"
}
else {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($entryPath,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) { Pass "Visual Console entrypoint parses" }
    else { foreach ($err in $parseErrors) { Fail "Entrypoint parse error: $($err.Message)" } }

    $text = Get-Content -Raw -LiteralPath $entryPath
    foreach ($needle in @(
        '$cards.ToArray()',
        '$rootLiteral = "''" + $escapedRoot + "''"',
        '$sourceText.Replace(''$PSScriptRoot'', $rootLiteral)',
        '[ScriptBlock]::Create($sourceText)'
    )) {
        if ($text.Contains($needle)) { Pass "Entrypoint compatibility behavior present: $needle" }
        else { Fail "Entrypoint compatibility behavior missing: $needle" }
    }

    foreach ($needle in @(
        'PART_EditableTextBox',
        '$WorkspaceCombo.Foreground = Get-ColorBrush "#F4F7FF"',
        '$WorkspaceCombo.Background = Get-ColorBrush "#0B1221"',
        '$WorkspaceCombo.FontSize = 13',
        '$WorkspaceCombo.Height = 38',
        '$BrowseButton.Content = "选择 CLI 目录"',
        '$workspaceTitle.Text = "CLI 工作目录"',
        '不会切换 Codex Desktop 左侧项目',
        '$WorkspaceCombo.Add_DropDownOpened',
        'Register-ListWheelForwarding',
        'Add_PreviewMouseWheel',
        'ScrollToVerticalOffset',
        'Register-ListWheelForwarding $DashboardModelList',
        'Register-ListWheelForwarding $ModelsModelList'
    )) {
        if ($text.Contains($needle)) { Pass "Entrypoint UI usability behavior present: $needle" }
        else { Fail "Entrypoint UI usability behavior missing: $needle" }
    }

    foreach ($needle in @(
        'desktop-chat-provider.ps1',
        '切换桌面 Chat → OX',
        '恢复桌面 ChatGPT',
        'Refresh-DesktopRouteUI',
        '-Mode activate-ox -ConfirmationCode "OX"',
        '-Mode restore',
        'stealth/ox-alpha',
        'Desktop Chat：OX ACTIVE'
    )) {
        if ($text.Contains($needle)) { Pass "Entrypoint Desktop route behavior present: $needle" }
        else { Fail "Entrypoint Desktop route behavior missing: $needle" }
    }

    foreach ($needle in @(
        'windows-app-identity.ps1',
        '$window.Add_SourceInitialized',
        '[System.Windows.Interop.WindowInteropHelper]::new($window)',
        'Set-ManagerWindowAppIdentity -WindowHandle $windowHandle'
    )) {
        if ($text.Contains($needle)) { Pass "Entrypoint window identity behavior present: $needle" }
        else { Fail "Entrypoint window identity behavior missing: $needle" }
    }

    if ($text.Contains('$bootstrap =')) { Fail "Entrypoint reintroduced bootstrap-string root injection" }
    else { Pass "Entrypoint does not use bootstrap-string root injection" }

    if ($text -match '(?im)\bgit\s+(reset|clean|stash)\b') { Fail "Entrypoint contains destructive Git command" }
    else { Pass "Entrypoint contains no destructive Git command" }

    if ($text -match '(?i)OPENROUTER_API_KEY|MIMO_API_KEY|DASHSCOPE_API_KEY') { Fail "Entrypoint should not read or expose provider secret variables" }
    else { Pass "Entrypoint is secret-independent; provider secret handling stays in the route tool" }

    # Reproduce the path-literal transformation without opening the WPF window.
    $sampleRoot = "C:\Users\Test User\Projects\codex-multimodel-manager\installer\scripts"
    $escapedRoot = $sampleRoot.Replace("'", "''")
    $rootLiteral = "'" + $escapedRoot + "'"
    $sample = 'Join-Path $PSScriptRoot "controller-catalog.ps1"'
    $transformed = $sample.Replace('$PSScriptRoot', $rootLiteral)
    $expected = 'Join-Path ''C:\Users\Test User\Projects\codex-multimodel-manager\installer\scripts'' "controller-catalog.ps1"'
    if ($transformed -eq $expected) { Pass "Entrypoint preserves the exact scripts directory literal" }
    else { Fail "Entrypoint path transformation is malformed: $transformed" }

    if (Test-Path -LiteralPath $sourcePath) {
        $source = Get-Content -Raw -LiteralPath $sourcePath
        if ($source.Contains('$script:loadingRoute = $false')) { Pass "Visual Console source exposes the runtime injection anchor" }
        else { Fail "Visual Console source is missing the runtime injection anchor" }

        # Materialize the same runtime text that production builds before
        # ScriptBlock.Create(). This catches syntax failures that do not exist in
        # visual-console-entry.ps1 itself, such as smart quotes inside injected
        # PowerShell string literals.
        try {
            $normalizedEntry = $text.Replace("`r`n", "`n")

            function Get-HereStringBody([string]$VariableName) {
                $marker = '$' + $VariableName + " = @'`n"
                $start = $normalizedEntry.IndexOf($marker, [System.StringComparison]::Ordinal)
                if ($start -lt 0) { throw "Missing here-string marker for $VariableName" }
                $start += $marker.Length
                $finish = $normalizedEntry.IndexOf("`n'@", $start, [System.StringComparison]::Ordinal)
                if ($finish -lt 0) { throw "Missing here-string terminator for $VariableName" }
                return $normalizedEntry.Substring($start, $finish - $start)
            }

            $materialized = $source.Replace('$script:modelCards = @($cards)', '$script:modelCards = $cards.ToArray()')

            $uiPatch = Get-HereStringBody 'uiUsabilityPatch'
            $uiAnchor = '$script:loadingRoute = $false'
            $uiIndex = $materialized.IndexOf($uiAnchor, [System.StringComparison]::Ordinal)
            if ($uiIndex -lt 0) { throw "Missing UI usability injection anchor" }
            $materialized = $materialized.Substring(0, $uiIndex) + $uiPatch + $materialized.Substring($uiIndex + $uiAnchor.Length)

            $hierarchyPatch = Get-HereStringBody 'hierarchyInjection'
            $hierarchyAnchor = '$initialWorkspace = Resolve-InitialWorkspace'
            $hierarchyIndex = $materialized.IndexOf($hierarchyAnchor, [System.StringComparison]::Ordinal)
            if ($hierarchyIndex -lt 0) { throw "Missing hierarchy injection anchor" }
            $materialized = $materialized.Substring(0, $hierarchyIndex) + $hierarchyPatch + $materialized.Substring($hierarchyIndex + $hierarchyAnchor.Length)

            $scriptsRoot = Join-Path $RepositoryRoot 'installer/scripts'
            $escapedScriptsRoot = $scriptsRoot.Replace("'", "''")
            $scriptsRootLiteral = "'" + $escapedScriptsRoot + "'"
            $materialized = $materialized.Replace('$PSScriptRoot', $scriptsRootLiteral)

            [ScriptBlock]::Create($materialized) | Out-Null
            Pass "Fully materialized Visual Console runtime parses before WPF launch"
        }
        catch {
            Fail "Materialized Visual Console parse failed: $($_.Exception.Message)"
        }
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Visual Console entrypoint validation FAILED ($($failures.Count) failures)" -ForegroundColor Red
    exit 1
}

Write-Host "Visual Console entrypoint validation PASSED" -ForegroundColor Green
exit 0
