[CmdletBinding()]
param(
    [string]$OutputRoot = "run/fnv-strip-sniper-cinematic",
    [string]$BinaryRoot = "local/openmw-pristine-mads-33568a",
    [string]$GraphicsConfig = "config/fnv-cinematic-graphics",
    [string]$ProfileDirectory = "profiles/fallout_new_vegas",
    [string]$Target = "FormId:0x010efb24",
    [ValidateRange(1, 100000)]
    [int]$TargetHealth = 250,
    [ValidateRange(30, 600)]
    [int]$TimeoutSeconds = 120,
    [switch]$KeepFrames
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Stop-CaptureProcesses {
    $captureProcesses = @(Get-Process -Name openmw -ErrorAction SilentlyContinue)
    if ($captureProcesses.Count -gt 0) {
        $captureProcesses | Stop-Process -Force
        Start-Sleep -Milliseconds 300
    }
    if (Get-Process -Name openmw -ErrorAction SilentlyContinue) {
        throw "OpenMW capture processes did not stop."
    }
}

function Remove-CheckedCaptureDirectory([string]$CaptureDirectory, [string]$AllowedRoot) {
    $resolvedCapture = [IO.Path]::GetFullPath($CaptureDirectory)
    $resolvedRoot = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $requiredPrefix = $resolvedRoot + [IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path $resolvedCapture -Leaf
    if (-not $resolvedCapture.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not $leaf.StartsWith("capture-", [StringComparison]::Ordinal)) {
        throw "Refusing to remove capture directory outside the output root: $resolvedCapture"
    }
    Remove-Item -LiteralPath $resolvedCapture -Recurse -Force
}

$binaryRootPath = Resolve-RepoPath $BinaryRoot
$binary = Join-Path $binaryRootPath "openmw.exe"
$resources = Join-Path $binaryRootPath "resources"
$profile = Resolve-RepoPath $ProfileDirectory
$graphicsConfigPath = Resolve-RepoPath $GraphicsConfig
$nativeScreenshotDirectory = Join-Path $profile "userdata\screenshots"
$outputRootPath = Resolve-RepoPath $OutputRoot
$mp4Path = Join-Path $outputRootPath "FNV-Strip-Sniper-Cinematic.mp4"
$contactPath = Join-Path $outputRootPath "contact-sheet.png"
$telemetryPath = Join-Path $outputRootPath "telemetry.log"
$manifestPath = Join-Path $outputRootPath "manifest.json"

foreach ($requiredPath in @($binary, $resources, $profile, $graphicsConfigPath, $nativeScreenshotDirectory)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required path not found: $requiredPath"
    }
}
if (Get-Process -Name openmw -ErrorAction SilentlyContinue) {
    throw "openmw.exe is already running. Close it before starting the deterministic capture."
}

$ffmpeg = Get-Command ffmpeg -ErrorAction Stop
$ffprobe = Get-Command ffprobe -ErrorAction Stop
New-Item -ItemType Directory -Path $outputRootPath -Force | Out-Null

$captureId = "capture-" + (Get-Date -Format "yyyyMMdd-HHmmss")
$captureDirectory = Join-Path $outputRootPath $captureId
$framesDirectory = Join-Path $captureDirectory "frames"
New-Item -ItemType Directory -Path $framesDirectory -Force | Out-Null

$engineFrames = New-Object System.Collections.Generic.List[int]
for ($frame = 120; $frame -le 420; $frame += 2) {
    $engineFrames.Add($frame)
}
$engineFrameText = ($engineFrames -join ",")

$environment = [ordered]@{
    OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI = "1"
    OPENMW_PROOF_SCREENSHOT_FRAME = $engineFrameText
    OPENMW_WORLD_VIEWER_START_WORLDSPACE = "FormId:0x0113b308"
    OPENMW_WORLD_VIEWER_START_GRID_X = "0"
    OPENMW_WORLD_VIEWER_START_GRID_Y = "0"
    OPENMW_WORLD_VIEWER_START_POS_X = "800"
    OPENMW_WORLD_VIEWER_START_POS_Y = "-200"
    OPENMW_WORLD_VIEWER_START_POS_Z = "1030"
    OPENMW_WORLD_VIEWER_START_CAMERA_MODE = "static"
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_FRAMES = "0,180,230,270,340"
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_EYE_X = "1100,690,1100,610,1100"
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_EYE_Y = "-60,-330,-60,100,-60"
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_EYE_Z = "1190,1110,1190,1100,1190"
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_TARGET_X = "800,800,800,800,800"
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_TARGET_Y = "-50,-200,-50,100,-50"
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_TARGET_Z = "1060,1075,1060,1070,1060"
    OPENMW_WORLD_VIEWER_TIME_SEQUENCE_FRAMES = "1"
    OPENMW_WORLD_VIEWER_TIME_SEQUENCE_HOURS = "18.5"
    OPENMW_PROOF_HIDE_GUI = "1"
    OPENMW_PROOF_HIDE_PLAYER_VISUAL = "1"
    OPENMW_FNV_DISABLE_AI_PACKAGES = "1"
    OPENMW_FNV_DISABLE_PACKAGE_PROCEDURE = "1"
    OPENMW_FNV_DISABLE_PACKAGE_PREPLACEMENT = "1"
    OPENMW_PROOF_SAY_ACTORS = "FormId:0x011740c4"
    OPENMW_PROOF_ACTOR_BATCH_WARMUP_FRAMES = "120"
    OPENMW_PROOF_ACTOR_BATCH_FORCE_BASE_SPAWN = "1"
    OPENMW_PROOF_PLACE_ACTOR_IF_MISSING = "1"
    OPENMW_PROOF_SAY_FRAME = "30"
    OPENMW_PROOF_SUPPRESS_ACTOR_AI = "1"
    OPENMW_PROOF_STAGE_ACTOR = "1"
    OPENMW_PROOF_ACTOR_STAGE_X = "800"
    OPENMW_PROOF_ACTOR_STAGE_Y = "-200"
    OPENMW_PROOF_ACTOR_STAGE_Z = "1030"
    OPENMW_PROOF_ACTOR_STAGE_ROT_X = "0"
    OPENMW_PROOF_ACTOR_STAGE_ROT_Y = "0"
    OPENMW_PROOF_ACTOR_STAGE_ROT_Z = "0"
    OPENMW_PROOF_PIN_STAGED_ACTOR = "1"
    OPENMW_FNV_STRIP_SNIPER_CINEMATIC = "1"
    OPENMW_FNV_STRIP_SNIPER_TRIGGER_FRAME = "240"
    OPENMW_FNV_STRIP_SNIPER_MAX_HOLD_FRAMES = "150"
    OPENMW_FNV_STRIP_SNIPER_TARGET = $Target
    OPENMW_FNV_STRIP_SNIPER_TARGET_HEALTH = [string]$TargetHealth
    OPENMW_FNV_STRIP_SNIPER_TARGET_X = "800"
    OPENMW_FNV_STRIP_SNIPER_TARGET_Y = "100"
    OPENMW_FNV_STRIP_SNIPER_TARGET_Z = "1030"
    OPENMW_FNV_STRIP_SNIPER_TARGET_ROT_Z = "3.14159265"
    OPENMW_FNV_STRIP_SNIPER_SLOW_SCALE = "0.35"
    OPENMW_FNV_STRIP_SNIPER_SLOW_FRAMES = "90"
    OPENMW_FNV_STRIP_SNIPER_RESULT_TIMEOUT_FRAMES = "150"
    OPENMW_FNV_STRIP_SNIPER_REACTION_DISTANCE = "72"
    OPENMW_FNV_STRIP_SNIPER_REACTION_LIFT = "20"
    OPENMW_FNV_STRIP_SNIPER_REACTION_RADIANS = "0.35"
    OPENMW_FNV_STRIP_SNIPER_REACTION_RISE_FRAMES = "8"
    OPENMW_FNV_STRIP_SNIPER_REACTION_DURATION_FRAMES = "54"
}

$environmentPrefixes = @("OPENMW_PROOF_", "OPENMW_WORLD_VIEWER_", "OPENMW_FNV_")
$previousEnvironment = @{}
$processEnvironment = [Environment]::GetEnvironmentVariables("Process")
foreach ($keyObject in @($processEnvironment.Keys)) {
    $key = [string]$keyObject
    if ($environmentPrefixes | Where-Object { $key.StartsWith($_, [StringComparison]::Ordinal) }) {
        $previousEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, $null, "Process")
    }
}
foreach ($entry in $environment.GetEnumerator()) {
    if (-not $previousEnvironment.ContainsKey($entry.Key)) {
        $previousEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, "Process")
    }
    [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, "Process")
}

$existingScreenshots = @{}
foreach ($file in @(Get-ChildItem -LiteralPath $nativeScreenshotDirectory -File -Filter "*.png")) {
    $existingScreenshots[$file.FullName] = $true
}

$arguments = @(
    "--replace", "config",
    "--config", $profile,
    "--resources", $resources,
    "--skip-menu",
    "--start", "TheStripWorldNew",
    "--no-sound",
    "--config", $graphicsConfigPath
)

$captureStartedAt = Get-Date
$newScreenshots = @()
try {
    $process = Start-Process -FilePath $binary -ArgumentList $arguments -WorkingDirectory $binaryRootPath `
        -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $newScreenshots = @(Get-ChildItem -LiteralPath $nativeScreenshotDirectory -File -Filter "*.png" |
            Where-Object { -not $existingScreenshots.ContainsKey($_.FullName) } |
            Sort-Object LastWriteTimeUtc, Name)
        if ($process.HasExited -and $newScreenshots.Count -lt $engineFrames.Count) {
            throw "OpenMW exited before capture completed (exit $($process.ExitCode), frames $($newScreenshots.Count)/$($engineFrames.Count))."
        }
    } while ($newScreenshots.Count -lt $engineFrames.Count -and (Get-Date) -lt $deadline)

    if ($newScreenshots.Count -ne $engineFrames.Count) {
        throw "Timed out with $($newScreenshots.Count)/$($engineFrames.Count) native frames."
    }
    Start-Sleep -Milliseconds 500
}
finally {
    Stop-CaptureProcesses
    foreach ($entry in $previousEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
    }
}

for ($index = 0; $index -lt $newScreenshots.Count; ++$index) {
    $destination = Join-Path $framesDirectory ("frame-{0:D4}.png" -f ($index + 1))
    Copy-Item -LiteralPath $newScreenshots[$index].FullName -Destination $destination
}

$activeLogPath = Join-Path $graphicsConfigPath "openmw.log"
if (-not (Test-Path -LiteralPath $activeLogPath)) {
    throw "OpenMW capture log not found: $activeLogPath"
}
$telemetry = @(Select-String -LiteralPath $activeLogPath -Pattern @(
        "FNV Strip sniper cinematic setup:",
        "FNV Strip sniper cinematic combat:",
        "FNV combat shot:",
        "FNV Strip sniper cinematic gate:",
        "FNV Strip sniper cinematic reaction:",
        "FNV Strip sniper cinematic slow time:",
        "FNV combat death:"
    ) | ForEach-Object { $_.Line })
$expectedHealthAfter = [Math]::Max(0, $TargetHealth - 110)
$healthPattern = "healthBefore=$TargetHealth(?:\.0+)? healthAfter=$expectedHealthAfter(?:\.0+)?"
$shotPass = $telemetry | Where-Object { $_ -match "FNV combat shot:.*ammoBefore=8 ammoAfter=7.*actorHit=1.*$healthPattern.*status=pass" }
$gatePass = $telemetry | Where-Object { $_ -match "FNV Strip sniper cinematic gate:.*ammoBefore=8 ammoAfter=7.*$healthPattern.*status=pass" }
$reactionPass = $telemetry | Where-Object {
    $_ -match "FNV Strip sniper cinematic reaction:.*control=(?:damage-driven-transform|death-state).*status=pass"
}
if (-not $shotPass -or -not $gatePass -or -not $reactionPass) {
    throw "Retail sniper telemetry gate did not pass. Capture data remains in $captureDirectory"
}
$telemetry | Set-Content -LiteralPath $telemetryPath -Encoding utf8

$framePattern = Join-Path $framesDirectory "frame-%04d.png"
$impactScriptPath = Join-Path $graphicsConfigPath "strip-sniper-impact.vgs"
if (-not (Test-Path -LiteralPath $impactScriptPath)) {
    throw "Cinematic tracer script not found: $impactScriptPath"
}
$impactFilterPath = $impactScriptPath.Replace("\", "/").Replace(":", "\:")
$damageFontPath = "C\:/Windows/Fonts/arialbd.ttf"
$videoFilter = "[0:v]chromakey=0xff00ff:0.28:0.05[keyed];" +
    "[1:v][keyed]overlay=shortest=1," +
    "eq=gamma=1.12:brightness=0.015:contrast=1.08:saturation=0.88," +
    "drawvg=file='$impactFilterPath':enable='between(t,4.50,4.70)'," +
    "drawtext=fontfile='$damageFontPath':text='-110':x=865:y=135:fontsize=54:fontcolor=0xff3b30:" +
    "borderw=4:bordercolor=black@0.85:enable='between(t,4.57,5.00)'," +
    "drawtext=fontfile='$damageFontPath':text='-110':x=485:y=105:fontsize=58:fontcolor=0xff3b30:" +
    "borderw=4:bordercolor=black@0.85:enable='between(t,5.00,5.60)'," +
    "drawtext=fontfile='$damageFontPath':text='-110':x=585:y=100:fontsize=58:fontcolor=0xff3b30:" +
    "borderw=4:bordercolor=black@0.85:enable='between(t,5.60,6.20)'," +
    "drawbox=x=0:y=0:w=iw:h=70:color=black:t=fill," +
    "drawbox=x=0:y=650:w=iw:h=70:color=black:t=fill," +
    "drawbox=x=0:y=0:w=iw:h=ih:color=white@0.16:t=fill:enable='between(t,4.45,4.53)'," +
    "fade=t=in:st=0:d=0.55,fade=t=out:st=9.25:d=0.8,fps=30,format=yuv420p[v]"
$encodeArguments = @(
    "-hide_banner", "-loglevel", "warning", "-y",
    "-framerate", "15", "-start_number", "1", "-i", $framePattern,
    "-f", "lavfi", "-i", "color=c=0x2b211d:s=1280x720:r=15",
    "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
    "-filter_complex", $videoFilter,
    "-map", "[v]", "-map", "2:a", "-t", "10.066667",
    "-c:v", "libx264", "-preset", "medium", "-crf", "18",
    "-profile:v", "high", "-level", "4.0",
    "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", $mp4Path
)
& $ffmpeg.Source @encodeArguments
if ($LASTEXITCODE -ne 0) {
    throw "MP4 encode failed with exit code $LASTEXITCODE."
}

$contactFilter = "select='eq(n\,12)+eq(n\,60)+eq(n\,108)+eq(n\,120)+eq(n\,132)+" +
    "eq(n\,140)+eq(n\,178)+eq(n\,220)+eq(n\,270)',scale=426:240,tile=3x3"
& $ffmpeg.Source -hide_banner -loglevel error -y -i $mp4Path -vf $contactFilter -frames:v 1 $contactPath
if ($LASTEXITCODE -ne 0) {
    throw "Graded contact-sheet generation failed with exit code $LASTEXITCODE."
}

$probeText = (& $ffprobe.Source -v error -show_entries `
        "format=duration,size,bit_rate:stream=index,codec_name,codec_type,width,height,r_frame_rate,pix_fmt,profile" `
        -of json $mp4Path) -join [Environment]::NewLine
$probe = $probeText | ConvertFrom-Json
$videoStream = $probe.streams | Where-Object codec_type -eq "video" | Select-Object -First 1
$audioStream = $probe.streams | Where-Object codec_type -eq "audio" | Select-Object -First 1
if ($videoStream.codec_name -ne "h264" -or $videoStream.width -ne 1280 -or $videoStream.height -ne 720 -or
    $videoStream.r_frame_rate -ne "30/1" -or $videoStream.pix_fmt -ne "yuv420p" -or
    $audioStream.codec_name -ne "aac" -or [double]$probe.format.duration -lt 10.0) {
    throw "Encoded MP4 metadata validation failed."
}
& $ffmpeg.Source -v error -i $mp4Path -f null -
if ($LASTEXITCODE -ne 0) {
    throw "Full MP4 decode validation failed with exit code $LASTEXITCODE."
}

$binaryHash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
$videoHash = (Get-FileHash -LiteralPath $mp4Path -Algorithm SHA256).Hash
$manifest = [ordered]@{
    schemaVersion = 1
    createdAt = (Get-Date).ToString("o")
    world = [ordered]@{
        game = "Fallout: New Vegas"
        editorId = "TheStripWorldNew"
        worldspace = "FormId:0x0113b308"
        grid = @(0, 0)
        hour = 18.5
    }
    productionForms = [ordered]@{
        ranger = "FormId:0x011740c4"
        weapon = "FormId:0x0108f21c"
        ammo = "FormId:0x0108ecff"
        target = $Target
    }
    capture = [ordered]@{
        nativeFrames = $engineFrames.Count
        engineFrameRange = @(120, 420)
        engineFrameStep = 2
        elapsedSeconds = [math]::Round(((Get-Date) - $captureStartedAt).TotalSeconds, 3)
        graphicsPreset = $graphicsConfigPath
        binary = $binary
        binarySha256 = $binaryHash
    }
    combatGate = [ordered]@{
        exact = $true
        ammoBefore = 8
        ammoAfter = 7
        healthBefore = $TargetHealth
        healthAfter = $expectedHealthAfter
        damage = 110
        actorHit = $true
        targetKilled = $expectedHealthAfter -eq 0
        targetReaction = "72-unit recoil, 20-unit lift, recovery"
        status = "pass"
    }
    output = [ordered]@{
        path = $mp4Path
        sha256 = $videoHash
        bytes = [long]$probe.format.size
        durationSeconds = [double]$probe.format.duration
        video = "H.264 High, 1280x720, 30 fps, yuv420p"
        audio = "AAC LC stereo silence"
        fullDecode = "pass"
        contactSheet = $contactPath
        telemetry = $telemetryPath
    }
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8

foreach ($runtimeFileName in @("openmw.log", "MyGUI.log", "console_history.txt", "shaders.yaml")) {
    $runtimeFile = Join-Path $graphicsConfigPath $runtimeFileName
    if (Test-Path -LiteralPath $runtimeFile) {
        Remove-Item -LiteralPath $runtimeFile -Force
    }
}
if (-not $KeepFrames) {
    Remove-CheckedCaptureDirectory -CaptureDirectory $captureDirectory -AllowedRoot $outputRootPath
}

[pscustomobject]@{
    Status = "pass"
    Mp4 = $mp4Path
    ContactSheet = $contactPath
    Manifest = $manifestPath
    Telemetry = $telemetryPath
    Sha256 = $videoHash
    OpenMWRunning = [bool](Get-Process -Name openmw -ErrorAction SilentlyContinue)
    FfmpegRunning = [bool](Get-Process -Name ffmpeg -ErrorAction SilentlyContinue)
}
