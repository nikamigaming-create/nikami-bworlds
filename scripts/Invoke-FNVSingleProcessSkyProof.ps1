param(
    [string]$OutputRoot = "run/fnv-sky-single-process",
    [string]$BinaryRoot = "local/openmw-fo4guard",
    [int]$RunSeconds = 30,
    [int]$CaptureSecond = 15,
    [int]$NativeScreenshotWaitSeconds = 15,
    [switch]$KeepRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$slotFrames = @(150, 270, 390, 510, 630, 750)
$captureFrames = @(210, 330, 450, 570, 690, 810)
$hours = @(2, 6.00486183, 12, 18.004568, 12, 22)
$celestialCameraFrames = @($slotFrames[4], $slotFrames[5])
$pitches = @(1.3528525440, 0.7886557)
$yaws = @(-2.2896263264, -0.950687)

$environment = @(
    "OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY=",
    "OPENMW_FNV_PROOF_WEATHER_ID=FormId:0x11237d7",
    "OPENMW_FNV_BOOTSTRAP_HOUR=2",
    "OPENMW_FNV_PROOF_FREEZE_TIME=1",
    "OPENMW_WORLD_VIEWER_TIME_SEQUENCE_FRAMES=$($slotFrames -join ',')",
    "OPENMW_WORLD_VIEWER_TIME_SEQUENCE_HOURS=$($hours -join ',')",
    "OPENMW_WORLD_VIEWER_CAMERA_ANGLE_SEQUENCE_FRAMES=$($celestialCameraFrames -join ',')",
    "OPENMW_WORLD_VIEWER_CAMERA_ANGLE_SEQUENCE_PITCHES=$($pitches -join ',')",
    "OPENMW_WORLD_VIEWER_CAMERA_ANGLE_SEQUENCE_YAWS=$($yaws -join ',')"
)

$invoke = @{
    WorldId = @("fallout_new_vegas")
    Mode = "flat"
    OutputRoot = $OutputRoot
    BinaryRoot = $BinaryRoot
    RunSeconds = $RunSeconds
    CaptureSeconds = @($CaptureSecond)
    EngineScreenshotFrames = ($captureFrames -join ",")
    ExpectedScreenshotCount = $captureFrames.Count
    NativeScreenshotWaitSeconds = $NativeScreenshotWaitSeconds
    SetEnv = $environment
    BackgroundWindow = $true
}
if ($KeepRunning) {
    $invoke.KeepRunning = $true
}

& (Join-Path $PSScriptRoot "Invoke-RealWorldScreenshots.ps1") @invoke
