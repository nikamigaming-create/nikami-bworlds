[CmdletBinding()]
param(
    [string]$EngineRoot = "D:\code\nikami-openmw-save330-integrated",
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$ParityRoot = "D:\code\nikami-worlds-fnv-parity",
    [string]$JamRoot = "D:\code\nikami-worlds\local\mods\jam-4.6-original",
    [string]$JamArchive = "D:\code\nikami-worlds\local\mod-depot\archives\jam\Just Assorted Mods-66666-4-6-1717763151.7z",
    [string]$SavePath = "C:\Users\nbrys\OneDrive\Documents\My Games\FalloutNV\Saves\Save 331     Goodsprings  00 17 36.fos",
    [string]$OutputRoot = "",
    [int]$TimeoutSeconds = 120,
    [ValidateRange(5, 600)]
    [int]$CaptureSeconds = 13,
    [switch]$ProofDrive,
    [switch]$FullProofDrive,
    [switch]$SelfDrive,
    [switch]$EnableSound,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($FullProofDrive -and -not $SelfDrive) {
    throw "The canonical full JAM proof is background/self-driven. Re-run with -FullProofDrive -SelfDrive; foreground activation and injected Windows input are forbidden for release evidence."
}

$expectedArchiveSha256 = "D1101470496E7A8231CFF1355DC62E09B63C5BCEFE3974AB1E4AAC272098DF6B"
$expectedPluginSha256 = "CFDC2B1807A57C8861335858DF96A2D08E546F93DFD8C390E8F5905F2694D8DE"
$retailBaselineSpeed = 217.23114
$retailSprintSpeed = 380.05325
$absoluteSpeedTolerance = 0.15

function Quote-Arg([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Write-Utf8NoBom([string]$Path, [string[]]$Lines) {
    [IO.File]::WriteAllLines($Path, $Lines, [Text.UTF8Encoding]::new($false))
}

function Convert-MeasurementText([string]$Text) {
    $result = [ordered]@{}
    foreach ($token in @($Text -split '\s+')) {
        if ($token -notmatch '^(?<name>[^=]+)=(?<value>.*)$') {
            continue
        }
        $name = $Matches["name"]
        $value = $Matches["value"]
        [double]$number = 0
        if ([double]::TryParse(
                $value,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$number)) {
            $result[$name] = $number
        }
        else {
            $result[$name] = $value
        }
    }
    return [pscustomobject]$result
}

function Get-MeasurementValue($Measurements, [string]$Name) {
    if ($null -eq $Measurements -or
        $null -eq $Measurements.PSObject.Properties[$Name]) {
        return $null
    }
    return $Measurements.PSObject.Properties[$Name].Value
}

function Convert-LogClockToSeconds([string]$Clock) {
    if ($Clock -notmatch '^(?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2}(?:\.\d+)?)$') {
        return $null
    }
    return [int]$Matches["hour"] * 3600 +
        [int]$Matches["minute"] * 60 +
        [double]::Parse(
            $Matches["second"], [Globalization.CultureInfo]::InvariantCulture)
}

function Get-LogEventClock([string]$Text, [string]$EventPattern) {
    $matches = [regex]::Matches(
        $Text,
        '(?m)^\[(?<clock>\d{2}:\d{2}:\d{2}\.\d+)[^\]]*\].*' +
            $EventPattern + '.*\r?$'
    )
    if ($matches.Count -eq 0) {
        return $null
    }
    return Convert-LogClockToSeconds $matches[$matches.Count - 1].Groups["clock"].Value
}

function Get-CloudMotionRows([string]$Text, [int]$Layer = 3) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $matches = [regex]::Matches(
        $Text,
        '(?m)^\[(?<clock>\d{2}:\d{2}:\d{2}\.\d+)[^\]]*\].*' +
            'FNV/ESM4 proof: weather cloud motion timers=(?<timers>[^\r\n]+)\r?$'
    )
    foreach ($match in $matches) {
        $timerMatch = [regex]::Match(
            $match.Groups["timers"].Value,
            '(?:^|,)' + [regex]::Escape([string]$Layer) +
                ':(?<value>-?[0-9]+(?:\.[0-9]+)?)'
        )
        if (-not $timerMatch.Success) {
            continue
        }
        $rows.Add([pscustomobject]@{
            clock = Convert-LogClockToSeconds $match.Groups["clock"].Value
            value = [double]::Parse(
                $timerMatch.Groups["value"].Value,
                [Globalization.CultureInfo]::InvariantCulture)
        })
    }
    return @($rows)
}

function Get-CloudMotionRate(
    [object[]]$Rows,
    [double]$StartSeconds,
    [double]$EndSeconds
) {
    $window = @($Rows | Where-Object {
        [double]$_.clock -ge $StartSeconds -and [double]$_.clock -le $EndSeconds
    } | Sort-Object { [double]$_.clock })
    if ($window.Count -lt 2) {
        return $null
    }
    $elapsed = [double]$window[-1].clock - [double]$window[0].clock
    if ($elapsed -le 0) {
        return $null
    }
    $delta = [double]$window[-1].value - [double]$window[0].value
    while ($delta -lt 0) {
        $delta += 4.0
    }
    return $delta / $elapsed
}

function Wait-ForLogPattern(
    [string]$Path,
    [string]$Pattern,
    [Diagnostics.Process]$Process,
    [DateTime]$Deadline
) {
    while ([DateTime]::UtcNow -lt $Deadline) {
        if ($Process.HasExited) {
            throw "OpenMW exited before log marker '$Pattern'."
        }
        if ((Test-Path -LiteralPath $Path) -and
            (Select-String -LiteralPath $Path -Pattern $Pattern -Quiet)) {
            return
        }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
    }
    throw "Timed out waiting for OpenMW log marker '$Pattern'."
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class JamProofInput
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;
    private const uint KeyEventScanCode = 0x0008;

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit, Size = 40)]
    private struct Input
    {
        [FieldOffset(0)]
        public uint Type;
        [FieldOffset(8)]
        public KeyboardInput Keyboard;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, Input[] inputs, int inputSize);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);

    [DllImport("user32.dll")]
    private static extern IntPtr SetActiveWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr SetFocus(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    private static void SendScanCode(ushort scanCode, bool keyUp)
    {
        Input input = new Input();
        input.Type = InputKeyboard;
        input.Keyboard.VirtualKey = 0;
        input.Keyboard.ScanCode = scanCode;
        input.Keyboard.Flags = KeyEventScanCode | (keyUp ? KeyEventKeyUp : 0);
        input.Keyboard.Time = 0;
        input.Keyboard.ExtraInfo = UIntPtr.Zero;
        Input[] inputs = new Input[] { input };
        if (SendInput(1, inputs, Marshal.SizeOf(typeof(Input))) != 1)
            throw new InvalidOperationException("SendInput failed with Win32 error " + Marshal.GetLastWin32Error());
    }

    public static void Down(ushort scanCode)
    {
        SendScanCode(scanCode, false);
    }

    public static void Up(ushort scanCode)
    {
        SendScanCode(scanCode, true);
    }

    public static bool ForceForegroundWindow(IntPtr hWnd)
    {
        uint ignoredProcessId;
        uint currentThread = GetCurrentThreadId();
        uint targetThread = GetWindowThreadProcessId(hWnd, out ignoredProcessId);
        IntPtr previousForeground = GetForegroundWindow();
        uint foregroundThread = GetWindowThreadProcessId(previousForeground, out ignoredProcessId);
        bool attachedForeground = foregroundThread != 0 && foregroundThread != currentThread
            && AttachThreadInput(currentThread, foregroundThread, true);
        bool attachedTarget = targetThread != 0 && targetThread != currentThread
            && targetThread != foregroundThread && AttachThreadInput(currentThread, targetThread, true);
        try
        {
            ShowWindow(hWnd, 9);
            BringWindowToTop(hWnd);
            SetForegroundWindow(hWnd);
            SetActiveWindow(hWnd);
            SetFocus(hWnd);
            return GetForegroundWindow() == hWnd;
        }
        finally
        {
            if (attachedTarget)
                AttachThreadInput(currentThread, targetThread, false);
            if (attachedForeground)
                AttachThreadInput(currentThread, foregroundThread, false);
        }
    }
}
"@

$binary = Join-Path $EngineRoot "MSVC2022_64\RelWithDebInfo\openmw.exe"
$engineResources = Join-Path $EngineRoot "MSVC2022_64\RelWithDebInfo\resources"
$cmakeCache = Join-Path $EngineRoot "MSVC2022_64\CMakeCache.txt"
$profileConfig = Join-Path $WorldsRoot "profiles\fallout_new_vegas"
$baselineConfig = Join-Path $ParityRoot "config\playable-baseline"
$graphicsConfig = Join-Path $ParityRoot "config\fnv-playable-graphics"
$pluginPath = Join-Path $JamRoot "JustAssortedMods.esp"
$providerResource = Join-Path $engineResources "vfs\scripts\omw\fnv\compat\jam_sprint.lua"
$proofRoot = Join-Path $WorldsRoot "proof\jam-full"
$proofContent = Join-Path $proofRoot "fnv-jam-full-proof.omwscripts"

if (-not $SkipBuild) {
    & cmake --build (Join-Path $EngineRoot "MSVC2022_64") --config RelWithDebInfo --target openmw -- /m:4
    if ($LASTEXITCODE -ne 0) {
        throw "JAM compatibility build failed with exit code $LASTEXITCODE."
    }
}

foreach ($required in @(
    $binary,
    $engineResources,
    $cmakeCache,
    $profileConfig,
    $baselineConfig,
    $graphicsConfig,
    $JamArchive,
    $pluginPath,
    $SavePath,
    $providerResource
)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required JAM proof input is missing: $required"
    }
}

$myGuiLibraryEntry = Select-String -LiteralPath $cmakeCache `
    -Pattern '^MyGUI_LIBRARY:FILEPATH=(?<path>.+)$' | Select-Object -First 1
if ($null -eq $myGuiLibraryEntry) {
    throw "The OpenMW CMake cache does not declare MyGUI_LIBRARY."
}
$myGuiLibrary = $myGuiLibraryEntry.Matches[0].Groups["path"].Value
$dependencyRoot = Split-Path -Parent (Split-Path -Parent $myGuiLibrary)
$runtimeBinCandidates = @(
    (Join-Path $dependencyRoot "bin\Release"),
    (Join-Path $dependencyRoot "bin")
)
$runtimeBins = @($runtimeBinCandidates | Where-Object {
    Test-Path -LiteralPath $_ -PathType Container
})
$myGuiRuntime = @($runtimeBins | ForEach-Object {
    Join-Path $_ "MyGUIEngine.dll"
} | Where-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
} | Select-Object -First 1)
if ($myGuiRuntime.Count -ne 1) {
    throw "The matching MyGUIEngine.dll was not found beneath $dependencyRoot."
}
$osgVersionEntry = Select-String -LiteralPath $cmakeCache `
    -Pattern '^OPENSCENEGRAPH_VERSION:INTERNAL=(?<version>.+)$' | Select-Object -First 1
if ($null -eq $osgVersionEntry) {
    throw "The OpenMW CMake cache does not declare OPENSCENEGRAPH_VERSION."
}
$osgVersion = $osgVersionEntry.Matches[0].Groups["version"].Value
$osgPluginRoot = Join-Path $dependencyRoot "plugins"
$osgPluginPath = Join-Path $osgPluginRoot "osgPlugins-$osgVersion"
if (-not (Test-Path -LiteralPath $osgPluginPath -PathType Container)) {
    throw "The matching OpenSceneGraph plugin directory is missing: $osgPluginPath"
}
foreach ($pluginName in @(
    "osgdb_bmp.dll",
    "osgdb_dae.dll",
    "osgdb_dds.dll",
    "osgdb_freetype.dll",
    "osgdb_jpeg.dll",
    "osgdb_osg.dll",
    "osgdb_png.dll",
    "osgdb_serializers_osg.dll",
    "osgdb_tga.dll"
)) {
    $pluginRuntime = Join-Path $osgPluginPath $pluginName
    if (-not (Test-Path -LiteralPath $pluginRuntime -PathType Leaf)) {
        throw "The matching OpenSceneGraph plugin is missing: $pluginRuntime"
    }
}
if (($ProofDrive -or $FullProofDrive) -and -not (Test-Path -LiteralPath $proofContent)) {
    throw "JAM proof driver content is missing: $proofContent"
}

$archiveSha256 = (Get-FileHash -LiteralPath $JamArchive -Algorithm SHA256).Hash
$pluginSha256 = (Get-FileHash -LiteralPath $pluginPath -Algorithm SHA256).Hash
if ($archiveSha256 -ne $expectedArchiveSha256) {
    throw "JAM archive hash is not the Nexus-published 4.6 hash: $archiveSha256"
}
if ($pluginSha256 -ne $expectedPluginSha256) {
    throw "JAM plugin hash changed: $pluginSha256"
}
$dlls = @(Get-ChildItem -LiteralPath $JamRoot -Recurse -File -Filter "*.dll")
if ($dlls.Count -ne 0) {
    throw "Proof input unexpectedly contains DLLs: $($dlls.FullName -join ', ')"
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputRoot = Join-Path $WorldsRoot "run\jam-sprint-native-$stamp"
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$configDir = Join-Path $OutputRoot "config"
$userDataDir = Join-Path $OutputRoot "userdata"
$dataLocalDir = Join-Path $userDataDir "data"
New-Item -ItemType Directory -Force -Path $configDir, $dataLocalDir | Out-Null

$forwardUserData = $userDataDir.Replace('\', '/')
$forwardDataLocal = $dataLocalDir.Replace('\', '/')
$forwardJamRoot = $JamRoot.Replace('\', '/')
$openMwConfig = @(
    "user-data=$forwardUserData"
    "data-local=$forwardDataLocal"
    "data=$forwardJamRoot"
    "replace=content"
    "content=FalloutNV.esm"
    "content=DeadMoney.esm"
    "content=HonestHearts.esm"
    "content=OldWorldBlues.esm"
    "content=LonesomeRoad.esm"
    "content=TribalPack.esm"
    "content=MercenaryPack.esm"
    "content=ClassicPack.esm"
    "content=CaravanPack.esm"
    "content=GunRunnersArsenal.esm"
    "content=JustAssortedMods.esp"
)
if ($ProofDrive -or $FullProofDrive) {
    $openMwConfig += "data=$($proofRoot.Replace('\', '/'))"
    $openMwConfig += "content=fnv-jam-full-proof.omwscripts"
}
Write-Utf8NoBom (Join-Path $configDir "openmw.cfg") $openMwConfig
Write-Utf8NoBom (Join-Path $configDir "settings.cfg") @(
    "[Video]"
    "resolution x = 1280"
    "resolution y = 720"
    "fullscreen = false"
    "window border = false"
    "vsync mode = 0"
    "framerate limit = 60"
    ""
    "[Input]"
    "grab cursor = false"
    "always run = true"
    ""
    "[GUI]"
    "subtitles = true"
    ""
    "[Post Processing]"
    "enabled = true"
)

$stdoutLog = Join-Path $OutputRoot "stdout.log"
$stderrLog = Join-Path $OutputRoot "stderr.log"
$captureStdout = Join-Path $OutputRoot "ffmpeg.stdout.log"
$captureStderr = Join-Path $OutputRoot "ffmpeg.stderr.log"
$videoName = if ($FullProofDrive) {
    "OpenMW-JAM-4.6-full-execution-proof.mp4"
}
else {
    "OpenMW-JAM-4.6-native-sprint-proof.mp4"
}
$videoPath = Join-Path $OutputRoot $videoName
$reportPath = Join-Path $OutputRoot "proof-report.json"

$arguments = @(
    "--replace", "config",
    "--config", $profileConfig,
    "--config", $baselineConfig,
    "--config", $graphicsConfig,
    "--config", $configDir,
    "--user-data", $userDataDir,
    "--data-local", $dataLocalDir,
    "--resources", $engineResources,
    "--skip-menu",
    "--load-savegame", $SavePath
)
if (-not $EnableSound) {
    $arguments += "--no-sound"
}
$argumentLine = ($arguments | ForEach-Object { Quote-Arg $_ }) -join " "
$previousProofYaw = $env:OPENMW_FNV_JAM_PROOF_YAW_DEGREES
$previousProofDrive = $env:OPENMW_FNV_JAM_PROOF_DRIVE
$previousProofAutoMove = $env:OPENMW_FNV_JAM_PROOF_AUTOMOVE
$previousPath = $env:PATH
$previousOsgLibraryPath = $env:OSG_LIBRARY_PATH
$previousFullProofDrive = $env:OPENMW_FNV_JAM_FULL_PROOF
$previousProofWeatherId = $env:OPENMW_FNV_PROOF_WEATHER_ID
try {
    $env:PATH = (@($runtimeBins) + @($previousPath)) -join ";"
    $env:OSG_LIBRARY_PATH = $osgPluginRoot
    $env:OPENMW_FNV_JAM_PROOF_YAW_DEGREES = if ($FullProofDrive) { $null } else { "-15" }
    $env:OPENMW_FNV_JAM_PROOF_DRIVE = if ($ProofDrive) { "1" } else { $null }
    $env:OPENMW_FNV_JAM_PROOF_AUTOMOVE = if ($SelfDrive) { "1" } else { $null }
    $env:OPENMW_FNV_JAM_FULL_PROOF = if ($FullProofDrive) { "1" } else { $null }
    $env:OPENMW_FNV_PROOF_WEATHER_ID = if ($FullProofDrive) { "1" } else { $null }
    $game = Start-Process -FilePath $binary -ArgumentList $argumentLine `
        -WorkingDirectory (Split-Path -Parent $binary) -WindowStyle Normal `
        -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru
}
finally {
    $env:OPENMW_FNV_JAM_PROOF_YAW_DEGREES = $previousProofYaw
    $env:OPENMW_FNV_JAM_PROOF_DRIVE = $previousProofDrive
    $env:OPENMW_FNV_JAM_PROOF_AUTOMOVE = $previousProofAutoMove
    $env:PATH = $previousPath
    $env:OSG_LIBRARY_PATH = $previousOsgLibraryPath
    $env:OPENMW_FNV_JAM_FULL_PROOF = $previousFullProofDrive
    $env:OPENMW_FNV_PROOF_WEATHER_ID = $previousProofWeatherId
}

$ffmpegProcess = $null
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$scanW = [UInt16]0x11
$scanLeftShift = [UInt16]0x2A
try {
    Wait-ForLogPattern -Path $stdoutLog `
        -Pattern 'FNV mod compat: provider=JAM subsystem=sprint state=ready' `
        -Process $game -Deadline $deadline
    if ($FullProofDrive) {
        # The full reel has a deterministic real-time driver. Start recording
        # at its configured marker so chapter one is not lost while waiting
        # for the legacy sprint-only heading preflight.
        Wait-ForLogPattern -Path $stdoutLog `
            -Pattern '\[jam-full-proof\] state=configured source=untouched-JustAssortedMods\.esp' `
            -Process $game -Deadline $deadline
    }
    else {
        Wait-ForLogPattern -Path $stdoutLog `
            -Pattern 'FNV/ESM4 proof: JAM route heading .*status=pass' `
            -Process $game -Deadline $deadline
    }

    while ($game.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $game.Refresh()
    }
    if ($game.MainWindowHandle -eq 0) {
        throw "OpenMW did not expose a capturable window."
    }
    if (-not $SelfDrive) {
        $shell = New-Object -ComObject WScript.Shell
        $focused = $false
        for ($attempt = 0; $attempt -lt 10 -and -not $focused; $attempt++) {
            [void][JamProofInput]::ShowWindow($game.MainWindowHandle, 9)
            [void][JamProofInput]::BringWindowToTop($game.MainWindowHandle)
            [void]$shell.AppActivate($game.Id)
            [void][JamProofInput]::ForceForegroundWindow($game.MainWindowHandle)
            Start-Sleep -Milliseconds 100
            $focused = [JamProofInput]::GetForegroundWindow() -eq $game.MainWindowHandle
        }
        if (-not $focused) {
            Write-Warning "Foreground verification was inconclusive; continuing with the already-restored OpenMW window."
            [void][JamProofInput]::ShowWindow($game.MainWindowHandle, 9)
            [void][JamProofInput]::BringWindowToTop($game.MainWindowHandle)
            [void][JamProofInput]::ForceForegroundWindow($game.MainWindowHandle)
        }
        Start-Sleep -Milliseconds 400
    }

    $ffmpegArgs = @(
        "-hide_banner", "-loglevel", "warning", "-y",
        "-f", "gdigrab", "-framerate", "60", "-draw_mouse", "0",
        "-i", "title=OpenMW", "-t", "$CaptureSeconds",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", $videoPath
    )
    $ffmpegProcess = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgs `
        -WindowStyle Hidden -RedirectStandardOutput $captureStdout `
        -RedirectStandardError $captureStderr -PassThru

    if ($SelfDrive) {
        Start-Sleep -Seconds ([Math]::Max(1, $CaptureSeconds - 1))
    }
    else {
        Start-Sleep -Seconds 2
        [JamProofInput]::Down($scanW)
        Start-Sleep -Seconds 3
        [JamProofInput]::Up($scanW)
        Start-Sleep -Seconds 1
        [JamProofInput]::Down($scanW)
        Start-Sleep -Milliseconds 200
        [JamProofInput]::Down($scanLeftShift)
        Start-Sleep -Seconds 4
        [JamProofInput]::Up($scanLeftShift)
        [JamProofInput]::Up($scanW)
        Start-Sleep -Seconds 2
    }

    $ffmpegProcess.WaitForExit()
    $ffmpegProcess.Refresh()
    $ffmpegExitCode = $ffmpegProcess.ExitCode
    if ($null -ne $ffmpegExitCode -and $ffmpegExitCode -ne 0) {
        throw "ffmpeg capture failed with exit code $($ffmpegProcess.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $videoPath)) {
        throw "ffmpeg did not produce the proof video."
    }
}
finally {
    if (-not $SelfDrive) {
        [JamProofInput]::Up($scanLeftShift)
        [JamProofInput]::Up($scanW)
    }
    if ($null -ne $ffmpegProcess -and -not $ffmpegProcess.HasExited) {
        Stop-Process -Id $ffmpegProcess.Id -Force
    }
    if (-not $game.HasExited) {
        [void]$game.CloseMainWindow()
        if (-not $game.WaitForExit(5000)) {
            Stop-Process -Id $game.Id -Force
        }
    }
}

$logText = if (Test-Path -LiteralPath $stdoutLog) {
    Get-Content -LiteralPath $stdoutLog -Raw
}
else {
    ""
}

if ($FullProofDrive) {
    $expectedScenarios = @(
        "PROVIDER.knvse-animation"
        "JDC.dynamic-crosshair"
        "JHM.hit-marker"
        "JHI.hit-indicator"
        "JHB.hold-breath"
        "JBT.bullet-time"
        "JVS.sprint"
        "JVO.visual-objectives"
        "JWH.weapon-wheel"
        "JLM.loot-menu"
    )
    $expectedPhases = @(
        "probe-labelled-not-jam"
        "override-installed"
        "override-animation-visible"
        "override-removed"
        "original-animation-restored"
        "weapon-ready-idle"
        "walking-spread-expanded"
        "running-or-firing-spread-expanded"
        "stopped-spread-recovered"
        "aim-down-sights-mode"
        "interactable-prompt-coexistence"
        "hostile-system-color"
        "normal-hit-marker"
        "headshot-or-critical-marker"
        "kill-marker"
        "marker-faded"
        "front-indicator"
        "right-indicator"
        "rear-indicator"
        "left-indicator"
        "indicator-faded"
        "aiming-with-baseline-sway"
        "hold-breath-active-and-resource-drained"
        "hold-breath-released-baseline-restored"
        "normal-time-before"
        "bullet-time-active-world-slow-resource-drained"
        "normal-time-restored"
        "baseline-run"
        "sprint-at-speed-turn-and-resource-drain"
        "sprint-release-action-points-recovering"
        "objective-marker-visible"
        "marker-screen-position-updated"
        "distance-updated-while-walking"
        "completed-or-disabled-objective-hidden"
        "wheel-open"
        "slice-one-highlighted"
        "selected-weapon-equipped"
        "wheel-closed"
        "reopened-and-cancel-preserved-weapon"
        "crosshair-container-detected"
        "loot-menu-visible-authoritative-rows"
        "selection-scrolled"
        "single-item-transferred-exactly-once"
        "menu-closed-crosshair-cleared"
    )
    $phaseStartMatches = [regex]::Matches(
        $logText, '\[jam-full-proof\] state=phase-start ')
    $phaseCompleteMatches = [regex]::Matches(
        $logText, '\[jam-full-proof\] state=phase-complete ')
    $missingScenarios = @($expectedScenarios | Where-Object {
        $logText -notmatch [regex]::Escape(
            "[jam-full-proof] state=scenario-complete scenarioId=$_ ")
    })
    $missingPhases = @($expectedPhases | Where-Object {
        $phasePattern = [regex]::Escape(
            "[jam-full-proof] state=phase-start") +
                " scenarioId=[^ ]+ phase=" + [regex]::Escape($_) + " "
        $logText -notmatch $phasePattern
    })
    $compatFailures = @([regex]::Matches(
        $logText,
        '\[obscript-compat\][^\r\n]*state=(unknown-command|unsupported-command|dispatch-error|script-error)'
    ) | ForEach-Object { $_.Value })
    $compatFailures += @([regex]::Matches(
        $logText, 'FNV/ESM4 ObScript unsupported command:[^\r\n]*'
    ) | ForEach-Object { $_.Value })
    $proofFailures = @([regex]::Matches(
        $logText, '\[jam-full-proof\][^\r\n]*state=(error|failed)'
    ) | ForEach-Object { $_.Value })
    $scenarioMeasurementText = [ordered]@{}
    $scenarioMeasurements = [ordered]@{}
    foreach ($scenario in $expectedScenarios) {
        $measurement = [regex]::Matches(
            $logText,
            [regex]::Escape(
                "[jam-full-proof] state=scenario-complete scenarioId=$scenario ") +
                '(?<values>[^\r\n]+)'
        ) | Select-Object -Last 1
        $measurementText = if ($null -ne $measurement) {
            $measurement.Groups["values"].Value.Trim()
        }
        else {
            ""
        }
        $scenarioMeasurementText[$scenario] = $measurementText
        $scenarioMeasurements[$scenario] = Convert-MeasurementText $measurementText
    }

    $semanticFailures = [System.Collections.Generic.List[string]]::new()
    $requiredMeasurements = [ordered]@{
        "JDC.dynamic-crosshair" = @(
            "idleReticleExtentPixels", "walkingReticleExtentPixels",
            "activeReticleExtentPixels", "recoveredReticleExtentPixels",
            "adsMode", "interactablePromptVisible", "hostileSystemColor"
        )
        "JHM.hit-marker" = @(
            "normalHitHealthDelta", "headshotOrCriticalHealthDelta",
            "killHealthDelta", "markerDisplaySeconds",
            "normalMarkerVisible", "criticalMarkerVisible", "killMarkerVisible",
            "normalMarkerMode", "criticalMarkerMode", "killMarkerMode",
            "markerFaded"
        )
        "JHI.hit-indicator" = @(
            "frontAngularErrorDegrees", "rightAngularErrorDegrees",
            "rearAngularErrorDegrees", "leftAngularErrorDegrees",
            "frontVisible", "rightVisible", "rearVisible", "leftVisible",
            "indicatorDisplaySeconds", "indicatorFaded",
            "totalPlayerHealthDelta"
        )
        "JHB.hold-breath" = @(
            "baselineSwayRms", "activeSwayRms", "restoredSwayRms",
            "resourceBefore", "resourceAfter",
            "activeObserved", "releasedObserved"
        )
        "JBT.bullet-time" = @(
            "normalTimeScale", "activeTimeScale", "restoredTimeScale",
            "resourceBefore", "resourceAfter",
            "activeObserved", "restoredInactive"
        )
        "JVS.sprint" = @(
            "baselineSpeed", "sprintSpeed", "speedRatio",
            "actionPointsBefore", "actionPointsAfter",
            "baselineDistance", "sprintDistance",
            "sprintActiveObserved", "sprintReleasedObserved"
        )
        "JVO.visual-objectives" = @(
            "objectiveFormId", "initialScreenX", "initialScreenY",
            "movedScreenX", "movedScreenY", "initialDistance", "movedDistance",
            "markerInitiallyVisible", "markerHidden"
        )
        "JWH.weapon-wheel" = @(
            "initialWeaponFormId", "selectedSlice", "selectedWeaponFormId",
            "equippedWeaponFormId", "cancelledWeaponFormId",
            "wheelOpened", "wheelClosed", "cancelClosed"
        )
        "JLM.loot-menu" = @(
            "containerItemCountBefore", "containerItemCountAfter",
            "playerItemCountBefore", "playerItemCountAfter",
            "duplicateTransferCount", "authoritativeRowCount",
            "menuVisible", "menuClosed", "crosshairContainerDetected"
        )
        "PROVIDER.knvse-animation" = @(
            "overrideAnimationPath", "overridePlayCount",
            "restorePlayCount", "leakedOverrideCount",
            "pluginReportedInstalled", "jamDirectCallCount",
            "overrideInstallResult", "overridePlayResult",
            "overrideRemoveResult", "originalSourceRestored"
        )
    }
    foreach ($scenario in $requiredMeasurements.Keys) {
        foreach ($field in $requiredMeasurements[$scenario]) {
            if ($null -eq (Get-MeasurementValue $scenarioMeasurements[$scenario] $field)) {
                $semanticFailures.Add("$scenario missing measurement '$field'")
            }
        }
    }

    $jdc = $scenarioMeasurements["JDC.dynamic-crosshair"]
    $jdcIdle = [double](Get-MeasurementValue $jdc "idleReticleExtentPixels")
    $jdcWalking = [double](Get-MeasurementValue $jdc "walkingReticleExtentPixels")
    $jdcActive = [double](Get-MeasurementValue $jdc "activeReticleExtentPixels")
    $jdcRecovered = [double](Get-MeasurementValue $jdc "recoveredReticleExtentPixels")
    if ($jdcWalking -le $jdcIdle * 1.05) {
        $semanticFailures.Add("JDC walking reticle did not expand by at least five percent")
    }
    if ($jdcActive -le $jdcIdle * 1.05) {
        $semanticFailures.Add("JDC active reticle did not expand by at least five percent")
    }
    if ([Math]::Abs($jdcRecovered - $jdcIdle) -gt [Math]::Max(1, $jdcIdle * 0.10)) {
        $semanticFailures.Add("JDC reticle did not recover to the idle extent")
    }
    if ([double](Get-MeasurementValue $jdc "adsMode") -ne 4) {
        $semanticFailures.Add("JDC did not enter the authored ADS mode")
    }
    if ([double](Get-MeasurementValue $jdc "interactablePromptVisible") -ne 1) {
        $semanticFailures.Add("JDC did not coexist with the interactable prompt")
    }
    if ([double](Get-MeasurementValue $jdc "hostileSystemColor") -ne 2) {
        $semanticFailures.Add("JDC did not switch to the hostile system color")
    }

    $jhm = $scenarioMeasurements["JHM.hit-marker"]
    foreach ($field in @(
        "normalHitHealthDelta", "headshotOrCriticalHealthDelta", "killHealthDelta"
    )) {
        if ([double](Get-MeasurementValue $jhm $field) -le 0) {
            $semanticFailures.Add("JHM $field did not mutate real target health")
        }
    }
    foreach ($field in @(
        "normalMarkerVisible", "criticalMarkerVisible", "killMarkerVisible", "markerFaded"
    )) {
        if ([double](Get-MeasurementValue $jhm $field) -ne 1) {
            $semanticFailures.Add("JHM $field was not observed")
        }
    }
    foreach ($mode in @(
        @{ Field = "normalMarkerMode"; Expected = 1 },
        @{ Field = "criticalMarkerMode"; Expected = 4 },
        @{ Field = "killMarkerMode"; Expected = 3 }
    )) {
        if ([double](Get-MeasurementValue $jhm $mode.Field) -ne $mode.Expected) {
            $semanticFailures.Add(
                "JHM $($mode.Field) did not match authored mode $($mode.Expected)")
        }
    }
    if ([double](Get-MeasurementValue $jhm "markerDisplaySeconds") -lt 2.5) {
        $semanticFailures.Add("JHM marker display duration was not observed for at least 2.5 seconds")
    }

    $jhi = $scenarioMeasurements["JHI.hit-indicator"]
    foreach ($field in @(
        "frontAngularErrorDegrees", "rightAngularErrorDegrees",
        "rearAngularErrorDegrees", "leftAngularErrorDegrees"
    )) {
        if ([Math]::Abs([double](Get-MeasurementValue $jhi $field)) -gt 15) {
            $semanticFailures.Add("JHI $field exceeded 15 degrees")
        }
    }
    foreach ($field in @(
        "frontVisible", "rightVisible", "rearVisible", "leftVisible", "indicatorFaded"
    )) {
        if ([double](Get-MeasurementValue $jhi $field) -ne 1) {
            $semanticFailures.Add("JHI $field was not observed")
        }
    }
    if ([double](Get-MeasurementValue $jhi "indicatorDisplaySeconds") -lt 2) {
        $semanticFailures.Add("JHI authored display duration was not observed")
    }
    if ([double](Get-MeasurementValue $jhi "totalPlayerHealthDelta") -lt 4) {
        $semanticFailures.Add("JHI did not record all four real player-health deltas")
    }

    $jhb = $scenarioMeasurements["JHB.hold-breath"]
    $jhbBaseline = [double](Get-MeasurementValue $jhb "baselineSwayRms")
    $jhbActive = [double](Get-MeasurementValue $jhb "activeSwayRms")
    $jhbRestored = [double](Get-MeasurementValue $jhb "restoredSwayRms")
    if ($jhbActive -ge $jhbBaseline) {
        $semanticFailures.Add("JHB did not reduce aiming sway")
    }
    if ([Math]::Abs($jhbRestored - $jhbBaseline) -gt [Math]::Max(0.001, $jhbBaseline * 0.10)) {
        $semanticFailures.Add("JHB did not restore baseline aiming sway")
    }
    if ([double](Get-MeasurementValue $jhb "resourceAfter") -ge
        [double](Get-MeasurementValue $jhb "resourceBefore")) {
        $semanticFailures.Add("JHB did not drain Action Points")
    }
    if ([double](Get-MeasurementValue $jhb "activeObserved") -ne 1 -or
        [double](Get-MeasurementValue $jhb "releasedObserved") -ne 1) {
        $semanticFailures.Add("JHB active/released state transition was not observed")
    }

    $jbt = $scenarioMeasurements["JBT.bullet-time"]
    $jbtNormal = [double](Get-MeasurementValue $jbt "normalTimeScale")
    $jbtActive = [double](Get-MeasurementValue $jbt "activeTimeScale")
    $jbtRestored = [double](Get-MeasurementValue $jbt "restoredTimeScale")
    if ($jbtActive -ge $jbtNormal -or [Math]::Abs($jbtActive - 0.5) -gt 0.01) {
        $semanticFailures.Add("JBT did not apply the authored 0.5 simulation time scale")
    }
    if ([Math]::Abs($jbtRestored - $jbtNormal) -gt 0.001) {
        $semanticFailures.Add("JBT did not restore the original simulation time scale")
    }
    if ([double](Get-MeasurementValue $jbt "resourceAfter") -ge
        [double](Get-MeasurementValue $jbt "resourceBefore")) {
        $semanticFailures.Add("JBT did not drain Action Points")
    }
    if ([double](Get-MeasurementValue $jbt "activeObserved") -ne 1 -or
        [double](Get-MeasurementValue $jbt "restoredInactive") -ne 1) {
        $semanticFailures.Add("JBT active/restored state transition was not observed")
    }

    $jvs = $scenarioMeasurements["JVS.sprint"]
    $jvsBaseline = [double](Get-MeasurementValue $jvs "baselineSpeed")
    $jvsSprint = [double](Get-MeasurementValue $jvs "sprintSpeed")
    $jvsRatio = [double](Get-MeasurementValue $jvs "speedRatio")
    if ([Math]::Abs($jvsBaseline - $retailBaselineSpeed) / $retailBaselineSpeed -gt 0.05) {
        $semanticFailures.Add("JVS baseline speed did not match retail within five percent")
    }
    if ([Math]::Abs($jvsSprint - $retailSprintSpeed) / $retailSprintSpeed -gt 0.05) {
        $semanticFailures.Add("JVS sprint speed did not match retail within five percent")
    }
    if ($jvsRatio -lt 1.65 -or $jvsRatio -gt 1.85) {
        $semanticFailures.Add("JVS speed ratio was outside 1.65..1.85")
    }
    if ([double](Get-MeasurementValue $jvs "actionPointsAfter") -ge
        [double](Get-MeasurementValue $jvs "actionPointsBefore")) {
        $semanticFailures.Add("JVS did not drain Action Points")
    }
    if ([double](Get-MeasurementValue $jvs "baselineDistance") -le 1 -or
        [double](Get-MeasurementValue $jvs "sprintDistance") -le 1) {
        $semanticFailures.Add("JVS did not advance during both locomotion windows")
    }
    if ([double](Get-MeasurementValue $jvs "sprintActiveObserved") -ne 1 -or
        [double](Get-MeasurementValue $jvs "sprintReleasedObserved") -ne 1) {
        $semanticFailures.Add("JVS active/released state transition was not observed")
    }

    $jvo = $scenarioMeasurements["JVO.visual-objectives"]
    if ([double](Get-MeasurementValue $jvo "markerInitiallyVisible") -ne 1 -or
        [double](Get-MeasurementValue $jvo "markerHidden") -ne 1) {
        $semanticFailures.Add("JVO visible/hidden lifecycle was not observed")
    }
    $objectiveMotion =
        [Math]::Abs([double](Get-MeasurementValue $jvo "movedScreenX") -
            [double](Get-MeasurementValue $jvo "initialScreenX")) +
        [Math]::Abs([double](Get-MeasurementValue $jvo "movedScreenY") -
            [double](Get-MeasurementValue $jvo "initialScreenY"))
    if ($objectiveMotion -lt 2) {
        $semanticFailures.Add("JVO objective marker did not move on screen")
    }
    if ([Math]::Abs([double](Get-MeasurementValue $jvo "movedDistance") -
        [double](Get-MeasurementValue $jvo "initialDistance")) -lt 1) {
        $semanticFailures.Add("JVO objective distance did not update")
    }
    if ([string](Get-MeasurementValue $jvo "objectiveFormId") -notmatch '^FormId:0x') {
        $semanticFailures.Add("JVO did not bind a real objective target form")
    }

    $jwh = $scenarioMeasurements["JWH.weapon-wheel"]
    if ([double](Get-MeasurementValue $jwh "wheelOpened") -ne 1 -or
        [double](Get-MeasurementValue $jwh "wheelClosed") -ne 1 -or
        [double](Get-MeasurementValue $jwh "cancelClosed") -ne 1) {
        $semanticFailures.Add("JWH open/close/cancel visual lifecycle was not observed")
    }
    if ([double](Get-MeasurementValue $jwh "selectedSlice") -ne 1) {
        $semanticFailures.Add("JWH did not highlight slice one")
    }
    $selectedWeapon = [string](Get-MeasurementValue $jwh "selectedWeaponFormId")
    if ([string](Get-MeasurementValue $jwh "equippedWeaponFormId") -ne $selectedWeapon -or
        [string](Get-MeasurementValue $jwh "cancelledWeaponFormId") -ne $selectedWeapon) {
        $semanticFailures.Add("JWH selected weapon was not equipped and preserved on cancel")
    }

    $jlm = $scenarioMeasurements["JLM.loot-menu"]
    if ([double](Get-MeasurementValue $jlm "containerItemCountBefore") -
            [double](Get-MeasurementValue $jlm "containerItemCountAfter") -ne 1 -or
        [double](Get-MeasurementValue $jlm "playerItemCountAfter") -
            [double](Get-MeasurementValue $jlm "playerItemCountBefore") -ne 1) {
        $semanticFailures.Add("JLM did not transfer exactly one authoritative item")
    }
    if ([double](Get-MeasurementValue $jlm "duplicateTransferCount") -ne 0) {
        $semanticFailures.Add("JLM duplicated the selected item")
    }
    if ([double](Get-MeasurementValue $jlm "authoritativeRowCount") -lt 1 -or
        [double](Get-MeasurementValue $jlm "menuVisible") -ne 1 -or
        [double](Get-MeasurementValue $jlm "menuClosed") -ne 1 -or
        [double](Get-MeasurementValue $jlm "crosshairContainerDetected") -ne 1) {
        $semanticFailures.Add("JLM menu rows or crosshair/open/close lifecycle was not observed")
    }

    $knvse = $scenarioMeasurements["PROVIDER.knvse-animation"]
    if ([double](Get-MeasurementValue $knvse "jamDirectCallCount") -ne 0) {
        $semanticFailures.Add("kNVSE probe was incorrectly represented as a JAM command")
    }
    if ([double](Get-MeasurementValue $knvse "pluginReportedInstalled") -ne 1) {
        $semanticFailures.Add("xNVSE IsPluginInstalled did not expose the kNVSE compatibility provider")
    }
    foreach ($field in @(
        "overrideInstallResult", "overridePlayResult",
        "overrideRemoveResult", "originalSourceRestored"
    )) {
        if ([double](Get-MeasurementValue $knvse $field) -ne 1) {
            $semanticFailures.Add("kNVSE $field did not reach the native animation controller")
        }
    }
    if ([double](Get-MeasurementValue $knvse "overridePlayCount") -lt 1 -or
        [double](Get-MeasurementValue $knvse "restorePlayCount") -lt 1) {
        $semanticFailures.Add("kNVSE override and restored animation were not both played")
    }
    if ([double](Get-MeasurementValue $knvse "leakedOverrideCount") -ne 0) {
        $semanticFailures.Add("kNVSE provider probe leaked an animation override into JAM")
    }
    if ([string](Get-MeasurementValue $knvse "overrideAnimationPath") -notmatch
            '(?i)^meshes/characters/_male/idleanims/sprint/.+\.kf$') {
        $semanticFailures.Add("kNVSE provider probe did not use a real JAM sprint KF path")
    }

    $probe = & ffprobe -v error -show_entries format=duration,size `
        -show_entries stream=width,height,avg_frame_rate,nb_frames `
        -of json $videoPath | ConvertFrom-Json
    $duration = [double]::Parse(
        [string]$probe.format.duration,
        [Globalization.CultureInfo]::InvariantCulture)
    $videoBytes = [long]$probe.format.size
    $signalStatsStdout = Join-Path $OutputRoot "signalstats.stdout.log"
    $signalStatsStderr = Join-Path $OutputRoot "signalstats.stderr.log"
    $signalStatsProcess = Start-Process -FilePath "ffmpeg" -ArgumentList @(
        "-hide_banner", "-loglevel", "info", "-i", $videoPath,
        "-vf", "fps=1/10,signalstats,metadata=print",
        "-f", "null", "-"
    ) -WindowStyle Hidden -RedirectStandardOutput $signalStatsStdout `
        -RedirectStandardError $signalStatsStderr -PassThru -Wait
    if ($signalStatsProcess.ExitCode -ne 0) {
        throw "ffmpeg signal-stat analysis failed with exit code $($signalStatsProcess.ExitCode)."
    }
    $signalStatsText = Get-Content -LiteralPath $signalStatsStderr -Raw
    $lumaSamples = @([regex]::Matches(
        $signalStatsText,
        'lavfi\.signalstats\.YAVG=(?<value>[0-9.]+)'
    ) | ForEach-Object {
        [double]::Parse(
            $_.Groups["value"].Value,
            [Globalization.CultureInfo]::InvariantCulture)
    })
    $averageLuma = if ($lumaSamples.Count -gt 0) {
        [double](($lumaSamples | Measure-Object -Average).Average)
    }
    else { 0 }
    $minimumLuma = if ($lumaSamples.Count -gt 0) {
        [double](($lumaSamples | Measure-Object -Minimum).Minimum)
    }
    else { 0 }
    $maximumLuma = if ($lumaSamples.Count -gt 0) {
        [double](($lumaSamples | Measure-Object -Maximum).Maximum)
    }
    else { 0 }
    $videoVisualContentPassed = $lumaSamples.Count -ge 3 `
        -and $averageLuma -ge 10 `
        -and ($maximumLuma - $minimumLuma) -ge 2 `
        -and $videoBytes -ge 1000000

    $cloudRows = @(Get-CloudMotionRows $logText 3)
    $baselineCloudStart = Get-LogEventClock $logText (
        [regex]::Escape('[jam-full-proof] state=phase-start scenarioId=JVS.sprint phase=baseline-run '))
    $baselineCloudEnd = Get-LogEventClock $logText (
        [regex]::Escape('[jam-full-proof] state=phase-complete scenarioId=JVS.sprint phase=baseline-run '))
    $sprintCloudStart = Get-LogEventClock $logText (
        [regex]::Escape('[jam-full-proof] state=phase-start scenarioId=JVS.sprint phase=sprint-at-speed-turn-and-resource-drain '))
    $sprintCloudEnd = Get-LogEventClock $logText (
        [regex]::Escape('[jam-full-proof] state=phase-complete scenarioId=JVS.sprint phase=sprint-at-speed-turn-and-resource-drain '))
    $baselineCloudRate = if ($null -ne $baselineCloudStart -and
        $null -ne $baselineCloudEnd) {
        Get-CloudMotionRate $cloudRows $baselineCloudStart $baselineCloudEnd
    }
    else { $null }
    $sprintCloudRate = if ($null -ne $sprintCloudStart -and
        $null -ne $sprintCloudEnd) {
        Get-CloudMotionRate $cloudRows $sprintCloudStart $sprintCloudEnd
    }
    else { $null }
    $cloudRateRelativeDifference = if ($null -ne $baselineCloudRate -and
        $null -ne $sprintCloudRate -and $baselineCloudRate -gt 0) {
        [Math]::Abs($sprintCloudRate - $baselineCloudRate) / $baselineCloudRate
    }
    else { [double]::PositiveInfinity }
    $cloudMotionPassed = $null -ne $baselineCloudRate `
        -and $null -ne $sprintCloudRate `
        -and $baselineCloudRate -gt 0 `
        -and $sprintCloudRate -gt 0 `
        -and $cloudRateRelativeDifference -le 0.05
    if (-not $cloudMotionPassed) {
        $semanticFailures.Add(
            "JVS cloud UV motion was not observed at an invariant baseline/sprint rate")
    }
    if ($null -ne $baselineCloudRate -and $null -ne $sprintCloudRate) {
        $cloudAverageRate = ($baselineCloudRate + $sprintCloudRate) / 2
        $jvs | Add-Member -NotePropertyName cloudDisplacementPerRealSecond `
            -NotePropertyValue $cloudAverageRate -Force
        # Both JVS windows run at simulation scale 1.0. This is deliberately
        # reported separately so the contract can detect future time coupling.
        $jvs | Add-Member -NotePropertyName cloudDisplacementPerSimulationSecond `
            -NotePropertyValue $cloudAverageRate -Force
        $jvs | Add-Member -NotePropertyName baselineCloudDisplacementPerRealSecond `
            -NotePropertyValue $baselineCloudRate -Force
        $jvs | Add-Member -NotePropertyName sprintCloudDisplacementPerRealSecond `
            -NotePropertyValue $sprintCloudRate -Force
    }

    $phaseDurationMatches = @([regex]::Matches(
        $logText,
        '\[jam-full-proof\] state=phase-complete [^\r\n]* seconds=(?<seconds>[0-9.]+)'
    ))
    $shortPhaseCount = @($phaseDurationMatches | Where-Object {
        [double]::Parse(
            $_.Groups["seconds"].Value,
            [Globalization.CultureInfo]::InvariantCulture) -lt 3.0
    }).Count
    $fullCompletion = [regex]::Matches(
        $logText,
        '\[jam-full-proof\] state=complete scenarioCount=10 phaseCount=(?<phases>[0-9]+) elapsedRealSeconds=(?<seconds>[0-9.]+) errorCount=(?<errors>[0-9]+)'
    ) | Select-Object -Last 1
    $allProvidersVisible = $logText -match 'provider=xnvse-core' `
        -and $logText -match 'provider=jip-ln' `
        -and $logText -match 'provider=johnnyguitar' `
        -and $logText -match 'provider=knvse'
    $nativeEffectCount = [regex]::Matches(
        $logText, '\[obscript-compat\] state=native-effect ').Count
    $fullPassed = (Test-Path -LiteralPath $videoPath) `
        -and $archiveSha256 -eq $expectedArchiveSha256 `
        -and $pluginSha256 -eq $expectedPluginSha256 `
        -and $dlls.Count -eq 0 `
        -and $null -ne $fullCompletion `
        -and [int]$fullCompletion.Groups["errors"].Value -eq 0 `
        -and $phaseStartMatches.Count -eq $expectedPhases.Count `
        -and $phaseCompleteMatches.Count -eq $expectedPhases.Count `
        -and $shortPhaseCount -eq 0 `
        -and $missingScenarios.Count -eq 0 `
        -and $missingPhases.Count -eq 0 `
        -and $compatFailures.Count -eq 0 `
        -and $proofFailures.Count -eq 0 `
        -and $semanticFailures.Count -eq 0 `
        -and $allProvidersVisible `
        -and $nativeEffectCount -gt 0 `
        -and $videoVisualContentPassed `
        -and $duration -ge ($CaptureSeconds - 2)

    $report = [ordered]@{
        passed = $fullPassed
        claim = "Untouched JAM 4.6 ESP/UDF scripts execute all nine JAM modules through named xNVSE, JIP LN, and JohnnyGuitar compatibility paths with native OpenMW effects; the separately labelled kNVSE provider probe installs, plays, removes, and restores a real JAM animation without claiming a direct JAM call."
        scope = $expectedScenarios
        capture = [ordered]@{
            method = "openmw-self-drive-gdigrab-window-title"
            driver = "engine-native-JAM-full-proof"
            windowsAppControlUsed = (-not $SelfDrive)
            foregroundActivationUsed = (-not $SelfDrive)
            foregroundInputInjected = (-not $SelfDrive)
            selfDriven = [bool]$SelfDrive
            windowTitle = "OpenMW"
        }
        provenance = [ordered]@{
            nexusFile = "JAM 4.6"
            archive = $JamArchive
            archiveSha256 = $archiveSha256
            plugin = $pluginPath
            pluginSha256 = $pluginSha256
            dllCount = $dlls.Count
        }
        execution = [ordered]@{
            expectedPhaseCount = $expectedPhases.Count
            phaseStarts = $phaseStartMatches.Count
            phaseCompletions = $phaseCompleteMatches.Count
            missingScenarios = $missingScenarios
            missingPhases = $missingPhases
            providersVisible = $allProvidersVisible
            nativeEffectCount = $nativeEffectCount
            compatibilityFailures = $compatFailures
            proofFailures = $proofFailures
            semanticFailures = @($semanticFailures)
            shortPhaseCount = $shortPhaseCount
            measurements = $scenarioMeasurements
            measurementText = $scenarioMeasurementText
            cloudMotion = [ordered]@{
                layer = 3
                sampleCount = $cloudRows.Count
                baselineDisplacementPerRealSecond = $baselineCloudRate
                sprintDisplacementPerRealSecond = $sprintCloudRate
                relativeDifference = $cloudRateRelativeDifference
            }
        }
        gates = [ordered]@{
            exactArchiveHash = $archiveSha256 -eq $expectedArchiveSha256
            exactPluginHash = $pluginSha256 -eq $expectedPluginSha256
            noDlls = $dlls.Count -eq 0
            allTenScenariosCompleted = $missingScenarios.Count -eq 0
            allFortyFourPhasesStarted = $phaseStartMatches.Count -eq $expectedPhases.Count `
                -and $missingPhases.Count -eq 0
            allFortyFourPhasesCompleted = $phaseCompleteMatches.Count -eq $expectedPhases.Count
            everyPhaseVisibleForAtLeastThreeSeconds = $shortPhaseCount -eq 0
            allCompatibilityProvidersVisible = $allProvidersVisible
            nativeEffectsObserved = $nativeEffectCount -gt 0
            noCompatibilityDispatchFailures = $compatFailures.Count -eq 0
            noProofDriverFailures = $proofFailures.Count -eq 0
            everyScenarioSemanticAssertionPassed = $semanticFailures.Count -eq 0
            cloudMotionIndependentOfSprint = $cloudMotionPassed
            videoProduced = Test-Path -LiteralPath $videoPath
            videoCoversRequestedDuration = $duration -ge ($CaptureSeconds - 2)
            videoContainsChangingVisibleFrames = $videoVisualContentPassed
        }
        video = [ordered]@{
            path = $videoPath
            width = $probe.streams[0].width
            height = $probe.streams[0].height
            frameRate = $probe.streams[0].avg_frame_rate
            frameCount = $probe.streams[0].nb_frames
            duration = $probe.format.duration
            size = $probe.format.size
            lumaSampleCount = $lumaSamples.Count
            averageLuma = $averageLuma
            minimumLuma = $minimumLuma
            maximumLuma = $maximumLuma
        }
        stdout = $stdoutLog
        stderr = $stderrLog
    }
    Write-Utf8NoBom $reportPath @(($report | ConvertTo-Json -Depth 8))
    if (-not $fullPassed) {
        throw "JAM full execution proof failed. See $reportPath and $stdoutLog"
    }
    $report | ConvertTo-Json -Depth 8
    return
}

$baseline = [regex]::Matches(
    $logText,
    'state=baseline elapsed=(?<elapsed>[0-9.]+) distance=(?<distance>[0-9.]+) averageSpeed=(?<speed>[0-9.]+)'
) | Select-Object -Last 1
$sprint = [regex]::Matches(
    $logText,
    'state=stop elapsed=(?<elapsed>[0-9.]+) distance=(?<distance>[0-9.]+) averageSpeed=(?<speed>[0-9.]+) apBefore=(?<before>[0-9.]+) apAfter=(?<after>[0-9.]+)'
) | Select-Object -Last 1
$heading = [regex]::Matches(
    $logText,
    'JAM route heading source=save-relative savedYawRadians=(?<saved>-?[0-9.]+) deltaDegrees=(?<requested>-?[0-9.]+) targetYawRadians=(?<target>-?[0-9.]+) appliedYawRadians=(?<applied>-?[0-9.]+) appliedDeltaDegrees=(?<delta>-?[0-9.]+) status=(?<status>pass|fail)'
) | Select-Object -Last 1
if ($null -eq $baseline -or $null -eq $sprint -or $null -eq $heading) {
    throw "JAM proof did not produce heading, baseline, and sprint measurements. See $stdoutLog"
}

$invariant = [Globalization.CultureInfo]::InvariantCulture
$baselineSpeed = [double]::Parse($baseline.Groups["speed"].Value, $invariant)
$sprintSpeed = [double]::Parse($sprint.Groups["speed"].Value, $invariant)
$apBefore = [double]::Parse($sprint.Groups["before"].Value, $invariant)
$apAfter = [double]::Parse($sprint.Groups["after"].Value, $invariant)
$headingDeltaDegrees = [double]::Parse($heading.Groups["delta"].Value, $invariant)
$speedRatio = if ($baselineSpeed -gt 0) { $sprintSpeed / $baselineSpeed } else { 0 }
$baselineRelativeError = [Math]::Abs($baselineSpeed - $retailBaselineSpeed) / $retailBaselineSpeed
$sprintRelativeError = [Math]::Abs($sprintSpeed - $retailSprintSpeed) / $retailSprintSpeed
$headingPassed = $heading.Groups["status"].Value -eq "pass" `
    -and [Math]::Abs($headingDeltaDegrees - (-15.0)) -le 0.05
$absoluteSpeedsPassed = $baselineRelativeError -le $absoluteSpeedTolerance `
    -and $sprintRelativeError -le $absoluteSpeedTolerance
$providerReady = $logText -match 'state=ready plugin=JustAssortedMods\.esp keyDIK=42 keyMapped=1 speedMultiplier=1\.750'
$passed = (Test-Path -LiteralPath $videoPath) -and $providerReady `
    -and $headingPassed -and $absoluteSpeedsPassed `
    -and $baselineSpeed -gt 0 -and $speedRatio -ge 1.65 -and $speedRatio -le 1.85 `
    -and $apAfter -lt ($apBefore - 1)

$probe = & ffprobe -v error -show_entries format=duration,size `
    -show_entries stream=width,height,avg_frame_rate,nb_frames -of json $videoPath | ConvertFrom-Json
$report = [ordered]@{
    passed = $passed
    claim = "Untouched JAM 4.6 ESP drives an engine-native OpenMW sprint compatibility provider."
    capture = [ordered]@{
        method = if ($SelfDrive) {
            "openmw-self-drive-gdigrab-window-title"
        } else {
            "legacy-foreground-gdigrab-window-title"
        }
        windowsAppControlUsed = (-not $SelfDrive)
        foregroundActivationUsed = (-not $SelfDrive)
        foregroundInputInjected = (-not $SelfDrive)
        selfDriven = [bool]$SelfDrive
        windowTitle = "OpenMW"
    }
    scope = @(
        "JAM sprint key activation"
        "winning JVS global settings"
        "movement multiplier"
        "Fallout Action Points drain"
        "DirectInput-to-SDL key translation"
    )
    excluded = @(
        "JAM sprint kNVSE animation replacement"
        "JAM sprint sounds"
        "other JAM modules"
        "general JIP LN or JohnnyGuitar compatibility"
    )
    provenance = [ordered]@{
        nexusFile = "JAM 4.6"
        archive = $JamArchive
        archiveSha256 = $archiveSha256
        plugin = $pluginPath
        pluginSha256 = $pluginSha256
        dllCount = $dlls.Count
    }
    measurements = [ordered]@{
        saveRelativeYawDegrees = -15
        appliedRelativeYawDegrees = $headingDeltaDegrees
        retailBaselineSpeed = $retailBaselineSpeed
        baselineSpeed = $baselineSpeed
        baselineRelativeError = $baselineRelativeError
        retailSprintSpeed = $retailSprintSpeed
        sprintSpeed = $sprintSpeed
        sprintRelativeError = $sprintRelativeError
        speedRatio = $speedRatio
        actionPointsBefore = $apBefore
        actionPointsAfter = $apAfter
        actionPointsSpent = $apBefore - $apAfter
    }
    gates = [ordered]@{
        exactArchiveHash = $archiveSha256 -eq $expectedArchiveSha256
        exactPluginHash = $pluginSha256 -eq $expectedPluginSha256
        noDlls = $dlls.Count -eq 0
        providerReady = $providerReady
        exactSaveRelativeHeading = $headingPassed
        absoluteSpeedsMatchRetail = $absoluteSpeedsPassed
        speedRatio = $speedRatio -ge 1.65 -and $speedRatio -le 1.85
        actionPointsDrained = $apAfter -lt ($apBefore - 1)
        videoProduced = Test-Path -LiteralPath $videoPath
    }
    video = [ordered]@{
        path = $videoPath
        width = $probe.streams[0].width
        height = $probe.streams[0].height
        frameRate = $probe.streams[0].avg_frame_rate
        frameCount = $probe.streams[0].nb_frames
        duration = $probe.format.duration
        size = $probe.format.size
    }
    stdout = $stdoutLog
    stderr = $stderrLog
}
Write-Utf8NoBom $reportPath @(($report | ConvertTo-Json -Depth 6))

if (-not $passed) {
    throw "JAM native sprint proof failed. See $reportPath and $stdoutLog"
}
$report | ConvertTo-Json -Depth 6
