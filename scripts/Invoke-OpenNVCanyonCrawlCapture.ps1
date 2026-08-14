[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$BinaryRoot = "",
    [string]$OutputRoot = "",
    [ValidateRange(30, 180)]
    [int]$CaptureSeconds = 75,
    [ValidateRange(45, 300)]
    [int]$TimeoutSeconds = 150
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Quote-ProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

if ([string]::IsNullOrWhiteSpace($BinaryRoot)) { throw "Canyon capture requires -BinaryRoot." }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { throw "Canyon capture requires a unique -OutputRoot." }
$BinaryRoot = [IO.Path]::GetFullPath($BinaryRoot)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw "Refusing to overwrite canyon evidence: $OutputRoot" }

$exe = Join-Path $BinaryRoot "openmw.exe"
$resources = Join-Path $BinaryRoot "resources"
$runtimeManifest = Join-Path $BinaryRoot "runtime-manifest.json"
$profile = Join-Path $WorldsRoot "profiles\fallout_new_vegas"
$profileConfig = Join-Path $profile "openmw.cfg"
$morrowindConfig = Join-Path $WorldsRoot "profiles\morrowind\openmw.cfg"
$playableConfig = Join-Path $WorldsRoot "config\playable-baseline"
$graphicsConfig = Join-Path $WorldsRoot "config\fnv-playable-graphics"
foreach ($path in @($exe, $runtimeManifest, $profileConfig, $morrowindConfig,
        (Join-Path $playableConfig "settings.cfg"), (Join-Path $graphicsConfig "settings.cfg"))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing canyon input: $path" }
}
if (-not (Test-Path -LiteralPath $resources -PathType Container)) { throw "Missing resources: $resources" }
if (Get-Process -Name openmw,openmw_vr,FalloutNV -ErrorAction SilentlyContinue) {
    throw "A capture engine is already running; canyon capture will not interfere with it."
}
$honestHearts = "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data\HonestHearts.esm"
if (-not (Test-Path -LiteralPath $honestHearts -PathType Leaf)) { throw "Honest Hearts is not installed: $honestHearts" }
$profileText = Get-Content -Raw -LiteralPath $profileConfig
foreach ($required in @("content=HonestHearts.esm", "fallback-archive=HonestHearts - Main.bsa", "fallback-archive=HonestHearts - Sounds.bsa")) {
    if ($profileText -notmatch ('(?m)^' + [regex]::Escape($required) + '\s*$')) { throw "FNV profile is missing $required" }
}
$morrowindData = $null
foreach ($line in Get-Content -LiteralPath $morrowindConfig) {
    if ($line -match '^\s*data\s*=\s*(.+?)\s*$') { $morrowindData = [IO.Path]::GetFullPath($Matches[1].Trim('"')); break }
}
if ([string]::IsNullOrWhiteSpace($morrowindData)) { throw "Unable to resolve shared UI data." }

New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$sessionConfig = Join-Path $OutputRoot "session-config"
$userData = Join-Path $OutputRoot "user-data"
New-Item -ItemType Directory -Path $sessionConfig,$userData | Out-Null
[IO.File]::WriteAllText((Join-Path $sessionConfig "openmw.cfg"),
    ('user-data="{0}"' -f ($userData -replace '\\','/')), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $sessionConfig "settings.cfg"),
    "[Lua]`r`nlua num threads = 0`r`n", [Text.UTF8Encoding]::new($false))

$arguments = @(
    "--replace", "config", "--config", $profile, "--config", $playableConfig,
    "--config", $graphicsConfig, "--config", $sessionConfig, "--user-data", $userData,
    "--resources", $resources, "--skip-menu", "--start", "FormId:0x300736e",
    "--data", $morrowindData, "--fallback-archive", "Morrowind.bsa"
)
$argumentLine = ($arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join " "
$stdout = Join-Path $OutputRoot "stdout.log"
$stderr = Join-Path $OutputRoot "stderr.log"
$openmwLog = Join-Path $sessionConfig "openmw.log"
$video = Join-Path $OutputRoot "OpenMW-Honest-Hearts-Zion-slow-crawl.mp4"
$ffmpegLog = Join-Path $OutputRoot "ffmpeg.log"
$environment = [ordered]@{
    OPENMW_PLAYABLE_SESSION = "1"
    OPENMW_PLAYABLE_SESSION_ID = "honest-hearts-zion-joshua-camp-slow-crawl"
    OPENMW_PLAYABLE_SESSION_EXIT_AFTER_COMPLETE = "1"
    OPENMW_PLAYABLE_SESSION_DURATION_SECONDS = [string]([Math]::Max(30, $CaptureSeconds - 15))
    OPENMW_PLAYABLE_SESSION_SETTLE_FRAMES = "240"
    OPENMW_PLAYABLE_SESSION_FORWARD = "0.24"
    OPENMW_PLAYABLE_SESSION_STRAFE = "0"
    OPENMW_PLAYABLE_SESSION_RUN = "0"
    OPENMW_PLAYABLE_SESSION_FORCE_LEVEL_ONE = "0"
    OPENMW_PLAYABLE_SESSION_VALIDATE_CAMERAS = "0"
    OPENMW_PLAYABLE_SESSION_REQUIRE_ACTOR = "1"
    OPENMW_PLAYABLE_SESSION_NEUTRALIZE_ACTOR = "0"
    OPENMW_PLAYABLE_SESSION_CAPTURE_SCREENSHOTS = "1"
    OPENMW_PLAYABLE_SESSION_CAMERA_DISTANCE = "150"
    OPENMW_PLAYABLE_SESSION_MIN_DISTANCE = "32"
    OPENMW_PLAYABLE_SESSION_MIN_SPEED = "0.5"
    OPENMW_PLAYABLE_SESSION_MAX_SPEED = "250"
    OPENMW_PLAYABLE_SESSION_MAX_VERTICAL_DRIFT = "1024"
    OPENMW_PLAYABLE_SESSION_MAX_ACTOR_DRIFT = "4096"
    OPENMW_PLAYABLE_SESSION_MAX_ACTOR_DISTANCE = "3072"
    OPENMW_PLAYABLE_SESSION_ACTOR = "FormId:0x30093be"
    OPENMW_WORLD_VIEWER_START_WORLDSPACE = "FormId:0x300683b"
    OPENMW_WORLD_VIEWER_START_GRID_X = "6"
    OPENMW_WORLD_VIEWER_START_GRID_Y = "-8"
    OPENMW_WORLD_VIEWER_START_POS_X = "27800"
    OPENMW_WORLD_VIEWER_START_POS_Y = "-30350"
    OPENMW_WORLD_VIEWER_START_POS_Z = "5050"
    OPENMW_WORLD_VIEWER_START_ROT_X = "0"
    OPENMW_WORLD_VIEWER_START_ROT_Y = "0"
    OPENMW_WORLD_VIEWER_START_ROT_Z = "0"
    OPENMW_WORLD_VIEWER_START_CAMERA_MODE = "thirdperson"
    OPENMW_WORLD_VIEWER_START_CAMERA_DISTANCE = "150"
    OPENMW_WORLD_VIEWER_START_DRY = "0"
    OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS = "1"
    OPENMW_WORLD_VIEWER_TELEMETRY = "0"
    OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = "1"
    OPENMW_DEBUG_LEVEL = "INFO"
    OPENMW_DISABLE_CRASH_CATCHER = "1"
    OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG = "1"
}

$prefixes = @("OPENMW_WORLD_VIEWER_", "OPENMW_PROOF_", "OPENMW_FNV_", "OPENMW_ESM4_", "OPENMW_PLAYABLE_")
$previous = @{}
foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })) {
    if (@($prefixes | Where-Object { $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
}
$startedAt = [DateTime]::UtcNow
$game = $null; $ffmpeg = $null; $titleObserved = $false; $timedOut = $false; $exitCode = $null
try {
    foreach ($entry in $environment.GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process") }
    $game = Start-Process -FilePath $exe -ArgumentList $argumentLine -WorkingDirectory $BinaryRoot `
        -WindowStyle Normal -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $titleDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $titleDeadline) {
        $game.Refresh()
        $titleWindow = @(Get-Process -Name openmw -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -match 'OpenMW' } | Select-Object -First 1)
        if ($titleWindow.Count -gt 0) { $titleObserved = $true; $game = $titleWindow[0]; break }
        Start-Sleep -Milliseconds 100
    }
    if ($titleObserved) {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = "ffmpeg"; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $info.Arguments = (@("-y","-hide_banner","-loglevel","error","-f","gdigrab","-framerate","30",
            "-i","title=OpenMW","-t",[string]$CaptureSeconds,"-c:v","libx264","-preset","veryfast",
            "-pix_fmt","yuv420p",$video) | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join " "
        $ffmpeg = [Diagnostics.Process]::new(); $ffmpeg.StartInfo = $info; [void]$ffmpeg.Start()
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $game.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200; $game.Refresh() }
    if (-not $game.HasExited) { $timedOut = $true; $game.Kill(); $game.WaitForExit() } else { $game.WaitForExit() }
    $game.Refresh(); $exitCode = $game.ExitCode
}
finally {
    foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })) {
        if (@($prefixes | Where-Object { $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
    foreach ($entry in $previous.GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process") }
    if ($null -ne $ffmpeg -and -not $ffmpeg.HasExited) {
        try { $ffmpeg.StandardInput.WriteLine("q") } catch {}
        if (-not $ffmpeg.WaitForExit(15000)) { $ffmpeg.Kill(); $ffmpeg.WaitForExit() }
    }
    if ($null -ne $ffmpeg) {
        [IO.File]::WriteAllText($ffmpegLog, $ffmpeg.StandardOutput.ReadToEnd() + $ffmpeg.StandardError.ReadToEnd(), [Text.UTF8Encoding]::new($false)); $ffmpeg.Dispose()
    }
}

$logText = if (Test-Path -LiteralPath $openmwLog) { Get-Content -Raw -LiteralPath $openmwLog } else { "" }
$nativeFrames = @(Get-ChildItem -LiteralPath (Join-Path $userData "screenshots") -Filter '*.png' -File -ErrorAction SilentlyContinue | Sort-Object Name)
$startLine = @([regex]::Matches($logText, 'Playable session telemetry: phase=start id="honest-hearts-zion-joshua-camp-slow-crawl"[^\r\n]*') | Select-Object -Last 1)
$endLine = @([regex]::Matches($logText, 'Playable session telemetry: phase=end id="honest-hearts-zion-joshua-camp-slow-crawl"[^\r\n]*') | Select-Object -Last 1)
$worldObserved = $logText -match 'FormId:0x0?300683b|NVDLC02ZionCanyon'
$joshuaObserved = $logText -match 'FormId:0x0?30093be|NVDLC02Joshua'
$actorResolved = $startLine.Count -gt 0 -and $startLine[0].Value -match 'actorResolved=1'
$movementPassed = $endLine.Count -gt 0 -and $endLine[0].Value -match 'result=pass'
$videoRetained = (Test-Path -LiteralPath $video -PathType Leaf) -and (Get-Item -LiteralPath $video).Length -gt 0
$passed = $titleObserved -and -not $timedOut -and $worldObserved -and $joshuaObserved -and $actorResolved -and $movementPassed -and $nativeFrames.Count -ge 2 -and $videoRetained
$reason = if (-not $titleObserved) { "exact OpenMW window title was not observed" }
    elseif ($timedOut) { "OpenMW timed out before canyon route completion" }
    elseif (-not $worldObserved) { "Zion Canyon worldspace was not observed" }
    elseif (-not $joshuaObserved -or -not $actorResolved) { "authored Joshua Graham NPC did not resolve in the active Zion cells" }
    elseif (-not $movementPassed) { "slow crawl movement validation did not pass" }
    elseif ($nativeFrames.Count -lt 2) { "fewer than two native frames were retained" }
    elseif (-not $videoRetained) { "exact-title video was not retained" } else { "pass" }
$artifacts = [Collections.Generic.List[object]]::new()
foreach ($path in @($video,$stdout,$stderr,$openmwLog,$ffmpegLog,$runtimeManifest,$honestHearts) + @($nativeFrames.FullName)) {
    if (Test-Path -LiteralPath $path -PathType Leaf) { $f=Get-Item -LiteralPath $path; $artifacts.Add([pscustomobject]@{path=$f.FullName;bytes=$f.Length;sha256=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}) }
}
$report = [ordered]@{
    schema="nikami-openmw-fnv-canyon-crawl/v1"; status=$(if($passed){"pass"}else{"fail"}); firstObservedBlocker=$(if($passed){$null}else{$reason})
    startedAt=$startedAt.ToString("o"); completedAt=[DateTime]::UtcNow.ToString("o")
    route=[ordered]@{dlc="Honest Hearts";worldspace="NVDLC02ZionCanyon";worldspaceFormId="FormId:0x300683b";anchor="Joshua Graham / Angel Cave camp";targetNpc="NVDLC02Joshua";targetNpcFormId="FormId:0x30093be";forwardControl=0.24;run=$false;durationSeconds=[Math]::Max(30,$CaptureSeconds-15)}
    launch=[ordered]@{executable=$exe;arguments=$arguments;exitCode=$exitCode;timedOut=$timedOut;retailEngineLaunched=$false;openmwVrLaunched=$false}
    capture=[ordered]@{selfDriven=$true;windowsAppControlUsed=$false;foregroundActivationUsed=$false;foregroundInputInjected=$false;proofStateMutationUsed=$false;forcedActorsUsed=$false;forcedWeatherUsed=$false;cameraDrivingUsed=$false;exactTitleObserved=$titleObserved;nativeFrameCount=$nativeFrames.Count}
    assertions=[ordered]@{honestHeartsProfileInputsPresent=$true;zionWorldspaceObserved=$worldObserved;authoredJoshuaObserved=$joshuaObserved;authoredNpcResolved=$actorResolved;slowMovementPassed=$movementPassed;nativeFramesRetained=($nativeFrames.Count-ge 2);exactTitleVideoRetained=$videoRetained}
    telemetry=[ordered]@{start=$(if($startLine.Count){$startLine[0].Value}else{$null});end=$(if($endLine.Count){$endLine[0].Value}else{$null});log=$openmwLog}
    artifacts=@($artifacts)
}
$reportPath=Join-Path $OutputRoot "canyon-crawl-report.json"
[IO.File]::WriteAllText($reportPath,($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
$report|ConvertTo-Json -Depth 10
if(-not $passed){throw "OpenMW canyon crawl failed: $reason. See $reportPath"}
