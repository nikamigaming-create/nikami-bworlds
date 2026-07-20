[CmdletBinding()]
param(
    [int]$ObserverSeconds = 70,
    [int]$DialogueSeconds = 45,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Quote-Arg([string]$Value) {
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Clear-OpenMWProofEnvironment {
    $prefixes = @(
        "OPENMW_WORLD_VIEWER_",
        "OPENMW_PROOF_",
        "OPENMW_FNV_",
        "OPENMW_ESM4_",
        "OPENMW_PLAYABLE_"
    )
    foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })) {
        foreach ($prefix in $prefixes) {
            if ($name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                [Environment]::SetEnvironmentVariable($name, $null, "Process")
                break
            }
        }
    }
}

function Stop-ProcessTree {
    param([int]$RootProcessId)
    $all = @(Get-CimInstance Win32_Process)
    $pending = @($RootProcessId)
    $ids = New-Object System.Collections.Generic.List[int]
    while ($pending.Count -gt 0) {
        $current = [int]$pending[0]
        $pending = @($pending | Select-Object -Skip 1)
        $ids.Add($current) | Out-Null
        $pending += @($all | Where-Object { $_.ParentProcessId -eq $current } | ForEach-Object { [int]$_.ProcessId })
    }
    $kill = @($ids.ToArray())
    [array]::Reverse($kill)
    foreach ($id in $kill) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
}

function Wait-ForOpenMWWindow {
    param([int]$TimeoutSeconds = 45)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $window = @(Get-Process openmw -ErrorAction SilentlyContinue | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle)
        } | Select-Object -First 1)
        if ($window.Count -gt 0) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Start-FfmpegCapture {
    param(
        [string]$Path,
        [int]$Seconds,
        [int]$Width = 1280,
        [int]$Height = 720
    )
    $ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
    $args = @(
        "-hide_banner",
        "-y",
        "-f", "gdigrab",
        "-framerate", "30",
        "-i", "title=OpenMW",
        "-f", "dshow",
        "-i", "audio=Stereo Mix (Realtek(R) Audio)",
        "-t", [string]$Seconds,
        "-vf", "scale=${Width}:${Height}",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-crf", "23",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac",
        "-b:a", "160k",
        $Path
    )
    $line = ($args | ForEach-Object { Quote-Arg ([string]$_) }) -join " "
    Start-Process -FilePath $ffmpeg -ArgumentList $line -PassThru -WindowStyle Hidden
}

function Invoke-CaptureSegment {
    param(
        [string]$Name,
        [int]$Seconds,
        [hashtable]$Environment,
        [string[]]$ExtraArgs = @()
    )

    $repoRoot = "D:\code\nikami-worlds-fnv-parity"
    $worldRoot = "D:\code\nikami-worlds"
    $runtimeRoot = "D:\code\nikami-openmw-save330-integrated\MSVC2022_64\RelWithDebInfo"
    $binary = Join-Path $runtimeRoot "openmw.exe"
    $resources = Join-Path $runtimeRoot "resources"
    if (-not (Test-Path -LiteralPath $binary)) { throw "Missing OpenMW binary: $binary" }
    if (-not (Test-Path -LiteralPath $resources)) { throw "Missing OpenMW resources: $resources" }

    $segmentRoot = Join-Path $script:OutputRoot $Name
    $sessionConfig = Join-Path $segmentRoot "session-config"
    $sessionUserData = Join-Path $segmentRoot "user-data"
    New-Item -ItemType Directory -Path $sessionConfig,$sessionUserData -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $sessionConfig "openmw.cfg") `
        -Value ('user-data="{0}"' -f ($sessionUserData -replace '\\', '/')) -Encoding utf8

    $stdout = Join-Path $segmentRoot "openmw.stdout.log"
    $stderr = Join-Path $segmentRoot "openmw.stderr.log"
    $video = Join-Path $segmentRoot "$Name.mp4"

    $args = @(
        "--replace", "config",
        "--config", (Join-Path $worldRoot "profiles\fallout_new_vegas"),
        "--config", (Join-Path $repoRoot "config\playable-baseline"),
        "--config", (Join-Path $repoRoot "config\fnv-playable-graphics"),
        "--config", (Join-Path $repoRoot "config\door-preload"),
        "--config", $sessionConfig,
        "--user-data", $sessionUserData,
        "--resources", $resources,
        "--skip-menu",
        "--start", "Goodsprings",
        "--script-run", (Join-Path $repoRoot "config\starts\fnv-level-one-goodsprings.txt"),
        "--data", "D:\SteamLibrary\steamapps\common\Morrowind\Data Files",
        "--fallback-archive", "Morrowind.bsa"
    ) + $ExtraArgs
    $argumentLine = ($args | ForEach-Object { Quote-Arg ([string]$_) }) -join " "

    Clear-OpenMWProofEnvironment
    foreach ($entry in $Environment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process")
    }

    $game = $null
    $capture = $null
    try {
        $game = Start-Process -FilePath $binary -ArgumentList $argumentLine `
            -WorkingDirectory $runtimeRoot -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if (-not (Wait-ForOpenMWWindow -TimeoutSeconds 60)) {
            throw "OpenMW window did not appear for $Name"
        }
        Start-Sleep -Seconds 2
        $capture = Start-FfmpegCapture -Path $video -Seconds $Seconds
        $capture.WaitForExit(($Seconds + 20) * 1000) | Out-Null
        if (-not $capture.HasExited) {
            Stop-Process -Id $capture.Id -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if ($null -ne $game -and -not $game.HasExited) {
            Stop-ProcessTree -RootProcessId $game.Id
        }
        Clear-OpenMWProofEnvironment
    }

    if (-not (Test-Path -LiteralPath $video)) {
        throw "Capture did not produce $video"
    }
    return $video
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path "D:\code\nikami-worlds-fnv-parity\run\fnv-flat-observation-reel" (Get-Date -Format "yyyyMMdd-HHmmss")
}
$script:OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Path $script:OutputRoot -Force | Out-Null

Get-Process openmw,ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$observerEnv = @{
    OPENMW_PLAYABLE_SESSION = "1"
    OPENMW_PLAYABLE_SESSION_ID = "fnv-flat-observer-goodsprings"
    OPENMW_PLAYABLE_SESSION_SETTLE_FRAMES = "360"
    OPENMW_PLAYABLE_SESSION_DURATION_SECONDS = "45"
    OPENMW_PLAYABLE_SESSION_CAMERA_DISTANCE = "300"
    OPENMW_PLAYABLE_SESSION_FORWARD = "-0.55"
    OPENMW_PLAYABLE_SESSION_STRAFE = "0.18"
    OPENMW_PLAYABLE_SESSION_RUN = "0"
    OPENMW_PLAYABLE_SESSION_ACTOR = "FormId:0x1104c80"
    OPENMW_WORLD_VIEWER_START_POS_X = "-67735"
    OPENMW_WORLD_VIEWER_START_POS_Y = "3204"
    OPENMW_WORLD_VIEWER_START_POS_Z = "8425"
    OPENMW_WORLD_VIEWER_START_ROT_X = "0"
    OPENMW_WORLD_VIEWER_START_ROT_Y = "0"
    OPENMW_WORLD_VIEWER_START_ROT_Z = "-0.6981317"
    OPENMW_WORLD_VIEWER_START_CAMERA_MODE = "thirdperson"
    OPENMW_WORLD_VIEWER_START_CAMERA_DISTANCE = "300"
    OPENMW_WORLD_VIEWER_START_CAMERA_PITCH = "0.1"
    OPENMW_WORLD_VIEWER_START_CAMERA_YAW = "0.7"
    OPENMW_WORLD_VIEWER_START_CAMERA_NUDGE_DISTANCE = "0"
    OPENMW_WORLD_VIEWER_START_DRY = "0"
    OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS = "1"
    OPENMW_WORLD_VIEWER_TELEMETRY = "0"
    OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = "0"
    OPENMW_FNV_BOOTSTRAP_HOUR = "14.45"
}

$dialogueEnv = @{
    OPENMW_FNV_INTERACTION_AUDIT = "1"
    OPENMW_FNV_INTERACTION_SETTLE_FRAMES = "900"
    OPENMW_FNV_INTERACTION_PHASE_TIMEOUT_SECONDS = "45"
    OPENMW_PROOF_DELAY_STARTUP_SCRIPT = "1"
    OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI = "1"
    OPENMW_PROOF_HIDE_FIRST_PERSON = "1"
    OPENMW_WORLD_VIEWER_START_CAMERA_MODE = "thirdperson"
    OPENMW_WORLD_VIEWER_START_CAMERA_DISTANCE = "260"
    OPENMW_WORLD_VIEWER_START_CAMERA_NUDGE_DISTANCE = "0"
    OPENMW_WORLD_VIEWER_TELEMETRY = "0"
    OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = "0"
    OPENMW_FNV_BOOTSTRAP_HOUR = "14.45"
}

$observer = Invoke-CaptureSegment -Name "01-goodsprings-flat-observer" -Seconds $ObserverSeconds -Environment $observerEnv
$dialogue = Invoke-CaptureSegment -Name "02-easy-pete-dialogue-flat" -Seconds $DialogueSeconds -Environment $dialogueEnv

$concatList = Join-Path $script:OutputRoot "concat.txt"
Set-Content -LiteralPath $concatList -Value @(
    "file '$($observer -replace '\\','/')'",
    "file '$($dialogue -replace '\\','/')'"
) -Encoding ascii

$final = Join-Path $script:OutputRoot "fnv-flat-observation-dialogue-reel.mp4"
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$concatArgs = @("-hide_banner", "-y", "-f", "concat", "-safe", "0", "-i", $concatList, "-c", "copy", $final)
$concatLine = ($concatArgs | ForEach-Object { Quote-Arg ([string]$_) }) -join " "
$concat = Start-Process -FilePath $ffmpeg -ArgumentList $concatLine -PassThru -WindowStyle Hidden
$concat.WaitForExit(30000) | Out-Null
if (-not $concat.HasExited -or $concat.ExitCode -ne 0) {
    throw "ffmpeg concat failed"
}

Write-Host "FINAL_VIDEO=$final"
