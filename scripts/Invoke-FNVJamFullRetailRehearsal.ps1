[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$ParityRoot = "D:\code\nikami-worlds-fnv-parity",
    [string]$ShadowRoot =
        "D:\code\nikami-worlds\run\jam-retail-side-video-20260724-191235\retail-game",
    [string]$SavePath =
        "C:\Users\nbrys\OneDrive\Documents\My Games\FalloutNV\Saves\NikamiCleanPipBoyOracle-20260802.fos",
    [string]$OutputRoot = "",
    [int]$TimeoutSeconds = 130,
    [switch]$SmokeTest,
    [switch]$RecordVideo,
    [ValidateRange(1, 30)]
    [int]$VideoFrameStep = 3,
    [ValidateRange(1, 10000)]
    [int]$VideoStartFrame = 850,
    [ValidateRange(1, 10000)]
    [int]$VideoEndFrame = 3850,
    [ValidateRange(1, 240)]
    [int]$VideoTimelineFrameRate = 60
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputRoot = Join-Path $WorldsRoot "run\jam-retail-full-rehearsal-$stamp"
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing retail rehearsal: $OutputRoot"
}

$oracleScript = Join-Path $ParityRoot "scripts\Invoke-FNVRetailOracle.ps1"
$screenshots = Join-Path $OutputRoot "screens"
$stateBackup = Join-Path $OutputRoot "state-backup"
$oracleOutput = Join-Path $OutputRoot "retail-core.jsonl"

foreach ($required in @(
    $oracleScript,
    $ShadowRoot,
    $SavePath,
    (Join-Path $ShadowRoot "FalloutNV.exe")
)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing retail rehearsal input: $required"
    }
}
if ($RecordVideo) {
    foreach ($tool in @("ffmpeg", "ffprobe")) {
        if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue |
            Select-Object -First 1)) {
            throw "Background retail recording requires $tool on PATH."
        }
    }
    if ($VideoEndFrame -le $VideoStartFrame) {
        throw "VideoEndFrame must be greater than VideoStartFrame."
    }
}

New-Item -ItemType Directory -Path $OutputRoot, $screenshots, $stateBackup -Force |
    Out-Null

$additionalPluginDlls = @(
    (Join-Path $ShadowRoot "Data\nvse\plugins\jip_nvse.dll"),
    (Join-Path $ShadowRoot "Data\nvse\plugins\johnnyguitar.dll"),
    (Join-Path $ShadowRoot "Data\nvse\plugins\kNVSE.dll"),
    (Join-Path $ShadowRoot "Data\nvse\plugins\nvse_stewie_tweaks.dll"),
    (Join-Path $ShadowRoot "Data\nvse\plugins\ui_organizer.dll")
)
foreach ($plugin in $additionalPluginDlls) {
    if (-not (Test-Path -LiteralPath $plugin -PathType Leaf)) {
        throw "Missing retail dependency DLL: $plugin"
    }
}

$scheduledCommands = @(
    "845:EnableBackgroundInputPolling"
    "846:SetControl 6 184 0"
    "847@0x14:FirstPerson"
    "848:player.SetAngle X 0"
    "849:player.SetAngle Y 0"
    "850:player.SetPos X -72392.8438"
    "851:player.SetPos Y -1240.19263"
    "852:player.SetPos Z 8137.03955"
    "853:player.SetAngle Z 157.45"
    "854@0x14:FirstPerson"
    "855@0x14:SetWeaponOut 1"
    "856@0x14:RestoreAV Health 1000"
    "857@0x14:RestoreAV ActionPoints 1000"
    "858@0x14:AddItem 1537EA 50"
    "859@0x14:EquipItem 7EA24"
    "860@0x104f03:Resurrect 1"
    "861@0x104f03:Enable"
    "862@0x104f03:StopCombat"
    "863@0x104f03:RestoreAV Health 1000"
    "864@0x104f03:SetPos X -72000"
    "865@0x104f03:SetPos Y -1000"

    '900:MessageExAlt 5 "01 JDC IDLE / JAM JDCMainLoop / xNVSE UDF+EVENT / JIP UI+SPREAD / RETAIL NATIVE HUD"'
    "980:HoldKey 17"
    '1040:MessageExAlt 5 "02 JDC WALK / LIVE IsMoving %.0f IsRunning %.0f / CROSSHAIR SPREAD EXPANDS" (player.IsMoving) (player.IsRunning)'
    "1120:ReleaseKey 17"
    "1150@0x14:ForceFireWeapon"
    '1170:MessageExAlt 5 "03 JDC FIRE / NATIVE WEAPON SHOT / CROSSHAIR ACTIVE SPREAD"'
    "1220:player.SetAngle X 0"
    "1221:player.SetAngle Y 0"
    '1250:MessageExAlt 5 "04 JDC RECOVER / STOPPED RETICLE RETURNS TO IDLE"'
    "1290:player.SetAngle X 0"
    "1291:player.SetAngle Y 0"
    "1300:HoldKey 184"
    '1330:MessageExAlt 5 "05 JDC ADS / IsControlPressed %.0f / RETICLE ADS MODE" (IsControlPressed 6)'
    "1410:ReleaseKey 184"
    "1420:player.SetAngle X 0"
    "1421:player.SetAngle Y 0"
    "1440@0x104f03:StageInFrontOfPlayer 160"
    '1460:MessageExAlt 5 "06 JDC INTERACT / LIVE ACTOR PROMPT + JAM RETICLE COEXIST"'
    "1520@0x104f03:StartCombat player"
    '1540:MessageExAlt 5 "07 JDC HOSTILE / NATIVE RETICLE SYSTEM COLOR + JAM"'

    "1570@0x104f03:StopCombat"
    "1571:player.SetPos X -72392.8438"
    "1572:player.SetPos Y -1240.19263"
    "1573:player.SetPos Z 8137.03955"
    "1574:player.SetAngle Z 157.45"
    "1575:player.SetAngle X 0"
    "1576:player.SetAngle Y 0"
    "1580@0x104f03:StageInFrontOfPlayer 260"
    "1600@0x104f03:SetWeaponOut 1"
    "1610@0x104f03:ForceFireWeapon"
    "1620@0x14:DamageAV Health 1"
    "1622@0x14:Call JHIOnHitEventHandler -1 104f03"
    '1640:MessageExAlt 5 "08 JHI FRONT / Johnny OnHit / JAM JHIOnHitEventHandler / HP %.0f" (player.GetAV Health)'
    "1680@0x104f03:SetPos X -72628.6"
    "1681@0x104f03:SetPos Y -1340.3"
    "1682@0x104f03:SetPos Z 8137.0"
    "1683@0x104f03:SetAngle Z 67.45"
    "1690@0x14:DamageAV Health 1"
    "1692@0x14:Call JHIOnHitEventHandler -1 104f03"
    '1710:MessageExAlt 5 "09 JHI RIGHT / WORLD HEADING TO SCREEN INDICATOR"'
    "1750@0x104f03:SetPos X -72492.9"
    "1751@0x104f03:SetPos Y -1004.4"
    "1752@0x104f03:SetAngle Z 157.45"
    "1760@0x14:DamageAV Health 1"
    "1762@0x14:Call JHIOnHitEventHandler -1 104f03"
    '1780:MessageExAlt 5 "10 JHI REAR / REAL PLAYER HEALTH LOSS + ROTATED JAM TILE"'
    "1820@0x104f03:SetPos X -72157.0"
    "1821@0x104f03:SetPos Y -1140.1"
    "1822@0x104f03:SetAngle Z 247.45"
    "1830@0x14:DamageAV Health 1"
    "1832@0x14:Call JHIOnHitEventHandler -1 104f03"
    '1850:MessageExAlt 5 "11 JHI LEFT / FRONT RIGHT REAR LEFT COMPLETE"'

    "1900@0x104f03:StopCombat"
    "1901@0x104f03:RestoreAV Health 1000"
    "1902@0x104f03:StageInFrontOfPlayer 260"
    "1920@0x14:ForceFireWeapon"
    "1940@0x104f03:Call JHMOnHitEventHandler"
    "1950:player.SetAngle X 0"
    "1951:player.SetAngle Y 0"
    '1960:MessageExAlt 5 "12 JHM NORMAL HIT / REAL WEAPON FIRE + TARGET HEALTH + JAM MARKER"'
    "2000@0x14:ForceFireWeapon"
    "2020@0x104f03:Call JHMOnHitEventHandler"
    "2030:player.SetAngle X 0"
    "2031:player.SetAngle Y 0"
    '2040:MessageExAlt 5 "13 JHM HEAD/CRIT CLASSIFICATION / JAM MARKER MODE"'
    "2080@0x104f03:Kill player"
    "2090@0x104f03:Call JHMOnHitEventHandler"
    '2110:MessageExAlt 5 "14 JHM KILL / TARGET DEAD + KILL MARKER / THEN FADE"'

    "2180@0x104f03:AddItem 15169 3"
    "2190:Call JLMCrosshairEventHandler 104f03"
    "2220:Call JLMInventoryEventHandler"
    '2240:MessageExAlt 5 "15 JLM OPEN / DEAD ACTOR CONTAINER / JAM LOOT ROWS %.0f" JLM.iTotal'
    "2280:Call JLMOnKeyEventHandler JLMKey1"
    '2310:MessageExAlt 5 "16 JLM TAKE / AUTHORITATIVE INVENTORY TRANSFER / COUNT %.0f" (player.GetItemCount 15169)'
    "2350:Call JLMCrosshairEventHandler 0"
    '2370:MessageExAlt 5 "17 JLM CLOSED / CROSSHAIR MOVED AWAY"'

    "2420:SetCustomMapMarker -72000 -1200 8137"
    "2421:set JVOToggle to 1"
    "2430:Call JVOMainLoopEventHandler"
    "2440:Call JVOCoordinatesEventHandler"
    '2460:MessageExAlt 5 "18 JVO MARKER / Johnny SetCustomMapMarker / JIP WorldToScreen / JAM UI"'
    "2500:SetCustomMapMarker -71800 -900 8137"
    "2510:Call JVOMainLoopEventHandler"
    "2520:Call JVOCoordinatesEventHandler"
    '2540:MessageExAlt 5 "19 JVO MOVED / SCREEN POSITION + DISTANCE UPDATE"'
    "2580:ClearCustomMapMarker"
    "2590:Call JVOMainLoopEventHandler"
    '2610:MessageExAlt 5 "20 JVO HIDDEN / OBJECTIVE CLEARED"'

    "2660@0x14:AddItem 7ea24 1"
    "2661@0x14:AddItem 421c 1"
    "2670:set JWHToggle to 1"
    "2680:Call JWHOnKeyDownEventHandler JWHKey"
    '2700:MessageExAlt 5 "21 JWH OPEN / JAM WHEEL + REAL INVENTORY / Johnny EVENT LAYER"'
    "2740:Call JWHMenuOnKeyDownEventHandler 79"
    '2760:MessageExAlt 5 "22 JWH SLICE ONE / LIVE WHEEL SELECTION"'
    "2800:Call JWHMenuOnKeyDownEventHandler 80"
    '2820:MessageExAlt 5 "23 JWH DIFFERENT SLICE / LIVE HIGHLIGHT"'
    "2860:Call JWHOnKeyDownEventHandler JWHKey"
    "2870:Call JWHMainLoopEventHandler"
    '2890:MessageExAlt 5 "24 JWH CLOSE / SELECTED WEAPON EQUIPPED"'

    "2940@0x14:RestoreAV ActionPoints 1000"
    "2950:Call JBTOnKeyEventHandler JBTKey"
    '2980:MessageExAlt 5 "25 JBT ACTIVE / JAM BULLET TIME / TIME %.2f AP %.0f" (GetGlobalTimeMultiplier) (player.GetAV ActionPoints)'
    "3060:Call JBTOnKeyEventHandler JBTKey"
    "3070:Call JBTMainLoopEventHandler"
    '3090:MessageExAlt 5 "26 JBT RESTORED / NATIVE TIME %.2f AP %.0f" (GetGlobalTimeMultiplier) (player.GetAV ActionPoints)'

    "3140:set JHBModeOut to 1"
    "3141@0x14:RestoreAV ActionPoints 1000"
    "3145:HoldKey 184"
    "3150:Call JHBOnKeyDownEventHandler JHBKey"
    '3180:MessageExAlt 5 "27 JHB HOLD BREATH / JAM PERK+EFFECT / ACTIVE %.0f AP %.0f" JHB.iHoldBreath (player.GetAV ActionPoints)'
    "3250:set JHB.iDisable to 1"
    "3260:Call JHBMainLoopEventHandler"
    "3265:ReleaseKey 184"
    '3280:MessageExAlt 5 "28 JHB RELEASE / BASELINE SWAY RESTORED / ACTIVE %.0f" JHB.iHoldBreath'

    '3330@0x14:SetActorAnimationPath 0 1 "characters\_male\idleanims\sprint\specialidle_sprint.kf"'
    '3340@0x14:PlayAnimationPath "characters\_male\idleanims\sprint\specialidle_sprint.kf"'
    '3360:MessageExAlt 5 "29 kNVSE PROBE NOT JAM / REAL JAM KF OVERRIDE INSTALLED + PLAYED"'
    '3420@0x14:SetActorAnimationPath 0 0 "characters\_male\idleanims\sprint\specialidle_sprint.kf"'
    "3430:kNVSEReset"
    '3440@0x14:PlayAnimationPath "characters\_male\locomotion\mtidle.kf"'
    '3460:MessageExAlt 5 "30 kNVSE RESTORE / OVERRIDE REMOVED / ORIGINAL MTIDLE REPLAYED"'

    "3480:player.SetPos X -72392.8438"
    "3481:player.SetPos Y -1240.19263"
    "3482:player.SetPos Z 8137.03955"
    "3483:player.SetAngle Z 157.45"
    "3485:player.SetAngle X 0"
    "3486:player.SetAngle Y 0"
    "3484@0x104f03:Disable"
    "3510@0x14:RestoreAV ActionPoints 1000"
    "3520:HoldKey 17"
    '3560:MessageExAlt 5 "31 JVS BASELINE RUN / xNVSE KEY + JIP PLAYER STATE"'
    "3620:HoldKey 42"
    "3630:Call JVSOnKeyDownEventHandler 42"
    '3660:MessageExAlt 5 "32 JVS SPRINT / JAM ACTIVE %.0f / AP %.0f / LIVE 1.75x" JVS.iSprinting (player.GetAV ActionPoints)'
    "3740:ReleaseKey 42"
    "3750:Call JVSMainLoopEventHandler"
    '3770:MessageExAlt 5 "33 JVS RELEASE / SPEED RESTORED + AP RECOVERY"'
    "3810:ReleaseKey 17"
)

$screenshotFrames = @(
    920, 1060, 1180, 1260, 1340, 1460, 1540,
    1640, 1710, 1780, 1850,
    1960, 2040, 2110,
    2240, 2310, 2370,
    2460, 2540, 2610,
    2700, 2760, 2820, 2890,
    2980, 3090,
    3180, 3280,
    3360, 3460,
    3560, 3660, 3770
)
$maxFrames = 3900
$afterFrame = 3850

if ($SmokeTest) {
    $scheduledCommands = @(
        "845:EnableBackgroundInputPolling"
        "846:SetControl 6 184 0"
        "847:player.SetAngle X 0"
        "848:player.SetAngle Y 0"
        "850:player.SetAngle Z 157.45"
        '860:MessageExAlt 1 "RETAIL ORACLE SMOKE / BEFORE MOVE / JAM SCHEDULE LIVE"'
        "880:HoldKey 17"
        '900:MessageExAlt 1 "RETAIL ORACLE SMOKE / WALKING %.0f / xNVSE HOLDKEY -> RETAIL INPUT" (player.IsMoving)'
        "940:HoldKey 42"
        "945:Call JVSOnKeyDownEventHandler 42"
        '960:MessageExAlt 1 "RETAIL ORACLE SMOKE / JAM SPRINT %.0f / W+SHIFT -> JVS HANDLER" JVS.iSprinting'
        "1010:ReleaseKey 42"
        "1011:Call JVSMainLoopEventHandler"
        "1020:ReleaseKey 17"
        '1040:MessageExAlt 1 "RETAIL ORACLE SMOKE / STOPPED %.0f / INPUT RELEASED" (player.IsMoving)'
    )
    $screenshotFrames = @(870, 920, 980, 1060)
    $maxFrames = 1100
    $afterFrame = 1080
    if ($RecordVideo) {
        $VideoStartFrame = 850
        $VideoEndFrame = 1080
    }
}

if ($RecordVideo) {
    $videoFrames = @($VideoStartFrame..$VideoEndFrame |
        Where-Object { ($_ - $VideoStartFrame) % $VideoFrameStep -eq 0 })
    $screenshotFrames = @($screenshotFrames + $videoFrames |
        Sort-Object -Unique)
}

# JIP's HUD queue is intentionally serialized. Clear it one frame before every
# proof banner so the native capture labels the state that is actually on screen,
# rather than a previously queued chapter.
$scheduledCommands = @($scheduledCommands | ForEach-Object {
    if ($_ -match '^(\d+):MessageExAlt\b') {
        '{0}:ClearMessageQueue' -f ([int]$Matches[1] - 1)
    }
    $_
})

$pluginsPath = Join-Path $env:LOCALAPPDATA "FalloutNV\plugins.txt"
$prefsPath = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "My Games\FalloutNV\FalloutPrefs.ini"
$pluginsExisted = Test-Path -LiteralPath $pluginsPath -PathType Leaf
$prefsExisted = Test-Path -LiteralPath $prefsPath -PathType Leaf
[byte[]]$pluginsBytes = [byte[]]::new(0)
[byte[]]$prefsBytes = [byte[]]::new(0)
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
    New-Item -ItemType Directory -Path (Split-Path -Parent $pluginsPath) -Force |
        Out-Null
    [IO.File]::WriteAllLines(
        $pluginsPath, @("JustAssortedMods.esp"), [Text.UTF8Encoding]::new($false))

    if ($prefsExisted) {
        $prefsText = [IO.File]::ReadAllText($prefsPath)
        $prefsText = $prefsText -replace '(?m)^bFull Screen=.*$', 'bFull Screen=0'
        $prefsText = $prefsText -replace '(?m)^iSize W=.*$', 'iSize W=1280'
        $prefsText = $prefsText -replace '(?m)^iSize H=.*$', 'iSize H=720'
        $prefsText = $prefsText -replace '(?m)^bGamepadEnable=.*$', 'bGamepadEnable=0'
        [IO.File]::WriteAllText($prefsPath, $prefsText, [Text.Encoding]::Default)
    }

    & $oracleScript `
        -GameRoot $ShadowRoot `
        -OutputPath $oracleOutput `
        -SaveFixture $SavePath `
        -QuestForm @(
            "0x0A001800", "0x0A002800", "0x0A003800", "0x0A004800",
            "0x0A005800", "0x0A006800", "0x0A008800", "0x0A009800",
            "0x0A00A800"
        ) `
        -AdditionalPluginDll $additionalPluginDlls `
        -ScheduledCommand $scheduledCommands `
        -CaptureSession `
        -BackgroundDataMode `
        -VisibleGame `
        -SampleEvery 2 `
        -BeforeFrame 820 `
        -CommandFrame 850 `
        -AfterFrame $afterFrame `
        -ScreenshotFrame $screenshotFrames `
        -ScreenshotDirectory $screenshots `
        -MaxFrames $maxFrames `
        -TimeoutSeconds $TimeoutSeconds
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

$events = @(Get-Content -LiteralPath $oracleOutput | ForEach-Object {
    $_ | ConvertFrom-Json
})
$commands = @($events | Where-Object { $_.event -eq "scheduled-console-command" })
$rejectedCommands = @($commands | Where-Object { -not [bool]$_.accepted })
$captures = @($events | Where-Object { $_.event -eq "scheduled-backbuffer-capture" })
$snapshots = @($events | Where-Object { $_.event -eq "combat-session-snapshot" })
$backgroundInputEvents = @($events |
    Where-Object { $_.event -eq "background-input-polling" })
$backgroundInput = if ($backgroundInputEvents.Count -gt 0) {
    $backgroundInputEvents[-1]
} else {
    $null
}
$backgroundKeyboardDevices = @(if ($null -ne $backgroundInput) {
    $backgroundInput.devices | Where-Object {
        [bool]$_.selected -and [bool]$_.reconfigured
    }
})
$backgroundOtherDevicesUntouched = $null -ne $backgroundInput -and
    @($backgroundInput.devices | Where-Object {
        -not [bool]$_.selected -and [bool]$_.reconfigured
    }).Count -eq 0
$backgroundInputPassed = $null -ne $backgroundInput -and
    [bool]$backgroundInput.accepted -and
    $backgroundKeyboardDevices.Count -eq 1 -and
    $backgroundOtherDevicesUntouched
$pitchSamples = @($snapshots | Where-Object {
    $null -ne $_.player -and $null -ne $_.player.rotation
} | ForEach-Object {
    [Math]::Abs([double]$_.player.rotation[0])
})
$maximumAbsolutePlayerPitch = if ($pitchSamples.Count -gt 0) {
    [double](($pitchSamples | Measure-Object -Maximum).Maximum)
} else {
    [double]::PositiveInfinity
}
$motionEvidence = $null
if ($SmokeTest) {
    function Get-SmokePosition([int]$Frame) {
        $sample = @($snapshots | Where-Object { [int]$_.frame -ge $Frame } |
            Sort-Object { [int]$_.frame } | Select-Object -First 1)
        if ($sample.Count -ne 1 -or $null -eq $sample[0].player.position) {
            throw "Retail smoke telemetry has no player position at or after frame $Frame."
        }
        return $sample[0]
    }
    function Get-SmokeDistance([object]$Start, [object]$End) {
        $dx = [double]$End.player.position[0] - [double]$Start.player.position[0]
        $dy = [double]$End.player.position[1] - [double]$Start.player.position[1]
        $dz = [double]$End.player.position[2] - [double]$Start.player.position[2]
        return [Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz)
    }
    $beforeMotion = Get-SmokePosition -Frame 870
    $walkMotion = Get-SmokePosition -Frame 930
    $sprintMotion = Get-SmokePosition -Frame 1000
    $stoppedMotion = Get-SmokePosition -Frame 1070
    $motionEvidence = [ordered]@{
        beforeFrame = [int]$beforeMotion.frame
        walkFrame = [int]$walkMotion.frame
        sprintFrame = [int]$sprintMotion.frame
        stoppedFrame = [int]$stoppedMotion.frame
        walkDistance = Get-SmokeDistance -Start $beforeMotion -End $walkMotion
        totalActiveDistance = Get-SmokeDistance -Start $beforeMotion -End $sprintMotion
        postReleaseDistance = Get-SmokeDistance -Start $sprintMotion -End $stoppedMotion
    }
}

$video = $null
if ($RecordVideo) {
    $capturedVideoFrames = @(Get-ChildItem -LiteralPath $screenshots -File -Filter "frame-*.bmp" |
        ForEach-Object {
            $match = [regex]::Match($_.BaseName, '^frame-(?<frame>[0-9]+)$')
            if ($match.Success) {
                [pscustomobject]@{
                    frame = [int]$match.Groups["frame"].Value
                    file = $_
                }
            }
        } |
        Where-Object {
            $_.frame -ge $VideoStartFrame -and $_.frame -le $VideoEndFrame
        } |
        Sort-Object frame)
    $expectedVideoFrameCount = [Math]::Floor(
        ($VideoEndFrame - $VideoStartFrame) / $VideoFrameStep) + 1
    if ($capturedVideoFrames.Count -lt $expectedVideoFrameCount) {
        throw "Retail background video is missing native frames: expected at least " +
            "$expectedVideoFrameCount, got $($capturedVideoFrames.Count)."
    }

    $concatPath = Join-Path $OutputRoot "retail-native-frames.ffconcat"
    $concatLines = [Collections.Generic.List[string]]::new()
    $concatLines.Add("ffconcat version 1.0")
    for ($index = 0; $index -lt $capturedVideoFrames.Count; ++$index) {
        $escapedPath = $capturedVideoFrames[$index].file.FullName.Replace(
            "'", "'\''")
        $concatLines.Add("file '$escapedPath'")
        $durationFrames = if ($index + 1 -lt $capturedVideoFrames.Count) {
            $capturedVideoFrames[$index + 1].frame -
                $capturedVideoFrames[$index].frame
        } else {
            $VideoFrameStep
        }
        $duration = [double]$durationFrames / [double]$VideoTimelineFrameRate
        $concatLines.Add(
            "duration " + $duration.ToString(
                "0.000000000", [Globalization.CultureInfo]::InvariantCulture))
    }
    $lastEscapedPath = $capturedVideoFrames[-1].file.FullName.Replace(
        "'", "'\''")
    $concatLines.Add("file '$lastEscapedPath'")
    [IO.File]::WriteAllLines(
        $concatPath, $concatLines, [Text.UTF8Encoding]::new($false))

    $videoPath = Join-Path $OutputRoot "Retail-FNV-JAM-4.6-background-native.mp4"
    & ffmpeg -hide_banner -loglevel warning -y `
        -f concat -safe 0 -i $concatPath `
        -vf "fps=60,scale=1280:720:flags=lanczos" `
        -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p `
        -movflags +faststart $videoPath
    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath $videoPath -PathType Leaf)) {
        throw "ffmpeg failed to encode the retail native-frame recording."
    }
    $probe = & ffprobe -v error `
        -show_entries format=duration,size `
        -show_entries stream=width,height,avg_frame_rate,nb_frames `
        -of json $videoPath | ConvertFrom-Json
    $video = [ordered]@{
        captureMethod = "retail-d3d9-backbuffer-bmp-sequence"
        windowsAppControlUsed = $false
        foregroundRequired = $false
        sourceFrames = $capturedVideoFrames.Count
        sourceFrameStep = $VideoFrameStep
        timelineFrameRate = $VideoTimelineFrameRate
        path = $videoPath
        sha256 = (Get-FileHash -LiteralPath $videoPath -Algorithm SHA256).Hash.ToLowerInvariant()
        width = [int]$probe.streams[0].width
        height = [int]$probe.streams[0].height
        frameRate = [string]$probe.streams[0].avg_frame_rate
        frameCount = [long]$probe.streams[0].nb_frames
        duration = [double]::Parse(
            [string]$probe.format.duration,
            [Globalization.CultureInfo]::InvariantCulture)
        bytes = [long]$probe.format.size
    }
}

$summary = [ordered]@{
    schema = "nikami-fnv-jam-full-retail-rehearsal/v1"
    status = if (
        $commands.Count -eq $scheduledCommands.Count -and
        $rejectedCommands.Count -eq 0 -and
        $backgroundInputPassed -and
        $maximumAbsolutePlayerPitch -le 0.25 -and
        (Get-ChildItem -LiteralPath $screenshots -Filter "frame-*.bmp").Count -eq
            $screenshotFrames.Count -and
        (-not $RecordVideo -or $null -ne $video) -and
        (-not $SmokeTest -or (
            [double]$motionEvidence.walkDistance -gt 1 -and
            [double]$motionEvidence.totalActiveDistance -gt
                [double]$motionEvidence.walkDistance
        ))
    ) {
        "pass"
    } else {
        "fail"
    }
    scheduledCommandCount = $scheduledCommands.Count
    acceptedCommandCount = $commands.Count - $rejectedCommands.Count
    rejectedCommands = @($rejectedCommands | ForEach-Object {
        [ordered]@{
            frame = $_.frame
            command = $_.command
        }
    })
    requestedScreenshotCount = $screenshotFrames.Count
    screenshotCount =
        @(Get-ChildItem -LiteralPath $screenshots -Filter "frame-*.bmp").Count
    backgroundCapture = [ordered]@{
        inputPollingAccepted = if ($null -ne $backgroundInput) {
            [bool]$backgroundInput.accepted
        } else {
            $false
        }
        keyboardDevicesReconfigured = $backgroundKeyboardDevices.Count
        nonKeyboardDevicesUntouched = $backgroundOtherDevicesUntouched
        maximumAbsolutePlayerPitchRadians = $maximumAbsolutePlayerPitch
        windowsAppControlUsed = $false
        foregroundRequired = $false
    }
    video = $video
    motionEvidence = $motionEvidence
    telemetry = $oracleOutput
}

$summaryPath = Join-Path $OutputRoot "rehearsal-summary.json"
[IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))
$summary | ConvertTo-Json -Depth 8

if ($summary.status -ne "pass") {
    throw "Full retail JAM rehearsal failed. See $summaryPath"
}
