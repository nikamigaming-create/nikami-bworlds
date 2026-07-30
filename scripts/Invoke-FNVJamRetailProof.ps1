[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$ParityRoot = "D:\code\nikami-worlds-fnv-parity",
    [string]$RetailGameRoot = "D:\SteamLibrary\steamapps\common\Fallout New Vegas",
    [string]$SavePath = "C:\Users\nbrys\OneDrive\Documents\My Games\FalloutNV\Saves\Save 331     Goodsprings  00 17 36.fos",
    [string]$JamArchive = "D:\code\nikami-worlds\local\mod-depot\archives\jam\Just Assorted Mods-66666-4-6-1717763151.7z",
    [string]$JipArchive = "C:\Users\nbrys\Downloads\JIP LN NVSE Plugin-58277-57-30-1716662080.7z",
    [string]$UioArchive = "C:\Users\nbrys\Downloads\UIO - User Interface Organizer-57174-2-30-1629600625.7z",
    [string]$JohnnyArchive = "C:\Users\nbrys\Downloads\JohnnyGuitar NVSE 66927 5.28 2026-05-30T08-10Z XdsyTJhw.zip",
    [string]$StewieArchive = "C:\Users\nbrys\Downloads\Stewie Tweaks 66347 9.95 2026-07-04T10-46Z AMGTXWg1.zip",
    [string]$KnvseArchive = "C:\Users\nbrys\Downloads\kNVSE-71336-37-1731454771.7z",
    [string]$OutputRoot = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$expectedJamArchiveSha256 = "D1101470496E7A8231CFF1355DC62E09B63C5BCEFE3974AB1E4AAC272098DF6B"
$expectedJamPluginSha256 = "CFDC2B1807A57C8861335858DF96A2D08E546F93DFD8C390E8F5905F2694D8DE"
$sevenZip = "C:\Program Files\7-Zip\7z.exe"
$oracleScript = Join-Path $ParityRoot "scripts\Invoke-FNVRetailOracle.ps1"

function Write-Utf8NoBom([string]$Path, [string[]]$Lines) {
    [IO.File]::WriteAllLines($Path, $Lines, [Text.UTF8Encoding]::new($false))
}

function Expand-ArchiveWith7Zip([string]$Archive, [string]$Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    & $sevenZip x -y "-o$Destination" -- $Archive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip failed to extract '$Archive' with exit code $LASTEXITCODE."
    }
}

function Copy-TreeContents([string]$Source, [string]$Destination) {
    foreach ($entry in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item -LiteralPath $entry.FullName -Destination $Destination -Recurse -Force
    }
}

function New-HardLink([string]$Source, [string]$Destination) {
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    New-Item -ItemType HardLink -Path $Destination -Target $Source | Out-Null
}

function Get-PositionSample([object[]]$Snapshots, [int]$Frame) {
    $sample = @($Snapshots | Where-Object { [int]$_.frame -ge $Frame } |
        Sort-Object { [int]$_.frame } | Select-Object -First 1)
    if ($sample.Count -ne 1 -or $null -eq $sample[0].player.position) {
        throw "Retail telemetry has no player position at or after frame $Frame."
    }
    return $sample[0]
}

function Measure-Window([object[]]$Snapshots, [int]$StartFrame, [int]$EndFrame) {
    $start = Get-PositionSample -Snapshots $Snapshots -Frame $StartFrame
    $end = @($Snapshots | Where-Object { [int]$_.frame -le $EndFrame } |
        Sort-Object { [int]$_.frame } -Descending | Select-Object -First 1)
    if ($end.Count -ne 1 -or $null -eq $end[0].player.position) {
        throw "Retail telemetry has no player position at or before frame $EndFrame."
    }
    $dx = [double]$end[0].player.position[0] - [double]$start.player.position[0]
    $dy = [double]$end[0].player.position[1] - [double]$start.player.position[1]
    $dz = [double]$end[0].player.position[2] - [double]$start.player.position[2]
    $frames = [int]$end[0].frame - [int]$start.frame
    if ($frames -le 0) {
        throw "Retail telemetry measurement window has no duration."
    }
    return [ordered]@{
        startFrame = [int]$start.frame
        endFrame = [int]$end[0].frame
        distance = [Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz)
        unitsPerFrame = [Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz) / $frames
        startSpeedMultiplier = [double]$start.player.speedMultiplier
        endSpeedMultiplier = [double]$end[0].player.speedMultiplier
        startActionPoints = [double]$start.vats.actionPoints
        endActionPoints = [double]$end[0].vats.actionPoints
    }
}

foreach ($required in @(
    $sevenZip,
    $oracleScript,
    (Join-Path $RetailGameRoot "FalloutNV.exe"),
    $SavePath,
    $JamArchive,
    $JipArchive,
    $UioArchive,
    $JohnnyArchive,
    $StewieArchive,
    $KnvseArchive
)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing retail JAM proof input: $required"
    }
}

$jamHash = (Get-FileHash -LiteralPath $JamArchive -Algorithm SHA256).Hash
if ($jamHash -ne $expectedJamArchiveSha256) {
    throw "JAM archive hash mismatch. Expected $expectedJamArchiveSha256, got $jamHash."
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputRoot = Join-Path $WorldsRoot "run\jam-retail-oracle-$stamp"
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing retail JAM proof directory: $OutputRoot"
}

$shadowRoot = Join-Path $OutputRoot "retail-game"
$shadowData = Join-Path $shadowRoot "Data"
$stagingRoot = Join-Path $OutputRoot "staging"
$screenshots = Join-Path $OutputRoot "screens"
$oracleOutput = Join-Path $OutputRoot "retail-jam.jsonl"
$reportPath = Join-Path $OutputRoot "retail-proof-report.json"
$stateBackup = Join-Path $OutputRoot "state-backup"
New-Item -ItemType Directory -Path $shadowRoot, $shadowData, $stagingRoot, $screenshots, $stateBackup -Force |
    Out-Null

$rootFiles = @(
    "atimgpud.dll",
    "binkw32.dll",
    "Fallout_default.ini",
    "FalloutNV.exe",
    "FalloutNV.ico",
    "FalloutNVLauncher.exe",
    "GDFFalloutNV.dll",
    "high.ini",
    "libvorbis.dll",
    "libvorbisfile.dll",
    "low.ini",
    "MainTitle.wav",
    "medium.ini",
    "steam_api.dll",
    "VeryHigh.ini"
)
foreach ($relative in $rootFiles) {
    $source = Join-Path $RetailGameRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Retail game root is missing required file: $source"
    }
    New-HardLink -Source $source -Destination (Join-Path $shadowRoot $relative)
}

$retailData = Join-Path $RetailGameRoot "Data"
foreach ($source in @(Get-ChildItem -LiteralPath $retailData -Recurse -File)) {
    $relative = $source.FullName.Substring($retailData.Length).TrimStart('\', '/')
    if ($relative -ieq "FNVR.esp" -or $relative.StartsWith(
            "nvse\", [StringComparison]::OrdinalIgnoreCase)) {
        continue
    }
    New-HardLink -Source $source.FullName -Destination (Join-Path $shadowData $relative)
}

$archives = [ordered]@{
    uio = $UioArchive
    jip = $JipArchive
    johnny = $JohnnyArchive
    stewie = $StewieArchive
    knvse = $KnvseArchive
    jam = $JamArchive
}
$archiveEvidence = [ordered]@{}
foreach ($name in $archives.Keys) {
    $destination = Join-Path $stagingRoot $name
    Expand-ArchiveWith7Zip -Archive $archives[$name] -Destination $destination
    Copy-TreeContents -Source $destination -Destination $shadowData
    $archiveEvidence[$name] = [ordered]@{
        path = [IO.Path]::GetFullPath($archives[$name])
        sha256 = (Get-FileHash -LiteralPath $archives[$name] -Algorithm SHA256).Hash
        bytes = (Get-Item -LiteralPath $archives[$name]).Length
    }
}

$jamPlugin = Join-Path $shadowData "JustAssortedMods.esp"
$jamPluginHash = (Get-FileHash -LiteralPath $jamPlugin -Algorithm SHA256).Hash
if ($jamPluginHash -ne $expectedJamPluginSha256) {
    throw "Extracted JAM plugin hash mismatch. Expected $expectedJamPluginSha256, got $jamPluginHash."
}

$additionalPluginDlls = @(
    (Join-Path $shadowData "nvse\plugins\jip_nvse.dll"),
    (Join-Path $shadowData "nvse\plugins\johnnyguitar.dll"),
    (Join-Path $shadowData "nvse\plugins\kNVSE.dll"),
    (Join-Path $shadowData "nvse\plugins\nvse_stewie_tweaks.dll"),
    (Join-Path $shadowData "nvse\plugins\ui_organizer.dll")
)
foreach ($plugin in $additionalPluginDlls) {
    if (-not (Test-Path -LiteralPath $plugin -PathType Leaf)) {
        throw "Extracted dependency DLL is missing: $plugin"
    }
}

$pluginsPath = Join-Path $env:LOCALAPPDATA "FalloutNV\plugins.txt"
$prefsPath = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "My Games\FalloutNV\FalloutPrefs.ini"
$pluginsExisted = Test-Path -LiteralPath $pluginsPath -PathType Leaf
$prefsExisted = Test-Path -LiteralPath $prefsPath -PathType Leaf
$pluginsBytes = [byte[]]::new(0)
$prefsBytes = [byte[]]::new(0)
if ($pluginsExisted) {
    $pluginsBytes = [IO.File]::ReadAllBytes($pluginsPath)
}
if ($prefsExisted) {
    $prefsBytes = [IO.File]::ReadAllBytes($prefsPath)
}
if ($pluginsExisted) {
    [IO.File]::WriteAllBytes((Join-Path $stateBackup "plugins.txt"), $pluginsBytes)
}
if ($prefsExisted) {
    [IO.File]::WriteAllBytes((Join-Path $stateBackup "FalloutPrefs.ini"), $prefsBytes)
}

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $pluginsPath) -Force | Out-Null
    # Fallout New Vegas predates the asterisk-prefixed plugin.txt format.
    Write-Utf8NoBom -Path $pluginsPath -Lines @("JustAssortedMods.esp")

    if ($prefsExisted) {
        $prefsText = [IO.File]::ReadAllText($prefsPath)
        $prefsText = $prefsText -replace '(?m)^bFull Screen=.*$', 'bFull Screen=0'
        $prefsText = $prefsText -replace '(?m)^iSize W=.*$', 'iSize W=1280'
        $prefsText = $prefsText -replace '(?m)^iSize H=.*$', 'iSize H=720'
        $prefsText = $prefsText -replace '(?m)^bGamepadEnable=.*$', 'bGamepadEnable=0'
        [IO.File]::WriteAllText($prefsPath, $prefsText, [Text.Encoding]::Default)
    }

    $scheduledCommands = @(
        "850:player.SetPos X -72392.8438",
        "851:player.SetPos Y -1240.19263",
        "852:player.SetPos Z 8137.03955",
        "853:player.SetAngle Z 172.45",
        "1080:player.SetPos X -72392.8438",
        "1081:player.SetPos Y -1240.19263",
        "1082:player.SetPos Z 8137.03955",
        "1083:player.SetAngle Z 172.45",
        "1140:player.SetWeaponOut 0",
        "1180:Call JVSOnKeyDownEventHandler 42",
        "1278:GetJohnnyPatch",
        "1279:kNVSEReset",
        '1280:MessageExAlt 20 "HELLO RETAIL PLUGINS - xNVSE 6.4.8 / JIP LN 57.30 / JohnnyGuitar 5.28 / kNVSE 37 / JAM 4.6 ACTIVE - KEY %.0f / CONTROL %.0f / MOVING %.0f / RUNNING %.0f / JAM CONFIG 1.75x / AP %.0f" (IsKeyPressed 42) (IsControlPressed 0) (player.IsMoving) (player.IsRunning) (player.GetAV ActionPoints)'
    )
    $oracleArguments = @{
        GameRoot = $shadowRoot
        OutputPath = $oracleOutput
        SaveFixture = $SavePath
        QuestForm = @("0x0A008800") # JVS start-game-enabled quest
        GlobalForm = @(
            "0x0A008A00", # JVSEnabled
            "0x0A008A01", # JVSKey
            "0x0A008A03", # JVSToggle
            "0x0A008A0B", # JVSSpeedMult
            "0x0A008A0C", # JVSAPDrainMin
            "0x0A008A0D"  # JVSAPDrainMax
        )
        AdditionalPluginDll = $additionalPluginDlls
        ScheduledCommand = $scheduledCommands
        CaptureSession = $true
        BackgroundDataMode = $true
        VisibleGame = $true
        SampleEvery = 1
        BeforeFrame = 800
        CommandFrame = 850
        AfterFrame = 1600
        ScreenshotFrame = @(960, 1300, 1380)
        ScreenshotDirectory = $screenshots
        MaxFrames = 1800
        TimeoutSeconds = 120
    }
    & $oracleScript @oracleArguments
}
finally {
    if ($pluginsExisted) {
        [IO.File]::WriteAllBytes($pluginsPath, $pluginsBytes)
    }
    elseif (Test-Path -LiteralPath $pluginsPath) {
        Remove-Item -LiteralPath $pluginsPath -Force
    }
    if ($prefsExisted) {
        [IO.File]::WriteAllBytes($prefsPath, $prefsBytes)
    }
}

$events = @(Get-Content -LiteralPath $oracleOutput | ForEach-Object { $_ | ConvertFrom-Json })
$commands = @($events | Where-Object { $_.event -eq "scheduled-console-command" })
$rejectedCommands = @($commands | Where-Object { -not [bool]$_.accepted })
if ($commands.Count -ne $scheduledCommands.Count -or $rejectedCommands.Count -ne 0) {
    throw "Retail oracle did not accept the exact JAM input and position-reset schedule."
}
$snapshots = @($events | Where-Object { $_.event -eq "combat-session-snapshot" })
$baseline = Measure-Window -Snapshots $snapshots -StartFrame 930 -EndFrame 990
$sprint = Measure-Window -Snapshots $snapshots -StartFrame 1220 -EndFrame 1280
if ([double]$sprint.distance -le 1) {
    throw "Retail JAM sprint movement did not advance."
}
$speedRatio = [double]$sprint.unitsPerFrame / [double]$baseline.unitsPerFrame
$actionPointDrain = [double]$sprint.startActionPoints - [double]$sprint.endActionPoints
if ($speedRatio -lt 1.45 -or $speedRatio -gt 2.10) {
    throw "Retail JAM physical movement ratio $speedRatio is outside the expected 1.45-2.10 band."
}
if ($actionPointDrain -le 1) {
    throw "Retail JAM sprint did not drain native action points."
}

$baselineScreenshot = Join-Path $screenshots "frame-000960.bmp"
$sprintScreenshot = Join-Path $screenshots "frame-001300.bmp"
foreach ($screenshot in @($baselineScreenshot, $sprintScreenshot)) {
    if (-not (Test-Path -LiteralPath $screenshot -PathType Leaf)) {
        throw "Retail oracle did not produce required native screenshot: $screenshot"
    }
}

$report = [ordered]@{
    schema = "nikami-fnv-jam-retail-proof/v1"
    status = "pass"
    exactJam = [ordered]@{
        version = "4.6"
        archiveSha256 = $jamHash
        pluginSha256 = $jamPluginHash
    }
    dependencies = $archiveEvidence
    engine = [ordered]@{
        kind = "retail-fallout-new-vegas-xnvse"
        executable = [IO.Path]::GetFullPath((Join-Path $shadowRoot "FalloutNV.exe"))
        executableSha256 = (Get-FileHash -LiteralPath (Join-Path $shadowRoot "FalloutNV.exe") -Algorithm SHA256).Hash
    }
    input = [ordered]@{
        source = "real DirectInput W/Left-Shift scan codes plus the untouched JAM JVSOnKeyDownEventHandler through the isolated retail oracle"
        schedule = $scheduledCommands
    }
    baseline = $baseline
    sprint = $sprint
    measuredSpeedRatio = $speedRatio
    actionPointDrain = $actionPointDrain
    screenshots = [ordered]@{
        baseline = [IO.Path]::GetFullPath($baselineScreenshot)
        sprint = [IO.Path]::GetFullPath($sprintScreenshot)
    }
    oracleJsonl = [IO.Path]::GetFullPath($oracleOutput)
}
[IO.File]::WriteAllText(
    $reportPath,
    ($report | ConvertTo-Json -Depth 12),
    [Text.UTF8Encoding]::new($false))

$report | ConvertTo-Json -Depth 12
Write-Host "Retail JAM proof passed: $reportPath"
