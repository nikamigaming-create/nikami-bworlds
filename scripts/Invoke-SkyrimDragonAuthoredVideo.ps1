param(
    [ValidateSet(9, 10)]
    [int]$ActorIndex = 9,
    [string]$OutputRoot = "D:\code\nikami-worlds\run\skyrim-dragon-video\authored",
    [string]$BinaryRoot = "D:\code\nikami-worlds\local\openmw-fo4guard"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$portraitRunner = Join-Path $PSScriptRoot "Invoke-SkyrimMainStoryPortraits.ps1"
$animationData = "D:\code\nikami-worlds\run\skyrim-dragon-video\authored-dragon-sequence.bin"
$animationMetadata = [IO.Path]::ChangeExtension($animationData, ".json")
if (-not (Test-Path -LiteralPath $animationData -PathType Leaf)) {
    throw "Missing authored dragon animation stream: $animationData"
}
if (-not (Test-Path -LiteralPath $animationMetadata -PathType Leaf)) {
    throw "Missing authored dragon animation metadata: $animationMetadata"
}
$authored = Get-Content -Raw -LiteralPath $animationMetadata | ConvertFrom-Json
$stageZOffset = -[double]$authored.groundContactOffsetZ

$slug = if ($ActorIndex -eq 9) { "paarthurnax" } else { "alduin" }
$actorRoot = Join-Path $OutputRoot $slug
$videoPath = Join-Path $OutputRoot ("{0}-stand-walk-takeoff.mp4" -f $slug)
$env = @(
    "OPENMW_PROOF_FRAME_RATE_LIMIT=60",
    "OPENMW_PROOF_SKYRIM_AUTHORED_ANIMATION_DATA=$animationData",
    "OPENMW_PROOF_SKYRIM_AUTHORED_ANIMATION_START_DELAY=0.32",
    "OPENMW_PROOF_SKYRIM_AUTHORED_ANIMATION_SECONDS_PER_FRAME=0.0166666667",
    "OPENMW_PROOF_SKYRIM_AUTHORED_ANIMATION_LOOP=0",
    "OPENMW_PROOF_VIDEO_CAPTURE_START_FRAME=120",
    "OPENMW_PROOF_VIDEO_CAPTURE_END_FRAME=1020",
    "OPENMW_PROOF_VIDEO_CAPTURE_FRAME_STEP=1",
    "OPENMW_PROOF_VIDEO_CAPTURE_EXIT_DELAY_FRAMES=8",
    "OPENMW_PROOF_ACTOR_BATCH_EXIT_AFTER_COMPLETE=0",
    "OPENMW_PROOF_ACTOR_VIEW_STATIC_CAMERA=0",
    "OPENMW_PROOF_ACTOR_VIEW_ORBIT_DEGREES=165",
    "OPENMW_PROOF_ACTOR_VIEW_ORBIT_DEGREES_PER_FRAME=0.055",
    "OPENMW_PROOF_ACTOR_VIEW_ORBIT_START_FRAME=200",
    "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_MARGIN=0.02",
    "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_FIT_PADDING=0.95"
)

& $portraitRunner -OutputRoot $actorRoot -BinaryRoot $BinaryRoot `
    -MinIndex $ActorIndex -MaxIndex $ActorIndex -StageZOffset $stageZOffset `
    -RunSeconds 300 -WaitForProcessExit -Overwrite -SetEnv $env

$captureDirectory = Get-ChildItem -LiteralPath $actorRoot -Recurse -File -Filter "screenshot*.png" |
    Where-Object { $_.FullName -match '[\\/]userdata[\\/]screenshots[\\/]' } |
    Sort-Object LastWriteTimeUtc, FullName |
    Select-Object -Last 1 -ExpandProperty DirectoryName
if ([string]::IsNullOrWhiteSpace($captureDirectory)) {
    throw "No native dragon video frames were captured."
}

$frames = @(Get-ChildItem -LiteralPath $captureDirectory -File -Filter "screenshot*.png" |
    Sort-Object Name)
if ($frames.Count -lt 8) {
    throw "Only $($frames.Count) native dragon frames were captured in $captureDirectory."
}

$firstNumber = [int]([regex]::Match($frames[0].BaseName, '\d+$').Value)
$inputPattern = Join-Path $captureDirectory "screenshot%03d.png"
$sourceFrameRate = [Math]::Max(0.5, $frames.Count / [double]$authored.duration)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $videoPath) | Out-Null
& ffmpeg -hide_banner -loglevel warning -y `
    -framerate $sourceFrameRate -start_number $firstNumber -i $inputPattern `
    -vf "fps=60,scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2" `
    -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -movflags +faststart $videoPath
if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed with exit code $LASTEXITCODE" }

$result = [pscustomobject][ordered]@{
    actor = $slug
    source = "Skyrim - Animations.bsa authored HKX"
    clips = @(
        "ground_combatidle",
        "mtforwardground", "mtforwardground", "mtforwardground",
        "mttakeoff45",
        "mtfastforward_flap", "mtfastforward_flap", "mtfastforward_flap", "mtfastforward_flap"
    )
    frames = $frames.Count
    sourceFrameRate = $sourceFrameRate
    captureDirectory = $captureDirectory
    video = $videoPath
    animationData = $animationData
    groundContactBone = [string]$authored.groundContactBone
    groundContactOffsetZ = [double]$authored.groundContactOffsetZ
    appliedStageZOffset = $stageZOffset
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $actorRoot "video.json") -Encoding utf8
$result | Format-List
