param(
    [string]$BinaryRoot = "D:\code\nikami-openmw-actor-life-state\MSVC2022_64\RelWithDebInfo",
    [string]$Savegame = "C:\Users\nbrys\OneDrive\Documents\My Games\FalloutNV\Saves\Nikami10mmGoodsprings222.fos",
    [string]$ProofRoot = "proof/fnv-dirty-dozen-video",
    [int]$FrameStep = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Savegame -PathType Leaf)) {
    throw "Missing native FNV save: $Savegame"
}
if ($FrameStep -lt 1) {
    throw "FrameStep must be at least 1."
}

$locations = @(
    "Goodsprings",
    "Novac",
    "188 Trading Post",
    "Camp McCarran",
    "Gun Runners",
    "Freeside's North Gate",
    "The Strip North Gate",
    "Jacobstown",
    "Mojave Outpost",
    "Sloan",
    "HELIOS One",
    "Camp Golf"
)
$screenshotFrames = ((120..5400 | Where-Object { ($_ - 120) % $FrameStep -eq 0 }) -join ",")
$started = Get-Date

& (Join-Path $PSScriptRoot "Invoke-FlatWorldScreenshots.ps1") `
    -WorldId fallout_new_vegas `
    -BinaryRoot $BinaryRoot `
    -ProofRoot $ProofRoot `
    -RunSeconds 360 `
    -ScreenshotFrames $screenshotFrames `
    -LoadSavegame $Savegame `
    -VideoWidth 1280 `
    -VideoHeight 720 `
    -AllowBadScreenshots `
    -ShowGui `
    -NoTelemetry `
    -WaitForProcessExit `
    -SetEnv @(
        "OPENMW_PROOF_FRAME_RATE_LIMIT=30",
        "OPENMW_FNV_PROOF_TOUR_LOCATIONS=$($locations -join ',')"
    )

$run = Get-ChildItem -LiteralPath $ProofRoot -Directory |
    Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-2) } |
    Sort-Object LastWriteTimeUtc |
    Select-Object -Last 1
if ($null -eq $run) {
    throw "The dirty-dozen harness did not create a proof run."
}

$log = Join-Path $run.FullName "logs\fallout_new_vegas.openmw.log"
if (-not (Test-Path -LiteralPath $log -PathType Leaf)) {
    throw "Missing OpenMW proof log: $log"
}
if (-not (Select-String -LiteralPath $log -SimpleMatch "FNV dirty-dozen tour: result=pass stops=12" -Quiet)) {
    $lastTourLines = Select-String -LiteralPath $log -Pattern "dirty-dozen tour|fast travel rejected" |
        Select-Object -Last 20 |
        ForEach-Object { $_.Line }
    throw "Dirty-dozen acceptance gate failed.`n$($lastTourLines -join [Environment]::NewLine)"
}

$captureDirectory = Join-Path $run.FullName "fallout_new_vegas\userdata\screenshots"
$frames = @(Get-ChildItem -LiteralPath $captureDirectory -File -Filter "screenshot*.png" | Sort-Object Name)
if ($frames.Count -lt 120) {
    throw "Only $($frames.Count) tour frames were captured; at least 120 are required."
}

$firstNumber = [int]([regex]::Match($frames[0].BaseName, "\d+$").Value)
$inputPattern = Join-Path $captureDirectory "screenshot%03d.png"
$video = Join-Path $run.FullName "fnv-dirty-dozen-tour.mp4"
$sourceRate = 30.0 / $FrameStep
& ffmpeg -hide_banner -loglevel warning -y `
    -framerate $sourceRate -start_number $firstNumber -i $inputPattern `
    -vf "fps=30,scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2" `
    -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -movflags +faststart $video
if ($LASTEXITCODE -ne 0) {
    throw "ffmpeg failed with exit code $LASTEXITCODE"
}

$ready = @(Select-String -LiteralPath $log -Pattern "dirty-dozen tour: ready stop=")
$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    savegame = (Resolve-Path -LiteralPath $Savegame).Path
    locations = $locations
    revealedAuthoredMarkers = 320
    passedStops = $ready.Count
    frames = $frames.Count
    sourceFrameRate = $sourceRate
    video = $video
    log = $log
}
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $run.FullName "tour.json") -Encoding utf8
$result | Format-List
