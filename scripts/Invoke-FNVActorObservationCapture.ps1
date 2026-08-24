[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PlanRoot,
    [Parameter(Mandatory)]
    [string]$CorpusRoot,
    [Parameter(Mandatory)]
    [ValidatePattern('^[^:]+\.(?:esm|esp):[0-9a-fA-F]{6}$')]
    [string]$CaptureJobKey,
    [Parameter(Mandatory)]
    [string]$OutputRoot,
    [Parameter(Mandatory)]
    [string]$OracleSeedRoot,
    [Parameter(Mandatory)]
    [string]$OraclePluginDll,
    [Parameter(Mandatory)]
    [string]$SaveFixture,
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\Fallout New Vegas',
    [string]$WorldsRoot = '',
    [int]$TimeoutSeconds = 0,
    [switch]$ActorDrawContractDiagnostic
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorldsRoot)) {
    $WorldsRoot = Split-Path -Parent $PSScriptRoot
}
$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)

function Resolve-ObservationPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $WorldsRoot $Path))
}

function Get-LowerSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-ManifestFile([string]$Root, [object]$Entry, [string]$Label) {
    $path = Join-Path $Root ([string]$Entry.file)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing $Label file: $path"
    }
    $item = Get-Item -LiteralPath $path
    if ($item.Length -ne [int64]$Entry.bytes) {
        throw "$Label byte count differs from its immutable manifest: $path"
    }
    $actualHash = Get-LowerSha256 $path
    if ($actualHash -cne [string]$Entry.sha256) {
        throw "$Label SHA-256 differs from its immutable manifest: $path"
    }
    return $path
}

function Write-ImmutableJson([string]$Path, [object]$Value, [int]$Depth = 20) {
    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to overwrite immutable JSON: $Path"
    }
    $json = ($Value | ConvertTo-Json -Depth $Depth) + [Environment]::NewLine
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Get-FileEvidence([string]$Path, [string]$Kind) {
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject][ordered]@{
        kind = $Kind
        path = $item.FullName
        bytes = $item.Length
        sha256 = Get-LowerSha256 $item.FullName
    }
}

function Test-FiniteNumberArray([object[]]$Values, [int]$ExpectedCount) {
    if ($Values.Count -ne $ExpectedCount) { return $false }
    foreach ($value in $Values) {
        try { $number = [double]$value } catch { return $false }
        if (-not [double]::IsFinite($number)) { return $false }
    }
    return $true
}

function ConvertTo-StableFormKey([uint32]$FormId, [object[]]$RuntimePlugins) {
    if ($FormId -eq 0) { return $null }
    $pluginIndex = [int](($FormId -shr 24) -band 0xff)
    if ($pluginIndex -lt 0 -or $pluginIndex -ge $RuntimePlugins.Count) { return $null }
    $pluginName = [string]$RuntimePlugins[$pluginIndex].name
    if ([string]::IsNullOrWhiteSpace($pluginName)) { return $null }
    return '{0}:{1:x6}' -f $pluginName, ($FormId -band 0x00ffffff)
}

$planDirectory = Resolve-ObservationPath $PlanRoot
$corpusDirectory = Resolve-ObservationPath $CorpusRoot
$outputDirectory = Resolve-ObservationPath $OutputRoot
$seedDirectory = Resolve-ObservationPath $OracleSeedRoot
$pluginSource = Resolve-ObservationPath $OraclePluginDll
$saveSource = Resolve-ObservationPath $SaveFixture
$gameDirectory = Resolve-ObservationPath $GameRoot
$catalogPath = Join-Path $WorldsRoot 'catalog\fnv-jam-background-capture-recipes.json'
$oracleRunner = Join-Path $PSScriptRoot 'Invoke-FNVRetailOracle.ps1'

foreach ($directory in @($planDirectory, $corpusDirectory, $seedDirectory, $gameDirectory)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Missing actor-observation directory: $directory"
    }
}
foreach ($file in @($pluginSource, $saveSource, $catalogPath, $oracleRunner)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Missing actor-observation file: $file"
    }
}
if ([IO.Path]::GetExtension($saveSource) -ine '.fos') {
    throw "SaveFixture must be a legally owned Fallout: New Vegas .fos file: $saveSource"
}
if (Test-Path -LiteralPath $outputDirectory) {
    throw "Refusing to overwrite an existing actor-observation output: $outputDirectory"
}

$catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
$recipes = @($catalog.actorObservationRecipes | Where-Object {
    [string]$_.id -eq 'fnv-official-actor-retail-observation-v1'
})
if ($recipes.Count -ne 1) {
    throw 'The canonical retail actor-observation recipe is missing or duplicated.'
}
$recipe = $recipes[0]
$policy = $recipe.capturePolicy
$telemetryPolicy = $recipe.telemetryPolicy
$surfaceContractPolicy = $telemetryPolicy.surfaceContract
$drawContractPolicy = $telemetryPolicy.drawContractDiagnostic
if ([string]$telemetryPolicy.mode -cne 'compact-actor-pose-sample' -or
    [string]$telemetryPolicy.poseEvent -cne 'actor-pose-sample' -or
    [string]$telemetryPolicy.visualSnapshotEvent -cne 'actor-visual-snapshot' -or
    [string]$telemetryPolicy.visualSnapshotFaultEvent -cne 'actor-visual-snapshot-fault' -or
    [int]$telemetryPolicy.requiredVisualSnapshotsPerSourceFrame -ne 1 -or
    [int]$telemetryPolicy.requiredAppearanceSnapshots -ne 1 -or
    -not [bool]$telemetryPolicy.requireSkinPalettesForSkinnedGeometry -or
    [int]$telemetryPolicy.skinPaletteComponentsPerRegister -lt 1 -or
    [int]$telemetryPolicy.skinPaletteBytesPerComponent -lt 1 -or
    [int]$telemetryPolicy.skinPaletteMaximumBytesPerShape -lt 1 -or
    [int]$telemetryPolicy.minimumNamedNodesPerSnapshot -lt 1 -or
    [int]$telemetryPolicy.minimumPoseSamples -lt 2 -or
    [int]$telemetryPolicy.cameraMatrixElementCount -ne 16 -or
    [int]$telemetryPolicy.cameraWorldRotationElementCount -ne 9 -or
    [int]$telemetryPolicy.cameraWorldTranslationElementCount -ne 3 -or
    [int]$telemetryPolicy.cameraFrustumElementCount -ne 7 -or
    [int]$telemetryPolicy.cameraViewportElementCount -ne 4 -or
    -not [bool]$telemetryPolicy.requireExactPerspectiveProjection -or
    [int64]$telemetryPolicy.maximumJsonlBytes -lt 1 -or
    @($telemetryPolicy.forbiddenEvents).Count -lt 1) {
    throw 'The actor-observation telemetry policy is incomplete or invalid.'
}
if ($null -eq $surfaceContractPolicy -or
    [string]$surfaceContractPolicy.event -cne 'actor-surface-contract' -or
    [string]$surfaceContractPolicy.targetTexturesEvent -cne
        'actor-draw-contract-target-textures' -or
    [int]$surfaceContractPolicy.renderFrameLead -lt 1 -or
    [int]$surfaceContractPolicy.textureStageCount -lt 1 -or
    [int]$surfaceContractPolicy.textureStageCount -gt 16 -or
    [int]$surfaceContractPolicy.maximumShaderBytes -lt 1 -or
    [int]$surfaceContractPolicy.matrixElementCount -ne 16 -or
    [double]$surfaceContractPolicy.matrixTolerance -le 0 -or
    -not [bool]$surfaceContractPolicy.requireBackBufferDimensions -or
    [double]$surfaceContractPolicy.normalizedDepthMinimum -ge
        [double]$surfaceContractPolicy.normalizedDepthMaximum) {
    throw 'The actor surface-contract policy is incomplete or invalid.'
}
if ($null -eq $drawContractPolicy -or
    [string]$drawContractPolicy.event -cne 'actor-draw-contract' -or
    [string]$drawContractPolicy.targetTexturesEvent -cne
        'actor-draw-contract-target-textures' -or
    [int]$drawContractPolicy.renderFrameLead -lt 1 -or
    [int]$drawContractPolicy.textureStageCount -lt 1 -or
    [int]$drawContractPolicy.textureStageCount -gt 16 -or
    [int]$drawContractPolicy.maximumRecordsPerSourceFrame -lt 1 -or
    [int]$drawContractPolicy.vertexShaderRegisterCount -lt 1 -or
    [int]$drawContractPolicy.vertexShaderRegisterCount -gt 256 -or
    [int]$drawContractPolicy.maximumShaderBytes -lt 1 -or
    [int]$drawContractPolicy.maximumBufferBytesPerRecord -lt 1) {
    throw 'The actor draw-contract diagnostic policy is incomplete or invalid.'
}
if ($TimeoutSeconds -le 0) {
    $TimeoutSeconds = [int]$policy.timeoutSeconds
}

$planManifestPath = Join-Path $planDirectory 'manifest.json'
$corpusManifestPath = Join-Path $corpusDirectory 'manifest.json'
foreach ($manifestPath in @($planManifestPath, $corpusManifestPath)) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Missing immutable actor manifest: $manifestPath"
    }
}
$planManifest = Get-Content -Raw -LiteralPath $planManifestPath | ConvertFrom-Json
$corpusManifest = Get-Content -Raw -LiteralPath $corpusManifestPath | ConvertFrom-Json
if ([string]$planManifest.schema -cne 'opennv-actor-capture-plan/v1' -or
    [string]$corpusManifest.schema -cne 'opennv-actor-parity-corpus/v1') {
    throw 'Actor plan or corpus schema is not canonical v1.'
}
$jobsPath = Assert-ManifestFile $planDirectory $planManifest.outputs.jobs 'capture jobs'
$appearancePath = Assert-ManifestFile $corpusDirectory $corpusManifest.outputs.appearanceReview `
    'appearance review ledger'
if ([string]$planManifest.sourceCorpus.appearanceReviewSha256 -cne
    [string]$corpusManifest.outputs.appearanceReview.sha256) {
    throw 'Capture plan is not bound to the supplied appearance-review ledger.'
}

$jobMatches = [Collections.Generic.List[object]]::new()
foreach ($line in [IO.File]::ReadLines($jobsPath)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $row = $line | ConvertFrom-Json
    if ([string]$row.captureJobKey -ceq $CaptureJobKey) {
        $jobMatches.Add($row)
    }
}
if ($jobMatches.Count -ne 1) {
    throw "CaptureJobKey '$CaptureJobKey' matched $($jobMatches.Count) plan rows."
}
$job = $jobMatches[0]
if ([string]$job.recordType -notin @('NPC_', 'CREA') -or
    [string]$job.baseRuntimeFormId -notmatch '^[0-9a-fA-F]{8}$') {
    throw "Capture job '$CaptureJobKey' has an invalid actor type or runtime FormID."
}

$expectedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($key in @($job.expectedReviewKeys)) {
    if (-not $expectedKeys.Add([string]$key)) {
        throw "Capture job '$CaptureJobKey' contains a duplicate expected review key."
    }
}
$reviewRows = [Collections.Generic.List[object]]::new()
foreach ($line in [IO.File]::ReadLines($appearancePath)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $row = $line | ConvertFrom-Json
    if ($expectedKeys.Contains([string]$row.reviewKey)) {
        $reviewRows.Add($row)
    }
}
if ($reviewRows.Count -ne $expectedKeys.Count -or
    $reviewRows.Count -ne [int]$job.expectedOutcomeCount) {
    throw "Capture job '$CaptureJobKey' does not resolve its complete expected review set."
}
foreach ($row in $reviewRows) {
    if ([string]$row.baseFormKey -cne [string]$job.baseFormKey -or
        [string]$row.baseRuntimeFormId -cne [string]$job.baseRuntimeFormId -or
        [string]$row.recordType -cne [string]$job.recordType) {
        throw "Review row '$($row.reviewKey)' does not belong to '$CaptureJobKey'."
    }
}

$requiredShotKinds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($row in $reviewRows) {
    $rowShots = @($row.requiredShots | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    foreach ($shotKind in $rowShots) { [void]$requiredShotKinds.Add($shotKind) }
}
$shotTimeline = @($policy.shotTimeline)
if ($shotTimeline.Count -lt 1 -or $null -eq $policy.shotKindOverridesByRecordType) {
    throw 'Actor-observation capture policy declares no record-aware review timeline.'
}
$recordTypeMappings = @($policy.shotKindOverridesByRecordType.PSObject.Properties |
    Where-Object { [string]$_.Name -ceq [string]$job.recordType })
if ($recordTypeMappings.Count -ne 1) {
    throw "Actor-observation capture policy does not map record type '$($job.recordType)'."
}
$recordTypeMapping = $recordTypeMappings[0].Value
$shots = [Collections.Generic.List[object]]::new()
foreach ($timelineShot in $shotTimeline) {
    $slot = [string]$timelineShot.slot
    if ([string]::IsNullOrWhiteSpace($slot)) {
        throw 'Actor-observation review timeline contains an empty shot slot.'
    }
    $slotOverrides = @($recordTypeMapping.PSObject.Properties |
        Where-Object { [string]$_.Name -ceq $slot })
    if ($slotOverrides.Count -gt 1) {
        throw "Actor-observation shot slot '$slot' has duplicate record-type overrides."
    }
    $shotKind = if ($slotOverrides.Count -eq 1) { [string]$slotOverrides[0].Value } else { $slot }
    $shots.Add([pscustomobject][ordered]@{
        kind = $shotKind
        setFrame = [int]$timelineShot.setFrame
        screenshotFrames = @($timelineShot.screenshotFrames | ForEach-Object { [int]$_ })
    })
}
$configuredShotKinds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$screenshotFrames = [Collections.Generic.List[int]]::new()
$shotFrameKinds = [Collections.Generic.Dictionary[int,string]]::new()
foreach ($shot in $shots) {
    $shotKind = [string]$shot.kind
    $setFrame = [int]$shot.setFrame
    $frames = @($shot.screenshotFrames | ForEach-Object { [int]$_ })
    if ([string]::IsNullOrWhiteSpace($shotKind) -or
        -not $configuredShotKinds.Add($shotKind) -or $frames.Count -lt 1 -or
        $setFrame -le [int]$policy.stageFrame) {
        throw 'Actor-observation review shots contain an invalid or duplicate shot declaration.'
    }
    foreach ($frame in $frames) {
        if ($frame -le $setFrame -or $frame -gt [int]$policy.maxFrames -or
            $shotFrameKinds.ContainsKey($frame)) {
            throw "Actor-observation screenshot frame '$frame' is invalid or duplicated."
        }
        $screenshotFrames.Add($frame)
        $shotFrameKinds.Add($frame, $shotKind)
    }
}
if ((@($configuredShotKinds | Sort-Object) -join "`n") -cne
    (@($requiredShotKinds | Sort-Object) -join "`n")) {
    throw 'Configured retail shot kinds do not exactly cover the immutable review ledger.'
}
$motionPolicy = $policy.motionVideo
$motionShots = @($shots | Where-Object { [string]$_.kind -ceq [string]$motionPolicy.shotKind })
if ($motionShots.Count -ne 1 -or @($motionShots[0].screenshotFrames).Count -lt 2 -or
    [int]$motionPolicy.timelineFrameRate -lt 1 -or
    [int]$motionPolicy.tailDurationFrames -lt 1 -or
    [int]$motionPolicy.outputFrameRate -lt 1 -or
    [int]$motionPolicy.crf -lt 0 -or
    [string]::IsNullOrWhiteSpace([string]$motionPolicy.file)) {
    throw 'Actor-observation motion-video policy is incomplete or invalid.'
}
$ffmpeg = Get-Command ffmpeg -ErrorAction Stop | Select-Object -First 1
$ffprobe = Get-Command ffprobe -ErrorAction Stop | Select-Object -First 1

$expectedPluginNames = @($recipe.officialPlugins | ForEach-Object { [string]$_ })
$corpusInputs = @($corpusManifest.inputs | Sort-Object { [int]$_.loadOrderIndex })
$corpusPluginNames = @($corpusInputs | ForEach-Object { [string]$_.file })
if (($expectedPluginNames -join "`n") -cne ($corpusPluginNames -join "`n")) {
    throw 'Recipe official plugin order differs from the immutable corpus.'
}
$stackText = ($corpusInputs | ForEach-Object {
    '{0}:{1}:{2}' -f [int]$_.loadOrderIndex, [string]$_.file, [string]$_.sha256
}) -join "`n"
$stackBytes = [Text.UTF8Encoding]::new($false).GetBytes($stackText + "`n")
$officialPluginStackSha256 = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($stackBytes)).ToLowerInvariant()

New-Item -ItemType Directory -Path $outputDirectory | Out-Null
$seedManifestPath = Join-Path $seedDirectory 'oracle-runtime-manifest.json'
if (-not (Test-Path -LiteralPath $seedManifestPath -PathType Leaf)) {
    throw "Missing seed oracle runtime manifest: $seedManifestPath"
}
$seedManifest = Get-Content -Raw -LiteralPath $seedManifestPath | ConvertFrom-Json
$pluginSourceHash = Get-LowerSha256 $pluginSource
$runtimeIdentity = 'oracle-' + $pluginSourceHash.Substring(0, 16)
$runtimeDirectory = Join-Path $WorldsRoot "local\actor-observation-runtimes\$runtimeIdentity"
$runtimePluginDirectory = Join-Path $runtimeDirectory 'plugins'
$runtimePluginPath = Join-Path $runtimePluginDirectory 'nvse_retail_oracle.dll'
$runtimeManifestPath = Join-Path $runtimeDirectory 'oracle-runtime-manifest.json'
$runtimeFiles = [ordered]@{}
foreach ($entryName in @('loader', 'steamLoader', 'core')) {
    $entry = $seedManifest.files.$entryName
    $source = Join-Path $seedDirectory ([string]$entry.path)
    if ((Get-LowerSha256 $source) -cne [string]$entry.sha256) {
        throw "Seed oracle runtime file differs from its manifest: $source"
    }
    $runtimeFiles[$entryName] = [ordered]@{
        path = [string]$entry.path
        sha256 = [string]$entry.sha256
    }
}
$runtimeFiles['plugin'] = [ordered]@{
    path = 'plugins/nvse_retail_oracle.dll'
    sha256 = $pluginSourceHash
}
$expectedRuntimeManifest = [ordered]@{
    schema = 'nikami-xnvse-isolated-runtime/v1'
    overlay = $seedManifest.overlay
    files = $runtimeFiles
}
if (Test-Path -LiteralPath $runtimeDirectory -PathType Container) {
    if (-not (Test-Path -LiteralPath $runtimeManifestPath -PathType Leaf)) {
        throw "Content-addressed actor runtime has no manifest: $runtimeDirectory"
    }
    $existingRuntimeManifest = Get-Content -Raw -LiteralPath $runtimeManifestPath | ConvertFrom-Json
    if ([string]$existingRuntimeManifest.schema -cne [string]$expectedRuntimeManifest.schema -or
        [string]$existingRuntimeManifest.overlay.replayedTree -cne
            [string]$expectedRuntimeManifest.overlay.replayedTree) {
        throw "Content-addressed actor runtime metadata differs: $runtimeDirectory"
    }
    foreach ($entryName in @('loader', 'steamLoader', 'core', 'plugin')) {
        $entry = $expectedRuntimeManifest.files.$entryName
        $path = Join-Path $runtimeDirectory ([string]$entry.path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-LowerSha256 $path) -cne [string]$entry.sha256) {
            throw "Content-addressed actor runtime file differs: $path"
        }
    }
}
else {
    New-Item -ItemType Directory -Path $runtimePluginDirectory -Force | Out-Null
    foreach ($entryName in @('loader', 'steamLoader', 'core')) {
        $entry = $seedManifest.files.$entryName
        Copy-Item -LiteralPath (Join-Path $seedDirectory ([string]$entry.path)) `
            -Destination (Join-Path $runtimeDirectory ([string]$entry.path))
    }
    Copy-Item -LiteralPath $pluginSource -Destination $runtimePluginPath
    Write-ImmutableJson $runtimeManifestPath $expectedRuntimeManifest
}

$retailDirectory = Join-Path $outputDirectory 'retail'
New-Item -ItemType Directory -Path $retailDirectory | Out-Null
$drawArtifactDirectory = Join-Path $retailDirectory 'actor-draw-contract'
if ($ActorDrawContractDiagnostic) {
    New-Item -ItemType Directory -Path $drawArtifactDirectory | Out-Null
}
$jsonlPath = Join-Path $retailDirectory 'actor-observation.jsonl'
$screensDirectory = Join-Path $retailDirectory 'native-d3d9-frames'
$runtimeForm = ([string]$job.baseRuntimeFormId).ToUpperInvariant()
$distanceText = ([double]$policy.stageDistance).ToString(
    [Globalization.CultureInfo]::InvariantCulture)
$scheduledCommands = @(
    '{0}:SpawnActor {1}' -f [int]$policy.spawnFrame, $runtimeForm
    '{0}:ResolveSpawnedActor' -f [int]$policy.resolveFrame
    '{0}@0xffffffff:StageInFrontOfPlayer {1}' -f [int]$policy.stageFrame, $distanceText
)
$scheduledCommands += @($shots | ForEach-Object {
    '{0}:SetReviewShot {1}' -f [int]$_.setFrame, [string]$_.kind
})
$oracleArguments = @{
    GameRoot = $gameDirectory
    RuntimeRoot = $runtimeDirectory
    PluginDll = $runtimePluginPath
    OutputPath = $jsonlPath
    SaveFixture = $saveSource
    QuestForm = @()
    GlobalForm = @()
    Command = @()
    ScheduledCommand = $scheduledCommands
    BeforeFrame = [int]$policy.beforeFrame
    CommandFrame = [int]$policy.commandFrame
    AfterFrame = [int]$policy.afterFrame
    MaxFrames = [int]$policy.maxFrames
    TimeoutSeconds = $TimeoutSeconds
    SampleEvery = [int]$policy.sampleEvery
    TargetForm = "0x$runtimeForm"
    SpawnBaseCapture = $true
    CaptureAnimation = $true
    TargetAnimationOnly = $true
    CompactActorTelemetry = $true
    CaptureActorSkinPalettes = $true
    ActorSkinPaletteMaximumBytesPerShape =
        [int]$telemetryPolicy.skinPaletteMaximumBytesPerShape
    CaptureActorSurfaceContract = $true
    ActorSurfaceMaximumShaderBytes =
        [int]$surfaceContractPolicy.maximumShaderBytes
    ActorSurfaceTextureStageCount =
        [int]$surfaceContractPolicy.textureStageCount
    ActorSurfaceRenderFrameLead =
        [int]$surfaceContractPolicy.renderFrameLead
    CaptureActorDrawContract = [bool]$ActorDrawContractDiagnostic
    ActorDrawMaximumRecordsPerSourceFrame = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.maximumRecordsPerSourceFrame
    } else { 0 }
    ActorDrawVertexShaderRegisterCount = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.vertexShaderRegisterCount
    } else { 0 }
    ActorDrawMaximumShaderBytes = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.maximumShaderBytes
    } else { 0 }
    ActorDrawTextureStageCount = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.textureStageCount
    } else { 0 }
    ActorDrawRenderFrameLead = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.renderFrameLead
    } else { 0 }
    ActorDrawMaximumBufferBytesPerRecord = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.maximumBufferBytesPerRecord
    } else { 0 }
    ActorDrawArtifactDirectory = if ($ActorDrawContractDiagnostic) {
        $drawArtifactDirectory
    } else { '' }
    PrepareActorFrame = [int]$policy.maxFrames
    EquipActorFrame = [int]$policy.maxFrames
    ScreenshotFrame = @($screenshotFrames | Sort-Object)
    ScreenshotDirectory = $screensDirectory
    PortraitCamera = $true
    PortraitDistance = [float]$policy.portraitDistance
    CameraShotKind = [string]$shots[0].kind
    ExpectedCameraShotKind = @($shots | ForEach-Object { [string]$_.kind })
    FullBodyDistanceScale = [float]$policy.fullBodyDistanceScale
    RequireAppearanceTelemetry = [string]$job.recordType -eq 'NPC_'
    BackgroundDataMode = $true
}
$oracleRun = & $oracleRunner @oracleArguments

$events = @([IO.File]::ReadLines($jsonlPath) | ForEach-Object {
    if (-not [string]::IsNullOrWhiteSpace($_)) { $_ | ConvertFrom-Json }
})
$startEvents = @($events | Where-Object { [string]$_.event -eq 'start' })
if ($startEvents.Count -ne 1 -or -not [bool]$startEvents[0].compactActorTelemetry -or
    -not [bool]$startEvents[0].captureActorSkinPalettes -or
    [int]$startEvents[0].actorSkinPaletteMaximumBytesPerShape -ne
        [int]$telemetryPolicy.skinPaletteMaximumBytesPerShape -or
    -not [bool]$startEvents[0].captureActorSurfaceContract -or
    [int]$startEvents[0].actorSurfaceMaximumShaderBytes -ne
        [int]$surfaceContractPolicy.maximumShaderBytes -or
    [int]$startEvents[0].actorSurfaceTextureStageCount -ne
        [int]$surfaceContractPolicy.textureStageCount -or
    [int]$startEvents[0].actorSurfaceRenderFrameLead -ne
        [int]$surfaceContractPolicy.renderFrameLead -or
    [bool]$startEvents[0].captureActorDrawContract -ne
        [bool]$ActorDrawContractDiagnostic) {
    throw 'Retail actor observation did not confirm compact actor and configured skin-palette telemetry.'
}
$unexpectedDiagnosticEvents = @($events | Where-Object {
    [string]$_.event -in @($telemetryPolicy.forbiddenEvents)
})
if ($unexpectedDiagnosticEvents.Count -ne 0) {
    throw "Compact actor observation retained $($unexpectedDiagnosticEvents.Count) unrelated diagnostic event(s)."
}
$stackEvents = @($events | Where-Object { [string]$_.event -eq 'runtime-plugin-stack' })
if ($stackEvents.Count -ne 1 -or -not [bool]$stackEvents[0].readable) {
    throw 'Retail did not retain one readable runtime plugin stack.'
}
$runtimePlugins = @($stackEvents[0].plugins)
if ($runtimePlugins.Count -ne $expectedPluginNames.Count) {
    throw "Retail loaded $($runtimePlugins.Count) plugins; expected $($expectedPluginNames.Count)."
}
for ($index = 0; $index -lt $expectedPluginNames.Count; ++$index) {
    $plugin = $runtimePlugins[$index]
    if (-not [bool]$plugin.readable -or [int]$plugin.loadOrderIndex -ne $index -or
        [int]$plugin.modIndex -ne $index -or
        [string]$plugin.name -cne $expectedPluginNames[$index]) {
        throw "Retail plugin stack differs at index $index; expected '$($expectedPluginNames[$index])'."
    }
}
$templateEvents = @($events | Where-Object { [string]$_.event -eq 'actor-template-observation' })
$portraitEvents = @($events | Where-Object { [string]$_.event -eq 'portrait-camera-set' })
$cameraEvents = @($events | Where-Object { [string]$_.event -eq 'review-camera-observation' })
if ($templateEvents.Count -ne 1) {
    throw "Expected one actor-template-observation, got $($templateEvents.Count)."
}
if ($portraitEvents.Count -ne $shots.Count) {
    throw "Retail capture retained $($portraitEvents.Count) camera sets; expected $($shots.Count)."
}
for ($shotIndex = 0; $shotIndex -lt $shots.Count; ++$shotIndex) {
    if ([string]$portraitEvents[$shotIndex].shotKind -cne [string]$shots[$shotIndex].kind) {
        throw "Retail camera set $shotIndex does not match the configured shot sequence."
    }
}
$orderedScreenshotFrames = @($screenshotFrames | Sort-Object)
if ($cameraEvents.Count -ne $orderedScreenshotFrames.Count) {
    throw "Retail capture retained $($cameraEvents.Count) camera observations; expected $($orderedScreenshotFrames.Count)."
}
for ($cameraIndex = 0; $cameraIndex -lt $cameraEvents.Count; ++$cameraIndex) {
    $cameraEvent = $cameraEvents[$cameraIndex]
    $expectedFrame = [int]$orderedScreenshotFrames[$cameraIndex]
    $cameraWorld = $cameraEvent.cameraWorld
    $viewMatrix = @($cameraEvent.viewMatrix)
    $projectionMatrix = @($cameraEvent.projectionMatrix)
    $frustum = @($cameraEvent.frustum)
    $viewport = @($cameraEvent.viewport)
    if ([int]$cameraEvent.frame -ne $expectedFrame -or
        [string]$cameraEvent.shotKind -cne [string]$shotFrameKinds[$expectedFrame] -or
        -not [bool]$cameraEvent.readable -or
        -not [bool]$cameraEvent.projectionExact -or
        $null -eq $cameraWorld -or
        -not (Test-FiniteNumberArray @($cameraWorld.rotation) `
            ([int]$telemetryPolicy.cameraWorldRotationElementCount)) -or
        -not (Test-FiniteNumberArray @($cameraWorld.translation) `
            ([int]$telemetryPolicy.cameraWorldTranslationElementCount)) -or
        -not [double]::IsFinite([double]$cameraWorld.scale) -or
        [double]$cameraWorld.scale -le 0.0 -or
        -not (Test-FiniteNumberArray $viewMatrix `
            ([int]$telemetryPolicy.cameraMatrixElementCount)) -or
        -not (Test-FiniteNumberArray $projectionMatrix `
            ([int]$telemetryPolicy.cameraMatrixElementCount)) -or
        -not (Test-FiniteNumberArray $frustum `
            ([int]$telemetryPolicy.cameraFrustumElementCount)) -or
        -not (Test-FiniteNumberArray $viewport `
            ([int]$telemetryPolicy.cameraViewportElementCount)) -or
        -not [double]::IsFinite([double]$cameraEvent.fovYRadians) -or
        [double]$cameraEvent.fovYRadians -le 0.0 -or
        [double]$frustum[0] -ge [double]$frustum[1] -or
        [double]$frustum[3] -ge [double]$frustum[2] -or
        [double]$frustum[4] -le 0.0 -or
        [double]$frustum[5] -le [double]$frustum[4] -or
        [int]$frustum[6] -ne 0) {
        throw "Retail camera observation $cameraIndex does not match frame $expectedFrame and its configured shot."
    }
}
$spawnedReference = [uint32]$templateEvents[0].referenceForm
$requestedRuntimeForm = [Convert]::ToUInt32($runtimeForm, 16)
$templateObservation = $templateEvents[0]
$runtimeBaseFormTypeProperty =
    $telemetryPolicy.recordTypeRuntimeFormTypes.PSObject.Properties[[string]$job.recordType]
if ($null -eq $runtimeBaseFormTypeProperty) {
    throw "Retail telemetry policy has no runtime form type for '$($job.recordType)'."
}
$expectedRuntimeBaseType = [int]$runtimeBaseFormTypeProperty.Value
$observedRuntimeBase = [uint32]$templateObservation.runtimeBaseForm
$runtimeBaseTemporary = [bool]$templateObservation.runtimeBaseTemporary
$temporaryRuntimeFormIndex = [int]$telemetryPolicy.temporaryRuntimeFormIndex
$runtimeLineage = $templateObservation.leveledExtra
if (-not [bool]$templateObservation.baseReadable -or
    [uint32]$templateObservation.requestedBaseForm -ne $requestedRuntimeForm -or
    [uint32]$templateObservation.referenceForm -ne $spawnedReference -or
    $observedRuntimeBase -eq 0 -or
    [int]$templateObservation.runtimeBaseType -ne $expectedRuntimeBaseType) {
    throw 'Retail actor template observation does not bind the requested base, spawned reference, and runtime base.'
}
if ($runtimeBaseTemporary) {
    if ([int]$templateObservation.runtimeBaseModIndex -ne $temporaryRuntimeFormIndex -or
        $null -eq $runtimeLineage -or -not [bool]$runtimeLineage.readable -or
        [uint32]$runtimeLineage.baseForm -ne $requestedRuntimeForm -or
        [uint32]$runtimeLineage.form -eq 0) {
        throw 'Retail temporary actor base has no complete stable leveled lineage.'
    }
}
elseif ($observedRuntimeBase -ne $requestedRuntimeForm -or
    [int]$templateObservation.runtimeBaseModIndex -eq $temporaryRuntimeFormIndex) {
    throw 'Retail stable actor base differs from the requested base.'
}
$snapshotFaults = @($events | Where-Object {
    [string]$_.event -eq [string]$telemetryPolicy.visualSnapshotFaultEvent
})
if ($snapshotFaults.Count -ne 0) {
    throw "Retail actor observation reported $($snapshotFaults.Count) visual-snapshot fault(s)."
}
$visualSnapshots = @($events | Where-Object {
    [string]$_.event -eq [string]$telemetryPolicy.visualSnapshotEvent
})
$expectedSnapshotCount = $orderedScreenshotFrames.Count *
    [int]$telemetryPolicy.requiredVisualSnapshotsPerSourceFrame
if ($visualSnapshots.Count -ne $expectedSnapshotCount) {
    throw "Retail capture retained $($visualSnapshots.Count) actor visual snapshots; expected $expectedSnapshotCount."
}
$appearanceSnapshots = [Collections.Generic.List[object]]::new()
$snapshotSummaries = [Collections.Generic.List[object]]::new()
foreach ($expectedFrame in $orderedScreenshotFrames) {
    $frameSnapshots = @($visualSnapshots | Where-Object {
        [int]$_.requestedFrame -eq [int]$expectedFrame
    })
    if ($frameSnapshots.Count -ne [int]$telemetryPolicy.requiredVisualSnapshotsPerSourceFrame) {
        throw "Retail frame $expectedFrame does not have exactly one actor visual snapshot."
    }
    $snapshot = $frameSnapshots[0]
    $nodes = @($snapshot.nodes)
    if ([int]$snapshot.frame -ne [int]$expectedFrame -or
        [uint32]$snapshot.refForm -ne $spawnedReference -or
        [uint32]$snapshot.baseForm -ne $observedRuntimeBase -or
        $null -eq $snapshot.rootWorld -or
        $nodes.Count -lt [int]$telemetryPolicy.minimumNamedNodesPerSnapshot) {
        throw "Retail actor visual snapshot for frame $expectedFrame has invalid actor, root, or named-node identity."
    }
    foreach ($node in $nodes) {
        if ([string]::IsNullOrWhiteSpace([string]$node.name) -or
            [string]::IsNullOrWhiteSpace([string]$node.nodePath) -or
            $null -eq $node.transform -or
            @($node.transform.localRotation).Count -ne 9 -or
            @($node.transform.localTranslation).Count -ne 3 -or
            @($node.transform.worldRotation).Count -ne 9 -or
            @($node.transform.worldTranslation).Count -ne 3) {
            throw "Retail actor visual snapshot for frame $expectedFrame contains an incomplete named-node transform."
        }
    }
    if (@($nodes.nodePath | Sort-Object -Unique).Count -ne $nodes.Count) {
        throw "Retail actor visual snapshot for frame $expectedFrame contains duplicate node paths."
    }
    $skinPalettes = @($snapshot.skinPalettes)
    $skinPaletteCapture = $snapshot.skinPaletteCapture
    if ($null -eq $skinPaletteCapture -or [bool]$skinPaletteCapture.traversalTruncated -or
        [int]$skinPaletteCapture.invalidPalettes -ne 0 -or
        [int]$skinPaletteCapture.skinInstances -ne $skinPalettes.Count -or
        [int]$skinPaletteCapture.capturedPalettes +
            [int]$skinPaletteCapture.notRenderCached -ne $skinPalettes.Count) {
        throw "Retail actor visual snapshot for frame $expectedFrame has incomplete skin-palette traversal."
    }
    foreach ($palette in $skinPalettes) {
        if ([string]$palette.status -ceq 'not-render-cached') {
            if ([int64]$palette.matrixCount -ne 0 -or
                [int64]$palette.registersPerMatrix -ne 0 -or
                [int64]$palette.allocatedBytes -ne 0 -or
                [int64]$palette.matrixBytes -ne 0) {
                throw "Retail actor visual snapshot for frame $expectedFrame has inconsistent uncached skin data at $($palette.nodePath)."
            }
            continue
        }
        $matrixFloatCount = [int64]$palette.matrixCount *
            [int64]$palette.registersPerMatrix *
            [int64]$telemetryPolicy.skinPaletteComponentsPerRegister
        if ([string]$palette.status -cne 'captured' -or
            [string]::IsNullOrWhiteSpace([string]$palette.nodePath) -or
            [int]$palette.componentsPerRegister -ne
                [int]$telemetryPolicy.skinPaletteComponentsPerRegister -or
            [int64]$palette.matrixBytes -ne $matrixFloatCount *
                [int64]$telemetryPolicy.skinPaletteBytesPerComponent -or
            [int64]$palette.matrixBytes -gt
                [int64]$telemetryPolicy.skinPaletteMaximumBytesPerShape -or
            [int64]$palette.allocatedBytes -lt [int64]$palette.matrixBytes -or
            @($palette.bones).Count -ne [int64]$palette.matrixCount -or
            -not (Test-FiniteNumberArray @($palette.matrices) $matrixFloatCount)) {
            throw "Retail actor visual snapshot for frame $expectedFrame contains an invalid skin palette at $($palette.nodePath)."
        }
    }
    if (@($skinPalettes.nodePath | Sort-Object -Unique).Count -ne $skinPalettes.Count) {
        throw "Retail actor visual snapshot for frame $expectedFrame contains duplicate skin-palette node paths."
    }
    if ($null -ne $snapshot.appearance) {
        $appearanceSnapshots.Add($snapshot)
    }
    $snapshotSummaries.Add([pscustomobject][ordered]@{
        frame = [int]$snapshot.frame
        requestedFrame = [int]$snapshot.requestedFrame
        shotKind = [string]$shotFrameKinds[[int]$expectedFrame]
        namedNodeCount = $nodes.Count
        geometryCandidateCount = [int]$skinPaletteCapture.geometryCandidates
        skinPaletteCount = $skinPalettes.Count
        cachedSkinPaletteCount = [int]$skinPaletteCapture.capturedPalettes
        uncachedSkinInstanceCount = [int]$skinPaletteCapture.notRenderCached
        appearanceRetained = $null -ne $snapshot.appearance
        appearanceComplete = $null -ne $snapshot.appearance -and
            [bool]$snapshot.appearance.complete
        appearanceRenderPartCount = if ($null -ne $snapshot.appearance) {
            @($snapshot.appearance.renderParts).Count
        } else { 0 }
    })
}
if ($appearanceSnapshots.Count -ne [int]$telemetryPolicy.requiredAppearanceSnapshots) {
    throw "Retail capture retained $($appearanceSnapshots.Count) appearance snapshots; expected exactly one."
}
$appearanceSnapshot = $appearanceSnapshots[0].appearance
$appearanceFrame = [int]$appearanceSnapshots[0].frame
if ([string]$appearanceSnapshot.schema -cne [string]$telemetryPolicy.appearanceSchema) {
    throw "Retail appearance snapshot schema '$($appearanceSnapshot.schema)' does not match '$($telemetryPolicy.appearanceSchema)'."
}
if ([bool]$appearanceSnapshot.truncated -or
    @($appearanceSnapshot.renderParts).Count -lt 1) {
    throw 'Retail appearance snapshot is truncated or contains no resolved render parts.'
}
$appearancePoseEvents = @($events | Where-Object {
    [string]$_.event -ceq [string]$telemetryPolicy.poseEvent -and
    [int]$_.frame -eq $appearanceFrame
})
if ($appearancePoseEvents.Count -ne 1) {
    throw "Retail appearance frame $appearanceFrame does not have exactly one pose sample."
}
$equippedWeapon = $appearanceSnapshot.equippedWeapon
if ($null -eq $equippedWeapon) {
    throw 'Retail appearance snapshot has no equipped-weapon contract.'
}
$equippedWeaponState = [string]$equippedWeapon.state
$equippedWeaponRenderState = [string]$equippedWeapon.renderState
if ($null -eq $equippedWeapon.PSObject.Properties['weaponOut'] -or
    $equippedWeapon.weaponOut -isnot [bool]) {
    throw 'Retail equipped-weapon contract has no Boolean weaponOut state.'
}
$equippedWeaponOut = [bool]$equippedWeapon.weaponOut
$equippedWeaponNodeProperty = $equippedWeapon.PSObject.Properties['nodePresent']
if ($null -eq $equippedWeaponNodeProperty -or
    $equippedWeaponNodeProperty.Value -isnot [bool]) {
    throw 'Retail equipped-weapon contract has no Boolean nodePresent state.'
}
$equippedWeaponNodePresent = [bool]$equippedWeaponNodeProperty.Value
$equippedWeaponModelPath = [string]$equippedWeapon.modelPath
$canonicalEquippedWeaponModelPath = $equippedWeaponModelPath.Trim().Replace('\', '/').ToLowerInvariant()
$equippedWeaponModelPathIsCanonical = -not [string]::IsNullOrEmpty($equippedWeaponModelPath) -and
    $canonicalEquippedWeaponModelPath -ceq $equippedWeaponModelPath -and
    $canonicalEquippedWeaponModelPath.EndsWith('.nif', [StringComparison]::Ordinal) -and
    -not $canonicalEquippedWeaponModelPath.StartsWith('/', [StringComparison]::Ordinal) -and
    -not $canonicalEquippedWeaponModelPath.Contains('../', [StringComparison]::Ordinal)
$equippedWeaponFormText = [string]$equippedWeapon.sourceFormId
if ($equippedWeaponFormText -notmatch '^0x[0-9A-F]{8}$') {
    throw "Retail equipped-weapon FormID '$equippedWeaponFormText' is not canonical."
}
$equippedWeaponForm = [Convert]::ToUInt32($equippedWeaponFormText.Substring(2), 16)
$poseWeaponOutProperty = $appearancePoseEvents[0].PSObject.Properties['weaponOut']
if ($null -eq $poseWeaponOutProperty -or $poseWeaponOutProperty.Value -isnot [bool]) {
    throw "Retail pose at appearance frame $appearanceFrame has no Boolean weaponOut state."
}
$poseWeaponOut = [bool]$poseWeaponOutProperty.Value
$poseWeaponForm = [uint32]$appearancePoseEvents[0].weaponForm
$visibleWeaponParts = @($appearanceSnapshot.renderParts | Where-Object {
    [string]$_.role -ceq 'weapon' -and [bool]$_.visible
})
switch -CaseSensitive ($equippedWeaponState) {
    'none' {
        if ($equippedWeaponForm -ne 0 -or $poseWeaponForm -ne 0 -or
            $equippedWeaponRenderState -cne 'not-applicable' -or
            $equippedWeaponOut -or $poseWeaponOut -or
            $equippedWeaponNodePresent -or
            -not [string]::IsNullOrEmpty($equippedWeaponModelPath) -or
            $visibleWeaponParts.Count -ne 0) {
            throw 'Retail no-weapon appearance state disagrees with the live pose or render parts.'
        }
    }
    'equipped' {
        if ($equippedWeaponForm -eq 0 -or $poseWeaponForm -ne $equippedWeaponForm -or
            $equippedWeaponOut -ne $poseWeaponOut) {
            throw 'Retail equipped-weapon appearance disagrees with the same-frame live pose.'
        }
        switch -CaseSensitive ($equippedWeaponRenderState) {
            'visible-source-bound' {
                $matchingWeaponParts = @($visibleWeaponParts | Where-Object {
                    [string]$_.sourceFormId -ceq $equippedWeaponFormText -and
                    [string]$_.modelPath -ceq $equippedWeaponModelPath -and
                    [bool]$_.required -and [bool]$_.attached -and [bool]$_.drawable
                })
                if (-not $equippedWeaponNodePresent -or
                    -not $equippedWeaponModelPathIsCanonical -or
                    $matchingWeaponParts.Count -lt 1) {
                    throw 'Retail equipped-weapon appearance does not have one authoritative visible runtime attachment.'
                }
            }
            'not-visible-at-frame' {
                if ($equippedWeaponOut -or $visibleWeaponParts.Count -ne 0) {
                    throw 'Retail nonvisible equipped-weapon state disagrees with the same-frame pose or render parts.'
                }
                if (-not [string]::IsNullOrEmpty($equippedWeaponModelPath) -and
                    -not $equippedWeaponModelPathIsCanonical) {
                    throw 'Retail nonvisible equipped-weapon model path is not canonical.'
                }
            }
            'unreadable' {
                if ([bool]$appearanceSnapshot.complete) {
                    throw 'Retail appearance cannot be complete when equipped-weapon render state is unreadable.'
                }
            }
            default {
                throw "Retail appearance has unknown equipped-weapon render state '$equippedWeaponRenderState'."
            }
        }
    }
    'unreadable' {
        if ($equippedWeaponRenderState -cne 'unreadable' -or
            [bool]$appearanceSnapshot.complete) {
            throw 'Retail appearance cannot be complete when equipped-weapon state is unreadable.'
        }
    }
    default {
        throw "Retail appearance has unknown equipped-weapon state '$equippedWeaponState'."
    }
}
$appearanceFaults = @($appearanceSnapshot.faults | ForEach-Object { [string]$_ })
if (($appearanceFaults.Count -eq 0) -ne [bool]$appearanceSnapshot.complete -or
    @($appearanceFaults | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -ne 0 -or
    @($appearanceFaults | Sort-Object -Unique).Count -ne $appearanceFaults.Count) {
    throw 'Retail appearance snapshot completeness and fault codes disagree.'
}
$appearanceEvidenceStatus = if ([bool]$appearanceSnapshot.complete) {
    'complete'
} else {
    'incomplete-runtime-attachment-evidence'
}
$surfaceContractEvents = @($events | Where-Object {
    [string]$_.event -eq [string]$surfaceContractPolicy.event
})
$drawTargetEvents = @($events | Where-Object {
    [string]$_.event -eq [string]$surfaceContractPolicy.targetTexturesEvent
})
$drawTargetFaults = @($events | Where-Object {
    [string]$_.event -eq 'actor-draw-contract-target-textures-fault'
})
if ($drawTargetFaults.Count -ne 0 -or $drawTargetEvents.Count -ne 1 -or
    @($drawTargetEvents[0].textures).Count -lt 1) {
    throw 'Actor surface capture did not retain one nonempty target-texture registry.'
}
if ($surfaceContractEvents.Count -ne $orderedScreenshotFrames.Count) {
    throw "Actor surface capture retained $($surfaceContractEvents.Count) source-frame events; expected $($orderedScreenshotFrames.Count)."
}
$surfaceFrameSummaries = [Collections.Generic.List[object]]::new()
$matrixTolerance = [double]$surfaceContractPolicy.matrixTolerance
foreach ($expectedFrame in $orderedScreenshotFrames) {
    $frameEvents = @($surfaceContractEvents | Where-Object {
        [int]$_.sourceFrame -eq [int]$expectedFrame
    })
    if ($frameEvents.Count -ne 1) {
        throw "Actor surface contract frame $expectedFrame is missing or duplicated."
    }
    $surfaceEvent = $frameEvents[0]
    $surface = $surfaceEvent.surface
    if ([int]$surfaceEvent.frame -ne [int]$expectedFrame -or
        [int]$surfaceEvent.renderFrameLead -ne
            [int]$surfaceContractPolicy.renderFrameLead -or
        -not [bool]$surfaceEvent.targetTexturesReady -or
        [int]$surfaceEvent.captureCount -ne 1 -or $null -eq $surface) {
        throw "Actor surface contract frame $expectedFrame is missing one captured surface."
    }
    $transforms = $surface.fixedFunctionTransforms
    $projection = @($transforms.projection)
    $renderTarget = $surface.renderTarget
    $targetDescription = $renderTarget.renderTargetDescription
    $backBufferDescription = $renderTarget.backBufferDescription
    $viewport = $renderTarget.viewport
    $scissor = $renderTarget.scissor
    $matrixElementCount = [int]$surfaceContractPolicy.matrixElementCount
    $worldTransformFinite = Test-FiniteNumberArray `
        -Values @($transforms.world) -ExpectedCount $matrixElementCount
    $viewTransformFinite = Test-FiniteNumberArray `
        -Values @($transforms.view) -ExpectedCount $matrixElementCount
    $projectionTransformFinite = Test-FiniteNumberArray `
        -Values $projection -ExpectedCount $matrixElementCount
    if ([int]$surface.sourceFrame -ne [int]$expectedFrame -or
        [int]$surface.renderFrame -ne [int]$expectedFrame -
            [int]$surfaceContractPolicy.renderFrameLead -or
        [string]::IsNullOrWhiteSpace([string]$surface.matchedTexture.path) -or
        [int]$surface.vertexShader.getResult -ne 0 -or
        [int]$surface.vertexShader.getFunctionResult -ne 0 -or
        [int]$surface.vertexShader.byteCount -le 0 -or
        [uint32]$surface.vertexShader.fnv1a32 -eq 0 -or
        -not [bool]$surface.vertexShader.hasBonesParameter -or
        -not [bool]$surface.vertexShader.hasSkinModelViewProjectionParameter -or
        [int]$transforms.worldResult -ne 0 -or
        [int]$transforms.viewResult -ne 0 -or
        [int]$transforms.projectionResult -ne 0 -or
        -not $worldTransformFinite -or
        -not $viewTransformFinite -or
        -not $projectionTransformFinite -or
        [int]$renderTarget.renderTargetResult -ne 0 -or
        [int]$renderTarget.renderTargetDescriptionResult -ne 0 -or
        [int]$renderTarget.backBufferResult -ne 0 -or
        [int]$renderTarget.backBufferDescriptionResult -ne 0 -or
        [int]$renderTarget.renderTargetIdentityResult -ne 0 -or
        [int]$renderTarget.backBufferIdentityResult -ne 0 -or
        -not [bool]$renderTarget.matchesBackBufferDimensions -or
        [int]$targetDescription.width -le 0 -or
        [int]$targetDescription.height -le 0 -or
        [int]$targetDescription.width -ne [int]$backBufferDescription.width -or
        [int]$targetDescription.height -ne [int]$backBufferDescription.height -or
        [int]$viewport.getResult -ne 0 -or
        [int]$viewport.x -ne 0 -or [int]$viewport.y -ne 0 -or
        [int]$viewport.width -ne [int]$targetDescription.width -or
        [int]$viewport.height -ne [int]$targetDescription.height -or
        [Math]::Abs([double]$viewport.minimumZ -
            [double]$surfaceContractPolicy.normalizedDepthMinimum) -gt $matrixTolerance -or
        [Math]::Abs([double]$viewport.maximumZ -
            [double]$surfaceContractPolicy.normalizedDepthMaximum) -gt $matrixTolerance -or
        [int]$scissor.getResult -ne 0 -or
        [int]$scissor.left -ne 0 -or [int]$scissor.top -ne 0 -or
        [int]$scissor.right -ne [int]$targetDescription.width -or
        [int]$scissor.bottom -ne [int]$targetDescription.height -or
        [double]$projection[0] -le 0 -or [double]$projection[5] -le 0 -or
        [Math]::Abs([double]$projection[11] -
            [double]$surfaceContractPolicy.perspectiveWTerm) -gt $matrixTolerance -or
        [Math]::Abs([double]$projection[15] -
            [double]$surfaceContractPolicy.homogeneousBottomRight) -gt $matrixTolerance) {
        throw "Actor surface contract frame $expectedFrame is not one complete final-eye skinned source-resolution scene-color draw."
    }
    $surfaceFrameSummaries.Add([pscustomobject][ordered]@{
        sourceFrame = [int]$expectedFrame
        renderFrame = [int]$surface.renderFrame
        texture = [string]$surface.matchedTexture.path
        vertexShaderFnv1a32 = [uint32]$surface.vertexShader.fnv1a32
        backBufferWidth = [int]$backBufferDescription.width
        backBufferHeight = [int]$backBufferDescription.height
        projection = @($projection)
        verticalFovRadians = 2.0 * [Math]::Atan(1.0 / [double]$projection[5])
    })
}
$surfaceContractSummary = [pscustomobject][ordered]@{
    finalEyeSourceResolutionSceneColorRequired = $true
    skinnedShaderRequired = $true
    targetTextureCount = @($drawTargetEvents[0].textures).Count
    renderFrameLead = [int]$surfaceContractPolicy.renderFrameLead
    sourceFrames = @($surfaceFrameSummaries)
}
$drawContractSummary = $null
$drawContractEvents = @($events | Where-Object {
    [string]$_.event -eq [string]$drawContractPolicy.event
})
if ($ActorDrawContractDiagnostic) {
    if ($drawContractEvents.Count -ne $orderedScreenshotFrames.Count) {
        throw "Actor draw-contract diagnostic retained $($drawContractEvents.Count) source-frame events; expected $($orderedScreenshotFrames.Count)."
    }
    $drawFrameSummaries = [Collections.Generic.List[object]]::new()
    foreach ($expectedFrame in $orderedScreenshotFrames) {
        $frameEvents = @($drawContractEvents | Where-Object {
            [int]$_.sourceFrame -eq [int]$expectedFrame
        })
        if ($frameEvents.Count -ne 1) {
            throw "Actor draw-contract diagnostic frame $expectedFrame is missing or duplicated."
        }
        $drawEvent = $frameEvents[0]
        $records = @($drawEvent.records)
        if ([int]$drawEvent.frame -ne [int]$expectedFrame -or
            [int]$drawEvent.renderFrameLead -ne
                [int]$drawContractPolicy.renderFrameLead -or
            -not [bool]$drawEvent.targetTexturesReady -or
            [int]$drawEvent.maximumRecords -ne
                [int]$drawContractPolicy.maximumRecordsPerSourceFrame -or
            $records.Count -lt 1 -or $records.Count -gt
                [int]$drawContractPolicy.maximumRecordsPerSourceFrame) {
            throw "Actor draw-contract diagnostic frame $expectedFrame has invalid timing, registry, or record count."
        }
        $completeShaderRecords = 0
        $sourceResolutionRecords = 0
        $surfaceShaderRecords = 0
        $surfaceShaderHash = [uint32](@($surfaceContractEvents | Where-Object {
            [int]$_.sourceFrame -eq [int]$expectedFrame
        })[0].surface.vertexShader.fnv1a32)
        foreach ($record in $records) {
            $constants = @($record.vertexConstants.values)
            $recordTarget = $record.renderTarget
            if ([int]$record.sourceFrame -ne [int]$expectedFrame -or
                [int]$record.renderFrame -ne [int]$expectedFrame -
                    [int]$drawContractPolicy.renderFrameLead -or
                [string]::IsNullOrWhiteSpace([string]$record.matchedTexture.path) -or
                [int]$record.vertexConstants.registerCount -ne
                    [int]$drawContractPolicy.vertexShaderRegisterCount -or
                $constants.Count -ne
                    [int]$drawContractPolicy.vertexShaderRegisterCount * 4 -or
                [int]$recordTarget.renderTargetResult -ne 0 -or
                [int]$recordTarget.renderTargetDescriptionResult -ne 0 -or
                [int]$recordTarget.backBufferResult -ne 0 -or
                [int]$recordTarget.backBufferDescriptionResult -ne 0 -or
                [int]$recordTarget.renderTargetIdentityResult -ne 0 -or
                [int]$recordTarget.backBufferIdentityResult -ne 0) {
                throw "Actor draw-contract diagnostic frame $expectedFrame contains an invalid draw record."
            }
            if ([bool]$recordTarget.matchesBackBufferDimensions) {
                ++$sourceResolutionRecords
                if ([uint32]$record.vertexShader.fnv1a32 -eq $surfaceShaderHash) {
                    ++$surfaceShaderRecords
                }
            }
            if ([int]$record.vertexShader.getResult -eq 0 -and
                [int]$record.vertexShader.getFunctionResult -eq 0 -and
                [int]$record.vertexShader.byteCount -gt 0 -and
                [bool]$record.vertexShader.artifact.written -and
                [int]$record.vertexConstants.getResult -eq 0 -and
                @($record.vertexDeclaration.elements).Count -gt 0) {
                $shaderPath = [IO.Path]::GetFullPath([string]$record.vertexShader.artifact.path)
                if (-not (Test-Path -LiteralPath $shaderPath -PathType Leaf) -or
                    -not $shaderPath.StartsWith(
                        [IO.Path]::GetFullPath($drawArtifactDirectory) +
                            [IO.Path]::DirectorySeparatorChar,
                        [StringComparison]::OrdinalIgnoreCase) -or
                    (Get-Item -LiteralPath $shaderPath).Length -ne
                        [int64]$record.vertexShader.artifact.bytes) {
                    throw "Actor draw-contract shader artifact is missing or outside its immutable directory: $shaderPath"
                }
                ++$completeShaderRecords
            }
        }
        if ($completeShaderRecords -lt 1 -or $sourceResolutionRecords -lt 1 -or
            $surfaceShaderRecords -lt 1) {
            throw "Actor draw-contract diagnostic frame $expectedFrame contains no complete replayable copy of its final-eye surface draw."
        }
        $drawFrameSummaries.Add([pscustomobject][ordered]@{
            sourceFrame = [int]$expectedFrame
            renderFrame = [int]$expectedFrame -
                [int]$drawContractPolicy.renderFrameLead
            recordCount = $records.Count
            completeShaderRecordCount = $completeShaderRecords
            sourceResolutionRecordCount = $sourceResolutionRecords
            surfaceShaderRecordCount = $surfaceShaderRecords
            vertexBufferArtifacts = @($records | Where-Object {
                [bool]$_.vertexBuffer.artifact.written
            }).Count
            indexBufferArtifacts = @($records | Where-Object {
                [bool]$_.indexBuffer.artifact.written
            }).Count
        })
    }
    $drawContractSummary = [pscustomobject][ordered]@{
        diagnosticOnly = $true
        targetTextureCount = @($drawTargetEvents[0].textures).Count
        renderFrameLead = [int]$drawContractPolicy.renderFrameLead
        sourceFrames = @($drawFrameSummaries)
    }
}
elseif ($drawContractEvents.Count -ne 0) {
    throw 'Actor draw-contract events were retained without the explicit diagnostic switch.'
}
$actorFrames = @($events | Where-Object {
    [string]$_.event -eq [string]$telemetryPolicy.poseEvent -and
        [uint32]$_.refForm -eq $spawnedReference
})
if ($actorFrames.Count -lt [int]$telemetryPolicy.minimumPoseSamples) {
    throw 'Retail capture did not retain enough spawned-actor animation frames.'
}
if (@($actorFrames | Where-Object {
        [uint32]$_.baseForm -ne $observedRuntimeBase
    }).Count -ne 0) {
    throw 'Retail spawned-actor pose samples changed runtime base identity.'
}
$jsonlBytes = (Get-Item -LiteralPath $jsonlPath).Length
if ($jsonlBytes -gt [int64]$telemetryPolicy.maximumJsonlBytes) {
    throw "Compact actor telemetry is $jsonlBytes bytes; policy maximum is $($telemetryPolicy.maximumJsonlBytes)."
}
$scheduledEvents = @($events | Where-Object { [string]$_.event -eq 'scheduled-console-command' })
if ($scheduledEvents.Count -ne $scheduledCommands.Count -or
    @($scheduledEvents | Where-Object { -not [bool]$_.accepted }).Count -ne 0) {
    throw 'Actor observation did not accept its complete in-process schedule.'
}

$observedStableForms = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$leveledExtra = $templateEvents[0].leveledExtra
foreach ($runtimeSourceForm in @(
    [uint32]$leveledExtra.form,
    [uint32]$templateEvents[0].templateActorForm,
    [uint32]$templateEvents[0].subtypeTemplateForm
)) {
    if ($runtimeSourceForm -eq 0 -or $runtimeSourceForm -eq $requestedRuntimeForm) { continue }
    $stableForm = ConvertTo-StableFormKey $runtimeSourceForm $runtimePlugins
    if ($null -ne $stableForm) { [void]$observedStableForms.Add($stableForm) }
}

$classificationCandidates = [Collections.Generic.List[object]]::new()
$classificationMethod = 'pending-insufficient-runtime-lineage'
if ($reviewRows.Count -eq 1) {
    $classificationCandidates.Add($reviewRows[0])
    $classificationMethod = 'single-declared-outcome-with-validated-runtime-identity'
}
elseif ($observedStableForms.Count -gt 0) {
    foreach ($row in $reviewRows) {
        $rowForms = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($source in @($row.categorySources.PSObject.Properties.Value)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$source)) {
                [void]$rowForms.Add([string]$source)
            }
        }
        foreach ($path in @($row.templateSelectionPaths)) {
            foreach ($source in @($path)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$source)) {
                    [void]$rowForms.Add([string]$source)
                }
            }
        }
        $matchesEveryObservedForm = $true
        foreach ($observedForm in $observedStableForms) {
            if (-not $rowForms.Contains($observedForm)) {
                $matchesEveryObservedForm = $false
                break
            }
        }
        if ($matchesEveryObservedForm) { $classificationCandidates.Add($row) }
    }
    $classificationMethod = 'observed-runtime-lineage-to-declared-template-path'
}
$classifiedReviewKey = if ($classificationCandidates.Count -eq 1) {
    [string]$classificationCandidates[0].reviewKey
} else { $null }
$classificationComplete = $null -ne $classifiedReviewKey
$observationStatus = if ($classificationComplete -and
    $appearanceEvidenceStatus -ceq 'complete') {
    'captured-classified-runtime-observation'
} elseif ($classificationComplete) {
    'captured-classified-incomplete-appearance-evidence'
} else {
    'captured-unclassified-runtime-observation'
}

$motionFrameFiles = [Collections.Generic.List[object]]::new()
foreach ($frame in @($motionShots[0].screenshotFrames | ForEach-Object { [int]$_ })) {
    $expectedName = 'frame-{0:D6}.bmp' -f $frame
    $matches = @($oracleRun.screenshots | Where-Object {
        [IO.Path]::GetFileName([string]$_) -ceq $expectedName
    })
    if ($matches.Count -ne 1) {
        throw "Idle-motion source frame '$expectedName' was not retained exactly once."
    }
    $motionFrameFiles.Add([pscustomobject]@{ frame = $frame; path = [string]$matches[0] })
}
$motionConcatPath = Join-Path $retailDirectory 'idle-motion-source-frames.ffconcat'
$motionConcatLines = [Collections.Generic.List[string]]::new()
$timelineFrameRate = [double]$motionPolicy.timelineFrameRate
for ($frameIndex = 0; $frameIndex -lt $motionFrameFiles.Count; ++$frameIndex) {
    $sourcePath = [string]$motionFrameFiles[$frameIndex].path
    if ($sourcePath.Contains("'")) {
        throw "Idle-motion source path cannot be represented safely in ffconcat: $sourcePath"
    }
    $motionConcatLines.Add("file '$($sourcePath.Replace('\', '/'))'")
    $durationFrames = if ($frameIndex + 1 -lt $motionFrameFiles.Count) {
        [int]$motionFrameFiles[$frameIndex + 1].frame - [int]$motionFrameFiles[$frameIndex].frame
    } else {
        [int]$motionPolicy.tailDurationFrames
    }
    if ($durationFrames -lt 1) { throw 'Idle-motion source frames are not strictly increasing.' }
    $duration = [double]$durationFrames / $timelineFrameRate
    $motionConcatLines.Add('duration ' + $duration.ToString(
        '0.000000000', [Globalization.CultureInfo]::InvariantCulture))
}
$lastMotionPath = [string]$motionFrameFiles[-1].path
$motionConcatLines.Add("file '$($lastMotionPath.Replace('\', '/'))'")
[IO.File]::WriteAllLines(
    $motionConcatPath, $motionConcatLines, [Text.UTF8Encoding]::new($false))
$motionVideoPath = Join-Path $retailDirectory ([string]$motionPolicy.file)
$ffmpegArguments = @(
    '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'concat', '-safe', '0', '-i', $motionConcatPath,
    '-an', '-c:v', [string]$motionPolicy.codec,
    '-preset', [string]$motionPolicy.preset,
    '-crf', [string][int]$motionPolicy.crf,
    '-pix_fmt', [string]$motionPolicy.pixelFormat,
    '-r', [string][int]$motionPolicy.outputFrameRate,
    '-movflags', [string]$motionPolicy.movFlags,
    $motionVideoPath
)
& $ffmpeg.Source @ffmpegArguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $motionVideoPath -PathType Leaf)) {
    throw 'ffmpeg failed to encode the retail idle-motion clip.'
}
$probeJson = (& $ffprobe.Source -v error -select_streams v:0 `
    -show_entries 'stream=codec_name,width,height,avg_frame_rate:format=duration' `
    -of json -- $motionVideoPath) -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0) { throw 'ffprobe failed to inspect the retail idle-motion clip.' }
$motionProbe = $probeJson | ConvertFrom-Json
$motionVideoStreams = @($motionProbe.streams)
if ($motionVideoStreams.Count -ne 1 -or [int]$motionVideoStreams[0].width -lt 1 -or
    [int]$motionVideoStreams[0].height -lt 1 -or [double]$motionProbe.format.duration -le 0) {
    throw 'Retail idle-motion clip lacks one valid video stream and positive duration.'
}
$motionVideoEvidence = [ordered]@{
    file = Get-FileEvidence $motionVideoPath 'retail-idle-motion-video'
    sourceManifest = Get-FileEvidence $motionConcatPath 'retail-idle-motion-source-manifest'
    sourceFrames = @($motionFrameFiles)
    timelineFrameRate = [int]$motionPolicy.timelineFrameRate
    outputFrameRate = [int]$motionPolicy.outputFrameRate
    codec = [string]$motionVideoStreams[0].codec_name
    width = [int]$motionVideoStreams[0].width
    height = [int]$motionVideoStreams[0].height
    durationSeconds = [double]$motionProbe.format.duration
}

$artifacts = [Collections.Generic.List[object]]::new()
foreach ($artifact in @($jsonlPath, [string]$oracleRun.runManifest) +
    @($oracleRun.screenshots) + @($oracleRun.portraitProofCrops) +
    @($motionConcatPath, $motionVideoPath)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$artifact) -and
        (Test-Path -LiteralPath $artifact -PathType Leaf)) {
        $artifacts.Add((Get-FileEvidence $artifact 'retail-actor-observation'))
    }
}
if ($ActorDrawContractDiagnostic) {
    foreach ($artifact in Get-ChildItem -LiteralPath $drawArtifactDirectory -File) {
        $artifacts.Add((Get-FileEvidence $artifact.FullName 'retail-actor-draw-contract'))
    }
}
$reportPath = Join-Path $retailDirectory 'actor-observation-report.json'
$report = [ordered]@{
    schema = 'nikami-fnv-actor-observation/v1'
    status = $observationStatus
    captureJob = $job
    expectedReviewRows = @($reviewRows)
    classifiedReviewKey = $classifiedReviewKey
    classification = [ordered]@{
        complete = $classificationComplete
        method = $classificationMethod
        observedStableForms = @($observedStableForms | Sort-Object)
        candidateReviewKeys = @($classificationCandidates | ForEach-Object { [string]$_.reviewKey })
    }
    evidencePolicy = [ordered]@{
        inventoryIsNotVisualEvidence = $true
        planGenerationIsNotVisualEvidence = $true
        noReviewRowPassed = $true
        runtimeSignatureClassificationPending = -not $classificationComplete
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
    }
    provenance = [ordered]@{
        planManifest = Get-FileEvidence $planManifestPath 'actor-capture-plan-manifest'
        corpusManifest = Get-FileEvidence $corpusManifestPath 'actor-parity-corpus-manifest'
        captureJobs = Get-FileEvidence $jobsPath 'actor-capture-jobs'
        appearanceReview = Get-FileEvidence $appearancePath 'actor-appearance-review-ledger'
        officialPluginStackSha256 = $officialPluginStackSha256
        officialPluginStack = @($corpusInputs)
    }
    runtime = [ordered]@{
        plugins = @($runtimePlugins)
        requestedBaseRuntimeFormId = $runtimeForm
        spawnedReferenceFormId = '{0:x8}' -f $spawnedReference
        templateObservation = $templateEvents[0]
        cameras = @($cameraEvents)
        animationFrameCount = $actorFrames.Count
        animationFirstFrame = [int]$actorFrames[0].frame
        animationLastFrame = [int]$actorFrames[-1].frame
        animationTelemetry = [string]$telemetryPolicy.mode
        visualSnapshotEvent = [string]$telemetryPolicy.visualSnapshotEvent
        visualSnapshots = @($snapshotSummaries)
        skinPalettePolicy = [ordered]@{
            requiredForSkinnedGeometry =
                [bool]$telemetryPolicy.requireSkinPalettesForSkinnedGeometry
            componentsPerRegister =
                [int]$telemetryPolicy.skinPaletteComponentsPerRegister
            bytesPerComponent = [int]$telemetryPolicy.skinPaletteBytesPerComponent
            maximumBytesPerShape =
                [int]$telemetryPolicy.skinPaletteMaximumBytesPerShape
        }
        surfaceContract = $surfaceContractSummary
        drawContractDiagnostic = $drawContractSummary
        appearanceEvidenceStatus = $appearanceEvidenceStatus
        appearanceEvidenceFaults = $appearanceFaults
        appearanceSnapshot = $appearanceSnapshot
        telemetryBytes = $jsonlBytes
        telemetryMaximumBytes = [int64]$telemetryPolicy.maximumJsonlBytes
    }
    capture = [ordered]@{
        method = [string]$recipe.captureMethod
        scheduledCommands = $scheduledCommands
        shots = @($shots)
        sourceFrames = @($oracleRun.screenshots)
        proofCrops = @($oracleRun.portraitProofCrops)
        motionVideo = $motionVideoEvidence
        oracleRunManifest = [string]$oracleRun.runManifest
    }
    artifacts = @($artifacts)
}
Write-ImmutableJson $reportPath $report 30

[pscustomobject][ordered]@{
    schema = 'nikami-fnv-actor-observation-run/v1'
    status = [string]$report.status
    report = $reportPath
    captureJobKey = $CaptureJobKey
    spawnedReferenceFormId = $report.runtime.spawnedReferenceFormId
    artifacts = @($artifacts) + @(Get-FileEvidence $reportPath 'actor-observation-report')
    capture = [pscustomobject][ordered]@{
        method = [string]$recipe.captureMethod
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
    }
}
