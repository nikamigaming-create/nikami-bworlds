[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$BinaryRoot = "",
    [string]$SavePath = "",
    [string]$OutputRoot = "",
    [ValidateRange(10, 120)]
    [int]$CaptureSeconds = 45,
    [ValidateRange(30, 300)]
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Quote-ProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-ProfileValue([string]$ConfigPath, [string]$Key) {
    foreach ($line in Get-Content -LiteralPath $ConfigPath) {
        if ($line -match ('^\s*' + [Regex]::Escape($Key) + '\s*=\s*(.+?)\s*$')) {
            return $Matches[1].Trim('"')
        }
    }
    return $null
}

if ([string]::IsNullOrWhiteSpace($BinaryRoot)) {
    throw "FirstSmoke requires an explicit minimally manifested OpenMW runtime root."
}
if ([string]::IsNullOrWhiteSpace($SavePath)) {
    throw "FirstSmoke requires an explicit existing OpenMW-native Goodsprings save."
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    throw "FirstSmoke requires a unique output root."
}

$BinaryRoot = [IO.Path]::GetFullPath($BinaryRoot)
$SavePath = [IO.Path]::GetFullPath($SavePath)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing FirstSmoke output root: $OutputRoot"
}

$exe = Join-Path $BinaryRoot "openmw.exe"
$resources = Join-Path $BinaryRoot "resources"
$runtimeManifest = Join-Path $BinaryRoot "runtime-manifest.json"
$profile = Join-Path $WorldsRoot "profiles\fallout_new_vegas"
$profileConfig = Join-Path $profile "openmw.cfg"
$morrowindConfig = Join-Path $WorldsRoot "profiles\morrowind\openmw.cfg"
$baselineConfig = Join-Path $WorldsRoot "config\playable-baseline"
$graphicsConfig = Join-Path $WorldsRoot "config\fnv-playable-graphics"
$doorConfig = Join-Path $WorldsRoot "config\door-preload"
foreach ($file in @($exe, $runtimeManifest, $SavePath, $profileConfig, $morrowindConfig,
        (Join-Path $baselineConfig "settings.cfg"), (Join-Path $graphicsConfig "settings.cfg"),
        (Join-Path $doorConfig "settings.cfg"))) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Missing FirstSmoke input: $file"
    }
}
if (-not (Test-Path -LiteralPath $resources -PathType Container)) {
    throw "Missing FirstSmoke resources: $resources"
}
if (Get-Process -Name openmw,openmw_vr,FalloutNV -ErrorAction SilentlyContinue) {
    throw "A capture engine is already running. FirstSmoke will not interfere with it."
}

$morrowindData = Get-ProfileValue $morrowindConfig "data"
if ([string]::IsNullOrWhiteSpace($morrowindData)) {
    throw "Unable to resolve the shared OpenMW UI data directory from $morrowindConfig"
}
$morrowindData = [IO.Path]::GetFullPath($morrowindData)

New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$sessionConfig = Join-Path $OutputRoot "session-config"
$userData = Join-Path $OutputRoot "user-data"
New-Item -ItemType Directory -Path $sessionConfig,$userData | Out-Null
[IO.File]::WriteAllText(
    (Join-Path $sessionConfig "openmw.cfg"),
    ('user-data="{0}"' -f ($userData -replace '\\', '/')),
    [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText(
    (Join-Path $sessionConfig "settings.cfg"),
    "[Lua]`r`nlua num threads = 0`r`n",
    [Text.UTF8Encoding]::new($false))

$arguments = @(
    "--replace", "config",
    "--config", $profile,
    "--config", $baselineConfig,
    "--config", $graphicsConfig,
    "--config", $doorConfig,
    "--config", $sessionConfig,
    "--user-data", $userData,
    "--resources", $resources,
    "--data", $morrowindData,
    "--fallback-archive", "Morrowind.bsa",
    "--load-savegame", $SavePath
)
$argumentLine = ($arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join " "
$stdout = Join-Path $OutputRoot "stdout.log"
$stderr = Join-Path $OutputRoot "stderr.log"
$openmwLog = Join-Path $sessionConfig "openmw.log"
$video = Join-Path $OutputRoot "OpenMW-FNV-first-smoke-exact-title.mp4"
$ffmpegLog = Join-Path $OutputRoot "ffmpeg.log"
$startedAt = [DateTime]::UtcNow
$game = $null
$gameExitCode = $null
$ffmpeg = $null
$timedOut = $false
$titleObserved = $false
$previousSmoke = $env:OPENMW_FNV_FIRST_SMOKE
$previousDebug = $env:OPENMW_DEBUG_LEVEL
$previousCrashCatcher = $env:OPENMW_DISABLE_CRASH_CATCHER
$previousFatalDialog = $env:OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG
try {
    $env:OPENMW_FNV_FIRST_SMOKE = "1"
    $env:OPENMW_DEBUG_LEVEL = "INFO"
    $env:OPENMW_DISABLE_CRASH_CATCHER = "1"
    $env:OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG = "1"
    $game = Start-Process -FilePath $exe -ArgumentList $argumentLine -WorkingDirectory $BinaryRoot `
        -WindowStyle Normal -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $titleDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $titleDeadline -and -not $game.HasExited) {
        $game.Refresh()
        if ($game.MainWindowTitle -eq "OpenMW") {
            $titleObserved = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if ($titleObserved) {
        $ffmpegInfo = [Diagnostics.ProcessStartInfo]::new()
        $ffmpegInfo.FileName = "ffmpeg"
        $ffmpegInfo.UseShellExecute = $false
        $ffmpegInfo.CreateNoWindow = $true
        $ffmpegInfo.RedirectStandardInput = $true
        $ffmpegInfo.RedirectStandardOutput = $true
        $ffmpegInfo.RedirectStandardError = $true
        $ffmpegInfo.Arguments = (@("-y", "-hide_banner", "-loglevel", "error",
                "-f", "gdigrab", "-framerate", "30", "-i", "title=OpenMW",
                "-t", [string]$CaptureSeconds, "-c:v", "libx264", "-preset", "veryfast",
                "-pix_fmt", "yuv420p", $video) |
            ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join " "
        $ffmpeg = [Diagnostics.Process]::new()
        $ffmpeg.StartInfo = $ffmpegInfo
        [void]$ffmpeg.Start()
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $game.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $game.Refresh()
    }
    if (-not $game.HasExited) {
        $timedOut = $true
        $game.Kill()
        $game.WaitForExit()
    }
    else {
        $game.WaitForExit()
    }
    $game.Refresh()
    $gameExitCode = $game.ExitCode
}
finally {
    $env:OPENMW_FNV_FIRST_SMOKE = $previousSmoke
    $env:OPENMW_DEBUG_LEVEL = $previousDebug
    $env:OPENMW_DISABLE_CRASH_CATCHER = $previousCrashCatcher
    $env:OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG = $previousFatalDialog
    if ($null -ne $ffmpeg -and -not $ffmpeg.HasExited) {
        try { $ffmpeg.StandardInput.WriteLine("q") } catch {}
        if (-not $ffmpeg.WaitForExit(15000)) { $ffmpeg.Kill(); $ffmpeg.WaitForExit() }
    }
    if ($null -ne $ffmpeg) {
        $ffmpegText = $ffmpeg.StandardOutput.ReadToEnd() + $ffmpeg.StandardError.ReadToEnd()
        [IO.File]::WriteAllText($ffmpegLog, $ffmpegText, [Text.UTF8Encoding]::new($false))
        $ffmpeg.Dispose()
    }
}

$logText = if (Test-Path -LiteralPath $openmwLog) { Get-Content -Raw -LiteralPath $openmwLog } else { "" }
$resultMatch = [regex]::Matches(
    $logText,
    'FNV first smoke: result=(?<result>pass|fail) reason="(?<reason>[^"]*)" movement=(?<movement>[01]) door=(?<door>[01]) container=(?<container>[01])') |
    Select-Object -Last 1
$nativeFrames = @(Get-ChildItem -LiteralPath (Join-Path $userData "screenshots") -Filter '*.png' -File -ErrorAction SilentlyContinue | Sort-Object Name)
$artifacts = [Collections.Generic.List[object]]::new()
$nativeFramePaths = @($nativeFrames | ForEach-Object { $_.FullName })
foreach ($path in @($video, $stdout, $stderr, $openmwLog, $ffmpegLog, $runtimeManifest, $SavePath) + $nativeFramePaths) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $file = Get-Item -LiteralPath $path
        $artifacts.Add([pscustomobject][ordered]@{
            path = $file.FullName
            bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
}
$movement = $null -ne $resultMatch -and $resultMatch.Groups['movement'].Value -eq '1'
$door = $null -ne $resultMatch -and $resultMatch.Groups['door'].Value -eq '1'
$container = $null -ne $resultMatch -and $resultMatch.Groups['container'].Value -eq '1'
$peacefulExitLogged = $logText -match '(?m)^\[[^\]]+\] Quitting peacefully\.\s*$'
$videoRetained = (Test-Path -LiteralPath $video -PathType Leaf) -and (Get-Item -LiteralPath $video).Length -gt 0
$passed = $null -ne $resultMatch -and $resultMatch.Groups['result'].Value -eq 'pass' -and
    $movement -and $door -and $container -and $nativeFrames.Count -ge 4 -and $videoRetained -and
    $titleObserved -and -not $timedOut -and ($gameExitCode -eq 0 -or $peacefulExitLogged)
$reason = if ($null -ne $resultMatch) { $resultMatch.Groups['reason'].Value }
    elseif ($timedOut) { "OpenMW timed out before a first-smoke result" }
    elseif (-not $titleObserved) { "exact OpenMW window title was not observed" }
    else { "OpenMW exited without first-smoke result telemetry" }

$report = [ordered]@{
    schema = "nikami-openmw-fnv-first-smoke/v1"
    status = if ($passed) { "pass" } else { "fail" }
    startedAt = $startedAt.ToString("o")
    completedAt = [DateTime]::UtcNow.ToString("o")
    firstObservedBlocker = if ($passed) { $null } else { $reason }
    source = [ordered]@{
        runtimeRoot = $BinaryRoot
        runtimeManifest = $runtimeManifest
        savePath = $SavePath
        saveSha256 = (Get-FileHash -LiteralPath $SavePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    launch = [ordered]@{
        executable = $exe
        arguments = $arguments
        exitCode = $gameExitCode
        peacefulExitLogged = $peacefulExitLogged
        timedOut = $timedOut
        retailEngineLaunched = $false
        openmwVrLaunched = $false
    }
    capture = [ordered]@{
        method = "OpenMW native ScreenCaptureHandler frames plus ffmpeg gdigrab exact-title transport"
        selfDriven = $true
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        proofStateMutationUsed = $false
        cameraDrivingUsed = $false
        exactTitleObserved = $titleObserved
        nativeFrameCount = $nativeFrames.Count
    }
    assertions = [ordered]@{
        ordinaryExteriorGameplay = $logText -match 'FNV first smoke: exterior-ready cell='
        exteriorMovement = $movement
        authoredDoorTransition = $door
        unlockedContainerOpened = $container
        nativeFramesRetained = $nativeFrames.Count -ge 4
        exactTitleVideoRetained = $videoRetained
    }
    telemetry = [ordered]@{
        resultReason = $reason
        log = $openmwLog
    }
    artifacts = @($artifacts)
}
$reportPath = Join-Path $OutputRoot "first-smoke-report.json"
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 10
if (-not $passed) { throw "OpenMW FirstSmoke failed: $reason. See $reportPath" }
