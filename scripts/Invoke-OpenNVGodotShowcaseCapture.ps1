[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,
    [string]$WorldsRoot = 'D:\code\nikami-worlds',
    [string]$Godot = 'D:\code\gd\Godot_v4.6.3-stable_win64.exe',
    [string]$AudioDevice = 'Stereo Mix (Realtek(R) Audio)',
    [ValidateRange(60, 240)]
    [int]$CaptureSeconds = 210,
    [ValidateRange(180, 900)]
    [int]$TimeoutSeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing Godot showcase capture: $OutputRoot"
}
$projectRoot = Join-Path $WorldsRoot 'godot-fnv'
$bootstrapPath = Join-Path $projectRoot 'generated\bootstrap.json'
$ringPath = Join-Path $projectRoot 'generated\world\goodsprings-strip-road-route.json'
foreach ($required in @($Godot, $bootstrapPath, $ringPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing Godot showcase input: $required"
    }
}
foreach ($tool in @('ffmpeg', 'ffprobe')) {
    if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw "$tool is required for the canonical Godot showcase capture"
    }
}
$running = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^(Godot|openmw|FalloutNV|nvse_loader).*\.exe$'
})
if ($running.Count -ne 0) {
    throw "Refusing to overlap capture engines: $($running.ProcessId -join ', ')"
}

New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$nativeRoot = Join-Path $OutputRoot 'native-source-frames'
New-Item -ItemType Directory -Path $nativeRoot | Out-Null
$godotLog = Join-Path $OutputRoot 'godot.stdout.log'
$godotConsole = Join-Path $OutputRoot 'godot.console.log'
$godotError = Join-Path $OutputRoot 'godot.stderr.log'
$ffmpegLog = Join-Path $OutputRoot 'ffmpeg.stderr.log'
$ffmpegOutput = Join-Path $OutputRoot 'ffmpeg.stdout.log'
$routeReport = Join-Path $OutputRoot 'godot-route-report.json'
$gateFile = Join-Path $OutputRoot 'capture-gate.open'
$releaseFile = Join-Path $OutputRoot 'capture-release.open'
$videoPath = Join-Path $OutputRoot 'OpenNV-Goodsprings-to-Strip.mp4'

$prior = @{}
foreach ($name in @(
    'FNV_GODOT_SKIP_INTRO', 'FNV_GODOT_AUTOCONTINUE', 'FNV_GODOT_SELF_DRIVE',
    'FNV_GODOT_SHOWCASE_DOOR', 'FNV_GODOT_NATIVE_FRAME_DIR', 'FNV_GODOT_ROUTE_REPORT',
    'FNV_GODOT_CAPTURE_GATE_FILE', 'FNV_GODOT_CAPTURE_RELEASE_FILE',
    'FNV_GODOT_LONG_ROUTE', 'FNV_GODOT_OPENXR'
)) {
    $prior[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$godotProcess = $null
$ffmpegProcess = $null
$startedAt = Get-Date
try {
    $env:FNV_GODOT_SKIP_INTRO = '1'
    $env:FNV_GODOT_AUTOCONTINUE = '1'
    $env:FNV_GODOT_SELF_DRIVE = '1'
    $env:FNV_GODOT_SHOWCASE_DOOR = '0x105228'
    $env:FNV_GODOT_NATIVE_FRAME_DIR = $nativeRoot.Replace('\', '/')
    $env:FNV_GODOT_ROUTE_REPORT = $routeReport.Replace('\', '/')
    $env:FNV_GODOT_CAPTURE_GATE_FILE = $gateFile.Replace('\', '/')
    $env:FNV_GODOT_CAPTURE_RELEASE_FILE = $releaseFile.Replace('\', '/')
    $env:FNV_GODOT_LONG_ROUTE = '1'
    Remove-Item Env:FNV_GODOT_OPENXR -ErrorAction SilentlyContinue

    $godotProcess = Start-Process -FilePath $Godot `
        -ArgumentList @('--path', $projectRoot, '--editor-pid', '0', '--rendering-method', 'gl_compatibility', '--log-file', $godotLog) `
        -RedirectStandardOutput $godotConsole -RedirectStandardError $godotError -PassThru

    $readyDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds - $CaptureSeconds - 10)
    while ([DateTime]::UtcNow -lt $readyDeadline) {
        if ($godotProcess.HasExited) {
            throw "Godot exited before the showcase capture gate (exit $($godotProcess.ExitCode))"
        }
        if ((Test-Path -LiteralPath $godotLog) -and
            ((Get-Content -LiteralPath $godotLog -Raw -ErrorAction SilentlyContinue) -match 'OPENNV_SHOWCASE_CAPTURE_GATE_WAIT')) {
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path -LiteralPath $godotLog) -or
        ((Get-Content -LiteralPath $godotLog -Raw) -notmatch 'OPENNV_SHOWCASE_CAPTURE_GATE_WAIT')) {
        throw 'Godot never reached the engine-owned showcase capture gate'
    }

    # Godot decorates development-build window titles on some Windows builds
    # even after the game requests "OpenNV". Read the title from the exact
    # process we launched, require OpenNV branding, and give that exact title
    # to gdigrab. This is passive process metadata inspection: it performs no
    # focus, activation, input, or other Windows app control.
    $godotProcess.Refresh()
    $captureWindowTitle = [string]$godotProcess.MainWindowTitle
    if ([string]::IsNullOrWhiteSpace($captureWindowTitle)) {
        throw 'Godot reached the capture gate without exposing a recordable window title'
    }
    if ($captureWindowTitle -notmatch '^OpenNV(?:\s|$)' -or $captureWindowTitle -match '(?i)fallout') {
        throw "Godot exposed an unexpected or incorrectly branded title: $captureWindowTitle"
    }
    $captureWindowHandle = $godotProcess.MainWindowHandle
    if ($captureWindowHandle -eq [IntPtr]::Zero) {
        throw 'Godot reached the capture gate without exposing a recordable native window handle'
    }
    $captureWindowInput = 'hwnd=0x{0:x}' -f $captureWindowHandle.ToInt64()

    # ffmpeg intentionally exits nonzero after DirectShow enumeration and
    # writes the device list to stderr. PowerShell 5 surfaces that stderr as a
    # NativeCommandError when the script-wide policy is Stop, so scope the
    # expected probe behavior without weakening the capture itself.
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $audioProbe = ((& ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1) | Out-String)
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($audioProbe -notmatch [regex]::Escape('"' + $AudioDevice + '" (audio)')) {
        throw "Required capture audio device is unavailable: $AudioDevice"
    }

    $ffmpegArgs = @(
        '-hide_banner', '-y',
        '-f', 'gdigrab', '-framerate', '30', '-draw_mouse', '0', '-i', $captureWindowInput,
        '-f', 'dshow', '-i', ('audio="{0}"' -f $AudioDevice),
        '-t', [string]$CaptureSeconds,
        '-map', '0:v:0', '-map', '1:a:0',
        '-c:v', 'h264_nvenc', '-preset', 'p5', '-tune', 'hq', '-rc', 'vbr', '-cq', '18', '-b:v', '0', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', $videoPath
    )
    $ffmpegProcess = Start-Process -FilePath (Get-Command ffmpeg).Source `
        -ArgumentList $ffmpegArgs -RedirectStandardOutput $ffmpegOutput `
        -RedirectStandardError $ffmpegLog -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    if ($ffmpegProcess.HasExited) {
        throw "ffmpeg exited before the route began (exit $($ffmpegProcess.ExitCode))"
    }
    New-Item -ItemType File -Path $gateFile | Out-Null

    if (-not $ffmpegProcess.WaitForExit(($CaptureSeconds + 15) * 1000)) {
        throw 'ffmpeg did not finish its bounded showcase capture'
    }
    $ffmpegProcess.WaitForExit()
    $ffmpegProcess.Refresh()
    $ffmpegExitCode = $ffmpegProcess.ExitCode
    if ($null -ne $ffmpegExitCode -and $ffmpegExitCode -ne 0) {
        throw "ffmpeg showcase recording failed with exit code $ffmpegExitCode"
    }
    New-Item -ItemType File -Path $releaseFile | Out-Null
    if (-not $godotProcess.WaitForExit(20000)) {
        throw 'Godot did not exit after the capture release gate opened'
    }
    $godotProcess.WaitForExit()
    $godotProcess.Refresh()
    $godotExitCode = $godotProcess.ExitCode
    if ($null -ne $godotExitCode -and $godotExitCode -ne 0) {
        throw "Godot showcase route failed with exit code $godotExitCode"
    }
}
finally {
    if ($null -ne $ffmpegProcess -and -not $ffmpegProcess.HasExited) {
        Stop-Process -Id $ffmpegProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $godotProcess -and -not $godotProcess.HasExited) {
        Stop-Process -Id $godotProcess.Id -Force -ErrorAction SilentlyContinue
    }
    foreach ($name in $prior.Keys) {
        if ($null -eq $prior[$name]) {
            Remove-Item ("Env:" + $name) -ErrorAction SilentlyContinue
        }
        else {
            [Environment]::SetEnvironmentVariable($name, [string]$prior[$name], 'Process')
        }
    }
}

if (-not (Test-Path -LiteralPath $routeReport -PathType Leaf)) {
    throw 'The engine-owned Godot showcase route did not emit its report'
}
$route = Get-Content -LiteralPath $routeReport -Raw | ConvertFrom-Json
$nativeFrames = @(Get-ChildItem -LiteralPath $nativeRoot -Filter '*.png' -File | Sort-Object Name)
$probe = & ffprobe -v error -show_entries format=duration,size:stream=codec_type,codec_name,width,height `
    -of json -- $videoPath | ConvertFrom-Json
$duration = [double]$probe.format.duration
$videoStreams = @($probe.streams | Where-Object codec_type -eq 'video')
$audioStreams = @($probe.streams | Where-Object codec_type -eq 'audio')
$expectedPhases = @(
    'walk_to_entry', 'entry_opening', 'interior_walk', 'interior_look',
    'walk_to_exit', 'exit_opening', 'exterior_walkaway',
    'route_walking', 'route_gate_opening',
    'route_walking', 'route_gate_opening',
    'route_walking', 'route_gate_opening', 'route_walking'
)
$phaseSignature = @($route.phases) -join '|'
$expectedPhaseSignature = $expectedPhases -join '|'
$passed = $route.status -eq 'pass' -and
    $route.route -eq 'goodsprings-door-roundtrip-to-strip-v1' -and
    $phaseSignature -eq $expectedPhaseSignature -and
    $nativeFrames.Count -eq 13 -and
    $duration -ge ($CaptureSeconds - 1) -and
    $videoStreams.Count -eq 1 -and $audioStreams.Count -eq 1 -and
    -not [bool]$route.windowsAppControlUsed -and
    -not [bool]$route.foregroundActivationUsed -and
    -not [bool]$route.foregroundInputInjected

$artifacts = @($videoPath, $routeReport, $godotLog, $godotConsole, $godotError, $ffmpegLog) + @($nativeFrames.FullName)
$artifactRows = @($artifacts | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object {
    $item = Get-Item -LiteralPath $_
    [ordered]@{
        path = $item.FullName
        bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$report = [ordered]@{
    schema = 'nikami-opennv-godot-goodsprings-strip-capture/v1'
    status = if ($passed) { 'pass' } else { 'fail' }
    startedAt = $startedAt.ToString('o')
    completedAt = (Get-Date).ToString('o')
    capture = [ordered]@{
        method = 'ffmpeg exact-process-window OpenNV recording with engine-owned Goodsprings-to-Strip self-drive and retained Godot-native framebuffer checkpoints'
        verifiedWindowTitle = $captureWindowTitle
        windowSelection = 'native handle from the exact launched Godot process after OpenNV title verification'
        selfDriven = $true
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        sourceFramesRetained = $true
        outputOverwritten = $false
    }
    route = $route
    media = [ordered]@{
        videoPath = $videoPath
        durationSeconds = $duration
        videoStreamCount = $videoStreams.Count
        audioStreamCount = $audioStreams.Count
        nativeFrameCount = $nativeFrames.Count
    }
    artifacts = $artifactRows
}
$reportPath = Join-Path $OutputRoot 'godot-showcase-report.json'
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 10
if (-not $passed) {
    throw "Godot showcase capture failed acceptance; inspect $reportPath"
}
