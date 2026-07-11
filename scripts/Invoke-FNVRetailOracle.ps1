param(
    [string]$GameRoot = "D:\SteamLibrary\steamapps\common\Fallout New Vegas",
    [string]$PluginDll = "external\xnvse\nvse_retail_oracle\build\nvse_retail_oracle.dll",
    [string]$OutputPath = "run\retail-oracle\fnv-goodsprings-behavior.jsonl",
    [string]$SaveName = "Save 222     Goodsprings  00 01 36",
    [string]$SaveFixture = "",
    [string[]]$QuestForm = @("0x00102037", "0x00104C1C", "0x0010A214", "0x0015D912"),
    [string[]]$GlobalForm = @("0x35", "0x36", "0x37", "0x38", "0x39", "0x3A"),
    [string[]]$Command = @(),
    [string[]]$ActorCommand = @(),
    [string]$SetStageQuestForm = "0",
    [int]$SetStageIndex = 65535,
    [int]$BeforeFrame = 10,
    [int]$CommandFrame = 20,
    [int]$AfterFrame = 30,
    [int]$MaxFrames = 40,
    [int]$TimeoutSeconds = 55,
    [int]$SampleEvery = 1,
    [string]$TargetForm = "0",
    [string]$ObserverApproachForm = "0",
    [float]$ObserverApproachStopDistance = 1400,
    [float]$ObserverApproachStepDistance = 64,
    [string[]]$ObserverWaypoint = @(),
    [string]$EquipForm = "0",
    [string]$PlayGroup = "",
    [string]$DriveCommand = "",
    [int]$PrepareActorFrame = 60,
    [int]$EquipActorFrame = 60,
    [int]$DriveActorFrame = 180,
    [int]$FootIkToggleFrame = 0,
    [ValidateSet(-1, 0, 1)]
    [int]$FootIkToggleEnabled = -1,
    [switch]$FurnitureOnly,
    [string[]]$FurnitureSettledCommand = @(),
    [switch]$ExitAfterFurnitureRelease,
    [int]$ExitAfterFurnitureSettledSamples = 0,
    [int]$FurnitureReleaseSamples = 3,
    [switch]$BackgroundDataMode,
    [switch]$VisibleGame,
    [switch]$CaptureAnimation,
    [int[]]$ScreenshotFrame = @(),
    [string]$ScreenshotDirectory = "",
    [switch]$PortraitCamera,
    [ValidateRange(32, 1000)]
    [float]$PortraitDistance = 110
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Remove-FileWithRetry([string]$Path, [int]$TimeoutMilliseconds = 5000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 100
        }
        if (-not (Test-Path -LiteralPath $Path)) { return }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out removing file: $Path"
}

if ($BeforeFrame -lt 1 -or $CommandFrame -le $BeforeFrame -or $AfterFrame -le $CommandFrame) {
    throw "Expected 0 < BeforeFrame < CommandFrame < AfterFrame."
}
if ($MaxFrames -lt $AfterFrame) {
    throw "MaxFrames must be greater than or equal to AfterFrame."
}
if ($TimeoutSeconds -lt 10 -or $TimeoutSeconds -gt 300) {
    throw "TimeoutSeconds must be between 10 and 300."
}
if ($SampleEvery -lt 1) {
    throw "SampleEvery must be positive."
}
foreach ($form in @($TargetForm, $ObserverApproachForm, $EquipForm)) {
    if ($form -notmatch '^(0[xX][0-9a-fA-F]+|[0-9]+)$') {
        throw "Expected a decimal or 0x-prefixed FormID, got: $form"
    }
}
if ($ObserverApproachStopDistance -lt 64) {
    throw "ObserverApproachStopDistance must be at least 64 world units."
}
if ($ObserverApproachStepDistance -lt 1 -or $ObserverApproachStepDistance -gt 256) {
    throw "ObserverApproachStepDistance must be between 1 and 256 world units."
}
if ($PlayGroup -notmatch '^[A-Za-z0-9_]*$') {
    throw "PlayGroup may contain only ASCII letters, digits, and underscores."
}
if ($CaptureAnimation -and ($PrepareActorFrame -lt 1 -or $PrepareActorFrame -gt $MaxFrames)) {
    throw "PrepareActorFrame must be between 1 and MaxFrames for animation capture."
}
if ($CaptureAnimation -and
    (-not [string]::IsNullOrWhiteSpace($PlayGroup) -or -not [string]::IsNullOrWhiteSpace($DriveCommand)) -and
    ($EquipActorFrame -lt $PrepareActorFrame -or $DriveActorFrame -lt $EquipActorFrame -or
        $DriveActorFrame -gt $MaxFrames)) {
    throw "Expected PrepareActorFrame <= EquipActorFrame <= DriveActorFrame <= MaxFrames when PlayGroup is set."
}
if ($FootIkToggleFrame -lt 0 -or ($FootIkToggleFrame -gt 0 -and
    ($FootIkToggleFrame -lt $PrepareActorFrame -or $FootIkToggleFrame -gt $MaxFrames))) {
    throw "FootIkToggleFrame must be zero or between PrepareActorFrame and MaxFrames."
}
if (($FootIkToggleFrame -eq 0) -ne ($FootIkToggleEnabled -eq -1)) {
    throw "FootIkToggleFrame and FootIkToggleEnabled must be specified together."
}
if ($ExitAfterFurnitureRelease -and (-not $FurnitureOnly -or $TargetForm -match '^(0[xX]0+|0+)$')) {
    throw "ExitAfterFurnitureRelease requires FurnitureOnly and a nonzero TargetForm."
}
if ($FurnitureReleaseSamples -lt 1) {
    throw "FurnitureReleaseSamples must be positive."
}
if ($ExitAfterFurnitureSettledSamples -lt 0) {
    throw "ExitAfterFurnitureSettledSamples cannot be negative."
}
if ($ExitAfterFurnitureSettledSamples -gt 0 -and
    (-not $FurnitureOnly -or $TargetForm -match '^(0[xX]0+|0+)$')) {
    throw "ExitAfterFurnitureSettledSamples requires FurnitureOnly and a nonzero TargetForm."
}
if ($ExitAfterFurnitureRelease -and $ExitAfterFurnitureSettledSamples -gt 0) {
    throw "Choose one furniture completion condition: settled samples or release."
}
foreach ($entry in @($Command) + @($ActorCommand) + @($FurnitureSettledCommand)) {
    if ($entry -match '[|\r\n]') {
        throw "Retail oracle commands cannot contain pipe or newline characters: $entry"
    }
}
foreach ($waypoint in @($ObserverWaypoint)) {
    if ($waypoint -notmatch '^-?[0-9]+(?:\.[0-9]+)?,-?[0-9]+(?:\.[0-9]+)?$') {
        throw "ObserverWaypoint must be an X,Y numeric pair: $waypoint"
    }
}
if ($DriveCommand -match '[|\r\n]') {
    throw "Retail oracle drive command cannot contain pipe or newline characters: $DriveCommand"
}
$ScreenshotFrame = @($ScreenshotFrame | Sort-Object -Unique)
foreach ($frame in $ScreenshotFrame) {
    if ($frame -lt 1 -or $frame -gt $MaxFrames) {
        throw "ScreenshotFrame must be between 1 and MaxFrames: $frame"
    }
}
if ($PortraitCamera -and $TargetForm -match '^(0[xX]0+|0+)$') {
    throw "PortraitCamera requires a nonzero TargetForm."
}
if ($ScreenshotFrame.Count -gt 0 -and [string]::IsNullOrWhiteSpace($ScreenshotDirectory)) {
    $ScreenshotDirectory = "$OutputPath-screens"
}

$gameRootPath = Resolve-AbsolutePath $GameRoot
$loader = Join-Path $gameRootPath "nvse_loader.exe"
$gameExe = Join-Path $gameRootPath "FalloutNV.exe"
$sourcePlugin = Resolve-AbsolutePath $PluginDll
$output = Resolve-AbsolutePath $OutputPath
$pluginDirectory = Join-Path $gameRootPath "Data\NVSE\Plugins"
$installedPlugin = Join-Path $pluginDirectory "nvse_retail_oracle.dll"
$backupPlugin = "$installedPlugin.nikami-backup-$PID"
$screenshotBackupDirectory = Join-Path $gameRootPath ".nikami-screenshot-backup-$PID"
$screenshotOutputDirectory = if ([string]::IsNullOrWhiteSpace($ScreenshotDirectory)) {
    $null
} else {
    Resolve-AbsolutePath $ScreenshotDirectory
}
$capturedScreenshots = @()
$portraitProofCrops = @()
$fixtureDestinations = @()
$resolvedSaveFixture = $null
$fixtureSaveName = $null

if (-not [string]::IsNullOrWhiteSpace($SaveFixture)) {
    $resolvedSaveFixture = Resolve-AbsolutePath $SaveFixture
    if (-not (Test-Path -LiteralPath $resolvedSaveFixture -PathType Leaf) -or
        [System.IO.Path]::GetExtension($resolvedSaveFixture) -ine '.fos') {
        throw "SaveFixture must name an existing .fos file: $resolvedSaveFixture"
    }
    $saveDirectory = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\FalloutNV\Saves'
    $fixtureSaveName = "NikamiOracleFixture-$PID"
    foreach ($extension in @('.fos', '.nvse')) {
        $source = [System.IO.Path]::ChangeExtension($resolvedSaveFixture, $extension)
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $destination = Join-Path $saveDirectory ($fixtureSaveName + $extension)
            if (Test-Path -LiteralPath $destination) {
                throw "Refusing to overwrite stale retail-oracle fixture: $destination"
            }
            $fixtureDestinations += [pscustomobject]@{ Source = $source; Destination = $destination }
        }
    }
    $SaveName = $fixtureSaveName
}

foreach ($required in @($loader, $gameExe, $sourcePlugin)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing required retail-oracle file: $required"
    }
}
if (Get-Process -Name "FalloutNV" -ErrorAction SilentlyContinue) {
    throw "FalloutNV is already running. Close it before starting an isolated oracle capture."
}

New-Item -ItemType Directory -Force -Path $pluginDirectory | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
if (Test-Path -LiteralPath $output) {
    Remove-Item -LiteralPath $output -Force
}

$environment = [ordered]@{
    NIKAMI_ORACLE_OUTPUT = $output
    NIKAMI_ORACLE_SAMPLE_EVERY = [string]$SampleEvery
    NIKAMI_ORACLE_MAX_FRAMES = [string]$MaxFrames
    NIKAMI_ORACLE_TARGET_FORM = $TargetForm
    NIKAMI_ORACLE_OBSERVER_APPROACH_FORM = $ObserverApproachForm
    NIKAMI_ORACLE_OBSERVER_APPROACH_STOP_DISTANCE = [string]$ObserverApproachStopDistance
    NIKAMI_ORACLE_OBSERVER_APPROACH_STEP_DISTANCE = [string]$ObserverApproachStepDistance
    NIKAMI_ORACLE_OBSERVER_WAYPOINTS = (@($ObserverWaypoint) -join ";")
    NIKAMI_ORACLE_EQUIP_FORM = $EquipForm
    NIKAMI_ORACLE_ALL_HIGH_ACTORS = if ($CaptureAnimation) { "1" } else { "0" }
    NIKAMI_ORACLE_CAPTURE_ANIMATION = if ($CaptureAnimation) { "1" } else { "0" }
    NIKAMI_ORACLE_FURNITURE_ONLY = if ($FurnitureOnly) { "1" } else { "0" }
    NIKAMI_ORACLE_FURNITURE_SETTLED_COMMANDS = (@($FurnitureSettledCommand) -join "|")
    NIKAMI_ORACLE_EXIT_AFTER_FURNITURE_RELEASE = if ($ExitAfterFurnitureRelease) { "1" } else { "0" }
    NIKAMI_ORACLE_EXIT_AFTER_FURNITURE_SETTLED_SAMPLES = [string]$ExitAfterFurnitureSettledSamples
    NIKAMI_ORACLE_FURNITURE_RELEASE_SAMPLES = [string]$FurnitureReleaseSamples
    NIKAMI_ORACLE_CLOSE_MENUS = if ($BackgroundDataMode) { "1" } else { "0" }
    NIKAMI_ORACLE_SAVE = $SaveName
    NIKAMI_ORACLE_PLAY_GROUP = $PlayGroup
    NIKAMI_ORACLE_DRIVE_COMMAND = $DriveCommand
    NIKAMI_ORACLE_PREPARE_ACTOR_FRAME = [string]$PrepareActorFrame
    NIKAMI_ORACLE_EQUIP_ACTOR_FRAME = [string]$EquipActorFrame
    NIKAMI_ORACLE_DRIVE_ACTOR_FRAME = [string]$DriveActorFrame
    NIKAMI_ORACLE_FOOT_IK_TOGGLE_FRAME = [string]$FootIkToggleFrame
    NIKAMI_ORACLE_FOOT_IK_TOGGLE_ENABLED = if ($FootIkToggleEnabled -eq 1) { "1" } else { "0" }
    NIKAMI_ORACLE_QUEST_FORMS = (@($QuestForm) -join ",")
    NIKAMI_ORACLE_GLOBAL_FORMS = (@($GlobalForm) -join ",")
    NIKAMI_ORACLE_COMMANDS = (@($Command) -join "|")
    NIKAMI_ORACLE_ACTOR_COMMANDS = (@($ActorCommand) -join "|")
    NIKAMI_ORACLE_BEFORE_FRAME = [string]$BeforeFrame
    NIKAMI_ORACLE_COMMAND_FRAME = [string]$CommandFrame
    NIKAMI_ORACLE_AFTER_FRAME = [string]$AfterFrame
    NIKAMI_ORACLE_SET_STAGE_QUEST = $SetStageQuestForm
    NIKAMI_ORACLE_SET_STAGE_INDEX = [string]$SetStageIndex
    NIKAMI_ORACLE_SCREENSHOT_FRAMES = (@($ScreenshotFrame) -join ",")
    NIKAMI_ORACLE_PORTRAIT_CAMERA = if ($PortraitCamera) { "1" } else { "0" }
    NIKAMI_ORACLE_PORTRAIT_DISTANCE = [string]$PortraitDistance
    NIKAMI_ORACLE_EXIT_WHEN_DONE = "1"
}
$previousEnvironment = @{}
$gameProcess = $null
$hadInstalledPlugin = Test-Path -LiteralPath $installedPlugin -PathType Leaf

try {
    if ($ScreenshotFrame.Count -gt 0) {
        if (Test-Path -LiteralPath $screenshotBackupDirectory) {
            throw "Refusing to overwrite stale screenshot backup: $screenshotBackupDirectory"
        }
        New-Item -ItemType Directory -Path $screenshotBackupDirectory | Out-Null
        foreach ($existingScreenshot in @(Get-ChildItem -LiteralPath $gameRootPath -Filter 'ScreenShot*.bmp' -File)) {
            Move-Item -LiteralPath $existingScreenshot.FullName -Destination $screenshotBackupDirectory
        }
        New-Item -ItemType Directory -Force -Path $screenshotOutputDirectory | Out-Null
        if (@(Get-ChildItem -LiteralPath $screenshotOutputDirectory -Filter 'frame-*.bmp' -File).Count -gt 0) {
            throw "ScreenshotDirectory already contains frame-*.bmp files: $screenshotOutputDirectory"
        }
    }
    foreach ($fixture in $fixtureDestinations) {
        Copy-Item -LiteralPath $fixture.Source -Destination $fixture.Destination
    }
    if ($hadInstalledPlugin) {
        if (Test-Path -LiteralPath $backupPlugin) {
            throw "Refusing to overwrite stale oracle backup: $backupPlugin"
        }
        Move-Item -LiteralPath $installedPlugin -Destination $backupPlugin
    }
    Copy-Item -LiteralPath $sourcePlugin -Destination $installedPlugin

    foreach ($name in $environment.Keys) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, $environment[$name], "Process")
    }

    $startedAt = Get-Date
    $launchArguments = @{
        FilePath = $loader
        WorkingDirectory = $gameRootPath
        PassThru = $true
    }
    if (-not $VisibleGame) {
        $launchArguments.WindowStyle = 'Hidden'
    }
    $launcherProcess = Start-Process @launchArguments
    $launchDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $launchDeadline -and $null -eq $gameProcess) {
        $gameProcess = Get-Process -Name "FalloutNV" -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -ge $startedAt.AddSeconds(-2) } |
            Select-Object -First 1
        if ($null -eq $gameProcess) {
            Start-Sleep -Milliseconds 250
        }
    }
    if ($null -eq $gameProcess) {
        throw "nvse_loader did not start FalloutNV within 20 seconds (loader PID $($launcherProcess.Id))."
    }

    if ($BackgroundDataMode) {
        if (-not ('Nikami.NativeWindow' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Nikami {
    public static class NativeWindow {
        [DllImport("user32.dll")]
        public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
        public static void MinimizeBackground(IntPtr hWnd) {
            ShowWindowAsync(hWnd, 6);
        }
    }
}
'@
        }
        $windowDeadline = (Get-Date).AddSeconds(15)
        do {
            $gameProcess.Refresh()
            if ($gameProcess.MainWindowHandle -ne [IntPtr]::Zero) {
                [Nikami.NativeWindow]::MinimizeBackground($gameProcess.MainWindowHandle)
                break
            }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $windowDeadline -and -not $gameProcess.HasExited)
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not $gameProcess.HasExited -and (Get-Date) -lt $deadline) {
        $gameProcess.WaitForExit(250) | Out-Null
        $gameProcess.Refresh()
        if ($BackgroundDataMode -and -not $gameProcess.HasExited -and
            $null -ne $gameProcess.MainWindowHandle -and
            $gameProcess.MainWindowHandle -ne [IntPtr]::Zero) {
            [Nikami.NativeWindow]::MinimizeBackground($gameProcess.MainWindowHandle)
        }
    }
    if (-not $gameProcess.HasExited) {
        Stop-Process -Id $gameProcess.Id -Force
        $gameProcess.WaitForExit()
        throw "Retail oracle timed out after $TimeoutSeconds seconds."
    }
    $exitCode = $null
    try { $exitCode = $gameProcess.ExitCode } catch { $exitCode = $null }
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        throw "FalloutNV oracle process exited with code $exitCode."
    }
}
finally {
    if ($null -ne $gameProcess -and -not $gameProcess.HasExited) {
        Stop-Process -Id $gameProcess.Id -Force -ErrorAction SilentlyContinue
    }
    foreach ($name in $environment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], "Process")
    }
    if (Test-Path -LiteralPath $installedPlugin) {
        Remove-FileWithRetry -Path $installedPlugin
    }
    if ($hadInstalledPlugin -and (Test-Path -LiteralPath $backupPlugin)) {
        Move-Item -LiteralPath $backupPlugin -Destination $installedPlugin
    }
    foreach ($fixture in $fixtureDestinations) {
        if (Test-Path -LiteralPath $fixture.Destination) {
            Remove-FileWithRetry -Path $fixture.Destination
        }
    }
    if ($ScreenshotFrame.Count -gt 0) {
        $newScreenshots = @(Get-ChildItem -LiteralPath $gameRootPath -Filter 'ScreenShot*.bmp' -File |
            Sort-Object LastWriteTime, Name)
        for ($index = 0; $index -lt $newScreenshots.Count; $index++) {
            $frameLabel = if ($index -lt $ScreenshotFrame.Count) {
                '{0:D6}' -f $ScreenshotFrame[$index]
            } else {
                'extra-{0:D3}' -f ($index - $ScreenshotFrame.Count + 1)
            }
            $capturePath = Join-Path $screenshotOutputDirectory "frame-$frameLabel.bmp"
            Move-Item -LiteralPath $newScreenshots[$index].FullName -Destination $capturePath
            $capturedScreenshots += $capturePath
        }
        if (Test-Path -LiteralPath $screenshotBackupDirectory) {
            foreach ($originalScreenshot in @(Get-ChildItem -LiteralPath $screenshotBackupDirectory -File)) {
                Move-Item -LiteralPath $originalScreenshot.FullName -Destination $gameRootPath
            }
            Remove-Item -LiteralPath $screenshotBackupDirectory -Force
        }
    }
}

if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Retail oracle produced no output: $output"
}

$events = @(Get-Content -LiteralPath $output | ForEach-Object { $_ | ConvertFrom-Json })
$faults = @($events | Where-Object { $_.event -match 'fault' })
$snapshots = @($events | Where-Object { $_.event -eq "behavior-snapshot" })
$complete = @($events | Where-Object { $_.event -eq "capture-complete" })
if ($faults.Count -gt 0) {
    throw "Retail oracle reported $($faults.Count) capture fault(s)."
}
if (@($snapshots | Where-Object { $_.label -eq "before" }).Count -ne 1 -or
    @($snapshots | Where-Object { $_.label -eq "after" }).Count -ne 1) {
    throw "Retail oracle did not produce exactly one before and one after behavior snapshot."
}
if ($complete.Count -ne 1) {
    throw "Retail oracle did not report capture completion."
}
$screenshotRequests = @($events | Where-Object { $_.event -eq "screenshot-request" -and $_.accepted })
if ($ScreenshotFrame.Count -gt 0 -and
    ($screenshotRequests.Count -ne $ScreenshotFrame.Count -or $capturedScreenshots.Count -ne $ScreenshotFrame.Count)) {
    throw "Expected $($ScreenshotFrame.Count) accepted screenshot(s), got $($screenshotRequests.Count) request(s) and $($capturedScreenshots.Count) file(s)."
}
if ($PortraitCamera) {
    $portraitEvents = @($events | Where-Object { $_.event -eq "portrait-camera-set" })
    if ($portraitEvents.Count -ne 1) {
        throw "Portrait camera did not resolve and frame exactly one actor head."
    }
    Add-Type -AssemblyName System.Drawing
    foreach ($screenshot in $capturedScreenshots) {
        $sourceImage = [System.Drawing.Bitmap]::FromFile($screenshot)
        try {
            if ($sourceImage.Width -lt 800 -or $sourceImage.Height -lt 600) {
                throw "Portrait screenshot is too small to validate: $screenshot"
            }
            # Preserve the raw retail frame.  The derived square only removes unused
            # peripheral scenery; the head-relative camera keeps the actor in this
            # lower-center safe region at every supported aspect ratio.
            $cropSize = [Math]::Min($sourceImage.Width, [Math]::Floor($sourceImage.Height * 0.875))
            $cropX = [Math]::Floor(($sourceImage.Width - $cropSize) / 2)
            $cropY = $sourceImage.Height - $cropSize
            $proofImage = New-Object System.Drawing.Bitmap(
                $cropSize, $cropSize, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($proofImage)
                try {
                    $sourceRectangle = New-Object System.Drawing.Rectangle($cropX, $cropY, $cropSize, $cropSize)
                    $targetRectangle = New-Object System.Drawing.Rectangle(0, 0, $cropSize, $cropSize)
                    $graphics.DrawImage(
                        $sourceImage, $targetRectangle, $sourceRectangle, [System.Drawing.GraphicsUnit]::Pixel)
                }
                finally {
                    $graphics.Dispose()
                }
                $proofPath = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetDirectoryName($screenshot),
                    [System.IO.Path]::GetFileNameWithoutExtension($screenshot) + '-proof-crop.png')
                $proofImage.Save($proofPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $portraitProofCrops += $proofPath
            }
            finally {
                $proofImage.Dispose()
            }
        }
        finally {
            $sourceImage.Dispose()
        }
    }
}

[pscustomobject][ordered]@{
    schema = "nikami-fnv-retail-oracle-run/v1"
    output = $output
    bytes = (Get-Item -LiteralPath $output).Length
    save = $SaveName
    saveFixture = $resolvedSaveFixture
    quests = @($QuestForm)
    globals = @($GlobalForm)
    commands = @($Command)
    actorCommands = @($ActorCommand)
    furnitureSettledCommands = @($FurnitureSettledCommand)
    exitAfterFurnitureRelease = [bool]$ExitAfterFurnitureRelease
    exitAfterFurnitureSettledSamples = $ExitAfterFurnitureSettledSamples
    furnitureReleaseSamples = $FurnitureReleaseSamples
    backgroundDataMode = [bool]$BackgroundDataMode
    visibleGame = [bool]$VisibleGame
    screenshotFrames = @($ScreenshotFrame)
    screenshots = @($capturedScreenshots)
    portraitProofCrops = @($portraitProofCrops)
    portraitCamera = [bool]$PortraitCamera
    portraitDistance = $PortraitDistance
    setStageQuestForm = $SetStageQuestForm
    setStageIndex = $SetStageIndex
    captureAnimation = [bool]$CaptureAnimation
    furnitureOnly = [bool]$FurnitureOnly
    sampleEvery = $SampleEvery
    targetForm = $TargetForm
    observerApproachForm = $ObserverApproachForm
    observerApproachStopDistance = $ObserverApproachStopDistance
    observerApproachStepDistance = $ObserverApproachStepDistance
    observerWaypoints = @($ObserverWaypoint)
    equipForm = $EquipForm
    playGroup = $PlayGroup
    driveCommand = $DriveCommand
    prepareActorFrame = $PrepareActorFrame
    equipActorFrame = $EquipActorFrame
    driveActorFrame = $DriveActorFrame
    footIkToggleFrame = $FootIkToggleFrame
    footIkToggleEnabled = $FootIkToggleEnabled
    before = @($snapshots | Where-Object { $_.label -eq "before" } | Select-Object -First 1)
    after = @($snapshots | Where-Object { $_.label -eq "after" } | Select-Object -First 1)
    status = "captured"
}
