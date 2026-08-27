[CmdletBinding()]
param(
    [ValidateSet("Retail", "OpenMW", "Both", "Godot")]
    [string]$Target = "Both",
    [ValidateSet("Jam", "FirstSmoke", "ChetObservation", "ChetPersistent", "ChetTransaction", "ChetPersistence", "Canyon", "Opening", "TestMap", "PipBoy", "PipBoyVR", "Terminal", "RealSave", "ActorObservation", "GodotActorReview", "GodotGallery", "GodotGalleryVideo", "GodotRoute", "GodotCinematics", "GodotPortraits")]
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
    [ValidateRange(10, 120)]
    [int]$FirstSmokeCaptureSeconds = 45,
    [ValidateRange(30, 180)]
    [int]$CanyonCaptureSeconds = 75,
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
    [ValidateRange(8, 30)]
    [int]$PipBoyVRFrameRate = 12,
    [switch]$PipBoyVRWeaponWheel,
    [ValidateRange(52, 90)]
    [int]$TerminalCaptureSeconds = 65,
    [switch]$PipBoyLifecycleOnly,
    [switch]$PipBoyApparelOnly,
    [switch]$PipBoyAidOnly,
    [switch]$PipBoyAmmoOnly,
    [switch]$PipBoyMiscOnly,
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
    [string]$OpeningAudioDevice = "",
    [string]$ActorPlanRoot = "",
    [string]$ActorCorpusRoot = "",
    [string]$ActorCaptureJobKey = "",
    [string]$ActorOracleSeedRoot = "",
    [string]$ActorOraclePluginDll = "",
    [string]$ActorSaveFixture = "",
    [string]$ActorGalleryShot = "",
    [string]$ActorGameRoot = "D:\SteamLibrary\steamapps\common\Fallout New Vegas",
    [switch]$ActorDrawContractDiagnostic,
    [string]$OpenNvRoot = "",
    [string]$ActorReviewScene = "",
    [string]$ActorReviewBackgroundCell = "",
    [string]$GalleryCellScene = "",
    [string]$GalleryActorScene = "",
    [string]$GalleryShot = "",
    [string]$GalleryManifest = "",
    [string]$GodotBinary = "",
    # Opening captures may target an isolated runtime built under local/labs.
    # Leave empty to preserve the release runtime default used by existing
    # recipes and launcher invocations.
    [string]$OpeningRuntimeRoot = "",
    [int]$TimeoutSeconds = 240,
    [string]$WorldsRoot = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($WorldsRoot)) {
    $WorldsRoot = Split-Path -Parent $PSScriptRoot
}
$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")
$preflight = Join-Path $PSScriptRoot "Test-FNVJamBackgroundCapture.ps1"
$retailRunner = Join-Path $PSScriptRoot "Invoke-FNVJamFullRetailRehearsal.ps1"
$openMwRunner = Join-Path $PSScriptRoot "Invoke-FNVJamSprintProof.ps1"
$firstSmokeRunner = Join-Path $PSScriptRoot "Invoke-OpenNVFirstSmokeCapture.ps1"
$canyonRunner = Join-Path $PSScriptRoot "Invoke-OpenNVCanyonCrawlCapture.ps1"
$retailOpeningRunner = Join-Path $PSScriptRoot "Invoke-RetailTTWOpeningCapture.ps1"
$openingRunner = Join-Path $PSScriptRoot "Invoke-OpenNVOpeningCapture.ps1"
$testMapRunner = Join-Path $PSScriptRoot "Invoke-OpenNVTestMapDiagnostic.ps1"
$pipBoyRunner = Join-Path $PSScriptRoot "Invoke-OpenNVPipBoyShowcaseCapture.ps1"
$pipBoyVrRunner = Join-Path $PSScriptRoot "Invoke-OpenNVPipBoyVRCapture.ps1"
$terminalRunner = Join-Path $PSScriptRoot "Invoke-OpenNVTerminalCapture.ps1"
$retailPipBoyRunner = Join-Path $PSScriptRoot "Invoke-FNVRetailPipBoyStateCapture.ps1"
$realSaveRunner = Join-Path $PSScriptRoot "Invoke-FNVRealSaveCapture.ps1"
$godotRouteRunner = Join-Path $PSScriptRoot "Invoke-OpenNVGodotShowcaseCapture.ps1"
$godotCinematicRunner = Join-Path $PSScriptRoot "Invoke-OpenNVCinematicReelCapture.ps1"
$godotPortraitRunner = Join-Path $PSScriptRoot "Invoke-OpenNVFamousPeopleCapture.ps1"
$godotActorReviewRunner = Join-Path $PSScriptRoot "Invoke-OpenNVActorReviewCapture.ps1"
$godotGalleryRunner = Join-Path $PSScriptRoot "Invoke-OpenNVGalleryCapture.ps1"
$godotGalleryVideoRunner = Join-Path $PSScriptRoot "Invoke-OpenNVGalleryVideoCapture.ps1"
$actorObservationRunner = Join-Path $PSScriptRoot "Invoke-FNVActorObservationCapture.ps1"
$canonicalSave330Path = Join-Path $WorldsRoot "local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos"
if ([string]::IsNullOrWhiteSpace($SavePath)) {
    $SavePath = if ($Scenario -eq "RealSave") {
        $canonicalSave330Path
    }
    elseif ($Scenario -in @("FirstSmoke", "ChetObservation", "ChetPersistent", "ChetTransaction", "ChetPersistence")) {
        Join-Path $WorldsRoot "profiles\fallout_new_vegas\userdata\saves\ - 1\Autosave.omwsave"
    }
    else { "" }
}
if ($Target -ne "Godot" -and $Scenario -ne "ActorObservation" -and
    [string]::IsNullOrWhiteSpace($OpeningRuntimeRoot)) {
    $pipBoyRuntimeRoot = Join-Path $WorldsRoot "local\openmw-testmap-fnv-clean-20260801-080000"
    if ($Scenario -eq "PipBoy" -and (Test-Path -LiteralPath (Join-Path $pipBoyRuntimeRoot "openmw.exe") -PathType Leaf)) {
        $OpeningRuntimeRoot = $pipBoyRuntimeRoot
    }
    else {
        $OpeningRuntimeRoot = Resolve-NikamiOpenMWRuntimeRoot
    }
}
if ($Target -ne "Godot" -and $Scenario -ne "ActorObservation") {
    $OpeningRuntimeRoot = [IO.Path]::GetFullPath($OpeningRuntimeRoot)
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $outputPrefix = if ($Scenario -eq "RealSave") { "fnv-real-save-$($Target.ToLowerInvariant())" } elseif ($Scenario -eq "ActorObservation") { "fnv-actor-observation" } elseif ($Scenario -eq "GodotActorReview") { "opennv-godot-actor-review" } elseif ($Scenario -eq "GodotGallery") { "opennv-godot-gallery" } elseif ($Scenario -eq "GodotGalleryVideo") { "opennv-godot-gallery-video" } elseif ($Scenario -eq "GodotRoute") { "opennv-godot-route" } elseif ($Scenario -eq "GodotCinematics") { "opennv-godot-cinematics" } elseif ($Scenario -eq "GodotPortraits") { "opennv-godot-portraits" } else { "jam-background-$($Target.ToLowerInvariant())" }
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
if ($Scenario -in @("FirstSmoke", "ChetObservation", "ChetPersistent", "ChetTransaction", "ChetPersistence") -and $Target -ne "OpenMW") {
    throw "The FNV FirstSmoke and Chet persistent routes are OpenMW-only. Use -Target OpenMW."
}
if ($Scenario -eq "Canyon" -and $Target -ne "OpenMW") {
    throw "The Honest Hearts canyon crawl is OpenMW-only. Use -Target OpenMW."
}
if (($Scenario -in @("GodotActorReview", "GodotGallery", "GodotGalleryVideo", "GodotRoute", "GodotCinematics", "GodotPortraits")) -ne ($Target -eq "Godot")) {
    throw "Godot scenarios are dedicated Godot lanes. Use -Target Godot."
}

if ($Scenario -eq "Terminal" -and $Target -ne "OpenMW") {
    throw "Terminal interaction is an OpenMW-only capture route. Use -Target OpenMW."
}
if ($Scenario -eq "PipBoy" -and $Target -eq "Both") {
    throw "Pip-Boy state captures are intentionally single-engine. Run Retail first, then OpenMW."
}
if ($Scenario -eq "PipBoyVR" -and $Target -ne "OpenMW") {
    throw "PipBoyVR is an OpenMW-only native OpenXR capture. Use -Target OpenMW."
}
if ($Scenario -eq "RealSave" -and $Target -eq "Both") {
    throw "RealSave captures are intentionally single-engine. Run Retail first, then OpenMW."
}
if ($Scenario -eq "ActorObservation" -and $Target -ne "Retail") {
    throw "ActorObservation is a sequential retail-only lane. Use -Target Retail."
}
if ($ActorDrawContractDiagnostic -and $Scenario -ne "ActorObservation") {
    throw "ActorDrawContractDiagnostic is restricted to the retail ActorObservation lane."
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
    -ActorPlanRoot $ActorPlanRoot `
    -ActorCorpusRoot $ActorCorpusRoot `
    -ActorCaptureJobKey $ActorCaptureJobKey `
    -ActorOracleSeedRoot $ActorOracleSeedRoot `
    -ActorOraclePluginDll $ActorOraclePluginDll `
    -ActorSaveFixture $ActorSaveFixture `
    -ActorGalleryShot $ActorGalleryShot `
    -ActorGameRoot $ActorGameRoot `
    -OpenNvRoot $OpenNvRoot `
    -ActorReviewScene $ActorReviewScene `
    -ActorReviewBackgroundCell $ActorReviewBackgroundCell `
    -GalleryCellScene $GalleryCellScene `
    -GalleryActorScene $GalleryActorScene `
    -GalleryShot $GalleryShot `
    -GalleryManifest $GalleryManifest `
    -GodotBinary $GodotBinary `
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
$pipBoyVrResult = $null
$terminalResult = $null
$realSaveResult = $null
$godotRouteResult = $null
$firstSmokeResult = $null
$chetObservationResult = $null
$chetPersistentResult = $null
$canyonResult = $null
$actorObservationResult = $null
$actorReviewResult = $null
$galleryResult = $null
$galleryVideoResult = $null

if ($Scenario -eq "ActorObservation") {
    $actorCatalogPath = Join-Path $WorldsRoot "catalog\fnv-jam-background-capture-recipes.json"
    $actorCatalog = Get-Content -Raw -LiteralPath $actorCatalogPath | ConvertFrom-Json
    $actorRecipes = @($actorCatalog.actorObservationRecipes | Where-Object {
        [string]$_.id -eq 'fnv-official-actor-retail-observation-v1'
    })
    if ($actorRecipes.Count -ne 1 -or
        @($actorRecipes[0].acceptedObservationStatuses).Count -lt 1) {
        throw 'Canonical actor-observation statuses are missing from the recipe catalog.'
    }
    $acceptedActorObservationStatuses = @($actorRecipes[0].acceptedObservationStatuses)
    $actorOutput = Join-Path $OutputRoot "actor-observation"
    $actorObservationResult = & $actorObservationRunner `
        -WorldsRoot $WorldsRoot `
        -PlanRoot $ActorPlanRoot `
        -CorpusRoot $ActorCorpusRoot `
        -CaptureJobKey $ActorCaptureJobKey `
        -OutputRoot $actorOutput `
        -OracleSeedRoot $ActorOracleSeedRoot `
        -OraclePluginDll $ActorOraclePluginDll `
        -SaveFixture $ActorSaveFixture `
        -GalleryShotPath $ActorGalleryShot `
        -OpenNvRoot $OpenNvRoot `
        -GameRoot $ActorGameRoot `
        -ActorDrawContractDiagnostic:$ActorDrawContractDiagnostic `
        -TimeoutSeconds $TimeoutSeconds
    if ([string]$actorObservationResult.status -cnotin $acceptedActorObservationStatuses -or
        [bool]$actorObservationResult.capture.windowsAppControlUsed -or
        [bool]$actorObservationResult.capture.foregroundActivationUsed -or
        [bool]$actorObservationResult.capture.foregroundInputInjected) {
        throw "Canonical retail actor observation did not pass its identity, native-evidence, or no-control gates."
    }
}

if ($Scenario -eq "GodotActorReview") {
    $actorReviewOutput = Join-Path $OutputRoot 'godot'
    & $godotActorReviewRunner `
        -OpenNvRoot $OpenNvRoot `
        -ActorReviewScene $ActorReviewScene `
        -ActorReviewBackgroundCell $ActorReviewBackgroundCell `
        -OutputRoot $actorReviewOutput `
        -Godot $GodotBinary `
        -TimeoutSeconds $TimeoutSeconds
    $actorReviewResult = Get-Content -Raw -LiteralPath `
        (Join-Path $actorReviewOutput 'opennv-actor-review-report.json') |
        ConvertFrom-Json
    if ([string]$actorReviewResult.status -cne 'captured-pending-parity' -or
        [bool]$actorReviewResult.engine.parityPassed -or
        [bool]$actorReviewResult.capture.windowsAppControlUsed -or
        [bool]$actorReviewResult.capture.foregroundActivationUsed -or
        [bool]$actorReviewResult.capture.foregroundInputInjected) {
        throw 'Canonical Godot actor review failed its capture, pending-parity, or no-control gate.'
    }
}

if ($Scenario -eq "GodotGallery") {
    $galleryOutput = Join-Path $OutputRoot 'godot'
    & $godotGalleryRunner `
        -OpenNvRoot $OpenNvRoot `
        -CellScene $GalleryCellScene `
        -ActorScene $GalleryActorScene `
        -GalleryShot $GalleryShot `
        -OutputRoot $galleryOutput `
        -Godot $GodotBinary `
        -TimeoutSeconds $TimeoutSeconds
    $galleryResult = Get-Content -Raw -LiteralPath `
        (Join-Path $galleryOutput 'opennv-gallery-capture-report.json') |
        ConvertFrom-Json
    if ([string]$galleryResult.status -cne
            'captured-gallery-retail-bound-pending-parity' -or
        [bool]$galleryResult.engine.parity -or
        [bool]$galleryResult.engine.parityClaimed -or
        [bool]$galleryResult.capture.retailCaptureUsed -or
        -not [bool]$galleryResult.capture.retailEvidenceUsed -or
        [bool]$galleryResult.capture.windowsAppControlUsed -or
        [bool]$galleryResult.capture.foregroundActivationUsed -or
        [bool]$galleryResult.capture.foregroundInputInjected) {
        throw 'Canonical Godot gallery shot failed its authored, non-parity, or no-control gate.'
    }
}

if ($Scenario -eq "GodotGalleryVideo") {
    $galleryVideoOutput = Join-Path $OutputRoot 'godot'
    & $godotGalleryVideoRunner `
        -OpenNvRoot $OpenNvRoot `
        -GalleryManifest $GalleryManifest `
        -OutputRoot $galleryVideoOutput `
        -Godot $GodotBinary `
        -TimeoutSeconds $TimeoutSeconds | Out-Null
    $runtimeConfigurationPath = Join-Path `
        ([IO.Path]::GetFullPath($OpenNvRoot)) `
        'runtime\config\open-nv-runtime-v1.json'
    $runtimeConfiguration =
        Get-Content -Raw -LiteralPath $runtimeConfigurationPath | ConvertFrom-Json
    $galleryVideoReportPath = Join-Path $galleryVideoOutput `
        ([string]$runtimeConfiguration.capture.gallery.video.reportFileName)
    $galleryVideoResult = Get-Content -Raw -LiteralPath $galleryVideoReportPath |
        ConvertFrom-Json
    if ([string]$galleryVideoResult.status -cne
            'captured-gallery-video-retail-bound-pending-parity' -or
        -not [bool]$galleryVideoResult.gallery.allAuthoredMotionPassed -or
        [bool]$galleryVideoResult.capture.retailCaptureUsed -or
        -not [bool]$galleryVideoResult.capture.retailEvidenceUsed -or
        [bool]$galleryVideoResult.capture.windowsAppControlUsed -or
        [bool]$galleryVideoResult.capture.foregroundActivationUsed -or
        [bool]$galleryVideoResult.capture.foregroundInputInjected -or
        [bool]$galleryVideoResult.capture.parityClaimed) {
        throw 'Canonical Godot gallery video failed its authored-motion, non-parity, or no-control gate.'
    }
}

if ($Scenario -eq "FirstSmoke") {
    $firstSmokeOutput = Join-Path $OutputRoot "openmw"
    & $firstSmokeRunner `
        -WorldsRoot $WorldsRoot `
        -BinaryRoot $OpeningRuntimeRoot `
        -SavePath $SavePath `
        -OutputRoot $firstSmokeOutput `
        -CaptureSeconds $FirstSmokeCaptureSeconds `
        -TimeoutSeconds $TimeoutSeconds
    $firstSmokeResult = Get-Content -Raw -LiteralPath (Join-Path $firstSmokeOutput "first-smoke-report.json") |
        ConvertFrom-Json
    if ($firstSmokeResult.status -ne "pass" -or
        -not [bool]$firstSmokeResult.capture.selfDriven -or
        [bool]$firstSmokeResult.capture.windowsAppControlUsed -or
        [bool]$firstSmokeResult.capture.foregroundActivationUsed -or
        [bool]$firstSmokeResult.capture.foregroundInputInjected -or
        [bool]$firstSmokeResult.capture.proofStateMutationUsed -or
        [bool]$firstSmokeResult.capture.cameraDrivingUsed -or
        -not [bool]$firstSmokeResult.assertions.exteriorMovement -or
        -not [bool]$firstSmokeResult.assertions.authoredDoorTransition -or
        -not [bool]$firstSmokeResult.assertions.unlockedContainerOpened) {
        throw "Canonical OpenMW FirstSmoke did not pass movement, door, container, native-evidence, or no-control gates."
    }
    $openMwResult = $firstSmokeResult
}

if ($Scenario -eq "ChetObservation") {
    $chetObservationOutput = Join-Path $OutputRoot "openmw"
    & $firstSmokeRunner `
        -Route ChetObservation `
        -WorldsRoot $WorldsRoot `
        -BinaryRoot $OpeningRuntimeRoot `
        -SavePath $SavePath `
        -OutputRoot $chetObservationOutput `
        -CaptureSeconds $FirstSmokeCaptureSeconds `
        -TimeoutSeconds $TimeoutSeconds
    $chetObservationResult = Get-Content -Raw -LiteralPath (Join-Path $chetObservationOutput "r2-chet-observation-report.json") |
        ConvertFrom-Json
    if ($chetObservationResult.status -ne "pass" -or
        -not [bool]$chetObservationResult.capture.selfDriven -or
        [bool]$chetObservationResult.capture.windowsAppControlUsed -or
        [bool]$chetObservationResult.capture.foregroundActivationUsed -or
        [bool]$chetObservationResult.capture.foregroundInputInjected -or
        [bool]$chetObservationResult.capture.proofStateMutationUsed -or
        [bool]$chetObservationResult.capture.cameraDrivingUsed -or
        -not [bool]$chetObservationResult.assertions.authoredDoorTransition -or
        -not [bool]$chetObservationResult.assertions.chetDialogueOpened -or
        -not [bool]$chetObservationResult.assertions.authoredBarterOpened) {
        throw "Canonical OpenMW ChetObservation did not pass the authored door, dialogue, barter, native-evidence, or no-control gates."
    }
    $openMwResult = $chetObservationResult
}

if ($Scenario -eq "ChetPersistent") {
    $chetPersistentOutput = Join-Path $OutputRoot "openmw"
    & $firstSmokeRunner `
        -Route ChetPersistent `
        -WorldsRoot $WorldsRoot `
        -BinaryRoot $OpeningRuntimeRoot `
        -SavePath $SavePath `
        -OutputRoot $chetPersistentOutput `
        -CaptureSeconds $FirstSmokeCaptureSeconds `
        -TimeoutSeconds $TimeoutSeconds
    $chetPersistentResult = Get-Content -Raw -LiteralPath (Join-Path $chetPersistentOutput "r2-goodsprings-persistent-report.json") |
        ConvertFrom-Json
    if ($chetPersistentResult.status -ne "pass" -or
        -not [bool]$chetPersistentResult.capture.selfDriven -or
        [bool]$chetPersistentResult.capture.windowsAppControlUsed -or
        [bool]$chetPersistentResult.capture.foregroundActivationUsed -or
        [bool]$chetPersistentResult.capture.foregroundInputInjected -or
        [bool]$chetPersistentResult.capture.proofStateMutationUsed -or
        [bool]$chetPersistentResult.capture.cameraDrivingUsed -or
        -not [bool]$chetPersistentResult.assertions.authoredDoorTransition -or
        -not [bool]$chetPersistentResult.assertions.ordinaryContainerTransfer -or
        -not [bool]$chetPersistentResult.assertions.chetDialogueOpened -or
        -not [bool]$chetPersistentResult.assertions.authoredBarterOpened -or
        -not [bool]$chetPersistentResult.assertions.authoredBarterCancellationNoDelta) {
        throw "Canonical OpenMW ChetPersistent did not pass the container, barter-cancel, native-evidence, or no-control gates."
    }
    $openMwResult = $chetPersistentResult
}

if ($Scenario -eq "ChetTransaction") {
    $chetTransactionOutput = Join-Path $OutputRoot "openmw"
    & $firstSmokeRunner `
        -Route ChetTransaction `
        -WorldsRoot $WorldsRoot `
        -BinaryRoot $OpeningRuntimeRoot `
        -SavePath $SavePath `
        -OutputRoot $chetTransactionOutput `
        -CaptureSeconds $FirstSmokeCaptureSeconds `
        -TimeoutSeconds $TimeoutSeconds
    $chetTransactionResult = Get-Content -Raw -LiteralPath (Join-Path $chetTransactionOutput "r2-goodsprings-transaction-report.json") |
        ConvertFrom-Json
    if ($chetTransactionResult.status -ne "pass" -or
        -not [bool]$chetTransactionResult.capture.selfDriven -or
        [bool]$chetTransactionResult.capture.windowsAppControlUsed -or
        [bool]$chetTransactionResult.capture.foregroundActivationUsed -or
        [bool]$chetTransactionResult.capture.foregroundInputInjected -or
        [bool]$chetTransactionResult.capture.proofStateMutationUsed -or
        [bool]$chetTransactionResult.capture.cameraDrivingUsed -or
        -not [bool]$chetTransactionResult.assertions.authoredDoorTransition -or
        -not [bool]$chetTransactionResult.assertions.ordinaryContainerTransfer -or
        -not [bool]$chetTransactionResult.assertions.chetDialogueOpened -or
        -not [bool]$chetTransactionResult.assertions.authoredBarterOpened -or
        -not [bool]$chetTransactionResult.assertions.authoredMerchantTransaction) {
        throw "Canonical OpenMW ChetTransaction did not pass the container, merchant-transaction, native-evidence, or no-control gates."
    }
    $openMwResult = $chetTransactionResult
}

if ($Scenario -eq "ChetPersistence") {
    $persistenceOutput = Join-Path $OutputRoot "openmw"
    $saveOutput = Join-Path $persistenceOutput "save"
    & $firstSmokeRunner `
        -Route ChetPersistenceSave `
        -WorldsRoot $WorldsRoot `
        -BinaryRoot $OpeningRuntimeRoot `
        -SavePath $SavePath `
        -OutputRoot $saveOutput `
        -CaptureSeconds $FirstSmokeCaptureSeconds `
        -TimeoutSeconds $TimeoutSeconds
    $saveResult = Get-Content -Raw -LiteralPath (Join-Path $saveOutput "r2-goodsprings-persistence-save-report.json") |
        ConvertFrom-Json
    if ($saveResult.status -ne "pass" -or -not [bool]$saveResult.assertions.nativeProductionSave -or
        [string]::IsNullOrWhiteSpace([string]$saveResult.source.generatedSavePath)) {
        throw "Canonical OpenMW ChetPersistence save phase did not retain a production save."
    }
    $saveLog = Get-Content -Raw -LiteralPath $saveResult.telemetry.log
    $stateMatch = [regex]::Match($saveLog,
        'FNV R2 persistence save: state=before-write transferItem=(?<transferItem>FormId:0x[0-9a-fA-F]+) transferPlayer=(?<transferPlayer>\d+) transferContainer=(?<transferContainer>\d+) purchaseItem=(?<purchaseItem>FormId:0x[0-9a-fA-F]+) purchasePlayer=(?<purchasePlayer>\d+) purchaseMerchant=(?<purchaseMerchant>\d+) playerCaps=(?<playerCaps>\d+) merchantCaps=(?<merchantCaps>\d+)')
    if (-not $stateMatch.Success) {
        throw "ChetPersistence save phase omitted its exact post-transaction state telemetry."
    }
    $reloadOutput = Join-Path $persistenceOutput "reload"
    & $firstSmokeRunner `
        -Route ChetPersistenceReload `
        -WorldsRoot $WorldsRoot `
        -BinaryRoot $OpeningRuntimeRoot `
        -SavePath ([string]$saveResult.source.generatedSavePath) `
        -OutputRoot $reloadOutput `
        -CaptureSeconds $FirstSmokeCaptureSeconds `
        -TimeoutSeconds $TimeoutSeconds `
        -ReloadTransferItem $stateMatch.Groups['transferItem'].Value `
        -ReloadTransferPlayerCount ([int]$stateMatch.Groups['transferPlayer'].Value) `
        -ReloadTransferContainerCount ([int]$stateMatch.Groups['transferContainer'].Value) `
        -ReloadPurchaseItem $stateMatch.Groups['purchaseItem'].Value `
        -ReloadPurchasePlayerCount ([int]$stateMatch.Groups['purchasePlayer'].Value) `
        -ReloadPurchaseMerchantCount ([int]$stateMatch.Groups['purchaseMerchant'].Value) `
        -ReloadPlayerCaps ([int]$stateMatch.Groups['playerCaps'].Value) `
        -ReloadMerchantCaps ([int]$stateMatch.Groups['merchantCaps'].Value)
    $reloadResult = Get-Content -Raw -LiteralPath (Join-Path $reloadOutput "r2-goodsprings-persistence-reload-report.json") |
        ConvertFrom-Json
    if ($reloadResult.status -ne "pass" -or -not [bool]$reloadResult.assertions.coldReloadStateRetained -or
        -not [bool]$reloadResult.assertions.ordinaryReloadContainerOpened) {
        throw "Canonical OpenMW ChetPersistence cold reload did not retain state and open an ordinary container."
    }
    $persistenceArtifacts = @($saveResult.artifacts) + @($reloadResult.artifacts)
    $chetPersistenceResult = [pscustomobject][ordered]@{
        schema = "nikami-openmw-fnv-r2-goodsprings-persistence/v1"
        status = "pass"
        source = [ordered]@{ saveFixture = $SavePath; generatedSavePath = $saveResult.source.generatedSavePath }
        capture = [ordered]@{ selfDriven = $true; windowsAppControlUsed = $false; foregroundActivationUsed = $false; foregroundInputInjected = $false; proofStateMutationUsed = $false; cameraDrivingUsed = $false; capturesRanSequentially = $true }
        assertions = [ordered]@{ nativeProductionSave = $true; cleanExitAfterSave = [int]$saveResult.launch.exitCode -eq 0; coldReloadStateRetained = $true; ordinaryReloadContainerOpened = $true }
        telemetry = [ordered]@{ savedState = $stateMatch.Value; saveLog = $saveResult.telemetry.log; reloadLog = $reloadResult.telemetry.log }
        artifacts = $persistenceArtifacts
    }
    [IO.File]::WriteAllText((Join-Path $persistenceOutput "r2-goodsprings-persistence-report.json"),
        ($chetPersistenceResult | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $openMwResult = $chetPersistenceResult
}

if ($Scenario -eq "Canyon") {
    $canyonOutput = Join-Path $OutputRoot "openmw"
    & $canyonRunner `
        -WorldsRoot $WorldsRoot `
        -BinaryRoot $OpeningRuntimeRoot `
        -OutputRoot $canyonOutput `
        -CaptureSeconds $CanyonCaptureSeconds `
        -TimeoutSeconds $TimeoutSeconds
    $canyonResult = Get-Content -Raw -LiteralPath (Join-Path $canyonOutput "canyon-crawl-report.json") |
        ConvertFrom-Json
    if ($canyonResult.status -ne "pass" -or
        -not [bool]$canyonResult.capture.selfDriven -or
        [bool]$canyonResult.capture.windowsAppControlUsed -or
        [bool]$canyonResult.capture.foregroundActivationUsed -or
        [bool]$canyonResult.capture.foregroundInputInjected -or
        [bool]$canyonResult.capture.proofStateMutationUsed -or
        [bool]$canyonResult.capture.forcedActorsUsed -or
        [bool]$canyonResult.capture.forcedWeatherUsed -or
        [bool]$canyonResult.capture.cameraDrivingUsed -or
        -not [bool]$canyonResult.assertions.zionWorldspaceObserved -or
        -not [bool]$canyonResult.assertions.authoredNpcResolved -or
        -not [bool]$canyonResult.assertions.slowMovementPassed) {
        throw "Canonical OpenMW canyon crawl did not pass its Zion, NPC, movement, native-evidence, or no-control gates."
    }
    $openMwResult = $canyonResult
}

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
            # The final firearm frame must be taken after the authored reload
            # returns to its steady weapon pose, not during its contact frame.
            $pipBoyArgs.FramesPerPane = 210
            $pipBoyArgs.CaptureDelayFrames = 195
        }
        if ($PipBoyApparelOnly) {
            $pipBoyArgs.ApparelOnly = $true
        }
        if ($PipBoyAidOnly) {
            $pipBoyArgs.AidOnly = $true
        }
        if ($PipBoyAmmoOnly) {
            $pipBoyArgs.AmmoOnly = $true
        }
        if ($PipBoyMiscOnly) {
            $pipBoyArgs.MiscOnly = $true
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

if ($Scenario -eq "PipBoyVR") {
    $pipBoyVrOutput = Join-Path $OutputRoot "openmw"
    & $pipBoyVrRunner `
        -WorldsRoot $WorldsRoot `
        -BinaryRoot $OpeningRuntimeRoot `
        -OutputRoot $pipBoyVrOutput `
        -FrameRate $PipBoyVRFrameRate `
        -WeaponWheel:$PipBoyVRWeaponWheel `
        -TimeoutSeconds $TimeoutSeconds
    $pipBoyVrResult =
        Get-Content -Raw -LiteralPath (Join-Path $pipBoyVrOutput "vr-pipboy-interaction-report.json") |
        ConvertFrom-Json
    $requiredInteractionPassed = if ($PipBoyVRWeaponWheel) {
        [bool]$pipBoyVrResult.assertions.weaponWheelCentered -and
        [bool]$pipBoyVrResult.assertions.knifeSelectedByWheel -and
        [bool]$pipBoyVrResult.assertions.rifleSelectedByWheel -and
        [bool]$pipBoyVrResult.assertions.pistolSelectedByWheel -and
        [bool]$pipBoyVrResult.assertions.weaponAimFixturesPassed -and
        [bool]$pipBoyVrResult.assertions.weaponGripFixturesPassed
    } else {
        [bool]$pipBoyVrResult.assertions.livePipBoyScreenBound -and
        [bool]$pipBoyVrResult.assertions.knifeSelectedByPointer -and
        [bool]$pipBoyVrResult.assertions.rifleSelectedByPointer -and
        [bool]$pipBoyVrResult.assertions.pistolSelectedByPointer
    }
    $nativeWeaponPassed =
        [bool]$pipBoyVrResult.assertions.nativeAttachmentRigidPassed -and
        [bool]$pipBoyVrResult.assertions.weaponTexturesPassed -and
        [bool]$pipBoyVrResult.assertions.weaponVisibilityPassed -and
        [bool]$pipBoyVrResult.assertions.actualProjectileRayPassed -and
        [bool]$pipBoyVrResult.assertions.nativeWeaponDebugAxesPassed
    if ($pipBoyVrResult.status -ne "pass" -or
        [bool]$pipBoyVrResult.capture.windowsAppControlUsed -or
        [bool]$pipBoyVrResult.capture.foregroundActivationUsed -or
        [bool]$pipBoyVrResult.capture.foregroundInputInjected -or
        -not [bool]$pipBoyVrResult.capture.sourceFramesRetained -or
        -not [bool]$pipBoyVrResult.capture.telemetryRetained -or
        -not $requiredInteractionPassed -or
        -not $nativeWeaponPassed -or
        -not [bool]$pipBoyVrResult.assertions.knifeMeleePassed -or
        -not [bool]$pipBoyVrResult.assertions.rifleShotPassed -or
        -not [bool]$pipBoyVrResult.assertions.pistolShotPassed) {
        throw "Canonical OpenMW VR Pip-Boy interaction capture did not pass its native-frame, pointer, weapon-action, or no-control gates."
    }
    $openMwResult = $pipBoyVrResult
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
if ($Scenario -eq "PipBoyVR" -and $null -ne $pipBoyVrResult) {
    foreach ($artifact in @($pipBoyVrResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
}
if ($Scenario -eq "FirstSmoke" -and $null -ne $firstSmokeResult) {
    foreach ($artifact in @($firstSmokeResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
}
if ($Scenario -eq "ChetObservation" -and $null -ne $chetObservationResult) {
    foreach ($artifact in @($chetObservationResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
}
if ($Scenario -eq "ChetPersistent" -and $null -ne $chetPersistentResult) {
    foreach ($artifact in @($chetPersistentResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
}
if ($Scenario -eq "ChetTransaction" -and $null -ne $chetTransactionResult) {
    foreach ($artifact in @($chetTransactionResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
}
if ($Scenario -eq "ChetPersistence" -and $null -ne $chetPersistenceResult) {
    foreach ($artifact in @($chetPersistenceResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
    $artifactPaths.Add((Join-Path $OutputRoot "openmw\r2-goodsprings-persistence-report.json"))
}
if ($Scenario -eq "Canyon" -and $null -ne $canyonResult) {
    foreach ($artifact in @($canyonResult.artifacts)) {
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
if ($Scenario -eq "ActorObservation" -and $null -ne $actorObservationResult) {
    foreach ($artifact in @($actorObservationResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
}
if ($Scenario -eq "GodotActorReview" -and $null -ne $actorReviewResult) {
    foreach ($artifact in @($actorReviewResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
}
if ($Scenario -eq "GodotGallery" -and $null -ne $galleryResult) {
    foreach ($artifact in @($galleryResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
}
if ($Scenario -eq "GodotGalleryVideo" -and $null -ne $galleryVideoResult) {
    if (-not [string]::IsNullOrWhiteSpace([string]$galleryVideoReportPath)) {
        $artifactPaths.Add([string]$galleryVideoReportPath)
    }
    foreach ($artifact in @($galleryVideoResult.artifacts)) {
        if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
            $artifactPaths.Add([string]$artifact.path)
        }
    }
    foreach ($segment in @($galleryVideoResult.segments)) {
        foreach ($artifact in @($segment.sourceCaptureReport, $segment.sourceMovie,
                $segment.segment)) {
            if ($null -ne $artifact -and
                -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
                $artifactPaths.Add([string]$artifact.path)
            }
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
    status = if ($Scenario -eq 'GodotActorReview') {
        'captured-pending-parity'
    } elseif ($Scenario -eq 'GodotGallery') {
        'captured-gallery-retail-bound-pending-parity'
    } elseif ($Scenario -eq 'GodotGalleryVideo') {
        'captured-gallery-video-non-parity'
    } else {
        'pass'
    }
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
    pipBoyVR = $pipBoyVrResult
    terminalCapture = $terminalResult
    realSave = $realSaveResult
    firstSmoke = $firstSmokeResult
    chetPersistent = $chetPersistentResult
    canyonCrawl = $canyonResult
    godotRoute = $godotRouteResult
    actorObservation = $actorObservationResult
    actorReview = $actorReviewResult
    gallery = $galleryResult
    galleryVideo = $galleryVideoResult
    artifacts = @($artifacts)
}
$summaryPath = Join-Path $OutputRoot "background-capture-summary.json"
[IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 12),
    [Text.UTF8Encoding]::new($false))
$summary | ConvertTo-Json -Depth 12
