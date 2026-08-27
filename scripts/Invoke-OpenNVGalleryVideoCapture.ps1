[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OpenNvRoot,
    [Parameter(Mandatory)]
    [string]$GalleryManifest,
    [Parameter(Mandatory)]
    [string]$OutputRoot,
    [Parameter(Mandatory)]
    [string]$Godot,
    [ValidateRange(30, 1200)]
    [int]$TimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FileEvidence([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject][ordered]@{
        path = $item.FullName
        bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Assert-FileHash([string]$Path, [string]$ExpectedSha256) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Gallery video input is missing: $Path"
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $ExpectedSha256.ToLowerInvariant()) {
        throw "Gallery video input hash mismatch: $Path"
    }
}

function Get-VideoProbe([string]$Path) {
    $probe = (& ffprobe -v error -show_entries `
        format=duration:stream=codec_type,codec_name,r_frame_rate,nb_frames,width,height `
        -of json -- $Path | Out-String) | ConvertFrom-Json
    $streams = @($probe.streams | Where-Object { [string]$_.codec_type -ceq 'video' })
    if ($streams.Count -ne 1) {
        throw "Gallery media does not contain exactly one video stream: $Path"
    }
    return [ordered]@{
        durationSeconds = [double]::Parse(
            [string]$probe.format.duration,
            [Globalization.CultureInfo]::InvariantCulture)
        codec = [string]$streams[0].codec_name
        rate = [string]$streams[0].r_frame_rate
        frames = [string]$streams[0].nb_frames
        width = [int]$streams[0].width
        height = [int]$streams[0].height
    }
}

$openNvDirectory = [IO.Path]::GetFullPath($OpenNvRoot)
$manifestPath = [IO.Path]::GetFullPath($GalleryManifest)
$outputDirectory = [IO.Path]::GetFullPath($OutputRoot)
$godotPath = [IO.Path]::GetFullPath($Godot)
$runtimeDirectory = Join-Path $openNvDirectory 'runtime'
$projectFile = Join-Path $runtimeDirectory 'OpenNV.csproj'
$runtimeConfigurationPath = Join-Path $runtimeDirectory 'config\open-nv-runtime-v1.json'
$shotRunner = Join-Path $PSScriptRoot 'Invoke-OpenNVGalleryCapture.ps1'
foreach ($path in @($manifestPath, $godotPath, $projectFile,
        $runtimeConfigurationPath, $shotRunner)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Gallery video prerequisite is missing: $path"
    }
}
if (Test-Path -LiteralPath $outputDirectory) {
    throw "Refusing to overwrite OpenNV gallery video output: $outputDirectory"
}
foreach ($command in @('dotnet', 'ffmpeg', 'ffprobe')) {
    if ($null -eq (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Gallery video prerequisite is unavailable: $command"
    }
}
$active = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match '^(Godot.*|openmw|FalloutNV|nvse_loader)$'
})
if ($active.Count -ne 0) {
    throw "Gallery video requires idle engines: $($active.ProcessName -join ', ')"
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$runtimeConfiguration = Get-Content -Raw -LiteralPath $runtimeConfigurationPath | ConvertFrom-Json
$galleryPolicy = $runtimeConfiguration.capture.gallery
$videoPolicy = $galleryPolicy.video
$runtimeConfigurationSha256 =
    (Get-FileHash -LiteralPath $runtimeConfigurationPath -Algorithm SHA256).Hash.ToLowerInvariant()
$jobs = @($manifest.jobs | Sort-Object { [int]$_.ordinal })
if ([string]$manifest.schema -cne 'opennv-owned-gallery-compiled/v5' -or
    [string]$manifest.status -cne 'compiled-owned-authored-gallery-retail-bound' -or
    [bool]$manifest.parityClaimed -or [bool]$manifest.retailCaptureUsed -or
    -not [bool]$manifest.retailEvidenceUsed -or
    [int]$manifest.shotCount -ne $jobs.Count -or $jobs.Count -lt 1 -or
    [string]$manifest.configuration.sha256 -cne $runtimeConfigurationSha256) {
    throw 'Gallery manifest is not a current, configuration-bound retail-evidence gallery.'
}
for ($index = 0; $index -lt $jobs.Count; $index++) {
    $job = $jobs[$index]
    if ([int]$job.ordinal -ne $index + 1 -or
        [string]::IsNullOrWhiteSpace([string]$job.id) -or
        [string]$job.locationClass -cnotin @('interior', 'exterior') -or
        [string]$job.recordType -cnotin @('NPC_', 'CREA')) {
        throw "Gallery manifest job ordering or identity is invalid at index $index."
    }
    Assert-FileHash ([string]$job.cellScene) ([string]$job.cellSceneSha256)
    Assert-FileHash ([string]$job.actorScene) ([string]$job.actorSceneSha256)
    Assert-FileHash ([string]$job.shotContract) ([string]$job.shotContractSha256)
}
$interiorJobs = @($jobs | Where-Object { [string]$_.locationClass -ceq 'interior' })
$exteriorJobs = @($jobs | Where-Object { [string]$_.locationClass -ceq 'exterior' })
if ($interiorJobs.Count -ne [int]$manifest.interiorShots -or
    $exteriorJobs.Count -ne [int]$manifest.exteriorShots -or
    $interiorJobs.Count + $exteriorJobs.Count -ne $jobs.Count) {
    throw 'Gallery manifest location-class totals are inconsistent.'
}

dotnet build $projectFile --configuration Debug --nologo | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw 'OpenNV runtime build failed before gallery video capture.'
}

New-Item -ItemType Directory -Path $outputDirectory | Out-Null
$sourceRoot = Join-Path $outputDirectory 'source-shots'
$segmentRoot = Join-Path $outputDirectory 'segments'
New-Item -ItemType Directory -Path $sourceRoot | Out-Null
New-Item -ItemType Directory -Path $segmentRoot | Out-Null
$targetDurationSeconds =
    [double]$galleryPolicy.framesPerSubject / [double]$galleryPolicy.framesPerSecond
$durationToleranceSeconds =
    [double]$videoPolicy.durationToleranceFrames / [double]$galleryPolicy.framesPerSecond
$durationText = $targetDurationSeconds.ToString(
    [Globalization.CultureInfo]::InvariantCulture)
$startedAt = Get-Date
$segments = [Collections.Generic.List[object]]::new()

foreach ($job in $jobs) {
    $ordinalText = ([int]$job.ordinal).ToString('D3')
    $shotOutput = Join-Path $sourceRoot $ordinalText
    & $shotRunner `
        -OpenNvRoot $openNvDirectory `
        -CellScene ([string]$job.cellScene) `
        -ActorScene ([string]$job.actorScene) `
        -GalleryShot ([string]$job.shotContract) `
        -OutputRoot $shotOutput `
        -Godot $godotPath `
        -CaptureMovie `
        -SkipBuild `
        -TimeoutSeconds $TimeoutSeconds | Out-Null
    $shotReportPath = Join-Path $shotOutput 'opennv-gallery-capture-report.json'
    $shotReport = Get-Content -Raw -LiteralPath $shotReportPath | ConvertFrom-Json
    if ([string]$shotReport.schema -cne 'nikami-opennv-gallery-capture/v3' -or
        [string]$shotReport.status -cne
            'captured-gallery-retail-bound-pending-parity' -or
        -not [bool]$shotReport.engine.authoredMotion.passed -or
        [string]$shotReport.shot.id -cne [string]$job.id) {
        throw "Gallery authored-motion shot failed: $($job.id)"
    }
    $sourceMovie = [string]$shotReport.capture.movie.path
    $segmentPath = Join-Path $segmentRoot (
        $ordinalText + [string]$videoPolicy.deliveryContainerExtension)
    & ffmpeg -hide_banner -loglevel error -y `
        -sseof "-$durationText" -i $sourceMovie -t $durationText -an `
        -r ([string]$galleryPolicy.framesPerSecond) `
        -c:v ([string]$videoPolicy.videoCodec) `
        -pix_fmt ([string]$videoPolicy.pixelFormat) `
        -crf ([string]$videoPolicy.constantRateFactor) `
        -preset ([string]$videoPolicy.encoderPreset) `
        $segmentPath
    if ($LASTEXITCODE -ne 0) {
        throw "Gallery segment encoding failed: $($job.id)"
    }
    $segmentProbe = Get-VideoProbe $segmentPath
    if ([Math]::Abs($segmentProbe.durationSeconds - $targetDurationSeconds) -gt
        $durationToleranceSeconds) {
        throw "Gallery segment duration is outside configured tolerance: $($job.id)"
    }
    $segments.Add([ordered]@{
        ordinal = [int]$job.ordinal
        id = [string]$job.id
        label = [string]$job.label
        location = [string]$job.location
        locationClass = [string]$job.locationClass
        recordType = [string]$job.recordType
        sourceCaptureReport = Get-FileEvidence $shotReportPath
        sourceMovie = Get-FileEvidence $sourceMovie
        segment = Get-FileEvidence $segmentPath
        media = $segmentProbe
        authoredMotion = $shotReport.engine.authoredMotion
        animation = [ordered]@{
            logicalPath = [string]$shotReport.engine.actor.animationSourceLogicalPath
            sha256 = [string]$shotReport.engine.actor.animationSourceSha256
            channels = [int]$shotReport.engine.actor.animationSourceChannels
            tracks = [int]$shotReport.engine.actor.animationTrackCount
            observedProgressSeconds = [double]$shotReport.engine.actor.animationProgressSeconds
        }
    })
}

$concatPath = Join-Path $segmentRoot 'concat.txt'
$concatRows = @($segments | ForEach-Object {
    "file '$(([IO.Path]::GetFileName([string]$_.segment.path)))'"
})
[IO.File]::WriteAllLines($concatPath, $concatRows, [Text.UTF8Encoding]::new($false))
$deliveryPath = Join-Path $outputDirectory ([string]$videoPolicy.deliveryFileName)
& ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i $concatPath `
    -c copy $deliveryPath
if ($LASTEXITCODE -ne 0) {
    throw 'Gallery delivery video join failed.'
}
$deliveryProbe = Get-VideoProbe $deliveryPath
$expectedDeliveryDuration = $jobs.Count * $targetDurationSeconds
$deliveryTolerance = $jobs.Count * $durationToleranceSeconds
if ([Math]::Abs($deliveryProbe.durationSeconds - $expectedDeliveryDuration) -gt
    $deliveryTolerance -or
    [string]$deliveryProbe.codec -cne 'h264') {
    throw 'Gallery delivery video failed its duration or codec gate.'
}

$report = [ordered]@{
    schema = 'nikami-opennv-gallery-video/v1'
    status = 'captured-gallery-video-retail-bound-pending-parity'
    startedAt = $startedAt.ToString('o')
    completedAt = (Get-Date).ToString('o')
    gallery = [ordered]@{
        manifest = Get-FileEvidence $manifestPath
        configuration = Get-FileEvidence $runtimeConfigurationPath
        shotCount = $jobs.Count
        interiorShots = $interiorJobs.Count
        exteriorShots = $exteriorJobs.Count
        framesPerSubject = [int]$galleryPolicy.framesPerSubject
        framesPerSecond = [int]$galleryPolicy.framesPerSecond
        secondsPerSubject = $targetDurationSeconds
        allAuthoredMotionPassed = @($segments | Where-Object {
            -not [bool]$_.authoredMotion.passed
        }).Count -eq 0
    }
    capture = [ordered]@{
        method = 'sequential Godot engine-owned fixed-step movies from current OpenNV owned-data scenes'
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        retailCaptureUsed = $false
        retailEvidenceUsed = $true
        outputOverwritten = $false
        parityClaimed = $false
    }
    delivery = [ordered]@{
        file = Get-FileEvidence $deliveryPath
        media = $deliveryProbe
        expectedDurationSeconds = $expectedDeliveryDuration
    }
    segments = @($segments)
    artifacts = @(
        Get-FileEvidence $manifestPath
        Get-FileEvidence $runtimeConfigurationPath
        Get-FileEvidence $concatPath
        Get-FileEvidence $deliveryPath
    )
}
$reportPath = Join-Path $outputDirectory ([string]$videoPolicy.reportFileName)
[IO.File]::WriteAllText(
    $reportPath,
    ($report | ConvertTo-Json -Depth 40) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 40
