[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OpenNvRoot,
    [Parameter(Mandatory)]
    [string]$CellScene,
    [Parameter(Mandatory)]
    [string]$ActorScene,
    [Parameter(Mandatory)]
    [string]$GalleryShot,
    [Parameter(Mandatory)]
    [string]$OutputRoot,
    [Parameter(Mandatory)]
    [string]$Godot,
    [switch]$CaptureMovie,
    [switch]$SkipBuild,
    [ValidateRange(30, 600)]
    [int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ENGINE_IDLE_POLL_MILLISECONDS = 250

function Wait-CaptureEngineIdle([int]$MaximumWaitSeconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($MaximumWaitSeconds)
    while ($true) {
        $active = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -match '^(Godot.*|openmw|FalloutNV|nvse_loader)$'
        })
        if ($active.Count -eq 0) { return }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Gallery capture timed out waiting for idle engines: $($active.ProcessName -join ', ')"
        }
        Start-Sleep -Milliseconds $ENGINE_IDLE_POLL_MILLISECONDS
    }
}

function Resolve-CapturePath([string]$Path) {
    return [IO.Path]::GetFullPath($Path)
}

function Get-FileEvidence([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject][ordered]@{
        path = $item.FullName
        bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Normalize-FormId([string]$Value) {
    $normalized = $Value.Trim().ToLowerInvariant()
    if ($normalized.StartsWith('0x')) { $normalized = $normalized.Substring(2) }
    if ($normalized -cnotmatch '^[0-9a-f]{1,8}$') {
        throw "Invalid Fallout FormID: $Value"
    }
    return $normalized.PadLeft(8, [char]'0')
}

function Test-ExactStringSequence([object[]]$Actual, [object[]]$Expected) {
    $actualValues = @($Actual | ForEach-Object { [string]$_ })
    $expectedValues = @($Expected | ForEach-Object { [string]$_ })
    if ($actualValues.Count -ne $expectedValues.Count) { return $false }
    for ($index = 0; $index -lt $actualValues.Count; $index++) {
        if ($actualValues[$index] -cne $expectedValues[$index]) { return $false }
    }
    return $true
}

$openNvDirectory = Resolve-CapturePath $OpenNvRoot
$cellScenePath = Resolve-CapturePath $CellScene
$actorScenePath = Resolve-CapturePath $ActorScene
$galleryShotPath = Resolve-CapturePath $GalleryShot
$outputDirectory = Resolve-CapturePath $OutputRoot
$godotPath = Resolve-CapturePath $Godot
$runtimeDirectory = Join-Path $openNvDirectory 'runtime'
$projectPath = Join-Path $runtimeDirectory 'project.godot'
$projectFile = Join-Path $runtimeDirectory 'OpenNV.csproj'
$runtimeConfigurationPath = Join-Path $runtimeDirectory 'config\open-nv-runtime-v1.json'
foreach ($path in @($cellScenePath, $actorScenePath, $galleryShotPath, $godotPath,
        $projectPath, $projectFile, $runtimeConfigurationPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing OpenNV gallery input: $path"
    }
}
$runtimeConfiguration = Get-Content -Raw -LiteralPath $runtimeConfigurationPath | ConvertFrom-Json
$galleryPolicy = $runtimeConfiguration.capture.gallery
$videoPolicy = $galleryPolicy.video
$runtimeConfigurationSha256 =
    (Get-FileHash -LiteralPath $runtimeConfigurationPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (Test-Path -LiteralPath $outputDirectory) {
    throw "Refusing to overwrite OpenNV gallery capture: $outputDirectory"
}
Wait-CaptureEngineIdle $TimeoutSeconds

$cell = Get-Content -Raw -LiteralPath $cellScenePath | ConvertFrom-Json
if ([string]$cell.schema -cne 'opennv-cell-scene/v10' -or
    [string]$cell.status -cne 'geometry-structure' -or
    [string]$cell.cell.formId -cnotmatch '^[0-9a-f]{8}$') {
    throw 'CellScene is not current compiled OpenNV presentation data.'
}
$actor = Get-Content -Raw -LiteralPath $actorScenePath | ConvertFrom-Json
if ([string]$actor.schema -cne 'opennv-actor-scene/v5' -or
    [string]$actor.status -cne 'skinned-animated') {
    throw 'ActorScene is not a current compiled OpenNV animated actor.'
}
$shot = Get-Content -Raw -LiteralPath $galleryShotPath | ConvertFrom-Json
if ([string]$shot.schema -cne 'opennv-gallery-shot/v5' -or
    [string]$shot.status -cne 'owned-authored-placement' -or
    [string]$shot.locationClass -cnotin @('interior', 'exterior') -or
    [string]$shot.recordType -cnotin @('NPC_', 'CREA') -or
    [int]$shot.ordinal -lt 1) {
    throw 'GalleryShot is not a bounded authored-placement contract.'
}
$retailEvidencePath = Resolve-CapturePath ([string]$shot.retailEvidence.path)
if (-not (Test-Path -LiteralPath $retailEvidencePath -PathType Leaf)) {
    throw "Missing gallery retail evidence: $retailEvidencePath"
}
$retailEvidenceItem = Get-Item -LiteralPath $retailEvidencePath
$retailEvidenceSha256 =
    (Get-FileHash -LiteralPath $retailEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
$retailEvidence = Get-Content -Raw -LiteralPath $retailEvidencePath | ConvertFrom-Json
$retailPresentation = $retailEvidence.retail.presentation
$presentationPolicy = $galleryPolicy.retailPresentationSelection
$presentationSelection = $retailPresentation.selection
$policyCandidateShotKinds = @($presentationPolicy.candidateShotKinds |
    ForEach-Object { [string]$_ })
$evidenceCandidateShotKinds = @($presentationSelection.candidateShotKinds |
    ForEach-Object { [string]$_ })
$presentationFocusRules = @($presentationPolicy.semanticFocusFacingRules |
    Where-Object {
        [string]$_.focusKind -ceq [string]$presentationSelection.focusKind
    })
$presentationShotKind = [string]$retailPresentation.shotKind
$presentationSelectionValid =
    [string]$presentationPolicy.schema -ceq
        'opennv-gallery-presentation-selection/v1' -and
    [string]$presentationSelection.policySchema -ceq
        [string]$presentationPolicy.schema -and
    [string]$presentationSelection.tieBreak -ceq
        [string]$presentationPolicy.tieBreak -and
    (Test-ExactStringSequence $evidenceCandidateShotKinds $policyCandidateShotKinds) -and
    $presentationShotKind -cin $policyCandidateShotKinds -and
    $presentationFocusRules.Count -eq 1 -and
    $presentationShotKind -cin @($presentationFocusRules[0].allowedShotKinds) -and
    [double]$presentationSelection.cameraDirectionDotFocusForward -ge
        [double]$presentationFocusRules[0].minimumCameraDirectionDotFocusForward -and
    [double]$presentationSelection.cameraDirectionDotFocusForward -le
        [double]$presentationFocusRules[0].maximumCameraDirectionDotFocusForward -and
    [string]$presentationSelection.surfaceStatus -ceq
        [string]$presentationPolicy.requiredSurfaceStatus -and
    [bool]$presentationSelection.semanticFocusSurface -eq
        [bool]$presentationPolicy.requireSemanticFocusSurface -and
    [bool]$presentationSelection.cameraOutsideActorWorldBound -eq
        [bool]$presentationPolicy.requireCameraOutsideActorWorldBound -and
    [bool]$presentationSelection.cameraCorridorPassed -eq
        [bool]$presentationPolicy.requireClearCameraCorridor -and
    [double]$presentationSelection.cameraTranslationToleranceGameUnits -eq
        [double]$presentationPolicy.cameraTranslationToleranceGameUnits
$runtimeConfigurationItem = Get-Item -LiteralPath $runtimeConfigurationPath
if ([string]$retailEvidence.schema -cne 'opennv-gallery-retail-evidence/v2' -or
    [string]$retailEvidence.status -cne 'retail-authored-reference-observed' -or
    [long]$shot.retailEvidence.bytes -ne $retailEvidenceItem.Length -or
    [string]$shot.retailEvidence.sha256 -cne $retailEvidenceSha256 -or
    [string]$retailEvidence.shot.id -cne [string]$shot.id -or
    [int64]$retailEvidence.runtimeConfiguration.bytes -ne
        $runtimeConfigurationItem.Length -or
    [string]$retailEvidence.runtimeConfiguration.sha256 -cne
        $runtimeConfigurationSha256 -or
    -not $presentationSelectionValid -or
    [int]$retailPresentation.frame -lt 1 -or
    [string]$retailPresentation.sourceFrameCameraContractEventSha256 -cnotmatch
        '^[0-9a-f]{64}$' -or
    @($retailPresentation.camera.world.rotation).Count -ne 9 -or
    @($retailPresentation.camera.world.translation).Count -ne 3 -or
    @($retailPresentation.camera.frustum).Count -ne 7 -or
    @($retailPresentation.actor.rootWorld.rotation).Count -ne 9 -or
    @($retailPresentation.actor.rootWorld.translation).Count -ne 3 -or
    @($retailPresentation.actor.animationDataSequences).Count -lt 1 -or
    [bool]$retailEvidence.retail.actorTransformMutated -or
    [bool]$retailEvidence.evidencePolicy.windowsAppControlUsed -or
    [bool]$retailEvidence.evidencePolicy.foregroundActivationUsed -or
    [bool]$retailEvidence.evidencePolicy.foregroundInputInjected) {
    throw 'GalleryShot retail evidence is not immutable authored-reference telemetry.'
}
$outputFile = [string]$shot.outputFile
if ([IO.Path]::GetFileName($outputFile) -cne $outputFile -or
    [IO.Path]::GetExtension($outputFile) -cne [string]$galleryPolicy.stillImageExtension) {
    throw 'GalleryShot outputFile must use the configured still-image extension.'
}
$shotReference = Normalize-FormId ([string]$shot.referenceFormId)
$shotBase = Normalize-FormId ([string]$shot.baseFormId)
$shotActorCell = Normalize-FormId ([string]$shot.actor.cellFormId)
$shotSceneCell = Normalize-FormId ([string]$shot.scene.cellFormId)
$shotSceneInterior = [bool]$shot.scene.interior
$shotSceneWorldspace = if ($null -eq $shot.scene.worldspaceFormId) {
    $null
} else {
    Normalize-FormId ([string]$shot.scene.worldspaceFormId)
}
$actorReference = Normalize-FormId ([string]$actor.reference.formId)
$actorBase = Normalize-FormId ([string]$actor.reference.baseFormId)
$actorCell = Normalize-FormId ([string]$actor.cellFormId)
$actorRecordType = [string]$actor.actor.recordType
if ($shotReference -cne $actorReference -or $shotBase -cne $actorBase -or
    $shotActorCell -cne $actorCell -or
    [string]$shot.recordType -cne $actorRecordType) {
    throw 'GalleryShot does not identify the exact authored ActorScene placement.'
}
if ($shotSceneInterior -ne ([string]$shot.locationClass -ceq 'interior') -or
    ($shotSceneInterior -and $null -ne $shotSceneWorldspace) -or
    (-not $shotSceneInterior -and $null -eq $shotSceneWorldspace)) {
    throw 'GalleryShot rendered CELL/WRLD identity is inconsistent.'
}
$evidenceShotActorCell = Normalize-FormId `
    ([string]$retailEvidence.shot.actor.cellFormId)
$evidenceShotSceneCell = Normalize-FormId `
    ([string]$retailEvidence.shot.scene.cellFormId)
$evidenceShotSceneWorldspace = if (
    $null -eq $retailEvidence.shot.scene.worldspaceFormId) {
    $null
} else {
    Normalize-FormId ([string]$retailEvidence.shot.scene.worldspaceFormId)
}
$observerSceneCell = Normalize-FormId `
    ([string]$retailEvidence.retail.sceneObserver.cellFormId)
$observerSceneWorldspace = if (
    $null -eq $retailEvidence.retail.sceneObserver.worldspaceFormId) {
    $null
} else {
    Normalize-FormId ([string]$retailEvidence.retail.sceneObserver.worldspaceFormId)
}
if ([int]$retailEvidence.shot.ordinal -ne [int]$shot.ordinal -or
    [string]$retailEvidence.shot.label -cne [string]$shot.label -or
    [string]$retailEvidence.shot.locationId -cne [string]$shot.locationId -or
    [string]$retailEvidence.shot.location -cne [string]$shot.location -or
    [string]$retailEvidence.shot.locationClass -cne [string]$shot.locationClass -or
    (Normalize-FormId ([string]$retailEvidence.shot.referenceFormId)) -cne
        $shotReference -or
    (Normalize-FormId ([string]$retailEvidence.shot.baseFormId)) -cne $shotBase -or
    $evidenceShotActorCell -cne $shotActorCell -or
    $evidenceShotSceneCell -cne $shotSceneCell -or
    $evidenceShotSceneWorldspace -cne $shotSceneWorldspace -or
    [bool]$retailEvidence.shot.scene.interior -ne $shotSceneInterior -or
    [string]$retailEvidence.shot.recordType -cne [string]$shot.recordType -or
    [string]$retailEvidence.shot.enableState.mode -cne
        [string]$shot.enableState.mode -or
    [string]$retailEvidence.shot.outputFile -cne [string]$shot.outputFile -or
    $observerSceneCell -cne $shotSceneCell -or
    $observerSceneWorldspace -cne $shotSceneWorldspace -or
    [bool]$retailEvidence.retail.sceneObserver.interior -ne $shotSceneInterior) {
    throw 'GalleryShot and retail evidence do not identify one exact actor and scene.'
}
$enableStateMode = [string]$shot.enableState.mode
if ($enableStateMode -cnotin @('authored', 'proof-enable-initially-disabled')) {
    throw "GalleryShot has an invalid enable-state mode: $enableStateMode"
}
$proofEnableActor = $enableStateMode -ceq 'proof-enable-initially-disabled'
if ($proofEnableActor -ne [bool]$actor.reference.initiallyDisabled) {
    throw 'GalleryShot enable state differs from the authored ActorScene state.'
}
$loadedCellIds = @((Normalize-FormId ([string]$cell.cell.formId)))
if ($null -ne $cell.cell.PSObject.Properties['sourceCellFormIds']) {
    $loadedCellIds += @($cell.cell.sourceCellFormIds | ForEach-Object {
        Normalize-FormId ([string]$_)
    })
}
if ($shotSceneCell -cnotin $loadedCellIds) {
    throw "GalleryShot rendered CELL $shotSceneCell is not represented by CellScene."
}
if ([string]$cell.configuration.schema -cne 'opennv-runtime-configuration/v1' -or
    [string]$actor.configuration.schema -cne 'opennv-runtime-configuration/v1' -or
    [string]$cell.configuration.sha256 -cne [string]$actor.configuration.sha256 -or
    [string]$cell.configuration.sha256 -cne $runtimeConfigurationSha256) {
    throw 'CellScene and ActorScene do not share one current runtime configuration.'
}
$locationContract = $cell.galleryLocationContract
if ([string]$locationContract.schema -cne 'opennv-gallery-location-contract/v2' -or
    [string]$locationContract.runtimeConfigurationSha256 -cne
        $runtimeConfigurationSha256) {
    throw 'CellScene is not sealed by the current gallery location contract.'
}
$grassOverlaysProperty = @($cell.PSObject.Properties |
    Where-Object { [string]$_.Name -ceq 'grassOverlays' })
$grassOverlays = @(
    if ($grassOverlaysProperty.Count -eq 1) {
        $grassOverlaysProperty[0].Value
    }
)
if ([string]$shot.locationClass -ceq 'exterior') {
    $retailOraclePath = Resolve-CapturePath ([string]$retailEvidence.retail.oracleJsonl.path)
    if (-not (Test-Path -LiteralPath $retailOraclePath -PathType Leaf)) {
        throw "Missing gallery retail grass observation: $retailOraclePath"
    }
    $retailOracleHash =
        (Get-FileHash -LiteralPath $retailOraclePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$locationContract.subjectId -cne [string]$shot.id -or
        $grassOverlays.Count -lt 1 -or
        [string]$locationContract.retailGrassObservation.sha256 -cne
            $retailOracleHash -or
        [string]$cell.source.retailGrassObservation.sha256 -cne
            $retailOracleHash) {
        throw 'Exterior CellScene is not bound to this shot retail grass observation.'
    }
}
elseif ($null -ne $locationContract.subjectId -or
    $null -ne $locationContract.retailGrassObservation -or
    $grassOverlays.Count -ne 0) {
    throw 'Interior CellScene unexpectedly contains shot-bound exterior grass evidence.'
}

if (-not $SkipBuild) {
    dotnet build $projectFile --configuration Debug --nologo | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw 'OpenNV runtime build failed before gallery capture.'
    }
}

New-Item -ItemType Directory -Path $outputDirectory | Out-Null
$nativeRoot = Join-Path $outputDirectory 'native-source-frames'
$engineReport = Join-Path $outputDirectory 'gallery-engine-report.json'
$sessionSave = Join-Path $outputDirectory 'gallery-session-save.json'
$stdoutPath = Join-Path $outputDirectory 'godot.stdout.log'
$stderrPath = Join-Path $outputDirectory 'godot.stderr.log'
$godotLog = Join-Path $outputDirectory 'godot.log'
$sourceMovie = if ($CaptureMovie) {
    Join-Path $outputDirectory ('gallery-source' + [string]$videoPolicy.sourceContainerExtension)
} else { $null }
$startedAt = Get-Date
$process = $null
try {
    $arguments = @(
        '--xr-mode', 'off',
        '--path', $runtimeDirectory,
        '--log-file', $godotLog
    )
    if ($CaptureMovie) {
        $arguments += @(
            '--write-movie', $sourceMovie,
            '--fixed-fps', [string]$galleryPolicy.framesPerSecond
        )
    }
    $arguments += @(
        '--',
        '--cell-scene', $cellScenePath,
        '--actor-scene', $actorScenePath,
        '--gallery-shot', $galleryShotPath,
        '--save-path', $sessionSave,
        '--capture-root', $nativeRoot,
        '--report', $engineReport
    )
    if ($proofEnableActor) {
        $arguments += '--proof-enable-actor'
    }
    $process = Start-Process `
        -FilePath $godotPath `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        throw "OpenNV gallery capture exceeded $TimeoutSeconds seconds."
    }
    $process.WaitForExit()
    $process.Refresh()
    if ($null -ne $process.ExitCode -and $process.ExitCode -ne 0) {
        throw "OpenNV gallery Godot process failed with exit code $($process.ExitCode)."
    }
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
}

$movieEvidence = $null
if ($CaptureMovie) {
    if (-not (Test-Path -LiteralPath $sourceMovie -PathType Leaf)) {
        throw "OpenNV gallery source movie was not retained: $sourceMovie"
    }
    if ($null -eq (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
        throw 'ffprobe is required to validate the engine-owned gallery source movie.'
    }
    $probe = (& ffprobe -v error -show_entries `
        format=duration:stream=codec_type,codec_name,r_frame_rate,nb_frames `
        -of json -- $sourceMovie | Out-String) | ConvertFrom-Json
    $videoStreams = @($probe.streams | Where-Object { [string]$_.codec_type -ceq 'video' })
    $durationSeconds = [double]::Parse(
        [string]$probe.format.duration,
        [Globalization.CultureInfo]::InvariantCulture)
    $targetDurationSeconds =
        [double]$galleryPolicy.framesPerSubject / [double]$galleryPolicy.framesPerSecond
    $durationToleranceSeconds =
        [double]$videoPolicy.durationToleranceFrames / [double]$galleryPolicy.framesPerSecond
    if ($videoStreams.Count -ne 1 -or
        $durationSeconds + $durationToleranceSeconds -lt $targetDurationSeconds) {
        throw 'OpenNV gallery source movie failed its stream or duration gate.'
    }
    $movieEvidence = [ordered]@{
        path = $sourceMovie
        sha256 = (Get-FileHash -LiteralPath $sourceMovie -Algorithm SHA256).Hash.ToLowerInvariant()
        bytes = (Get-Item -LiteralPath $sourceMovie).Length
        codec = [string]$videoStreams[0].codec_name
        rate = [string]$videoStreams[0].r_frame_rate
        frames = [string]$videoStreams[0].nb_frames
        durationSeconds = $durationSeconds
        targetDurationSeconds = $targetDurationSeconds
    }
}

if (-not (Test-Path -LiteralPath $engineReport -PathType Leaf)) {
    throw "OpenNV gallery engine report was not retained: $engineReport"
}
$engine = Get-Content -Raw -LiteralPath $engineReport | ConvertFrom-Json
$nativeFrames = @(Get-ChildItem -LiteralPath $nativeRoot -Filter '*.png' -File)
$expectedFramePath = Join-Path $nativeRoot $outputFile
$enginePresentation = $engine.galleryShot.retailEvidence.presentation
$engineSelection = $enginePresentation.selection
$engineRenderedWorldspace = if (
    $null -eq $engine.galleryShot.renderedScene.worldspaceFormId) {
    $null
} else {
    Normalize-FormId ([string]$engine.galleryShot.renderedScene.worldspaceFormId)
}
$captured = [string]$engine.schema -ceq 'opennv-godot-gallery-capture/v5' -and
    [string]$engine.status -ceq 'captured-gallery-retail-bound-pending-parity' -and
    -not [bool]$engine.parity -and
    -not [bool]$engine.parityClaimed -and
    -not [bool]$engine.retailCaptureUsed -and
    [bool]$engine.retailEvidenceUsed -and
    -not [bool]$engine.windowsAppControlUsed -and
    -not [bool]$engine.foregroundActivationUsed -and
    -not [bool]$engine.foregroundInputInjected -and
    [string]$engine.galleryShot.sha256 -ceq
        (Get-FileHash -LiteralPath $galleryShotPath -Algorithm SHA256).Hash.ToLowerInvariant() -and
    [string]$engine.galleryShot.LocationId -ceq [string]$shot.locationId -and
    (Normalize-FormId ([string]$engine.galleryShot.actorCellFormId)) -ceq
        $shotActorCell -and
    (Normalize-FormId ([string]$engine.galleryShot.renderedScene.cellFormId)) -ceq
        $shotSceneCell -and
    $engineRenderedWorldspace -ceq $shotSceneWorldspace -and
    [bool]$engine.galleryShot.renderedScene.interior -eq $shotSceneInterior -and
    (Normalize-FormId ([string]$engine.scene.cellFormId)) -ceq $shotSceneCell -and
    (Normalize-FormId ([string]$engine.actor.referenceFormId)) -ceq $shotReference -and
    (Normalize-FormId ([string]$engine.actor.baseFormId)) -ceq $shotBase -and
    [string]$engine.galleryShot.EnableStateMode -ceq $enableStateMode -and
    [string]$enginePresentation.shotKind -ceq $presentationShotKind -and
    [int]$enginePresentation.frame -eq [int]$retailPresentation.frame -and
    [string]$enginePresentation.sourceFrameCameraContractEventSha256 -ceq
        [string]$retailPresentation.sourceFrameCameraContractEventSha256 -and
    [string]$engineSelection.policySchema -ceq
        [string]$presentationSelection.policySchema -and
    [string]$engineSelection.tieBreak -ceq [string]$presentationSelection.tieBreak -and
    (Test-ExactStringSequence @($engineSelection.candidateShotKinds) `
        @($presentationSelection.candidateShotKinds)) -and
    [string]$engineSelection.focusKind -ceq
        [string]$presentationSelection.focusKind -and
    [double]$engineSelection.cameraDirectionDotFocusForward -eq
        [double]$presentationSelection.cameraDirectionDotFocusForward -and
    [string]$engineSelection.surfaceStatus -ceq
        [string]$presentationSelection.surfaceStatus -and
    [bool]$engineSelection.semanticFocusSurface -eq
        [bool]$presentationSelection.semanticFocusSurface -and
    [bool]$engineSelection.cameraOutsideActorWorldBound -eq
        [bool]$presentationSelection.cameraOutsideActorWorldBound -and
    [bool]$engineSelection.cameraCorridorPassed -eq
        [bool]$presentationSelection.cameraCorridorPassed -and
    [bool]$engine.actor.initiallyDisabled -eq [bool]$actor.reference.initiallyDisabled -and
    [bool]$engine.actor.proofEnabled -eq $proofEnableActor -and
    [bool]$engine.authoredMotion.passed -and
    [bool]$engine.actor.groundContact.groundFound -and
    [bool]$engine.actor.groundContact.passed -and
    [bool]$engine.scene.lod.passed -and
    [bool]$engine.lighting.passed -and
    [bool]$engine.camera.headInViewport -and
    [string]$engine.camera.retailShotKind -ceq $presentationShotKind -and
    [int]$engine.camera.retailFrame -eq [int]$retailPresentation.frame -and
    [string]$engine.camera.targetNodeRole -ceq [string]$galleryPolicy.targetNodeRole -and
    [string]$engine.camera.facingPoseSource -ceq
        [string]$galleryPolicy.facingPoseSource -and
    [string]$engine.camera.occlusionClearanceSource -ceq
        [string]$galleryPolicy.occlusionClearanceSource -and
    $nativeFrames.Count -eq 1 -and
    (Test-Path -LiteralPath $expectedFramePath -PathType Leaf) -and
    @($engine.files).Count -eq 1
if (-not $captured) {
    throw "OpenNV gallery capture failed its authored-identity, native-frame, or no-control gate: $engineReport"
}

$artifactPaths = @(
    $cellScenePath,
    $actorScenePath,
    $galleryShotPath,
    $retailEvidencePath,
    [string]$retailEvidence.retail.report.path,
    [string]$retailEvidence.retail.oracleJsonl.path,
    $engineReport,
    (Join-Path $nativeRoot 'gallery-capture-report.json'),
    $stdoutPath,
    $stderrPath,
    $godotLog,
    $expectedFramePath
)
$artifactPaths += @($retailEvidence.retail.sourceFrames | ForEach-Object {
    [string]$_.path
})
if ($CaptureMovie) { $artifactPaths += $sourceMovie }
$artifacts = @($artifactPaths | Where-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
} | ForEach-Object { Get-FileEvidence $_ })
$report = [ordered]@{
    schema = 'nikami-opennv-gallery-capture/v3'
    status = 'captured-gallery-retail-bound-pending-parity'
    startedAt = $startedAt.ToString('o')
    completedAt = (Get-Date).ToString('o')
    shot = [ordered]@{
        id = [string]$shot.id
        ordinal = [int]$shot.ordinal
        label = [string]$shot.label
        location = [string]$shot.location
        locationClass = [string]$shot.locationClass
        recordType = [string]$shot.recordType
        referenceFormId = $shotReference
        baseFormId = $shotBase
        actor = [ordered]@{ cellFormId = $shotActorCell }
        scene = [ordered]@{
            cellFormId = $shotSceneCell
            worldspaceFormId = $shotSceneWorldspace
            interior = $shotSceneInterior
        }
        enableStateMode = $enableStateMode
    }
    capture = [ordered]@{
        method = if ($CaptureMovie) {
            'Godot engine-owned fixed-step movie plus viewport PNG from current OpenNV owned-data scenes'
        } else {
            'Godot engine-owned viewport PNG from current OpenNV owned-data scenes'
        }
        sourceFrames = if ($CaptureMovie) {
            [int]$galleryPolicy.framesPerSubject
        } else { 1 }
        movie = $movieEvidence
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        outputOverwritten = $false
        retailCaptureUsed = $false
        retailEvidenceUsed = $true
    }
    engine = $engine
    evidencePolicy = [ordered]@{
        exactAuthoredActorPlacementRequired = $true
        exactRetailEnvironmentEvidenceRequired = $true
        ownedDataInputsHashRetained = $true
        captureIsNotParityEvidence = $true
        retailRecaptureUsed = $false
    }
    artifacts = $artifacts
}
$reportPath = Join-Path $outputDirectory 'opennv-gallery-capture-report.json'
[IO.File]::WriteAllText(
    $reportPath,
    ($report | ConvertTo-Json -Depth 40) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 40
