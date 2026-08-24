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
    [int]$TimeoutSeconds = 0
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
if ([string]$telemetryPolicy.mode -cne 'compact-actor-pose-sample' -or
    [string]$telemetryPolicy.poseEvent -cne 'actor-pose-sample' -or
    [int]$telemetryPolicy.minimumPoseSamples -lt 2 -or
    [int]$telemetryPolicy.cameraMatrixElementCount -lt 1 -or
    [int64]$telemetryPolicy.maximumJsonlBytes -lt 1 -or
    @($telemetryPolicy.forbiddenEvents).Count -lt 1) {
    throw 'The actor-observation telemetry policy is incomplete or invalid.'
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
if ($startEvents.Count -ne 1 -or -not [bool]$startEvents[0].compactActorTelemetry) {
    throw 'Retail actor observation did not confirm compact actor telemetry mode.'
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
    if ([int]$cameraEvent.frame -ne $expectedFrame -or
        [string]$cameraEvent.shotKind -cne [string]$shotFrameKinds[$expectedFrame] -or
        -not [bool]$cameraEvent.readable -or
        @($cameraEvent.viewMatrix).Count -ne [int]$telemetryPolicy.cameraMatrixElementCount -or
        @($cameraEvent.projectionMatrix).Count -ne [int]$telemetryPolicy.cameraMatrixElementCount) {
        throw "Retail camera observation $cameraIndex does not match frame $expectedFrame and its configured shot."
    }
}
$spawnedReference = [uint32]$templateEvents[0].referenceForm
$actorFrames = @($events | Where-Object {
    [string]$_.event -eq [string]$telemetryPolicy.poseEvent -and
        [uint32]$_.refForm -eq $spawnedReference
})
if ($actorFrames.Count -lt [int]$telemetryPolicy.minimumPoseSamples) {
    throw 'Retail capture did not retain enough spawned-actor animation frames.'
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
$requestedRuntimeForm = [Convert]::ToUInt32($runtimeForm, 16)
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
$observationStatus = if ($classificationComplete) {
    'captured-classified-runtime-observation'
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
