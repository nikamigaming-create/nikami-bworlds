[CmdletBinding()]
param(
    [ValidateSet("All", "Retail", "OpenMW")]
    [string]$Target = "All",
    [ValidateSet("Jam", "Opening", "TestMap", "PipBoy")]
    [string]$Scenario = "Jam",
    [ValidateSet("TTW", "NewVegas")]
    [string]$OpeningCampaign = "TTW",
    [switch]$RuntimeReady,
    [switch]$RequireIdle,
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$ParityRoot = "D:\code\nikami-worlds-fnv-parity",
    [string]$EngineRoot = "D:\code\nikami-openmw-save330-integrated",
    [string]$RetailShadowRoot =
        "D:\code\nikami-worlds\run\jam-retail-side-video-20260724-191235\retail-game",
    [string]$JamRoot = "D:\code\nikami-worlds\local\mods\jam-4.6-original",
    [string]$JamArchive =
        "D:\code\nikami-worlds\local\mod-depot\archives\jam\Just Assorted Mods-66666-4-6-1717763151.7z",
    [string]$OpeningRuntimeRoot = "",
    [string]$OpeningTtwRoot = "D:\Modlists\fnv\mods\Tale of Two Wastelands - OpenMW",
    [string]$OpeningNewVegasData = "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data",
    [string]$OpeningAudioDevice = "Stereo Mix (Realtek(R) Audio)",
    [string]$SavePath =
        "C:\Users\nbrys\OneDrive\Documents\My Games\FalloutNV\Saves\Save 331     Goodsprings  00 17 36.fos"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")
if ([string]::IsNullOrWhiteSpace($OpeningRuntimeRoot)) {
    $pipBoyRuntimeRoot = Join-Path $WorldsRoot "local\openmw-testmap-fnv-clean-20260801-080000"
    if ($Scenario -eq "PipBoy" -and (Test-Path -LiteralPath (Join-Path $pipBoyRuntimeRoot "openmw.exe") -PathType Leaf)) {
        $OpeningRuntimeRoot = $pipBoyRuntimeRoot
    }
    else {
        $OpeningRuntimeRoot = Resolve-NikamiOpenMWRuntimeRoot
    }
}
$OpeningRuntimeRoot = [IO.Path]::GetFullPath($OpeningRuntimeRoot)

$checks = [Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [bool]$Passed, [string]$Detail) {
    $checks.Add([pscustomobject][ordered]@{
        name = $Name
        passed = $Passed
        detail = $Detail
    })
}

function Test-File([string]$Name, [string]$Path) {
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    Add-Check $Name $exists $Path
    return $exists
}

function Test-Directory([string]$Name, [string]$Path) {
    $exists = Test-Path -LiteralPath $Path -PathType Container
    Add-Check $Name $exists $Path
    return $exists
}

function Test-PowerShellParse([string]$Path) {
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$null, [ref]$parseErrors)
    Add-Check "PowerShell parses: $([IO.Path]::GetFileName($Path))" `
        ($parseErrors.Count -eq 0) `
        ($(if ($parseErrors.Count -eq 0) {
            $Path
        } else {
            ($parseErrors | ForEach-Object Message) -join "; "
        }))
}

$catalogPath = Join-Path $WorldsRoot "catalog\fnv-jam-background-capture-recipes.json"
$runbookPath = Join-Path $WorldsRoot "docs\fnv-jam-background-capture.md"
$entryPointPath = Join-Path $WorldsRoot "scripts\Invoke-FNVJamBackgroundCapture.ps1"
$preflightPath = Join-Path $WorldsRoot "scripts\Test-FNVJamBackgroundCapture.ps1"
$retailRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-FNVJamFullRetailRehearsal.ps1"
$openMwRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-FNVJamSprintProof.ps1"
$retailOpeningRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-RetailTTWOpeningCapture.ps1"
$retailTtwLayerInitializerPath = Join-Path $WorldsRoot "scripts\Initialize-TTWRetailCompatibilityLayer.ps1"
$retailTtwLayerManifestPath = Join-Path $WorldsRoot "local\ttw-retail-compat\compatibility-layer.json"
$openingRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-OpenNVOpeningCapture.ps1"
$testMapRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-OpenNVTestMapDiagnostic.ps1"
$pipBoyRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-OpenNVPipBoyShowcaseCapture.ps1"
$retailPipBoyRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-FNVRetailPipBoyStateCapture.ps1"
$ttwInitializerPath = Join-Path $WorldsRoot "scripts\Initialize-TTWCompatibilityProfile.ps1"
$newVegasInitializerPath = Join-Path $WorldsRoot "scripts\Initialize-OpenNVBaseProfile.ps1"
$oracleSourcePath =
    Join-Path $ParityRoot "oracles\xnvse\nvse_retail_oracle\main.cpp"
$oracleRuntimeManifestPath =
    Join-Path $ParityRoot "local\xnvse-retail-oracle\oracle-runtime-manifest.json"
$oracleDllPath =
    Join-Path $ParityRoot "local\xnvse-retail-oracle\plugins\nvse_retail_oracle.dll"

$canonicalFiles = [Collections.Generic.List[string]]::new()
foreach ($path in @($catalogPath, $runbookPath, $entryPointPath, $preflightPath)) {
    $canonicalFiles.Add($path)
}
if ($Scenario -eq "Jam") {
    foreach ($path in @($retailRunnerPath, $openMwRunnerPath, $oracleSourcePath)) {
        $canonicalFiles.Add($path)
    }
}
elseif ($Scenario -eq "Opening") {
    $openingFiles = [Collections.Generic.List[string]]::new()
    if ($Target -in @("All", "Retail")) {
        foreach ($path in @($retailOpeningRunnerPath, $retailTtwLayerInitializerPath, $oracleSourcePath)) {
            $openingFiles.Add($path)
        }
    }
    if ($Target -in @("All", "OpenMW")) {
        $openingInitializerPath = if ($OpeningCampaign -eq "TTW") {
            $ttwInitializerPath
        } else {
            $newVegasInitializerPath
        }
        foreach ($path in @($openingRunnerPath, $openingInitializerPath)) {
            $openingFiles.Add($path)
        }
    }
    foreach ($path in $openingFiles) {
        $canonicalFiles.Add($path)
    }
}
elseif ($Scenario -eq "PipBoy") {
    if ($Target -in @("All", "Retail")) {
        foreach ($path in @($retailPipBoyRunnerPath, $oracleSourcePath)) {
            $canonicalFiles.Add($path)
        }
    }
    if ($Target -in @("All", "OpenMW")) {
        foreach ($path in @($pipBoyRunnerPath, $newVegasInitializerPath)) {
            $canonicalFiles.Add($path)
        }
    }
}
else {
    $canonicalFiles.Add($testMapRunnerPath)
}
foreach ($path in $canonicalFiles) {
    [void](Test-File "Canonical file exists: $([IO.Path]::GetFileName($path))" $path)
}

$catalog = $null
try {
    $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
    Add-Check "Recipe catalog parses" $true $catalogPath
}
catch {
    Add-Check "Recipe catalog parses" $false $_.Exception.Message
}

if ($null -ne $catalog) {
    Add-Check "Recipe schema is canonical" `
        ($catalog.schema -eq "nikami-fnv-jam-background-capture-recipes/v1" -and
            $catalog.status -eq "canonical") `
        "$($catalog.schema); status=$($catalog.status)"
    Add-Check "Windows app control forbidden" `
        (-not [bool]$catalog.policy.windowsAppControlAllowed) `
        "windowsAppControlAllowed=$($catalog.policy.windowsAppControlAllowed)"
    Add-Check "Foreground activation forbidden" `
        (-not [bool]$catalog.policy.foregroundActivationAllowed) `
        "foregroundActivationAllowed=$($catalog.policy.foregroundActivationAllowed)"
    Add-Check "Injected Windows input forbidden" `
        (-not [bool]$catalog.policy.injectedWindowsInputAllowed) `
        "injectedWindowsInputAllowed=$($catalog.policy.injectedWindowsInputAllowed)"
    if ($Scenario -eq "TestMap") {
        Add-Check "TestMap diagnostic is restricted to OpenMW" `
            ($Target -eq "OpenMW") "target=$Target"
    }
    if ($Scenario -eq "PipBoy") {
        Add-Check "Pip-Boy capture selects one engine" `
            ($Target -in @("Retail", "OpenMW")) "target=$Target"
    }
    $selectedRecipes = @($(if ($Scenario -eq "Jam") { $catalog.recipes } elseif ($Scenario -eq "Opening") {
        @($catalog.openingRecipes | Where-Object {
            ($Target -eq "All" -or $_.target -eq $Target) -and
            ((-not $_.PSObject.Properties.Match("campaign")) -or [string]$_.campaign -eq $OpeningCampaign)
        })
    } elseif ($Scenario -eq "PipBoy") {
        @($catalog.showcaseRecipes | Where-Object {
            $_.target -eq $Target
        })
    } else {
        @($catalog.diagnosticRecipes | Where-Object {
            [string]$_.id -eq "opennv-testmap01-clean-native-v1" -and $_.target -eq $Target
        })
    }))
    $expectedRecipeCount = if ($Scenario -eq "Jam") {
        2
    }
    elseif ($Scenario -eq "TestMap") {
        if ($Target -eq "OpenMW") { 1 } else { 0 }
    }
    elseif ($Scenario -eq "PipBoy") {
        if ($Target -in @("Retail", "OpenMW")) { 1 } else { 0 }
    }
    elseif ($OpeningCampaign -eq "NewVegas") {
        # Standalone New Vegas has both the ordinary authored opening proof and
        # the longer, manifest-routed Vit-o-matic/SPECIAL proof. Retail is not
        # a supported standalone-New-Vegas opening target.
        if ($Target -eq "Retail") { 0 } else { 2 }
    }
    elseif ($Target -eq "All") {
        2
    }
    elseif ($Scenario -eq "Opening") {
        1
    }
    Add-Check "$Scenario scenario declares the expected canonical recipe count" `
        ($selectedRecipes.Count -eq $expectedRecipeCount) `
        (($selectedRecipes | ForEach-Object id) -join ", ")
    foreach ($recipe in $selectedRecipes) {
        $runnerPath = Join-Path $WorldsRoot ([string]$recipe.runner)
        Add-Check "$Scenario recipe runner exists: $($recipe.id)" `
            (Test-Path -LiteralPath $runnerPath -PathType Leaf) $runnerPath
        Add-Check "$Scenario recipe names a capture method: $($recipe.id)" `
            (-not [string]::IsNullOrWhiteSpace([string]$recipe.captureMethod)) `
            ([string]$recipe.captureMethod)
    }

    if ($Scenario -eq "Jam") {
        foreach ($anchor in $catalog.knownGoodEvidence.PSObject.Properties) {
            $anchorRoot = Join-Path $WorldsRoot ([string]$anchor.Value)
            $anchorExists = Test-Path -LiteralPath $anchorRoot -PathType Container
            Add-Check "Known-good anchor exists: $($anchor.Name)" `
                $anchorExists $anchorRoot
            if ($anchorExists) {
                $anchorSummaryName = if ($anchor.Name -eq "sideBySide") {
                    "side-by-side-proof-manifest.json"
                } else {
                    "background-capture-summary.json"
                }
                $anchorSummary = Join-Path $anchorRoot $anchorSummaryName
                $summaryExists = Test-Path -LiteralPath $anchorSummary -PathType Leaf
                Add-Check "Known-good anchor has canonical summary: $($anchor.Name)" `
                    $summaryExists $anchorSummary
                if ($summaryExists) {
                    try {
                        $knownGood =
                            Get-Content -Raw -LiteralPath $anchorSummary |
                            ConvertFrom-Json
                        $knownGoodPolicy = if ($anchor.Name -eq "sideBySide") {
                            $knownGood.capturePolicy
                        } else {
                            $knownGood.policy
                        }
                        $policyPassed = $knownGood.status -eq "pass" -and
                            -not [bool]$knownGoodPolicy.windowsAppControlUsed -and
                            -not [bool]$knownGoodPolicy.foregroundActivationUsed -and
                            -not [bool]$knownGoodPolicy.foregroundInputInjected
                        Add-Check "Known-good anchor passes no-control policy: $($anchor.Name)" `
                            $policyPassed $anchorSummary
                    }
                    catch {
                        Add-Check "Known-good anchor passes no-control policy: $($anchor.Name)" `
                            $false $_.Exception.Message
                    }
                }
            }
        }
    }
}

 $scriptsToParse = [Collections.Generic.List[string]]::new()
foreach ($script in @($entryPointPath, $preflightPath)) {
    $scriptsToParse.Add($script)
}
if ($Scenario -eq "Jam") {
    foreach ($script in @($retailRunnerPath, $openMwRunnerPath)) { $scriptsToParse.Add($script) }
}
elseif ($Scenario -eq "Opening") {
    if ($Target -in @("All", "Retail")) {
        foreach ($script in @($retailOpeningRunnerPath, $retailTtwLayerInitializerPath)) { $scriptsToParse.Add($script) }
    }
    if ($Target -in @("All", "OpenMW")) {
        foreach ($script in @($openingRunnerPath, $ttwInitializerPath)) { $scriptsToParse.Add($script) }
    }
}
elseif ($Scenario -eq "PipBoy") {
    if ($Target -eq "Retail") { $scriptsToParse.Add($retailPipBoyRunnerPath) }
    else { $scriptsToParse.Add($pipBoyRunnerPath) }
}
else {
    $scriptsToParse.Add($testMapRunnerPath)
}
foreach ($script in $scriptsToParse) {
    if (Test-Path -LiteralPath $script -PathType Leaf) {
        Test-PowerShellParse $script
    }
}

if (Test-Path -LiteralPath $entryPointPath -PathType Leaf) {
    $entryText = Get-Content -Raw -LiteralPath $entryPointPath
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Add-Check "Entry point excludes $forbidden" `
            ($entryText -notmatch [regex]::Escape($forbidden)) `
            $entryPointPath
    }
    if ($Scenario -eq "Jam") {
        Add-Check "OpenMW invocation forces SelfDrive" `
            ($entryText -match '(?s)Invoke-FNVJamSprintProof.*?-SelfDrive') `
            $entryPointPath
    }
    elseif ($Scenario -eq "Opening") {
        $retailRoutePresent = $entryText -match 'Invoke-RetailTTWOpeningCapture'
        $openMwRoutePresent = $entryText -match 'Invoke-OpenNVOpeningCapture'
        $expectedRoutePresent =
            (($Target -notin @("All", "Retail")) -or $retailRoutePresent) -and
            (($Target -notin @("All", "OpenMW")) -or $openMwRoutePresent)
        Add-Check "Opening invocation routes to the declared opening runner" `
            $expectedRoutePresent `
            $entryPointPath
    }
    elseif ($Scenario -eq "PipBoy") {
        $expectedPipBoyRoute = if ($Target -eq "Retail") {
            $entryText -match 'Invoke-FNVRetailPipBoyStateCapture'
        } else {
            $entryText -match 'Invoke-OpenNVPipBoyShowcaseCapture'
        }
        Add-Check "Pip-Boy invocation routes to the declared showcase runner" `
            $expectedPipBoyRoute `
            $entryPointPath
    }
    else {
        Add-Check "TestMap invocation routes to the declared diagnostic runner" `
            ($Target -eq "OpenMW" -and $entryText -match 'Invoke-OpenNVTestMapDiagnostic') `
            $entryPointPath
    }
}

if ($Scenario -eq "Jam" -and $Target -in @("All", "Retail")) {
    if (Test-Path -LiteralPath $retailRunnerPath -PathType Leaf) {
        $retailText = Get-Content -Raw -LiteralPath $retailRunnerPath
        Add-Check "Retail schedules background polling" `
            ($retailText -match 'EnableBackgroundInputPolling') $retailRunnerPath
        Add-Check "Retail uses native HoldKey and ReleaseKey" `
            ($retailText -match 'HoldKey' -and $retailText -match 'ReleaseKey') `
            $retailRunnerPath
        Add-Check "Retail supports dense native video frames" `
            ($retailText -match '\[switch\]\$RecordVideo' -and
                $retailText -match 'retail-d3d9-backbuffer-bmp-sequence') `
            $retailRunnerPath
        foreach ($forbidden in @(
            "AppActivate", "SetForegroundWindow", "BringWindowToTop",
            "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
        )) {
            Add-Check "Retail runner excludes $forbidden" `
                ($retailText -notmatch [regex]::Escape($forbidden)) `
                $retailRunnerPath
        }
    }

    if (Test-Path -LiteralPath $oracleSourcePath -PathType Leaf) {
        $oracleText = Get-Content -Raw -LiteralPath $oracleSourcePath
        Add-Check "Oracle selects only DirectInput keyboard" `
            ($oracleText -match 'GET_DIDEVICE_TYPE\(result\.deviceType\)\s*==\s*DI8DEVTYPE_KEYBOARD') `
            $oracleSourcePath
        Add-Check "Oracle requests background nonexclusive keyboard" `
            ($oracleText -match 'DISCL_BACKGROUND\s*\|\s*DISCL_NONEXCLUSIVE') `
            $oracleSourcePath
        Add-Check "Oracle reports reconfiguration explicitly" `
            ($oracleText -match '\\"reconfigured\\"') $oracleSourcePath
        Add-Check "Oracle returns before touching non-keyboard devices" `
            ($oracleText -match '(?s)if\s*\(!result\.selected\).*?return result;.*?device->Unacquire\(\)') `
            $oracleSourcePath
        Add-Check "Oracle supports schedules larger than 4096 bytes" `
            ($oracleText -match 'maxEnvironmentValueLength\s*=\s*1024\s*\*\s*1024' -and
                $oracleText -match 'GetEnvironmentVariableA\(name,\s*nullptr,\s*0\)') `
            $oracleSourcePath
    }

    $runtimeManifestExists =
        Test-File "Oracle runtime manifest exists" $oracleRuntimeManifestPath
    $runtimeDllExists =
        Test-File "Oracle runtime DLL exists" $oracleDllPath
    if ($runtimeManifestExists -and $runtimeDllExists) {
        try {
            $runtimeManifest =
                Get-Content -Raw -LiteralPath $oracleRuntimeManifestPath |
                ConvertFrom-Json
            $expectedHash = [string]$runtimeManifest.files.plugin.sha256
            $actualHash =
                (Get-FileHash -LiteralPath $oracleDllPath -Algorithm SHA256).
                Hash.ToLowerInvariant()
            Add-Check "Oracle DLL matches runtime manifest" `
                ($actualHash -eq $expectedHash.ToLowerInvariant()) `
                "expected=$expectedHash actual=$actualHash"
        }
        catch {
            Add-Check "Oracle DLL matches runtime manifest" $false `
                $_.Exception.Message
        }
    }
}

if ($Scenario -eq "Jam" -and $Target -in @("All", "OpenMW") -and
    (Test-Path -LiteralPath $openMwRunnerPath -PathType Leaf)) {
    $openMwText = Get-Content -Raw -LiteralPath $openMwRunnerPath
    Add-Check "Full OpenMW proof refuses non-SelfDrive runs" `
        ($openMwText -match '(?s)\$FullProofDrive\s+-and\s+-not\s+\$SelfDrive.*?throw') `
        $openMwRunnerPath
    Add-Check "OpenMW report records app-control flags" `
        ($openMwText -match 'windowsAppControlUsed' -and
            $openMwText -match 'foregroundActivationUsed' -and
            $openMwText -match 'foregroundInputInjected') `
        $openMwRunnerPath
}

if ($Scenario -eq "Opening" -and $Target -in @("All", "Retail") -and
    (Test-Path -LiteralPath $retailOpeningRunnerPath -PathType Leaf)) {
    $retailOpeningText = Get-Content -Raw -LiteralPath $retailOpeningRunnerPath
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Add-Check "Retail TTW opening runner excludes $forbidden" `
            ($retailOpeningText -notmatch [regex]::Escape($forbidden)) `
            $retailOpeningRunnerPath
    }
    Add-Check "Retail TTW opening runner awaits a native NewGame event" `
        ($retailOpeningText -match 'AwaitNewGame' -and
            $retailOpeningText -match 'new-game-observed') `
        $retailOpeningRunnerPath
    Add-Check "Retail TTW opening runner schedules StartNewCharacter and native D3D frames" `
        ($retailOpeningText -match '\$\{MenuStartGameLoopFrame\}:StartNewCharacter' -and
            $retailOpeningText -match 'scheduled-backbuffer-capture') `
        $retailOpeningRunnerPath
    $retailOracleText = Get-Content -Raw -LiteralPath $oracleSourcePath
    Add-Check "Retail oracle exposes StartNewCharacter through live New and Yes control API boundaries" `
        ($retailOracleText -match 'StartNewCharacter' -and
            $retailOracleText -match 'startMenuVisible' -and
            $retailOracleText -match 'menuPresent' -and
            $retailOracleText -match 'option\.tile == action\.actionTile' -and
            $retailOracleText -match 'dispatchStartMenuListBoxEnter\(\s*readiness\.menu, 0xE4, confirmation\.yesTile\)' -and
            $retailOracleText -match 'StartMenu\.HandleSpecialKeyInput\(kEnter\)' -and
            $retailOracleText -match 'specialKeyHandled' -and
            $retailOracleText -match 'selected == confirmation\.yesTile' -and
            $retailOracleText -match 'start-new-character-new-api-dispatch' -and
            $retailOracleText -match 'start-new-character-confirmation-api-dispatch' -and
            $retailOracleText -match 'xNVSE buffered menu-input queue' -and
            $retailOracleText -match 'desktopInputUsed\\":false' -and
            $retailOracleText -notmatch 'SendInput' -and
            $retailOracleText -match 'sStartMenuNewGameActionName = "New"' -and
            $retailOracleText -match 'sStartMenuNewGameListIndex = 1\.f') `
        $oracleSourcePath
    Add-Check "Retail TTW opening runner composes base Data with the TTW overlay" `
        ($retailOpeningText -match 'baseDataRoot' -and
            $retailOpeningText -match 'TTW overlay') `
        $retailOpeningRunnerPath
}

if ($Scenario -eq "Opening" -and $Target -in @("All", "OpenMW") -and
    (Test-Path -LiteralPath $openingRunnerPath -PathType Leaf)) {
    $openingText = Get-Content -Raw -LiteralPath $openingRunnerPath
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Add-Check "Opening runner excludes $forbidden" `
            ($openingText -notmatch [regex]::Escape($forbidden)) `
            $openingRunnerPath
    }
    Add-Check "Opening runner uses exact-title capture" `
        ($openingText -match 'title=OpenMW') $openingRunnerPath
    Add-Check "Opening runner prevents focus-loss minimization without foreground control" `
        ($openingText -match 'minimize on focus loss' -and
            $openingText -match 'Get-VideoVisualEvidence' -and
            $openingText -match 'changingVisibleFrames') $openingRunnerPath
    Add-Check "Opening runner records a DirectShow audio stream" `
        ($openingText -match 'audio=\$AudioDevice' -and $openingText -match 'Stereo Mix') `
        $openingRunnerPath
    Add-Check "Opening runner uses authored video capture markers" `
        ($openingText -match 'OPENMW_CAPTURE_VIDEO_READY_PATH' -and
            $openingText -match 'OPENMW_CAPTURE_VIDEO_GO_PATH') `
        $openingRunnerPath
    Add-Check "Opening runner validates the declared TTW data-layer contract" `
        ($openingText -match 'Assert-OpenNVTtwLayerContract' -and
            $openingText -match 'dataLayerContract') `
        $openingRunnerPath
    if (Test-Path -LiteralPath $ttwInitializerPath -PathType Leaf) {
        $ttwInitializerText = Get-Content -Raw -LiteralPath $ttwInitializerPath
        Add-Check "TTW profile declares an ordered base-plus-overlay data union" `
            ($ttwInitializerText -match 'dataLayers' -and
                $ttwInitializerText -match 'ttw-generated-overlay' -and
                $ttwInitializerText -match 'low-to-high precedence') `
            $ttwInitializerPath
        Add-Check "TTW profile verifies TTW-owned and base fallback assets" `
            ($ttwInitializerText -match 'Resolve-TtwLayeredFile' -and
                $ttwInitializerText -match 'Fallout - Voices1\.bsa' -and
                $ttwInitializerText -match 'TaleOfTwoWastelands - Textures\.bsa') `
            $ttwInitializerPath
    }
}

if ($Scenario -eq "PipBoy" -and $Target -eq "OpenMW" -and
    (Test-Path -LiteralPath $pipBoyRunnerPath -PathType Leaf)) {
    $pipBoyText = Get-Content -Raw -LiteralPath $pipBoyRunnerPath
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Add-Check "Pip-Boy showcase runner excludes $forbidden" `
            ($pipBoyText -notmatch [regex]::Escape($forbidden)) `
            $pipBoyRunnerPath
    }
    Add-Check "Pip-Boy showcase uses normal New Game plus final TestMap placement" `
        ($pipBoyText -match '"--skip-menu", "--new-game"' -and
            $pipBoyText -match 'OPENMW_FNV_GAMEPLAY_START_WORLDSPACE') `
        $pipBoyRunnerPath
    Add-Check "Pip-Boy showcase retains four native UI frames and an exact-title transport" `
        ($pipBoyText -match 'ScreenCaptureHandler' -and
            $pipBoyText -match 'title=OpenMW' -and
            $pipBoyText -match 'PipBoy-live-panel-collage\.png') `
        $pipBoyRunnerPath
    Add-Check "Pip-Boy showcase asserts authored Fallout inventory data without fallbacks" `
        ($pipBoyText -match 'authoredFalloutDataLoadoutObserved' -and
            $pipBoyText -match 'fallbackInventoryRecordsAbsent') `
        $pipBoyRunnerPath
    Add-Check "Pip-Boy showcase records no-control policy fields" `
        ($pipBoyText -match 'windowsAppControlUsed\s*=\s*\$false' -and
            $pipBoyText -match 'foregroundActivationUsed\s*=\s*\$false' -and
            $pipBoyText -match 'foregroundInputInjected\s*=\s*\$false') `
        $pipBoyRunnerPath
}

if ($Scenario -eq "TestMap" -and $Target -eq "OpenMW" -and
    (Test-Path -LiteralPath $testMapRunnerPath -PathType Leaf)) {
    $testMapText = Get-Content -Raw -LiteralPath $testMapRunnerPath
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Add-Check "TestMap runner excludes $forbidden" `
            ($testMapText -notmatch [regex]::Escape($forbidden)) `
            $testMapRunnerPath
    }
    Add-Check "TestMap runner uses an explicit diagnostic-only start cell" `
        ($testMapText -match '"--start", "TestMap01"' -and
            $testMapText -match 'diagnosticOnly\s*=\s*\$true') `
        $testMapRunnerPath
    Add-Check "TestMap runner retains a native OpenMW framebuffer frame" `
        ($testMapText -match 'OPENMW_PROOF_SCREENSHOT_FRAME' -and
            $testMapText -match 'ScreenCaptureHandler native framebuffer screenshot') `
        $testMapRunnerPath
    Add-Check "TestMap runner records no-control policy fields" `
        ($testMapText -match 'windowsAppControlUsed\s*=\s*\$false' -and
            $testMapText -match 'foregroundActivationUsed\s*=\s*\$false' -and
            $testMapText -match 'foregroundInputInjected\s*=\s*\$false') `
        $testMapRunnerPath
}

if (Test-Path -LiteralPath $runbookPath -PathType Leaf) {
    $runbookText = Get-Content -Raw -LiteralPath $runbookPath
    foreach ($requiredText in @(
        "retail FNV", "OpenMW", "DI8DEVTYPE_KEYBOARD",
        "reconfigured=false", "Invoke-FNVJamBackgroundCapture.ps1",
        "Test-FNVJamBackgroundCapture.ps1"
    )) {
        Add-Check "Runbook contains '$requiredText'" `
            ($runbookText -match [regex]::Escape($requiredText)) $runbookPath
    }
}

if ($RuntimeReady) {
    foreach ($tool in @("ffmpeg", "ffprobe")) {
        $command = Get-Command $tool -ErrorAction SilentlyContinue |
            Select-Object -First 1
        Add-Check "$tool is available" ($null -ne $command) `
            $(if ($null -ne $command) { $command.Source } else { "not on PATH" })
    }
    if ($Scenario -eq "Jam") {
    [void](Test-File "Shared native save exists" $SavePath)

    if ($Target -in @("All", "Retail")) {
        [void](Test-Directory "Retail shadow root exists" $RetailShadowRoot)
        foreach ($file in @(
            "FalloutNV.exe",
            "Data\nvse\plugins\jip_nvse.dll",
            "Data\nvse\plugins\johnnyguitar.dll",
            "Data\nvse\plugins\kNVSE.dll",
            "Data\nvse\plugins\nvse_stewie_tweaks.dll",
            "Data\nvse\plugins\ui_organizer.dll"
        )) {
            [void](Test-File "Retail runtime file exists: $file" `
                (Join-Path $RetailShadowRoot $file))
        }
    }

    if ($Target -in @("All", "OpenMW")) {
        [void](Test-File "OpenMW binary exists" `
            (Join-Path $EngineRoot "MSVC2022_64\RelWithDebInfo\openmw.exe"))
        [void](Test-Directory "OpenMW resources exist" `
            (Join-Path $EngineRoot "MSVC2022_64\RelWithDebInfo\resources"))
        $cmakeCache =
            Join-Path $EngineRoot "MSVC2022_64\CMakeCache.txt"
        $cmakeCacheExists =
            Test-File "OpenMW CMake cache exists" $cmakeCache
        if ($cmakeCacheExists) {
            $myGuiLibraryEntry = Select-String -LiteralPath $cmakeCache `
                -Pattern '^MyGUI_LIBRARY:FILEPATH=(?<path>.+)$' |
                Select-Object -First 1
            Add-Check "OpenMW CMake cache declares MyGUI" `
                ($null -ne $myGuiLibraryEntry) $cmakeCache
            $osgVersionEntry = Select-String -LiteralPath $cmakeCache `
                -Pattern '^OPENSCENEGRAPH_VERSION:INTERNAL=(?<version>.+)$' |
                Select-Object -First 1
            Add-Check "OpenMW CMake cache declares OSG version" `
                ($null -ne $osgVersionEntry) $cmakeCache
            if ($null -ne $myGuiLibraryEntry -and $null -ne $osgVersionEntry) {
                $myGuiLibrary =
                    $myGuiLibraryEntry.Matches[0].Groups["path"].Value
                $dependencyRoot =
                    Split-Path -Parent (Split-Path -Parent $myGuiLibrary)
                $myGuiRuntimeCandidates = @(
                    (Join-Path $dependencyRoot "bin\Release\MyGUIEngine.dll"),
                    (Join-Path $dependencyRoot "bin\MyGUIEngine.dll")
                )
                $myGuiRuntime = @($myGuiRuntimeCandidates | Where-Object {
                    Test-Path -LiteralPath $_ -PathType Leaf
                } | Select-Object -First 1)
                Add-Check "Matching OpenMW MyGUI runtime exists" `
                    ($myGuiRuntime.Count -eq 1) `
                    ($myGuiRuntimeCandidates -join ", ")

                $osgVersion =
                    $osgVersionEntry.Matches[0].Groups["version"].Value
                $osgPluginPath = Join-Path $dependencyRoot `
                    "plugins\osgPlugins-$osgVersion"
                [void](Test-Directory `
                    "Matching OpenMW OSG plugin directory exists" `
                    $osgPluginPath)
                foreach ($pluginName in @(
                    "osgdb_bmp.dll",
                    "osgdb_dae.dll",
                    "osgdb_dds.dll",
                    "osgdb_freetype.dll",
                    "osgdb_jpeg.dll",
                    "osgdb_osg.dll",
                    "osgdb_png.dll",
                    "osgdb_serializers_osg.dll",
                    "osgdb_tga.dll"
                )) {
                    [void](Test-File `
                        "Matching OpenMW OSG plugin exists: $pluginName" `
                        (Join-Path $osgPluginPath $pluginName))
                }
            }
        }
        [void](Test-File "Untouched JAM ESP exists" `
            (Join-Path $JamRoot "JustAssortedMods.esp"))
        [void](Test-File "Published JAM archive exists" $JamArchive)
        [void](Test-File "OpenMW JAM provider exists" `
            (Join-Path $EngineRoot `
                "MSVC2022_64\RelWithDebInfo\resources\vfs\scripts\omw\fnv\compat\jam_sprint.lua"))
    }
    }
    elseif ($Scenario -eq "Opening") {
        if ($Target -in @("All", "Retail")) {
            [void](Test-File "Retail TTW opening executable exists" `
                "D:\SteamLibrary\steamapps\common\Fallout New Vegas\FalloutNV.exe")
            [void](Test-Directory "Retail TTW opening base Data root exists" `
                "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data")
            [void](Test-File "Retail TTW opening retains base FNV voices archive" `
                "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data\Fallout - Voices1.bsa")
            [void](Test-Directory "Retail TTW opening content root exists" $OpeningTtwRoot)
            foreach ($asset in @(
                "FalloutNV.esm",
                "Fallout3.esm",
                "TaleOfTwoWastelands.esm",
                "YUPTTW.esm",
                "Video\Fallout INTRO Vsk.bik"
            )) {
                [void](Test-File "Retail TTW opening asset exists: $asset" `
                    (Join-Path $OpeningTtwRoot $asset))
            }
            [void](Test-File "Retail TTW opening oracle manifest exists" `
                $oracleRuntimeManifestPath)
            [void](Test-File "Retail TTW opening oracle DLL exists" $oracleDllPath)
            [void](Test-File "Retail TTW compatibility-layer manifest exists" `
                $retailTtwLayerManifestPath)
            if (Test-Path -LiteralPath $retailTtwLayerManifestPath -PathType Leaf) {
                try {
                    $retailTtwLayer = Get-Content -LiteralPath $retailTtwLayerManifestPath -Raw | ConvertFrom-Json
                    Add-Check "Retail TTW compatibility-layer schema is current" `
                        ([string]$retailTtwLayer.schema -eq 'opennv-ttw-retail-compat-layer/v1') `
                        ([string]$retailTtwLayer.schema)
                    foreach ($entry in @($retailTtwLayer.plugins)) {
                        $pluginPath = Join-Path (Split-Path -Parent $retailTtwLayerManifestPath) ([string]$entry.path)
                        $pluginExists = Test-Path -LiteralPath $pluginPath -PathType Leaf
                        $hashMatches = $pluginExists -and
                            ((Get-FileHash -LiteralPath $pluginPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq
                                ([string]$entry.sha256).ToLowerInvariant())
                        Add-Check "Retail TTW compatibility plugin is present and pinned: $($entry.id)" `
                            $hashMatches $pluginPath
                    }
                }
                catch {
                    Add-Check "Retail TTW compatibility-layer manifest parses" $false $_.Exception.Message
                }
            }
        }

        if ($Target -in @("All", "OpenMW")) {
        [void](Test-File "Deployed OpenNV opening binary exists" `
            (Join-Path $OpeningRuntimeRoot "openmw.exe"))
        [void](Test-Directory "Deployed OpenNV opening resources exist" `
            (Join-Path $OpeningRuntimeRoot "resources"))
        foreach ($plugin in @("osgdb_dds.dll", "osgdb_png.dll", "osgdb_freetype.dll")) {
            [void](Test-File "Deployed OpenNV OSG plugin exists: $plugin" `
                (Join-Path $OpeningRuntimeRoot (Join-Path "osgPlugins-3.6.5" $plugin)))
        }
        if ($OpeningCampaign -eq "NewVegas") {
            [void](Test-File "Standalone New Vegas opening profile initializer exists" $newVegasInitializerPath)
            [void](Test-Directory "Standalone New Vegas Data root exists" $OpeningNewVegasData)
            [void](Test-File "Standalone New Vegas opening master exists" `
                (Join-Path $OpeningNewVegasData "FalloutNV.esm"))
            [void](Test-File "Standalone New Vegas authored opening Bink exists" `
                (Join-Path $OpeningNewVegasData "Video\FNVIntro.bik"))
        }
        [void](Test-File "TTW opening profile initializer exists" $ttwInitializerPath)
        [void](Test-Directory "TTW opening content root exists" $OpeningTtwRoot)
        [void](Test-File "TTW authored opening Bink exists" `
            (Join-Path $OpeningTtwRoot "Video\Fallout INTRO Vsk.bik"))
        [void](Test-File "Fallout 3 opening master exists" `
            "D:\SteamLibrary\steamapps\common\Fallout 3 goty\Data\Fallout3.esm")
        [void](Test-File "New Vegas opening master exists" `
            "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data\FalloutNV.esm")

        try {
            $layerPreflightProfile = Join-Path $WorldsRoot "profiles\_verification\_preflight-ttw-layer-contract"
            $layerPreflightCampaign = Join-Path $WorldsRoot "profiles\_verification\_campaigns\_preflight-ttw-layer-contract\userdata"
            $layerPreflight = & $ttwInitializerPath `
                -TtwRoot $OpeningTtwRoot `
                -Fallout3Data "D:\SteamLibrary\steamapps\common\Fallout 3 goty\Data" `
                -FalloutNewVegasData "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data" `
                -ProfileDirectory $layerPreflightProfile `
                -CampaignUserdataDirectory $layerPreflightCampaign `
                -BinaryRoot $OpeningRuntimeRoot `
                -DryRun
            $expectedLayerIds = @(
                "fallout3-base",
                "fallout-new-vegas-base",
                "fallout3-archive-aliases",
                "ttw-generated-overlay"
            )
            $actualLayerIds = @($layerPreflight.dataLayers |
                Sort-Object { [int]$_.priority } |
                ForEach-Object { [string]$_.id })
            Add-Check "TTW OpenMW dry-run declares the retail-equivalent data union" `
                (($actualLayerIds -join '|') -eq ($expectedLayerIds -join '|')) `
                ($actualLayerIds -join ' -> ')
            $resolvedAssets = @($layerPreflight.resolvedLayeredAssets)
            $ttwResolved = @($resolvedAssets | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.expectedProviderLayerId)
            })
            Add-Check "TTW OpenMW dry-run resolves authored assets from the TTW overlay" `
                ($ttwResolved.Count -ge 7 -and
                    @($ttwResolved | Where-Object {
                        [string]$_.providerLayerId -ne [string]$_.expectedProviderLayerId
                    }).Count -eq 0) `
                (@($ttwResolved | ForEach-Object { "$($_.id)=$($_.providerLayerId)" }) -join '; ')
            $baseFallbacks = @($resolvedAssets | Where-Object {
                [string]::IsNullOrWhiteSpace([string]$_.expectedProviderLayerId)
            })
            Add-Check "TTW OpenMW dry-run preserves required base fallback archives" `
                ($baseFallbacks.Count -ge 2 -and
                    @($baseFallbacks | Where-Object {
                        -not (Test-Path -LiteralPath ([string]$_.providerPath) -PathType Leaf)
                    }).Count -eq 0) `
                (@($baseFallbacks | ForEach-Object { "$($_.id)=$($_.providerLayerId)" }) -join '; ')
        }
        catch {
            Add-Check "TTW OpenMW dry-run validates the data-layer union" $false $_.Exception.Message
        }

        $deviceText = ""
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $deviceText = ((& ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1) | Out-String)
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        Add-Check "DirectShow opening audio device is available" `
            ($deviceText -match [regex]::Escape('"' + $OpeningAudioDevice + '" (audio)')) `
            $OpeningAudioDevice
        }
    }
    elseif ($Scenario -eq "PipBoy") {
        if ($Target -eq "Retail") {
            [void](Test-File "Retail FalloutNV binary exists" `
                (Join-Path (Split-Path -Parent $OpeningNewVegasData) "FalloutNV.exe"))
            [void](Test-File "Retail Pip-Boy oracle DLL exists" $oracleDllPath)
            [void](Test-File "Retail Pip-Boy save fixture exists" $SavePath)
        }
        else {
            # The live Pip-Boy panel run uses the same isolated standalone FNV
            # runtime as TestMap01, but reaches it after normal New Game.
            [void](Test-File "Deployed OpenNV Pip-Boy binary exists" `
                (Join-Path $OpeningRuntimeRoot "openmw.exe"))
            [void](Test-Directory "Deployed OpenNV Pip-Boy resources exist" `
                (Join-Path $OpeningRuntimeRoot "resources"))
            foreach ($plugin in @("osgdb_dds.dll", "osgdb_png.dll", "osgdb_freetype.dll")) {
                [void](Test-File "Deployed OpenNV Pip-Boy OSG plugin exists: $plugin" `
                    (Join-Path $OpeningRuntimeRoot (Join-Path "osgPlugins-3.6.5" $plugin)))
            }
            [void](Test-File "Standalone New Vegas Pip-Boy profile initializer exists" $newVegasInitializerPath)
            [void](Test-Directory "Standalone New Vegas Pip-Boy Data root exists" $OpeningNewVegasData)
            [void](Test-File "Standalone New Vegas Pip-Boy master exists" `
                (Join-Path $OpeningNewVegasData "FalloutNV.esm"))
        }
    }
    else {
        # TestMap01 is a standalone FNV renderer diagnostic. It does not pull
        # TTW, retail, or Morrowind assets into the profile.
        [void](Test-File "Deployed OpenNV TestMap binary exists" `
            (Join-Path $OpeningRuntimeRoot "openmw.exe"))
        [void](Test-Directory "Deployed OpenNV TestMap resources exist" `
            (Join-Path $OpeningRuntimeRoot "resources"))
        foreach ($plugin in @("osgdb_dds.dll", "osgdb_png.dll", "osgdb_freetype.dll")) {
            [void](Test-File "Deployed OpenNV TestMap OSG plugin exists: $plugin" `
                (Join-Path $OpeningRuntimeRoot (Join-Path "osgPlugins-3.6.5" $plugin)))
        }
        [void](Test-File "Standalone New Vegas TestMap profile initializer exists" $newVegasInitializerPath)
        [void](Test-Directory "Standalone New Vegas TestMap Data root exists" $OpeningNewVegasData)
        [void](Test-File "Standalone New Vegas TestMap master exists" `
            (Join-Path $OpeningNewVegasData "FalloutNV.esm"))
    }
}

if ($RequireIdle) {
    $processNames = if ($Target -eq "Retail") {
        @("FalloutNV", "nvse_loader")
    } elseif ($Target -eq "OpenMW") {
        @("openmw")
    } else {
        @("FalloutNV", "nvse_loader", "openmw")
    }
    $running = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
    Add-Check "Capture engines are idle" ($running.Count -eq 0) `
        $(if ($running.Count -eq 0) {
            "none"
        } else {
            ($running | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ", "
        })
}

$failed = @($checks | Where-Object { -not $_.passed })
$result = [pscustomobject][ordered]@{
    schema = "nikami-fnv-jam-background-capture-preflight/v1"
    status = if ($failed.Count -eq 0) { "pass" } else { "fail" }
    target = $Target
    scenario = $Scenario
    runtimeReadyChecked = [bool]$RuntimeReady
    idleChecked = [bool]$RequireIdle
    passedChecks = $checks.Count - $failed.Count
    failedChecks = $failed.Count
    checks = @($checks)
}
$result
if ($failed.Count -ne 0) {
    throw "FNV/JAM background-capture preflight failed $($failed.Count) check(s): " +
        (($failed | ForEach-Object name) -join "; ")
}
