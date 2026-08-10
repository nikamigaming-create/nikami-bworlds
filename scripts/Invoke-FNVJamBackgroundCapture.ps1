[CmdletBinding()]
param(
    [ValidateSet("Retail", "OpenMW", "Both", "Godot")]
    [string]$Target = "Both",
    [ValidateSet("Jam", "Opening", "TestMap", "PipBoy", "Terminal", "RealSave", "GodotRoute", "GodotCinematics", "GodotPortraits")]
    [string]$Scenario = "Jam",
    [string]$OutputRoot = "",
    [switch]$SmokeTest,
    [switch]$OpeningDiagnostic,
    [switch]$OpeningInputDiagnostic,
    [switch]$OpeningTitleGateDiagnostic,
    [switch]$OpeningTitleStateDiagnostic,
    [switch]$OpeningTitleInputDiagnostic,
    # Diagnostic only: load a declared retail cell through the in-process
    # console boundary. It separates a broken world/content load from a
    # broken StartMenu New Game handoff and is never canonical opening proof.
    [switch]$OpeningWorldLoadDiagnostic,
    [switch]$OpeningSkipBackgroundInputPolling,
    [switch]$SkipBuild,
    [switch]$EnableSound,
    [ValidateRange(1, 30)]
    [int]$RetailVideoFrameStep = 3,
    [ValidateRange(5, 600)]
    [int]$OpenMwCaptureSeconds = 160,
    [ValidateRange(60, 240)]
    [int]$GodotRouteCaptureSeconds = 210,
    [ValidateRange(5, 120)]
    [int]$OpeningVideoSeconds = 20,
    [ValidateRange(3, 180)]
    [int]$OpeningSceneSeconds = 8,
    [ValidateRange(6, 60)]
    [int]$TestMapCaptureSeconds = 16,
    [ValidateRange(15, 90)]
    [int]$PipBoyCaptureSeconds = 80,
    [ValidateRange(52, 90)]
    [int]$TerminalCaptureSeconds = 65,
    [switch]$PipBoyLifecycleOnly,
    # Optional isolated retail fixture for the Pip-Boy interaction oracle.
    # The source save is copied by Invoke-FNVRetailOracle and never modified.
    [string]$RetailPipBoySavePath = "",
    # Request a retail xNVSE first-person weapon reference before the normal
    # Pip-Boy sequence. This remains a retail-only, public-entry capture.
    [switch]$RetailPipBoyWeaponAudit,
    [ValidatePattern('^[0-9a-fA-F]{1,8}$')]
    [string]$RetailPipBoyWeaponForm = '0000434F',
    # Immutable native Save330 fixture for the canonical single-engine lane.
    [string]$SavePath = "",
    [ValidateSet("save330-cold-load-settle-v1", "save330-reload-idempotence-v1", "save330-pipboy-map-selection-v1", "save330-pipboy-map-travel-v1", "save330-pipboy-rejection-matrix-v1", "save330-travel-persistence-v1", "save330-pipboy-inventory-v1", "save330-pipboy-weapon-selection-v1", "save330-pipboy-radio-stations-v1")]
    [string]$RealSaveRouteId = "save330-cold-load-settle-v1",
    [ValidateRange(5, 600)]
    [int]$RealSaveCaptureSeconds = 30,
    [ValidateSet("", "invBindThenSkeleton", "skeleton", "skeletonThenInvBind", "bindThenSkeleton", "skeletonThenBind", "source", "identity")]
    [string]$RealSaveHandSkinningMode = "",
    [switch]$RealSaveHandPoseAudit,
    [switch]$InteractiveHandoff,
    [ValidateRange(60, 3600)]
    [int]$TestMapNativeScreenshotFrame = 480,
    # Opt-in native-driver telemetry for an OpenMW TestMap renderer issue.
    [switch]$TestMapOpenGlDebug,
    [ValidateRange(0, 60)]
    [double]$OpeningDefaultChoiceDelaySeconds = 1,
    [ValidateRange(50, 1000)]
    [int]$OpeningNativeFrameIntervalMilliseconds = 250,
    [ValidateSet("TTW", "NewVegas")]
    [string]$OpeningCampaign = "TTW",
    # Optional manifest for an engine-internal authored-route checkpoint to
    # accompany an OpenMW opening capture.  It is not accepted for retail,
    # where the retail oracle owns its own in-process schedule.
    [string]$OpeningAuthoredRoutePath = "",
    [string]$OpeningAudioDevice = "Stereo Mix (Realtek(R) Audio)",
    # Opening captures may target an isolated runtime built under local/labs.
    # Leave empty to preserve the release runtime default used by existing
    # recipes and launcher invocations.
    [string]$OpeningRuntimeRoot = "",
    [int]$TimeoutSeconds = 240,
    [string]$WorldsRoot = "D:\code\nikami-worlds"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")
$preflight = Join-Path $PSScriptRoot "Test-FNVJamBackgroundCapture.ps1"
$retailRunner = Join-Path $PSScriptRoot "Invoke-FNVJamFullRetailRehearsal.ps1"
$openMwRunner = Join-Path $PSScriptRoot "Invoke-FNVJamSprintProof.ps1"
$retailOpeningRunner = Join-Path $PSScriptRoot "Invoke-RetailTTWOpeningCapture.ps1"
$openingRunner = Join-Path $PSScriptRoot "Invoke-OpenNVOpeningCapture.ps1"
$testMapRunner = Join-Path $PSScriptRoot "Invoke-OpenNVTestMapDiagnostic.ps1"
$pipBoyRunner = Join-Path $PSScriptRoot "Invoke-OpenNVPipBoyShowcaseCapture.ps1"
$terminalRunner = Join-Path $PSScriptRoot "Invoke-OpenNVTerminalCapture.ps1"
$retailPipBoyRunner = Join-Path $PSScriptRoot "Invoke-FNVRetailPipBoyStateCapture.ps1"
$realSaveRunner = Join-Path $PSScriptRoot "Invoke-FNVRealSaveCapture.ps1"
$godotRouteRunner = Join-Path $PSScriptRoot "Invoke-OpenNVGodotShowcaseCapture.ps1"
$godotCinematicRunner = Join-Path $PSScriptRoot "Invoke-OpenNVCinematicReelCapture.ps1"
$godotPortraitRunner = Join-Path $PSScriptRoot "Invoke-OpenNVFamousPeopleCapture.ps1"
$canonicalSave330Path = Join-Path $WorldsRoot "local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos"
if ([string]::IsNullOrWhiteSpace($SavePath)) {
    $SavePath = if ($Scenario -eq "RealSave") {
        $canonicalSave330Path
    }
    else {
        "C:\Users\nbrys\OneDrive\Documents\My Games\FalloutNV\Saves\NikamiCleanPipBoyOracle-20260802.fos"
    }
}
if ($Target -ne "Godot" -and [string]::IsNullOrWhiteSpace($OpeningRuntimeRoot)) {
    $pipBoyRuntimeRoot = Join-Path $WorldsRoot "local\openmw-testmap-fnv-clean-20260801-080000"
    if ($Scenario -eq "PipBoy" -and (Test-Path -LiteralPath (Join-Path $pipBoyRuntimeRoot "openmw.exe") -PathType Leaf)) {
        $OpeningRuntimeRoot = $pipBoyRuntimeRoot
    }
    else {
        $OpeningRuntimeRoot = Resolve-NikamiOpenMWRuntimeRoot
    }
}
if ($Target -ne "Godot") {
    $OpeningRuntimeRoot = [IO.Path]::GetFullPath($OpeningRuntimeRoot)
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $outputPrefix = if ($Scenario -eq "RealSave") { "fnv-real-save-$($Target.ToLowerInvariant())" } elseif ($Scenario -eq "GodotRoute") { "opennv-godot-route" } elseif ($Scenario -eq "GodotCinematics") { "opennv-godot-cinematics" } elseif ($Scenario -eq "GodotPortraits") { "opennv-godot-portraits" } else { "jam-background-$($Target.ToLowerInvariant())" }
    $OutputRoot = Join-Path $WorldsRoot "run\$outputPrefix-$stamp"
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing background-capture run: $OutputRoot"
}
if ($Scenario -eq "Opening" -and $SmokeTest) {
    throw "The authored-opening scenario has no abbreviated smoke path. It must retain the requested Bink interval and nursery handoff."
}
if ($Scenario -eq "Opening" -and $OpeningCampaign -eq "NewVegas" -and $Target -ne "OpenMW") {
    throw "The standalone New Vegas authored opening is currently an OpenMW-only capture route. Use -Target OpenMW -OpeningCampaign NewVegas."
}
if ($Scenario -eq "TestMap" -and $Target -ne "OpenMW") {
    throw "TestMap01 is an OpenMW-only renderer diagnostic. Use -Target OpenMW."
}
if (($Scenario -in @("GodotRoute", "GodotCinematics", "GodotPortraits")) -ne ($Target -eq "Godot")) {
    throw "GodotRoute and GodotCinematics are dedicated Godot lanes. Use -Target Godot."
}

if ($Scenario -eq "Terminal" -and $Target -ne "OpenMW") {
    throw "Terminal interaction is an OpenMW-only capture route. Use -Target OpenMW."
}
if ($Scenario -eq "PipBoy" -and $Target -eq "Both") {
    throw "Pip-Boy state captures are intentionally single-engine. Run Retail first, then OpenMW."
}
if ($Scenario -eq "RealSave" -and $Target -eq "Both") {
    throw "RealSave captures are intentionally single-engine. Run Retail first, then OpenMW."
}
if ($Scenario -eq "RealSave" -and $InteractiveHandoff -and $Target -eq "Retail") {
    throw "Interactive handoff is restricted to the playable OpenMW lane."
}
    if (($OpeningDiagnostic -or $OpeningInputDiagnostic -or $OpeningTitleGateDiagnostic -or $OpeningTitleStateDiagnostic -or $OpeningTitleInputDiagnostic -or $OpeningWorldLoadDiagnostic) -and ($Scenario -ne "Opening" -or $Target -ne "Retail")) {
    throw "Opening diagnostics are short retail TTW fresh-game diagnostics. Use -Target Retail -Scenario Opening."
}
    if (@(@($OpeningDiagnostic, $OpeningInputDiagnostic, $OpeningTitleGateDiagnostic, $OpeningTitleStateDiagnostic, $OpeningTitleInputDiagnostic, $OpeningWorldLoadDiagnostic) | Where-Object { $_ }).Count -gt 1) {
    throw "Choose one retail opening diagnostic route."
}
if ($OpeningSkipBackgroundInputPolling -and -not $OpeningTitleStateDiagnostic) {
    throw "-OpeningSkipBackgroundInputPolling is restricted to -OpeningTitleStateDiagnostic."
}
if (-not [string]::IsNullOrWhiteSpace($OpeningAuthoredRoutePath) -and
    ($Scenario -ne "Opening" -or $Target -notin @("OpenMW", "Both"))) {
    throw "-OpeningAuthoredRoutePath is only valid for an OpenMW authored-opening capture."
}
if ($Scenario -eq "Jam" -and $SmokeTest -and $Target -ne "Retail") {
    throw "OpenMW has no abbreviated JAM proof: all 44 phases must run for at least three seconds. Use -SmokeTest only with -Target Retail; omit it for OpenMW or Both."
}

$preflightTarget = if ($Target -eq "Both") { "All" } else { $Target }
& $preflight `
    -Target $preflightTarget `
    -Scenario $Scenario `
    -OpeningCampaign $OpeningCampaign `
    -OpeningRuntimeRoot $OpeningRuntimeRoot `
    -SavePath $SavePath `
    -RealSaveRouteId $RealSaveRouteId `
    -RealSaveCaptureSeconds $RealSaveCaptureSeconds `
    -TerminalCaptureSeconds $TerminalCaptureSeconds `
    -OutputRoot $OutputRoot `
    -InteractiveHandoff:$InteractiveHandoff `
    -RuntimeReady `
    -RequireIdle | Out-Null

New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$startedAt = Get-Date
$retailResult = $null
$openMwResult = $null
$retailOpeningResult = $null
$openingResult = $null
$testMapResult = $null
$pipBoyResult = $null
$terminalResult = $null
$realSaveResult = $null
$godotRouteResult = $null

if ($Scenario -eq "GodotRoute") {
    $godotTimeout = [Math]::Max(360, $TimeoutSeconds)
    & $godotRouteRunner `
        -WorldsRoot $WorldsRoot `
        -OutputRoot (Join-Path $OutputRoot "godot") `
        -CaptureSeconds $GodotRouteCaptureSeconds `
        -TimeoutSeconds $godotTimeout
    $godotRouteResult =
        Get-Content -Raw -LiteralPath (Join-Path $OutputRoot "godot\godot-showcase-report.json") |
        ConvertFrom-Json
    if ($godotRouteResult.status -ne "pass" -or
        [bool]$godotRouteResult.capture.windowsAppControlUsed -or
        [bool]$godotRouteResult.capture.foregroundActivationUsed -or
        [bool]$godotRouteResult.capture.foregroundInputInjected) {
        throw "Canonical Godot Goodsprings-to-Strip capture did not pass its route, media, or no-control gates."
    }
}

if ($Scenario -eq "GodotCinematics") {
    & $godotCinematicRunner -WorldsRoot $WorldsRoot -OutputRoot (Join-Path $OutputRoot "godot") -TimeoutSeconds ([Math]::Max(900, $TimeoutSeconds))
    $godotRouteResult = Get-Content -Raw -LiteralPath (Join-Path $OutputRoot "godot\opennv-cinematic-reel-report.json") | ConvertFrom-Json
    if ($godotRouteResult.status -ne "pass" -or [bool]$godotRouteResult.capture.windowsAppControlUsed -or [bool]$godotRouteResult.capture.foregroundActivationUsed -or [bool]$godotRouteResult.capture.foregroundInputInjected) {
        throw "Canonical Godot cinematic capture did not pass its media or no-control gates."
    }
}

if ($Scenario -eq "GodotPortraits") {
    & $godotPortraitRunner -WorldsRoot $WorldsRoot -OutputRoot (Join-Path $OutputRoot "godot") -TimeoutSeconds ([Math]::Max(120, $TimeoutSeconds))
    $godotRouteResult = Get-Content -Raw -LiteralPath (Join-Path $OutputRoot "godot\opennv-famous-people-report.json") | ConvertFrom-Json
    if ($godotRouteResult.status -ne "pass" -or [bool]$godotRouteResult.capture.windowsAppControlUsed) {
        throw "Canonical Godot famous-people capture failed."
    }
}

if ($Scenario -eq "Opening") {
    if ($Target -in @("Retail", "Both")) {
        $retailOpeningOutput = Join-Path $OutputRoot "retail"
        & $retailOpeningRunner `
            -WorldsRoot $WorldsRoot `
            -OutputRoot $retailOpeningOutput `
            -IntroSeconds $OpeningVideoSeconds `
            -NurserySeconds $OpeningSceneSeconds `
            -TimeoutSeconds $TimeoutSeconds `
            -Diagnostic:$OpeningDiagnostic `
            -InputDiagnostic:$OpeningInputDiagnostic `
            -TitleGateDiagnostic:$OpeningTitleGateDiagnostic `
            -TitleStateDiagnostic:$OpeningTitleStateDiagnostic `
            -TitleInputDiagnostic:$OpeningTitleInputDiagnostic `
            -WorldLoadDiagnostic:$OpeningWorldLoadDiagnostic `
            -SkipBackgroundInputPolling:$OpeningSkipBackgroundInputPolling
        $retailOpeningResult =
            Get-Content -Raw -LiteralPath (Join-Path $retailOpeningOutput "retail-opening-report.json") |
            ConvertFrom-Json
        if ($retailOpeningResult.status -ne "pass" -or
            [bool]$retailOpeningResult.capture.windowsAppControlUsed -or
            [bool]$retailOpeningResult.capture.foregroundActivationUsed -or
            [bool]$retailOpeningResult.capture.foregroundInputInjected -or
            -not [bool]$retailOpeningResult.capture.sourceAssetsUnmodified -or
            -not [bool]$retailOpeningResult.capture.userConfigurationRestored) {
            throw "Canonical retail TTW opening capture did not pass its fresh-game or no-control policy gates."
        }
        $retailResult = $retailOpeningResult
    }
    if ($Target -in @("OpenMW", "Both")) {
        $openingOutput = Join-Path $OutputRoot "openmw"
        & $openingRunner `
            -WorldsRoot $WorldsRoot `
            -BinaryRoot $OpeningRuntimeRoot `
            -Campaign $OpeningCampaign `
            -OutputRoot $openingOutput `
            -VideoSeconds $OpeningVideoSeconds `
            -SceneSeconds $OpeningSceneSeconds `
            -DefaultChoiceDelaySeconds $OpeningDefaultChoiceDelaySeconds `
            -NativeFrameIntervalMilliseconds $OpeningNativeFrameIntervalMilliseconds `
            -AuthoredRoutePath $OpeningAuthoredRoutePath `
            -AudioDevice $OpeningAudioDevice `
            -TimeoutSeconds $TimeoutSeconds
        $openingResult =
            Get-Content -Raw -LiteralPath (Join-Path $openingOutput "opening-capture-report.json") |
            ConvertFrom-Json
        if ($openingResult.status -ne "pass" -or
            [bool]$openingResult.capture.windowsAppControlUsed -or
            [bool]$openingResult.capture.foregroundActivationUsed -or
            [bool]$openingResult.capture.foregroundInputInjected -or
            [int]$openingResult.media.audioStreamCount -ne 1 -or
            -not [bool]$openingResult.capture.nativeSourceFrameSequenceValid -or
            [string]$openingResult.capture.presentationVisualSource -ne "openmw-native-screencapture-frames" -or
            -not [bool]$openingResult.media.visualEvidence.changingVisibleFrames) {
            throw "Canonical OpenNV $OpeningCampaign opening capture did not pass its authored-video, native-frame, audio, or no-control policy gates."
        }
        $openMwResult = $openingResult
    }
}

if ($Scenario -eq "TestMap") {
    # This is deliberately a declared visual diagnostic rather than a claim
    # about the authored start. It uses only --start TestMap01, native OpenMW
    # framebuffer capture, and exact-title recording; no desktop input path is
    # present or permitted.
    $testMapOutput = Join-Path $OutputRoot "openmw"
    & $testMapRunner `
        -WorldsRoot $WorldsRoot `
        -BinaryRoot $OpeningRuntimeRoot `
        -OutputRoot $testMapOutput `
        -CaptureSeconds $TestMapCaptureSeconds `
        -NativeScreenshotFrame $TestMapNativeScreenshotFrame `
        -OpenGlDebug:$TestMapOpenGlDebug `
        -TimeoutSeconds $TimeoutSeconds
    $testMapResult =
        Get-Content -Raw -LiteralPath (Join-Path $testMapOutput "testmap-diagnostic-report.json") |
        ConvertFrom-Json
    if ($testMapResult.status -ne "pass" -or
        [bool]$testMapResult.capture.windowsAppControlUsed -or
        [bool]$testMapResult.capture.foregroundActivationUsed -or
        [bool]$testMapResult.capture.foregroundInputInjected -or
        -not [bool]$testMapResult.assertions.nativeFrameHealth.passed -or
        -not [bool]$testMapResult.assertions.missingLegacyTextureFailuresAbsent) {
        throw "Canonical OpenMW TestMap01 renderer diagnostic did not pass its native-frame or no-control policy gates."
    }
    $openMwResult = $testMapResult
}

if ($Scenario -eq "PipBoy") {
    if ($Target -eq "Retail") {
        $pipBoyOutput = Join-Path $OutputRoot "retail"
        $retailPipBoyArgs = @{
            WorldsRoot = $WorldsRoot
            OutputRoot = $pipBoyOutput
            TimeoutSeconds = $TimeoutSeconds
        }
        if (-not [string]::IsNullOrWhiteSpace($RetailPipBoySavePath)) {
            $retailPipBoyArgs.SavePath = [IO.Path]::GetFullPath($RetailPipBoySavePath)
        }
        if ($RetailPipBoyWeaponAudit) {
            $retailPipBoyArgs.WeaponAudit = $true
            $retailPipBoyArgs.WeaponForm = $RetailPipBoyWeaponForm
        }
        & $retailPipBoyRunner @retailPipBoyArgs
        $pipBoyResult =
            Get-Content -Raw -LiteralPath (Join-Path $pipBoyOutput "retail-pipboy-state-report.json") |
            ConvertFrom-Json
        if ($pipBoyResult.status -ne "pass" -or
            [bool]$pipBoyResult.capture.windowsAppControlUsed -or
            [bool]$pipBoyResult.capture.foregroundActivationUsed -or
            [bool]$pipBoyResult.capture.foregroundInputInjected) {
            throw "Canonical retail Pip-Boy state capture did not pass its state or no-control policy gates."
        }
        $retailResult = $pipBoyResult
    }
    else {
        # This is a normal-New-Game UI render, not the explicit TestMap01
        # renderer diagnostic. The engine opens the real Tab mode and queues
        # native UI frames itself; no desktop input is sent.
        $pipBoyOutput = Join-Path $OutputRoot "openmw"
        $pipBoyArgs = @{
            WorldsRoot = $WorldsRoot
            BinaryRoot = $OpeningRuntimeRoot
            OutputRoot = $pipBoyOutput
            CaptureSeconds = $PipBoyCaptureSeconds
            TimeoutSeconds = $TimeoutSeconds
        }
        if ($PipBoyLifecycleOnly) {
            $pipBoyArgs.LifecycleOnly = $true
            $pipBoyArgs.FramesPerPane = 90
            $pipBoyArgs.CaptureDelayFrames = 78
        }
        & $pipBoyRunner @pipBoyArgs
        $pipBoyResult =
            Get-Content -Raw -LiteralPath (Join-Path $pipBoyOutput "pipboy-showcase-report.json") |
            ConvertFrom-Json
        if ($pipBoyResult.status -ne "pass" -or
            [bool]$pipBoyResult.capture.windowsAppControlUsed -or
            [bool]$pipBoyResult.capture.foregroundActivationUsed -or
            [bool]$pipBoyResult.capture.foregroundInputInjected -or
            -not [bool]$pipBoyResult.assertions.normalNewGameObserved -or
            -not [bool]$pipBoyResult.assertions.authoredFalloutDataLoadoutObserved -or
            -not [bool]$pipBoyResult.assertions.fallbackInventoryRecordsAbsent -or
            [int]$pipBoyResult.assertions.nativePanelCount -ne [int]$pipBoyResult.assertions.expectedNativeStateCount) {
            throw "Canonical OpenMW live Pip-Boy showcase did not pass its complete-state, authored-data, or no-control policy gates."
        }
        $openMwResult = $pipBoyResult
    }
}

if ($Scenario -eq "Terminal") {
    $terminalOutput = Join-Path $OutputRoot "openmw"
    & $terminalRunner `
        -WorldsRoot $WorldsRoot `
        -BinaryRoot $OpeningRuntimeRoot `
        -OutputRoot $terminalOutput `
        -CaptureSeconds $TerminalCaptureSeconds `
        -TimeoutSeconds $TimeoutSeconds
    $terminalResult =
        Get-Content -Raw -LiteralPath (Join-Path $terminalOutput "terminal-capture-report.json") |
        ConvertFrom-Json
    if ($terminalResult.status -ne "pass" -or
        [bool]$terminalResult.launch.retailEngineLaunched -or
        [bool]$terminalResult.capture.windowsAppControlUsed -or
        [bool]$terminalResult.capture.foregroundActivationUsed -or
        [bool]$terminalResult.capture.foregroundInputInjected -or
        -not [bool]$terminalResult.assertions.selfDriveScriptLoaded -or
        -not [bool]$terminalResult.assertions.stagingObserved -or
        -not [bool]$terminalResult.assertions.ordinaryActivationObserved -or
        -not [bool]$terminalResult.assertions.ordinaryActivationTargetObserved -or
        [bool]$terminalResult.assertions.directActivationObserved -or
        [int]$terminalResult.assertions.physicalCameraEntryCount -ne 2 -or
        [int]$terminalResult.assertions.cameraRestorationCount -ne 2 -or
        -not [bool]$terminalResult.assertions.hackingOpened -or
        [int]$terminalResult.assertions.nativeFrameCount -ne 7) {
        throw "Canonical OpenMW Terminal capture did not pass its authored-activation, paced-input, native-frame, or no-control gates."
    }
    $openMwResult = $terminalResult
}

if ($Scenario -eq "RealSave") {
    $realSaveOutput = Join-Path $OutputRoot $Target.ToLowerInvariant()
    & $realSaveRunner `
        -WorldsRoot $WorldsRoot `
        -Target $Target `
        -SavePath $SavePath `
        -BinaryRoot $OpeningRuntimeRoot `
        -OutputRoot $realSaveOutput `
        -RouteId $RealSaveRouteId `
        -CaptureSeconds $RealSaveCaptureSeconds `
        -RadioAudioDevice $OpeningAudioDevice `
        -HandSkinningMode $RealSaveHandSkinningMode `
        -HandPoseAudit:$RealSaveHandPoseAudit `
        -InteractiveHandoff:$InteractiveHandoff `
        -TimeoutSeconds $TimeoutSeconds
    $realSaveResult =
        Get-Content -Raw -LiteralPath (Join-Path $realSaveOutput "real-save-capture-report.json") |
        ConvertFrom-Json
    if ($realSaveResult.status -ne "pass" -or
        [bool]$realSaveResult.capture.windowsAppControlUsed -or
        [bool]$realSaveResult.capture.foregroundActivationUsed -or
        [bool]$realSaveResult.capture.foregroundInputInjected) {
        throw "Canonical RealSave capture did not pass its state/evidence or no-control policy gates."
    }
}

if ($Scenario -eq "Jam" -and $Target -in @("Retail", "Both")) {
    $retailOutput = Join-Path $OutputRoot "retail"
    & $retailRunner `
        -OutputRoot $retailOutput `
        -TimeoutSeconds $TimeoutSeconds `
        -RecordVideo `
        -VideoFrameStep $RetailVideoFrameStep `
        -SmokeTest:$SmokeTest
    $retailResult =
        Get-Content -Raw -LiteralPath (Join-Path $retailOutput "rehearsal-summary.json") |
        ConvertFrom-Json
    if ($retailResult.status -ne "pass" -or
        [bool]$retailResult.backgroundCapture.windowsAppControlUsed -or
        [bool]$retailResult.backgroundCapture.foregroundRequired) {
        throw "Canonical retail background capture did not pass its policy gates."
    }
}

if ($Scenario -eq "Jam" -and $Target -in @("OpenMW", "Both")) {
    # Retail and OpenMW are deliberately sequential. The OpenMW path is always
    # SelfDrive, which bypasses every legacy window-control/input branch.
    $openMwOutput = Join-Path $OutputRoot "openmw"
    & $openMwRunner `
        -OutputRoot $openMwOutput `
        -TimeoutSeconds $TimeoutSeconds `
        -CaptureSeconds $OpenMwCaptureSeconds `
        -FullProofDrive `
        -SelfDrive `
        -SkipBuild:$SkipBuild `
        -EnableSound:$EnableSound
    $openMwResult =
        Get-Content -Raw -LiteralPath (Join-Path $openMwOutput "proof-report.json") |
        ConvertFrom-Json
    if (-not [bool]$openMwResult.passed -or
        [bool]$openMwResult.capture.windowsAppControlUsed -or
        [bool]$openMwResult.capture.foregroundActivationUsed -or
        [bool]$openMwResult.capture.foregroundInputInjected -or
        -not [bool]$openMwResult.capture.selfDriven) {
        throw "Canonical OpenMW background capture did not pass its policy gates."
    }
}

$artifacts = [Collections.Generic.List[object]]::new()
$artifactPaths = [Collections.Generic.List[string]]::new()
if ($null -ne $retailResult -and
    $retailResult.PSObject.Properties.Name -contains 'video' -and
    $null -ne $retailResult.video) {
    $artifactPaths.Add([string]$retailResult.video.path)
}
if ($Scenario -eq "Jam" -and $null -ne $openMwResult -and $null -ne $openMwResult.video) {
    $artifactPaths.Add([string]$openMwResult.video.path)
}
if ($Scenario -eq "Opening") {
    foreach ($openingCaptureResult in @($retailOpeningResult, $openingResult)) {
        if ($null -ne $openingCaptureResult) {
            foreach ($artifact in @($openingCaptureResult.artifacts)) {
                if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
                    $artifactPaths.Add([string]$artifact.path)
                }
            }
        }
    }
}
if ($Scenario -eq "TestMap" -and $null -ne $testMapResult) {
    foreach ($artifact in @($testMapResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
}
if ($Scenario -eq "PipBoy" -and $null -ne $pipBoyResult) {
    foreach ($artifact in @($pipBoyResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
}
if ($Scenario -eq "Terminal" -and $null -ne $terminalResult) {
    foreach ($artifact in @($terminalResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
}
if ($Scenario -eq "RealSave" -and $null -ne $realSaveResult) {
    foreach ($artifact in @($realSaveResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
}
if ($Scenario -in @("GodotRoute", "GodotCinematics", "GodotPortraits") -and $null -ne $godotRouteResult) {
    foreach ($artifact in @($godotRouteResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
}
foreach ($artifact in $artifactPaths) {
    if (-not [string]::IsNullOrWhiteSpace([string]$artifact) -and
        (Test-Path -LiteralPath $artifact -PathType Leaf)) {
        $file = Get-Item -LiteralPath $artifact
        $artifacts.Add([pscustomobject][ordered]@{
            path = $file.FullName
            bytes = $file.Length
            sha256 =
                (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).
                Hash.ToLowerInvariant()
        })
    }
}

$summary = [ordered]@{
    schema = "nikami-fnv-jam-background-capture-run/v1"
    status = "pass"
    target = $Target
    scenario = $Scenario
    recipeCatalog =
        (Join-Path $WorldsRoot "catalog\fnv-jam-background-capture-recipes.json")
    startedAt = $startedAt.ToString("o")
    completedAt = (Get-Date).ToString("o")
    policy = [ordered]@{
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        capturesRanSequentially = $true
        outputOverwritten = $false
    }
    retail = $retailResult
    openMw = $openMwResult
    retailOpening = $retailOpeningResult
    opening = $openingResult
    testMapDiagnostic = $testMapResult
    pipBoyShowcase = $pipBoyResult
    terminalCapture = $terminalResult
    realSave = $realSaveResult
    godotRoute = $godotRouteResult
    artifacts = @($artifacts)
}
$summaryPath = Join-Path $OutputRoot "background-capture-summary.json"
[IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 12),
    [Text.UTF8Encoding]::new($false))
$summary | ConvertTo-Json -Depth 12
