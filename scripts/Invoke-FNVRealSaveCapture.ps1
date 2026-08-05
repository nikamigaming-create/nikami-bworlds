[CmdletBinding()]
param(
    [ValidateSet("Retail", "OpenMW")]
    [string]$Target,
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$SavePath = "D:\code\nikami-worlds\local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos",
    [string]$BinaryRoot = "",
    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,
    [ValidateSet("save330-cold-load-settle-v1", "save330-reload-idempotence-v1", "save330-pipboy-map-selection-v1", "save330-pipboy-map-travel-v1", "save330-pipboy-rejection-matrix-v1", "save330-travel-persistence-v1", "save330-pipboy-inventory-v1", "save330-pipboy-weapon-selection-v1")]
    [string]$RouteId = "save330-cold-load-settle-v1",
    [ValidateSet("", "invBindThenSkeleton", "skeleton", "skeletonThenInvBind", "bindThenSkeleton", "skeletonThenBind", "source", "identity")]
    [string]$HandSkinningMode = "",
    [switch]$HandPoseAudit,
    [ValidateRange(5, 600)]
    [int]$CaptureSeconds = 30,
    [switch]$InteractiveHandoff,
    [ValidateRange(30, 900)]
    [int]$TimeoutSeconds = 240
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Quote-OpenMWArgument {
    param([Parameter(Mandatory = $true)][string]$Argument)

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }
    return '"' + ($Argument -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-Artifact {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $file = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $file.FullName
        bytes = [long]$file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Save-And-ClearOpenMWEnvironment {
    $previous = @{}
    foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })) {
        if ($name.StartsWith("OPENMW_", [StringComparison]::OrdinalIgnoreCase)) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
    return $previous
}

function Restore-Environment {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Previous,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        if (-not $Previous.ContainsKey($name)) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
    foreach ($entry in $Previous.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process")
    }
}

function Save-AsyncProcessStreams {
    param(
        [Parameter(Mandatory = $true)][System.Threading.Tasks.Task[string]]$StandardOutputTask,
        [Parameter(Mandatory = $true)][System.Threading.Tasks.Task[string]]$StandardErrorTask,
        [Parameter(Mandatory = $true)][string]$StandardOutputPath,
        [Parameter(Mandatory = $true)][string]$StandardErrorPath
    )

    [IO.File]::WriteAllText(
        $StandardOutputPath,
        $StandardOutputTask.GetAwaiter().GetResult(),
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $StandardErrorPath,
        $StandardErrorTask.GetAwaiter().GetResult(),
        [Text.UTF8Encoding]::new($false))
}

function Set-CaptureProfileSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $lines = [Collections.Generic.List[string]]::new([string[]](Get-Content -LiteralPath $Path))
    $sectionHeader = "[$Section]"
    $sectionStart = -1
    $sectionEnd = $lines.Count
    for ($index = 0; $index -lt $lines.Count; ++$index) {
        if ($lines[$index].Trim().Equals($sectionHeader, [StringComparison]::OrdinalIgnoreCase)) {
            $sectionStart = $index
            for ($next = $index + 1; $next -lt $lines.Count; ++$next) {
                if ($lines[$next] -match '^\s*\[.+\]\s*$') {
                    $sectionEnd = $next
                    break
                }
            }
            break
        }
    }

    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    if ($sectionStart -lt 0) {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines.Add("")
        }
        $lines.Add($sectionHeader)
        $lines.Add("$Key = $Value")
    }
    else {
        $written = $false
        for ($index = $sectionStart + 1; $index -lt $sectionEnd; ++$index) {
            if ($lines[$index] -match $keyPattern) {
                $lines[$index] = "$Key = $Value"
                $written = $true
                break
            }
        }
        if (-not $written) {
            $lines.Insert($sectionEnd, "$Key = $Value")
        }
    }

    [IO.File]::WriteAllText(
        $Path,
        (($lines -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false))
}

function Get-SourceDenominator {
    param([Parameter(Mandatory = $true)][string]$Root)

    $path = Join-Path $Root "run\fnv-real-save-campaign\save330-player-denominator.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing normalized Save330 denominator required by the RealSave state manifest: $path"
    }
    return [pscustomobject]@{
        path = [IO.Path]::GetFullPath($path)
        evidence = Get-Artifact $path
        json = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    }
}

function Get-OpenMWLogText {
    param(
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][string]$ProfileDirectory
    )

    $parts = [Collections.Generic.List[string]]::new()
    foreach ($path in @($StdoutPath, $StderrPath, (Join-Path $ProfileDirectory "openmw.log"))) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $parts.Add((Get-Content -Raw -LiteralPath $path))
        }
    }
    return $parts -join [Environment]::NewLine
}

function Get-RealSaveRuntimeObservation {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$LogText,
        [Parameter(Mandatory = $true)][pscustomobject]$Denominator,
        [switch]$AllowOpenMWSaveReload,
        [AllowNull()][pscustomobject]$ExpectedTransform
    )

    $json = $Denominator.json
    $transform = $json.transform
    $worldspace = [string]$transform.cellOrWorldspace.value
    $position = @($transform.position | ForEach-Object { [double]$_.value })
    $rotation = @($transform.rotationRadians | ForEach-Object { [double]$_.value })
    if ($null -ne $ExpectedTransform) {
        if ($ExpectedTransform.PSObject.Properties.Name -contains "worldspace" -and
            -not [string]::IsNullOrWhiteSpace([string]$ExpectedTransform.worldspace)) {
            $worldspace = [string]$ExpectedTransform.worldspace
        }
        if ($ExpectedTransform.PSObject.Properties.Name -contains "position" -and
            @($ExpectedTransform.position).Count -eq 3) {
            $position = @($ExpectedTransform.position | ForEach-Object { [double]$_ })
        }
        if ($ExpectedTransform.PSObject.Properties.Name -contains "rotation" -and
            @($ExpectedTransform.rotation).Count -eq 3) {
            $rotation = @($ExpectedTransform.rotation | ForEach-Object { [double]$_ })
        }
    }
    $playerIdentity = [ordered]@{
        baseRecord = [string]$json.player.baseRecord.value
        referenceRecord = [string]$json.player.referenceRecord.value
    }
    $telemetryPattern = 'World viewer telemetry: frame=(?<frame>\d+) state=(?<state>-?\d+) loadingGui=(?<loadingGui>[01]) worldReady=(?<worldReady>[01]) readyFrames=(?<readyFrames>\d+) activeCells=(?<activeCells>\d+) hour=(?<hour>[-+0-9.eE]+) weatherId=(?<weatherId>-?\d+) weatherTransition=(?<weatherTransition>[-+0-9.eE]+) playerCell="(?<cell>[^"]+)" exterior=(?<exterior>[01]) grid=\((?<gridX>-?\d+),(?<gridY>-?\d+)\) worldspace=(?<worldspace>[^ ]+) playerPos=\((?<px>[-+0-9.eE]+),(?<py>[-+0-9.eE]+),(?<pz>[-+0-9.eE]+)\) playerRot=\((?<rx>[-+0-9.eE]+),(?<ry>[-+0-9.eE]+),(?<rz>[-+0-9.eE]+)\) cameraMode=(?<cameraMode>-?\d+) cameraPos=\((?<cx>[-+0-9.eE]+),(?<cy>[-+0-9.eE]+),(?<cz>[-+0-9.eE]+)\) cameraPitch=(?<pitch>[-+0-9.eE]+) cameraYaw=(?<yaw>[-+0-9.eE]+) playerHealth=(?<health>[-+0-9.eE]+) playerActionPoints=(?<actionPoints>[-+0-9.eE]+) playerActionPointsMax=(?<actionPointsMax>[-+0-9.eE]+)'
    $telemetryMatches = [regex]::Matches($LogText, $telemetryPattern)
    $telemetryObservations = @($telemetryMatches | ForEach-Object {
        $match = $_
        [ordered]@{
            frame = [int]$match.Groups["frame"].Value
            state = [int]$match.Groups["state"].Value
            loadingGui = $match.Groups["loadingGui"].Value -eq "1"
            worldReady = $match.Groups["worldReady"].Value -eq "1"
            readyFrames = [int]$match.Groups["readyFrames"].Value
            activeCells = [int]$match.Groups["activeCells"].Value
            gameHour = [double]$match.Groups["hour"].Value
            weatherId = [int]$match.Groups["weatherId"].Value
            weatherTransition = [double]$match.Groups["weatherTransition"].Value
            cell = $match.Groups["cell"].Value
            exterior = $match.Groups["exterior"].Value -eq "1"
            grid = @([int]$match.Groups["gridX"].Value, [int]$match.Groups["gridY"].Value)
            worldspace = $match.Groups["worldspace"].Value
            position = @([double]$match.Groups["px"].Value, [double]$match.Groups["py"].Value, [double]$match.Groups["pz"].Value)
            rotation = @([double]$match.Groups["rx"].Value, [double]$match.Groups["ry"].Value, [double]$match.Groups["rz"].Value)
            cameraMode = [int]$match.Groups["cameraMode"].Value
            cameraPosition = @([double]$match.Groups["cx"].Value, [double]$match.Groups["cy"].Value, [double]$match.Groups["cz"].Value)
            cameraPitch = [double]$match.Groups["pitch"].Value
            cameraYaw = [double]$match.Groups["yaw"].Value
            health = [double]$match.Groups["health"].Value
            actionPoints = [double]$match.Groups["actionPoints"].Value
            actionPointsMax = [double]$match.Groups["actionPointsMax"].Value
        }
    })
    $readyTelemetry = @($telemetryObservations | Where-Object { $_.worldReady })
    $observed = if ($readyTelemetry.Count -gt 0) { $readyTelemetry[0] } elseif ($telemetryObservations.Count -gt 0) { $telemetryObservations[0] } else { $null }
    $settledObserved = if ($telemetryObservations.Count -gt 0) { $telemetryObservations[-1] } else { $null }

    $syntheticPlacementTokens = @(
        "Test" + "Map01",
        "explicit " + "exterior start location",
        "gameplay " + "start placement",
        "FNV " + "bootstrap"
    )
    $syntheticPlacementPattern = "(?i)(" + (($syntheticPlacementTokens | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")"
    $fallbackInventoryPattern = "(?i)(fallback inventory|bootstrap inventory|FNV_PROOF inventory|" +
        ([regex]::Escape("Test" + "Map01")) + "|" +
        ([regex]::Escape("explicit " + "exterior start location")) + ")"
    $positionPass = $false
    $rotationPass = $false
    $worldspacePass = $false
    if ($null -ne $observed) {
        $positionPass = if ($AllowOpenMWSaveReload) {
            [Math]::Abs($observed.position[0] - $position[0]) -le 0.5 -and
                [Math]::Abs($observed.position[1] - $position[1]) -le 0.5 -and
                [Math]::Abs($observed.position[2] - $position[2]) -le 5.0
        }
        else {
            @(0..2 | Where-Object {
                [Math]::Abs($observed.position[$_] - $position[$_]) -le 0.5
            }).Count -eq 3
        }
        $rotationPass = (@(0..2 | Where-Object {
            [Math]::Abs($observed.rotation[$_] - $rotation[$_]) -le 0.01
        }).Count -eq 3)
        $observedWorldspaceMatch = [regex]::Match($observed.worldspace, '0x(?<form>[0-9a-fA-F]{1,8})')
        $expectedWorldspaceValue = [Convert]::ToUInt32($worldspace.Substring(2), 16)
        $worldspacePass = $observedWorldspaceMatch.Success -and
            (([Convert]::ToUInt32($observedWorldspaceMatch.Groups["form"].Value, 16) -band 0x00ffffff) -eq
                ($expectedWorldspaceValue -band 0x00ffffff))
    }

    $ordinaryLoadPathObserved = $LogText -match 'loading save from command line'
    $openMwSaveLoadObserved = $LogText -match '(?i)Reading save file .*\.omwsave' -and
        $LogText -match '(?i)Loading saved game '
    $openMwPersistenceTelemetryObserved = $LogText -match 'FNV B04 persistence: OpenMW save player inventory stacks=\d+ visible=\d+ worn=\d+'
    $nativeInventoryObserved = $LogText -match 'Native FNV save Player runtime inventory rebuilt: stacks=\d+ visible=\d+'
    $persistenceInventoryObserved = $LogText -match 'FNV B04 persistence: OpenMW save player inventory stacks=\d+ visible=\d+ worn=\d+'
    $nativeIdentityRestored = $LogText -match 'Native FNV save Player identity restored:'
    $persistenceIdentityRestored = $LogText -match 'FNV B04 persistence: OpenMW save player identity initialized=1'
    $nativeCameraOwnershipObserved = $LogText -match 'Native FNV save owns camera mode='
    $standardReloadPass = $AllowOpenMWSaveReload -and
        $ordinaryLoadPathObserved -and $openMwSaveLoadObserved -and $openMwPersistenceTelemetryObserved -and
        $persistenceInventoryObserved -and $persistenceIdentityRestored -and $null -ne $observed -and
        $worldspacePass -and $positionPass -and $rotationPass -and
        $LogText -notmatch $fallbackInventoryPattern
    $nativeLoadPass = -not $AllowOpenMWSaveReload -and
        $ordinaryLoadPathObserved -and
        $LogText -match 'Native FNV save structural parse complete: masters=10' -and
        $nativeIdentityRestored -and
        $LogText -match 'Native FNV save Player inventory: stacks=\d+ worn=\d+' -and
        $nativeInventoryObserved -and
        $nativeCameraOwnershipObserved -and $null -ne $observed -and $worldspacePass -and $positionPass -and
        $rotationPass -and $LogText -notmatch $fallbackInventoryPattern

    [ordered]@{
        validationMode = if ($AllowOpenMWSaveReload) { "standard-openmw-save-reload" } else { "native-fos-save-load" }
        ordinaryLoadPathObserved = $ordinaryLoadPathObserved
        openMwSaveLoadObserved = $openMwSaveLoadObserved
        openMwPersistenceTelemetryObserved = $openMwPersistenceTelemetryObserved
        structuralParseObserved = $LogText -match 'Native FNV save structural parse complete: masters=10'
        nativeSaveCameraOwnershipObserved = $nativeCameraOwnershipObserved
        playerIdentity = $playerIdentity
        playerIdentityRestored = $nativeIdentityRestored -or $persistenceIdentityRestored
        inventoryRebuild = [ordered]@{
            observed = $nativeInventoryObserved -or $persistenceInventoryObserved
            nativeObserved = $nativeInventoryObserved
            openMwPersistenceObserved = $persistenceInventoryObserved
            savedPlanObserved = ($LogText -match 'Native FNV save Player inventory: stacks=\d+ worn=\d+') -or
                $persistenceInventoryObserved
            fallbackInventoryAbsent = $LogText -notmatch '(?i)(fallback inventory|bootstrap inventory|FNV_PROOF inventory)'
        }
        observed = $observed
        telemetry = [ordered]@{
            count = $telemetryObservations.Count
            readyCount = $readyTelemetry.Count
            initial = $observed
            latest = $settledObserved
        }
        transform = [ordered]@{
            expectedWorldspace = $worldspace
            expectedPosition = $position
            expectedRotation = $rotation
            worldspaceMatches = $worldspacePass
            positionMatches = $positionPass
            rotationMatches = $rotationPass
        }
        noSyntheticPlacement = $LogText -notmatch $syntheticPlacementPattern
        loadComplete = if ($AllowOpenMWSaveReload) {
            $standardReloadPass
        }
        else {
            $nativeCameraOwnershipObserved
        }
        pass = $nativeLoadPass -or $standardReloadPass
    }
}

function Invoke-RetailRealSaveCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Fixture,
        [Parameter(Mandatory = $true)][string]$Worlds
    )

    $oracle = Join-Path $Worlds "scripts\Invoke-FNVRetailOracle.ps1"
    $telemetry = Join-Path $Root "retail-real-save.jsonl"
    $frames = Join-Path $Root "native-d3d9-frames"
    $scheduled = @(
        "40:EnableBackgroundInputPolling",
        "90:PipBoySnapshot real-save-settle",
        "92:PipBoyTreeSnapshot real-save-settle"
    )
    $screenshotFrames = @(120, 150)
    & $oracle `
        -OutputPath $telemetry `
        -SaveFixture $Fixture `
        -ScheduledCommand $scheduled `
        -PipBoyProbe `
        -BackgroundDataMode `
        -VisibleGame `
        -IsolateFromFNVXR `
        -SampleEvery 2 `
        -BeforeFrame 30 `
        -CommandFrame 60 `
        -AfterFrame 180 `
        -ScreenshotFrame $screenshotFrames `
        -ScreenshotDirectory $frames `
        -MaxFrames 190 `
        -TimeoutSeconds $TimeoutSeconds

    if (-not (Test-Path -LiteralPath $telemetry -PathType Leaf)) {
        throw "Retail RealSave oracle did not retain telemetry: $telemetry"
    }
    $events = @(Get-Content -LiteralPath $telemetry | ForEach-Object { $_ | ConvertFrom-Json })
    $load = @($events | Where-Object { $_.event -eq "load-result" -and [bool]$_.succeeded })
    $snapshots = @($events | Where-Object { $_.event -eq "retail-pipboy-snapshot" -and -not [bool]$_.inventory.truncated })
    $nativeFrames = @(Get-ChildItem -LiteralPath $frames -Filter "*.bmp" -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $retailPolicy = [ordered]@{
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        sourceFramesRetained = $nativeFrames.Count -gt 0
        telemetryRetained = $events.Count -gt 0
    }
    $artifacts = [Collections.Generic.List[object]]::new()
    foreach ($path in @($telemetry)) {
        $artifact = Get-Artifact $path
        if ($null -ne $artifact) { $artifacts.Add($artifact) }
    }
    foreach ($frame in $nativeFrames) {
        $artifacts.Add((Get-Artifact $frame.FullName))
    }
    return [ordered]@{
        status = if ($load.Count -gt 0 -and $snapshots.Count -gt 0 -and $nativeFrames.Count -gt 0) { "pass" } else { "fail" }
        target = "Retail"
        capture = [ordered]@{
            method = "xNVSE in-process retail save load plus native Direct3D 9 backbuffer frames"
            driver = "bounded oracle observation; no host keyboard or mouse input"
            windowsAppControlUsed = $false
            foregroundActivationUsed = $false
            foregroundInputInjected = $false
            sourceFramesRetained = $nativeFrames.Count -gt 0
            telemetryRetained = $events.Count -gt 0
        }
        assertions = [ordered]@{
            ordinarySaveLoadObserved = $load.Count -gt 0
            completeInventorySnapshotObserved = $snapshots.Count -gt 0
            retainedNativeFrameCount = $nativeFrames.Count
        }
        artifacts = @($artifacts)
        error = $null
    }
}

function Invoke-OpenMWRealSaveCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Fixture,
        [Parameter(Mandatory = $true)][string]$Worlds,
        [Parameter(Mandatory = $true)][string]$Runtime,
        [Parameter(Mandatory = $true)][pscustomobject]$Denominator,
        [switch]$QuickSaveAfterLoad,
        [switch]$QuitAfterQuickSave,
        [switch]$AllowOpenMWSaveReload,
        [switch]$PersistenceTelemetry,
        [switch]$C04MapSelection,
        [switch]$C05MapTravel,
        [switch]$C06RejectionMatrix,
        [switch]$C07PersistenceFirst,
        [switch]$C07PersistenceReload,
        [switch]$D01Inventory,
        [switch]$D02WeaponSelection,
        [ValidateSet("", "invBindThenSkeleton", "skeleton", "skeletonThenInvBind", "bindThenSkeleton", "skeletonThenBind", "source", "identity")]
        [string]$HandSkinningMode = "",
        [switch]$HandPoseAudit,
        [AllowNull()][pscustomobject]$ExpectedTransform
    )

    $binary = Join-Path $Runtime "openmw.exe"
    $resources = Join-Path $Runtime "resources"
    $initializer = Join-Path $Worlds "scripts\Initialize-OpenNVBaseProfile.ps1"
    $dataRoot = "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data"
    foreach ($path in @($binary, $resources, $initializer, (Join-Path $dataRoot "FalloutNV.esm"))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -and
            -not (Test-Path -LiteralPath $path -PathType Container)) {
            throw "Missing OpenMW RealSave requirement: $path"
        }
    }

    $stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $profileDirectory = Join-Path $Worlds "profiles\_verification\real-save330-$stamp-$PID"
    $campaignUserdata = Join-Path $Worlds "profiles\_verification\_campaigns\real-save330-$stamp-$PID\userdata"
    $profile = & $initializer `
        -FalloutNewVegasData $dataRoot `
        -ProfileDirectory $profileDirectory `
        -CampaignUserdataDirectory $campaignUserdata `
        -BinaryRoot $Runtime `
        -DlcPolicy RequireAll `
        -Force
    if ($null -eq $profile -or -not [bool]$profile.launchable) {
        throw "The isolated Save330 OpenMW profile is not launchable."
    }
    $settingsPath = Join-Path ([string]$profile.profileDirectory) "settings.cfg"
    Set-CaptureProfileSetting -Path $settingsPath -Section "General" -Key "screenshot format" -Value "png"
    Set-CaptureProfileSetting -Path $settingsPath -Section "General" -Key "notify on saved screenshot" -Value "false"
    Set-CaptureProfileSetting -Path $settingsPath -Section "General" -Key "minimize on focus loss" -Value "false"
    Set-CaptureProfileSetting -Path $settingsPath -Section "Physics" -Key "async num threads" -Value "0"

    $stdoutPath = Join-Path $Root "openmw.stdout.log"
    $stderrPath = Join-Path $Root "openmw.stderr.log"
    $captureStdoutPath = Join-Path $Root "ffmpeg.stdout.log"
    $captureStderrPath = Join-Path $Root "ffmpeg.stderr.log"
    $mapRoute = $C04MapSelection -or $C05MapTravel -or $C06RejectionMatrix -or
        $C07PersistenceFirst -or $C07PersistenceReload
    $frameSequenceRoute = $mapRoute -or $D01Inventory -or $D02WeaponSelection
    $rawVideoFileName = if ($D02WeaponSelection) {
        "OpenMW-Save330-D02-weapon-selection-exact-title-raw.mp4"
    } elseif ($D01Inventory) {
        "OpenMW-Save330-D01-inventory-exact-title-raw.mp4"
    } elseif ($C04MapSelection) {
        "OpenMW-Save330-C04-map-selection-exact-title-raw.mp4"
    } elseif ($C05MapTravel) {
        "OpenMW-Save330-C05-map-travel-exact-title-raw.mp4"
    } elseif ($C06RejectionMatrix) {
        "OpenMW-Save330-C06-rejection-matrix-exact-title-raw.mp4"
    } elseif ($C07PersistenceFirst) {
        "OpenMW-Save330-C07-travel-persistence-first-exact-title-raw.mp4"
    } elseif ($C07PersistenceReload) {
        "OpenMW-Save330-C07-travel-persistence-reload-exact-title-raw.mp4"
    } else {
        "OpenMW-Save330-exact-title-raw.mp4"
    }
    $rawVideoPath = Join-Path $Root $rawVideoFileName
    $nativeFramePath = Join-Path $Root "Save330-native-world.png"
    $nativeFramesDirectory = Join-Path $Root "native-source-frames"
    $c04NativeFrameNames = @("map-world-toggle-contact", "map-world-overview", "map-marker-focused", "map-confirmation-open")
    $c05NativeFrameNames = @("map-travel-before-confirmation", "map-travel-confirmation", "map-travel-destination")
    $c06NativeFrameNames = @("rejection-cancelled", "rejection-disabled-travel", "rejection-enemies-nearby", "rejection-undiscovered", "rejection-invalid-destination")
    $c07FirstNativeFrameNames = @("first-map-before-confirmation", "first-map-confirmation", "first-map-destination")
    $c07ReloadNativeFrameNames = @("reload-map-before-confirmation", "reload-map-confirmation", "reload-map-destination")
    $d01NativeFrameNames = @("inventory-weap", "inventory-apparel", "inventory-aid", "inventory-misc", "inventory-ammo")
    $d02NativeFrameNames = @("weapon-00", "weapon-01", "weapon-02", "weapon-03", "weapon-04", "weapon-05", "weapon-06", "weapon-07", "weapon-08", "weapon-09")
    # Sequence routes disable the unrelated generic proof screenshot below, so
    # their logged ScreenCaptureHandler requests map deterministically to their
    # retained source frames.  C04 starts with the live MAP/WORLD scroll-knob
    # contact before its overview, focus, and confirmation frames.
    $mapNativeSourceFrameIndices = if ($D02WeaponSelection) { @(0..9) } elseif ($C04MapSelection) { @(0, 1, 2, 3) } elseif ($C06RejectionMatrix) { @(0, 1, 2, 3, 4) } elseif ($D01Inventory) { @(0, 1, 2, 3, 4) } else { @(0, 1, 2) }
    $nativeFramePaths = if ($D02WeaponSelection) {
        @($d02NativeFrameNames | ForEach-Object { Join-Path $Root ("Save330-D02-$_.png") })
    } elseif ($D01Inventory) {
        @($d01NativeFrameNames | ForEach-Object { Join-Path $Root ("Save330-D01-$_.png") })
    } elseif ($C04MapSelection) {
        @($c04NativeFrameNames | ForEach-Object { Join-Path $Root ("Save330-C04-$_.png") })
    } elseif ($C05MapTravel) {
        @($c05NativeFrameNames | ForEach-Object { Join-Path $Root ("Save330-C05-$_.png") })
    } elseif ($C06RejectionMatrix) {
        @($c06NativeFrameNames | ForEach-Object { Join-Path $Root ("Save330-C06-$_.png") })
    } elseif ($C07PersistenceFirst) {
        @($c07FirstNativeFrameNames | ForEach-Object { Join-Path $Root ("Save330-C07-$_.png") })
    } elseif ($C07PersistenceReload) {
        @($c07ReloadNativeFrameNames | ForEach-Object { Join-Path $Root ("Save330-C07-$_.png") })
    } else {
        @($nativeFramePath)
    }
    $stateManifestPath = Join-Path $Root "real-save-state.json"
    $reportPath = Join-Path $Root "real-save-capture-report.json"
    $screenshotDirectory = Join-Path $campaignUserdata "screenshots"
    $previousEnvironment = Save-And-ClearOpenMWEnvironment
    $environmentNames = @(
        "OPENMW_DEBUG_LEVEL", "OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG",
        "OPENMW_PROOF_SCREENSHOT_READY_FRAMES", "OPENMW_WORLD_VIEWER_TELEMETRY",
        "OPENMW_WORLD_VIEWER_TELEMETRY_INTERVAL", "OPENMW_PROOF_QUICKSAVE_FRAME",
        "OPENMW_PROOF_QUICKSAVE_NAME", "OPENMW_PROOF_QUIT_AFTER_QUICKSAVE",
        "OPENMW_PROOF_QUICKSAVE_QUIT_DELAY_FRAMES", "OPENMW_FNV_B04_PERSISTENCE_TELEMETRY",
        "OPENMW_FNV_REAL_SAVE_C04", "OPENMW_FNV_REAL_SAVE_C04_MARKER",
        "OPENMW_FNV_REAL_SAVE_C04_FIRST_READY_FRAME",
        "OPENMW_FNV_REAL_SAVE_C05", "OPENMW_FNV_REAL_SAVE_C05_MARKER",
        "OPENMW_FNV_REAL_SAVE_C05_FIRST_READY_FRAME",
        "OPENMW_FNV_REAL_SAVE_C06", "OPENMW_FNV_REAL_SAVE_C06_MARKER",
        "OPENMW_FNV_REAL_SAVE_C06_FIRST_READY_FRAME",
        "OPENMW_FNV_REAL_SAVE_C07", "OPENMW_FNV_REAL_SAVE_C07_PHASE",
        "OPENMW_FNV_REAL_SAVE_C07_MARKER", "OPENMW_FNV_REAL_SAVE_C07_FIRST_READY_FRAME",
        "OPENMW_FNV_REAL_SAVE_D01", "OPENMW_FNV_REAL_SAVE_D01_FIRST_READY_FRAME",
        "OPENMW_FNV_REAL_SAVE_D01_FRAMES_PER_CATEGORY",
        "OPENMW_FNV_REAL_SAVE_D02", "OPENMW_FNV_REAL_SAVE_D02_FIRST_READY_FRAME",
        "OPENMW_FNV_REAL_SAVE_D02_FRAMES_PER_WEAPON",
        "OPENMW_ESM4_HAND_SKINNING_MODE", "OPENMW_FNV_HAND_POSE_AUDIT", "OPENMW_FNV_RIG_DRAW_AUDIT",
        "OPENMW_PLAYABLE_SESSION_BACKGROUND", "OPENMW_PROOF_CAPTURE_KEEP_WINDOW_VISIBLE",
        "OSG_GL_TEXTURE_STORAGE"
    )
    $game = $null
    $gameStdoutTask = $null
    $gameStderrTask = $null
    $gameStreamsSaved = $false
    $recorder = $null
    $recorderStdoutTask = $null
    $recorderStderrTask = $null
    $recorderStreamsSaved = $false
    $recorderExitCode = $null
    $nativeSourceFrame = $null
    $nativeSourceFrames = @()
    $captureError = $null
    $gameTermination = "not-started"
    $startedAt = [DateTime]::UtcNow
    try {
        [Environment]::SetEnvironmentVariable("OSG_GL_TEXTURE_STORAGE", "OFF", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_DEBUG_LEVEL", "INFO", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG", "1", "Process")
        # The unattended title recorder keeps the SDL window hidden.  Preserve
        # ordinary in-engine simulation while it is hidden; this is not host
        # input or a synthetic gameplay route.
        [Environment]::SetEnvironmentVariable("OPENMW_PLAYABLE_SESSION_BACKGROUND", "1", "Process")
        # Keep an ordinary titled SDL surface available for the required
        # passive transport recording without foreground activation.
        [Environment]::SetEnvironmentVariable("OPENMW_PROOF_CAPTURE_KEEP_WINDOW_VISIBLE", "1", "Process")
        $proofReadyFrames = if ($frameSequenceRoute) { "-1" } else { "120" }
        [Environment]::SetEnvironmentVariable("OPENMW_PROOF_SCREENSHOT_READY_FRAMES", $proofReadyFrames, "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_TELEMETRY", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_TELEMETRY_INTERVAL", "30", "Process")
        if (-not [string]::IsNullOrWhiteSpace($HandSkinningMode)) {
            [Environment]::SetEnvironmentVariable("OPENMW_ESM4_HAND_SKINNING_MODE", $HandSkinningMode, "Process")
        }
        if ($HandPoseAudit) {
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_HAND_POSE_AUDIT", "1", "Process")
            # The same explicit diagnostic switch also records the exact cull
            # path for Fallout rig geometry.  This is telemetry only: it does
            # not alter the animation, skinning, camera, or proof route.
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_RIG_DRAW_AUDIT", "1", "Process")
        }
        if ($QuickSaveAfterLoad) {
            [Environment]::SetEnvironmentVariable("OPENMW_PROOF_QUICKSAVE_FRAME", "300", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_PROOF_QUICKSAVE_NAME", "Save330 B04 Reload", "Process")
            if ($QuitAfterQuickSave) {
                [Environment]::SetEnvironmentVariable("OPENMW_PROOF_QUIT_AFTER_QUICKSAVE", "1", "Process")
                [Environment]::SetEnvironmentVariable("OPENMW_PROOF_QUICKSAVE_QUIT_DELAY_FRAMES", "30", "Process")
            }
        }
        if ($AllowOpenMWSaveReload -or $PersistenceTelemetry) {
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_B04_PERSISTENCE_TELEMETRY", "1", "Process")
        }
        if ($C04MapSelection) {
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C04", "1", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C04_MARKER", "FormId:0x03008885", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C04_FIRST_READY_FRAME", "30", "Process")
        }
        if ($C05MapTravel) {
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C05", "1", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C05_MARKER", "FormId:0x03008885", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C05_FIRST_READY_FRAME", "30", "Process")
        }
        if ($C06RejectionMatrix) {
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C06", "1", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C06_MARKER", "FormId:0x03008885", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C06_FIRST_READY_FRAME", "30", "Process")
        }
        if ($C07PersistenceFirst -or $C07PersistenceReload) {
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C05", "1", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C05_MARKER", "FormId:0x03008885", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C05_FIRST_READY_FRAME", "30", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C07", "1", "Process")
            $c07PhaseValue = if ($C07PersistenceFirst) { "first" } else { "reload" }
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C07_PHASE", $c07PhaseValue, "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C07_MARKER", "FormId:0x03008885", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_C07_FIRST_READY_FRAME", "30", "Process")
        }
        if ($D01Inventory) {
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_D01", "1", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_D01_FIRST_READY_FRAME", "30", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_D01_FRAMES_PER_CATEGORY", "90", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_B04_PERSISTENCE_TELEMETRY", "1", "Process")
        }
        if ($D02WeaponSelection) {
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_D02", "1", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_D02_FIRST_READY_FRAME", "30", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_REAL_SAVE_D02_FRAMES_PER_WEAPON", "135", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_FNV_B04_PERSISTENCE_TELEMETRY", "1", "Process")
        }

        # This is the ordinary OpenMW SaveGame command-line boundary. The
        # engine's existing ScreenCaptureHandler native framebuffer hook is
        # the only native world-frame source used by this lane.
        $arguments = @(
            "--replace", "config",
            "--config", [string]$profile.profileDirectory,
            "--resources", [string]$resources,
            "--skip-menu",
            "--load-savegame", [IO.Path]::GetFullPath($Fixture)
        )
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $binary
        $startInfo.Arguments = ($arguments | ForEach-Object { Quote-OpenMWArgument $_ }) -join " "
        $startInfo.WorkingDirectory = Split-Path -Parent $binary
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $game = [Diagnostics.Process]::new()
        $game.StartInfo = $startInfo
        if (-not $game.Start()) {
            throw "Unable to start OpenMW for the Save330 RealSave lane."
        }
        $gameStdoutTask = $game.StandardOutput.ReadToEndAsync()
        $gameStderrTask = $game.StandardError.ReadToEndAsync()

        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ($game.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $game.Refresh()
            if ($game.HasExited) {
                throw "OpenMW exited before the Save330 exact-title window appeared."
            }
        }
        if ($game.MainWindowHandle -eq 0) {
            throw "OpenMW did not expose the exact-title Save330 capture window."
        }

        $ffmpegArguments = @(
            "-hide_banner", "-loglevel", "warning", "-y",
            "-f", "gdigrab", "-framerate", "60", "-draw_mouse", "0", "-i", "title=OpenMW",
            "-t", ([string]$CaptureSeconds),
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", $rawVideoPath
        )
        $recorderInfo = [Diagnostics.ProcessStartInfo]::new()
        $recorderInfo.FileName = (Get-Command ffmpeg -ErrorAction Stop).Source
        $recorderInfo.Arguments = ($ffmpegArguments | ForEach-Object { Quote-OpenMWArgument $_ }) -join " "
        $recorderInfo.WorkingDirectory = $Worlds
        $recorderInfo.UseShellExecute = $false
        $recorderInfo.CreateNoWindow = $true
        $recorderInfo.RedirectStandardOutput = $true
        $recorderInfo.RedirectStandardError = $true
        $recorder = [Diagnostics.Process]::new()
        $recorder.StartInfo = $recorderInfo
        if (-not $recorder.Start()) {
            throw "Unable to start the exact-title OpenMW Save330 recorder."
        }
        $recorderStdoutTask = $recorder.StandardOutput.ReadToEndAsync()
        $recorderStderrTask = $recorder.StandardError.ReadToEndAsync()

        $requiredNativeFrameCount = if ($D02WeaponSelection) { $d02NativeFrameNames.Count } elseif ($C04MapSelection) { $c04NativeFrameNames.Count } elseif ($C06RejectionMatrix) { $c06NativeFrameNames.Count } elseif ($D01Inventory) { $d01NativeFrameNames.Count } elseif ($mapRoute) { 3 } else { 1 }
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $screenshotDirectory -PathType Container) {
                $nativeSourceFrames = @(Get-ChildItem -LiteralPath $screenshotDirectory -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Length -gt 0 -and $_.Extension.ToLowerInvariant() -in @(".png", ".jpg", ".jpeg") } |
                    Sort-Object LastWriteTimeUtc, Name)
                if ($nativeSourceFrames.Count -ge $requiredNativeFrameCount) {
                    $nativeSourceFrame = $nativeSourceFrames[0]
                    break
                }
            }
            $game.Refresh()
            if ($game.HasExited) {
                throw "OpenMW exited before the required native Save330 frame sequence was written. expected=$requiredNativeFrameCount"
            }
            Start-Sleep -Milliseconds 100
        }
        if ($nativeSourceFrames.Count -lt $requiredNativeFrameCount) {
            throw "Timed out waiting for the native Save330 frame sequence. expected=$requiredNativeFrameCount received=$($nativeSourceFrames.Count)"
        }
        if ($frameSequenceRoute) {
            New-Item -ItemType Directory -Path $nativeFramesDirectory | Out-Null
            for ($index = 0; $index -lt $nativeFramePaths.Count; ++$index) {
                $sourceIndex = $mapNativeSourceFrameIndices[$index]
                $source = $nativeSourceFrames[$sourceIndex]
                $retainedSource = Join-Path $nativeFramesDirectory $source.Name
                Copy-Item -LiteralPath $source.FullName -Destination $retainedSource -ErrorAction Stop
                Copy-Item -LiteralPath $source.FullName -Destination $nativeFramePaths[$index] -ErrorAction Stop
            }
        }
        else {
            Copy-Item -LiteralPath $nativeSourceFrame.FullName -Destination $nativeFramePath -ErrorAction Stop
        }

        if ($frameSequenceRoute) {
            $engineExitDeadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not $game.HasExited -and [DateTime]::UtcNow -lt $engineExitDeadline) {
                Start-Sleep -Milliseconds 100
                $game.Refresh()
            }
        }

        $recorder.WaitForExit()
        $recorder.Refresh()
        $recorderExitCode = $recorder.ExitCode
        Save-AsyncProcessStreams `
            -StandardOutputTask $recorderStdoutTask `
            -StandardErrorTask $recorderStderrTask `
            -StandardOutputPath $captureStdoutPath `
            -StandardErrorPath $captureStderrPath
        $recorderStreamsSaved = $true
        if ($recorderExitCode -ne 0 -or -not (Test-Path -LiteralPath $rawVideoPath -PathType Leaf)) {
            throw "The exact-title OpenMW Save330 recorder did not produce a valid raw MP4."
        }
    }
    catch {
        $captureError = $_.Exception.Message
    }
    finally {
        if ($null -ne $recorder) {
            $recorder.Refresh()
            if (-not $recorder.HasExited) {
                $recorder.Kill()
                $recorder.WaitForExit()
            }
            if ($null -eq $recorderExitCode -and $recorder.HasExited) {
                $recorderExitCode = $recorder.ExitCode
            }
            if (-not $recorderStreamsSaved -and $null -ne $recorderStdoutTask -and $null -ne $recorderStderrTask) {
                Save-AsyncProcessStreams `
                    -StandardOutputTask $recorderStdoutTask `
                    -StandardErrorTask $recorderStderrTask `
                    -StandardOutputPath $captureStdoutPath `
                    -StandardErrorPath $captureStderrPath
            }
        }
        if ($null -ne $game) {
            $game.Refresh()
            if (-not $game.HasExited) {
                Stop-Process -Id $game.Id -Force -ErrorAction SilentlyContinue
                [void]$game.WaitForExit(15000)
                $game.Refresh()
                $gameTermination = if ($game.HasExited) { "owned-process-terminated-after-capture" } else { "owned-process-exit-timeout" }
            }
            else {
                $gameTermination = "engine-exited"
            }
            if ($game.HasExited -and -not $gameStreamsSaved -and $null -ne $gameStdoutTask -and $null -ne $gameStderrTask) {
                Save-AsyncProcessStreams `
                    -StandardOutputTask $gameStdoutTask `
                    -StandardErrorTask $gameStderrTask `
                    -StandardOutputPath $stdoutPath `
                    -StandardErrorPath $stderrPath
                $gameStreamsSaved = $true
            }
            $game.Dispose()
            $game = $null
        }
        Restore-Environment -Previous $previousEnvironment -Names $environmentNames
    }

    $logText = Get-OpenMWLogText -StdoutPath $stdoutPath -StderrPath $stderrPath -ProfileDirectory ([string]$profile.profileDirectory)
    $observation = Get-RealSaveRuntimeObservation -LogText $logText -Denominator $Denominator `
        -AllowOpenMWSaveReload:$AllowOpenMWSaveReload -ExpectedTransform $ExpectedTransform
    $stateManifest = [ordered]@{
        schema = "nikami-fnv-real-save-state/v1"
        status = if ($observation.pass) { "pass" } else { "fail" }
        routeId = $RouteId
        source = [ordered]@{
            savePath = [IO.Path]::GetFullPath($Fixture)
            saveBytes = (Get-Artifact $Fixture)
            normalizedDenominator = $Denominator.evidence
        }
        launch = [ordered]@{
            ordinaryLoadSavegame = $true
            arguments = @("--skip-menu", "--load-savegame", [IO.Path]::GetFullPath($Fixture))
            usedStart = $false
            usedTestMapPlacement = $false
            usedBootstrapInventory = $false
            usedConsoleInjection = $false
            handSkinningMode = if ([string]::IsNullOrWhiteSpace($HandSkinningMode)) { "default" } else { $HandSkinningMode }
            handPoseAudit = [bool]$HandPoseAudit
            rigDrawAudit = [bool]$HandPoseAudit
        }
        expected = [ordered]@{
            player = $Denominator.json.player
            transform = $Denominator.json.transform
            camera = $Denominator.json.camera
            scene = $Denominator.json.scene
            inventory = [ordered]@{
                distinctRows = @($Denominator.json.inventory.finalTotals).Count
                totalItems = (@($Denominator.json.inventory.finalTotals) | Measure-Object -Property count -Sum).Sum
            }
        }
        c04MapSelection = [ordered]@{
            enabled = [bool]$C04MapSelection
            marker = if ($C04MapSelection) { "FormId:0x03008885" } else { $null }
            expectedNativeFrameCount = if ($C04MapSelection) { $c04NativeFrameNames.Count } else { 1 }
            retainedNativeFrameCount = @($nativeFramePaths | Where-Object {
                Test-Path -LiteralPath $_ -PathType Leaf
            }).Count
            retainedNativeFrames = @($nativeFramePaths | ForEach-Object { Get-Artifact $_ }) |
                Where-Object { $null -ne $_ }
        }
        c05MapTravel = [ordered]@{
            enabled = [bool]$C05MapTravel
            marker = if ($C05MapTravel) { "FormId:0x03008885" } else { $null }
            expectedNativeFrameCount = if ($C05MapTravel) { $c05NativeFrameNames.Count } else { 1 }
            retainedNativeFrameCount = @($nativeFramePaths | Where-Object {
                Test-Path -LiteralPath $_ -PathType Leaf
            }).Count
            retainedNativeFrames = @($nativeFramePaths | ForEach-Object { Get-Artifact $_ }) |
                Where-Object { $null -ne $_ }
        }
        c06RejectionMatrix = [ordered]@{
            enabled = [bool]$C06RejectionMatrix
            marker = if ($C06RejectionMatrix) { "FormId:0x03008885" } else { $null }
            expectedNativeFrameCount = if ($C06RejectionMatrix) { $c06NativeFrameNames.Count } else { 1 }
            retainedNativeFrameCount = @($nativeFramePaths | Where-Object {
                Test-Path -LiteralPath $_ -PathType Leaf
            }).Count
            retainedNativeFrames = @($nativeFramePaths | ForEach-Object { Get-Artifact $_ }) |
                Where-Object { $null -ne $_ }
        }
        c07TravelPersistence = [ordered]@{
            enabled = [bool]($C07PersistenceFirst -or $C07PersistenceReload)
            phase = if ($C07PersistenceFirst) { "first" } elseif ($C07PersistenceReload) { "reload" } else { $null }
            marker = if ($C07PersistenceFirst -or $C07PersistenceReload) { "FormId:0x03008885" } else { $null }
            expectedNativeFrameCount = if ($C07PersistenceFirst -or $C07PersistenceReload) { 3 } else { 1 }
            retainedNativeFrameCount = @($nativeFramePaths | Where-Object {
                Test-Path -LiteralPath $_ -PathType Leaf
            }).Count
            retainedNativeFrames = @($nativeFramePaths | ForEach-Object { Get-Artifact $_ }) |
                Where-Object { $null -ne $_ }
        }
        d01Inventory = [ordered]@{
            enabled = [bool]$D01Inventory
            categories = @("WEAP", "APP", "AID", "MISC", "AMMO")
            expectedNativeFrameCount = if ($D01Inventory) { $d01NativeFrameNames.Count } else { 1 }
            retainedNativeFrameCount = @($nativeFramePaths | Where-Object {
                Test-Path -LiteralPath $_ -PathType Leaf
            }).Count
            retainedNativeFrames = @($nativeFramePaths | ForEach-Object { Get-Artifact $_ }) |
                Where-Object { $null -ne $_ }
        }
        d02WeaponSelection = [ordered]@{
            enabled = [bool]$D02WeaponSelection
            expectedWeaponCount = 10
            expectedNativeFrameCount = if ($D02WeaponSelection) { $d02NativeFrameNames.Count } else { 1 }
            retainedNativeFrameCount = @($nativeFramePaths | Where-Object {
                Test-Path -LiteralPath $_ -PathType Leaf
            }).Count
            retainedNativeFrames = @($nativeFramePaths | ForEach-Object { Get-Artifact $_ }) |
                Where-Object { $null -ne $_ }
        }
        observed = $observation
        logs = @{
            stdout = Get-Artifact $stdoutPath
            stderr = Get-Artifact $stderrPath
            profile = Get-Artifact (Join-Path ([string]$profile.profileDirectory) "openmw.log")
        }
    }
    [IO.File]::WriteAllText($stateManifestPath, ($stateManifest | ConvertTo-Json -Depth 18) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

    $artifacts = [Collections.Generic.List[object]]::new()
    foreach ($path in @($stdoutPath, $stderrPath, (Join-Path ([string]$profile.profileDirectory) "openmw.log"), $captureStdoutPath, $captureStderrPath, $stateManifestPath, $nativeFramePaths, $rawVideoPath)) {
        $artifact = Get-Artifact $path
        if ($null -ne $artifact) { $artifacts.Add($artifact) }
    }
    if ($frameSequenceRoute -and (Test-Path -LiteralPath $nativeFramesDirectory -PathType Container)) {
        foreach ($sourceFrame in @(Get-ChildItem -LiteralPath $nativeFramesDirectory -File | Sort-Object Name)) {
            $artifacts.Add((Get-Artifact $sourceFrame.FullName))
        }
    }
    $nativeFrameRetentionPass = @($nativeFramePaths | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    }).Count -eq $nativeFramePaths.Count
    $passed = [string]::IsNullOrWhiteSpace($captureError) -and
        [bool]$observation.pass -and
        $nativeFrameRetentionPass -and
        (Test-Path -LiteralPath $rawVideoPath -PathType Leaf) -and
        $recorderExitCode -eq 0
    return [ordered]@{
        schema = "nikami-fnv-real-save-capture/v1"
        status = if ($passed) { "pass" } else { "fail" }
        target = "OpenMW"
        routeId = $RouteId
        capture = [ordered]@{
            method = if ($D02WeaponSelection) {
                "ordinary OpenMW --load-savegame plus production Pip-Boy WEAP row activation, production close/reload, live weapon/model audit, ScreenCaptureHandler native world frames, and exact-title ffmpeg transport"
            } elseif ($D01Inventory) {
                "ordinary OpenMW --load-savegame plus production Pip-Boy ITEMS category navigation through the restored inventory models, ScreenCaptureHandler native GUI frames, and exact-title ffmpeg transport"
            } elseif ($mapRoute) {
                if ($C07PersistenceFirst -or $C07PersistenceReload) {
                    "ordinary OpenMW --load-savegame plus production Pip-Boy MAP/WORLD selection, confirmation, fast-travel persistence phase, ScreenCaptureHandler native GUI/world frames, and exact-title ffmpeg transport"
                } elseif ($C05MapTravel) {
                    "ordinary OpenMW --load-savegame plus production Pip-Boy MAP/WORLD selection, confirmation, fast-travel execution, ScreenCaptureHandler native GUI/world frames, and exact-title ffmpeg transport"
                } else {
                "ordinary OpenMW --load-savegame plus production Pip-Boy MAP/WORLD selection, ScreenCaptureHandler native GUI frames, and exact-title ffmpeg transport"
                }
            } else {
                "ordinary OpenMW --load-savegame plus ScreenCaptureHandler native world frame and exact-title ffmpeg transport"
            }
            driver = if ($D02WeaponSelection) {
                "engine-owned production Pip-Boy weapon row callbacks and MechanicsManager reload only; no host keyboard or mouse input"
            } elseif ($D01Inventory) {
                "engine-owned production Pip-Boy inventory callbacks only; no host keyboard or mouse input"
            } elseif ($mapRoute) {
                "engine-owned production Pip-Boy/map callbacks only; no host keyboard or mouse input"
            } else {
                "engine-owned bounded capture hook; no host keyboard or mouse input"
            }
            windowsAppControlUsed = $false
            foregroundActivationUsed = $false
            foregroundInputInjected = $false
            sourceFrameRetained = $nativeFrameRetentionPass
            nativeFrameCount = $nativeFramePaths.Count
            nativeFramePaths = @($nativeFramePaths)
            telemetryRetained = Test-Path -LiteralPath $stateManifestPath -PathType Leaf
            exactTitleVideoRetained = Test-Path -LiteralPath $rawVideoPath -PathType Leaf
            recorderExitCode = $recorderExitCode
            gameTermination = $gameTermination
            userConfigurationRestored = $true
            handSkinningMode = if ([string]::IsNullOrWhiteSpace($HandSkinningMode)) { "default" } else { $HandSkinningMode }
            handPoseAudit = [bool]$HandPoseAudit
        }
        source = [ordered]@{
            binary = Get-Artifact $binary
            resources = $resources
            profileDirectory = [string]$profile.profileDirectory
            campaignUserdata = $campaignUserdata
            profileManifest = [string]$profile.manifestPath
            saveFixture = Get-Artifact $Fixture
            normalizedDenominator = $Denominator.evidence
        }
        assertions = [ordered]@{
            stateManifestPass = [bool]$observation.pass
            ordinaryLoadPathObserved = [bool]$observation.ordinaryLoadPathObserved
            nativeSaveLoadComplete = [bool]$observation.loadComplete
            playerIdentityRestored = [bool]$observation.playerIdentityRestored
            savedTransformApplied = [bool]($observation.transform.worldspaceMatches -and $observation.transform.positionMatches -and $observation.transform.rotationMatches)
            fallbackInventoryAbsent = [bool]$observation.inventoryRebuild.fallbackInventoryAbsent
            syntheticPlacementAbsent = [bool]$observation.noSyntheticPlacement
            nativeWorldFrameRetained = $nativeFrameRetentionPass
            nativeFrameCount = $nativeFramePaths.Count
            c04MapSelectionFramesRetained = -not $C04MapSelection -or $nativeFramePaths.Count -eq $c04NativeFrameNames.Count
            c05MapTravelFramesRetained = -not $C05MapTravel -or $nativeFramePaths.Count -eq 3
            c06RejectionMatrixFramesRetained = -not $C06RejectionMatrix -or $nativeFramePaths.Count -eq 5
            c07TravelPersistenceFramesRetained = -not ($C07PersistenceFirst -or $C07PersistenceReload) -or $nativeFramePaths.Count -eq 3
            d01InventoryFramesRetained = -not $D01Inventory -or $nativeFramePaths.Count -eq $d01NativeFrameNames.Count
            d02WeaponSelectionFramesRetained = -not $D02WeaponSelection -or $nativeFramePaths.Count -eq $d02NativeFrameNames.Count
            exactTitleVideoRetained = Test-Path -LiteralPath $rawVideoPath -PathType Leaf
        }
        artifacts = @($artifacts)
        error = $captureError
    }
}

function Invoke-OpenMWRealSaveReloadCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Fixture,
        [Parameter(Mandatory = $true)][string]$Worlds,
        [Parameter(Mandatory = $true)][string]$Runtime,
        [Parameter(Mandatory = $true)][pscustomobject]$Denominator
    )

    $saveRoot = Join-Path $Root "save330-before-reload"
    $reloadRoot = Join-Path $Root "save330-after-reload"
    New-Item -ItemType Directory -Path $saveRoot, $reloadRoot | Out-Null

    $first = Invoke-OpenMWRealSaveCapture -Root $saveRoot -Fixture $Fixture -Worlds $Worlds -Runtime $Runtime -Denominator $Denominator -QuickSaveAfterLoad -QuitAfterQuickSave -PersistenceTelemetry
    [IO.File]::WriteAllText(
        (Join-Path $saveRoot "real-save-capture-report.json"),
        ($first | ConvertTo-Json -Depth 18) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))

    if ($first.status -ne "pass") {
        throw "B04 production-save phase failed before a reload artifact was emitted."
    }
    $campaignUserdata = [string]$first.source.campaignUserdata
    $saveCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($campaignUserdata) -and
        (Test-Path -LiteralPath $campaignUserdata -PathType Container)) {
        $saveCandidates = @(Get-ChildItem -LiteralPath $campaignUserdata -Recurse -File -Filter "*.omwsave" |
            Sort-Object FullName)
    }
    if ($saveCandidates.Count -ne 1) {
        throw "B04 expected exactly one new production .omwsave under $campaignUserdata, found $($saveCandidates.Count)."
    }

    $generatedSavePath = Join-Path $Root "Save330-production-reload.omwsave"
    if (Test-Path -LiteralPath $generatedSavePath) {
        throw "Refusing to overwrite generated B04 campaign save: $generatedSavePath"
    }
    Copy-Item -LiteralPath $saveCandidates[0].FullName -Destination $generatedSavePath
    $generatedSave = Get-Artifact $generatedSavePath
    if ($null -eq $generatedSave) {
        throw "B04 production campaign save copy is missing: $generatedSavePath"
    }

    $saveManifest = [ordered]@{
        schema = "nikami-fnv-real-save-b04-production-save/v1"
        sourceFixture = Get-Artifact $Fixture
        generatedSave = $generatedSave
        productionDescription = "Save330 B04 Reload"
        sourcePath = $saveCandidates[0].FullName
        sourceCampaignUserdata = $campaignUserdata
        cleanQuitObserved = [string]$first.capture.gameTermination -eq "engine-exited"
        savePhaseReport = Get-Artifact (Join-Path $saveRoot "real-save-capture-report.json")
    }
    $saveManifestPath = Join-Path $Root "save330-production-save-manifest.json"
    [IO.File]::WriteAllText(
        $saveManifestPath,
        ($saveManifest | ConvertTo-Json -Depth 18) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))

    $second = Invoke-OpenMWRealSaveCapture -Root $reloadRoot -Fixture $generatedSavePath -Worlds $Worlds -Runtime $Runtime -Denominator $Denominator -AllowOpenMWSaveReload
    [IO.File]::WriteAllText(
        (Join-Path $reloadRoot "real-save-capture-report.json"),
        ($second | ConvertTo-Json -Depth 18) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))

    $artifacts = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($first.artifacts, $second.artifacts, $generatedSave, (Get-Artifact $saveManifestPath))) {
        if ($null -ne $entry) {
            foreach ($artifact in @($entry)) {
                if ($null -ne $artifact -and
                    -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
                    $artifacts.Add($artifact)
                }
            }
        }
    }
    $passed = $first.status -eq "pass" -and
        $second.status -eq "pass" -and
        [string]$first.capture.gameTermination -eq "engine-exited" -and
        (Test-Path -LiteralPath (Join-Path $saveRoot "real-save-state.json") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $reloadRoot "real-save-state.json") -PathType Leaf)
    return [ordered]@{
        schema = "nikami-fnv-real-save-b04-capture/v1"
        status = if ($passed) { "pass" } else { "fail" }
        target = "OpenMW"
        routeId = "save330-reload-idempotence-v1"
        capture = [ordered]@{
            method = "ordinary OpenMW Save330 load, production StateManager quicksave, clean quit, and cold --load-savegame reload"
            driver = "engine-owned bounded schedule only; no host keyboard or mouse input"
            windowsAppControlUsed = $false
            foregroundActivationUsed = $false
            foregroundInputInjected = $false
            capturesRanSequentially = $true
            userConfigurationRestored = $true
            cleanQuitObserved = [string]$first.capture.gameTermination -eq "engine-exited"
        }
        source = [ordered]@{
            binary = $second.source.binary
            resources = $second.source.resources
            saveFixture = Get-Artifact $Fixture
            normalizedDenominator = $Denominator.evidence
        }
        generatedSave = $generatedSave
        phases = [ordered]@{
            save = $first
            reload = $second
        }
        assertions = [ordered]@{
            productionSaveCreated = $null -ne $generatedSave
            productionSavePhasePass = $first.status -eq "pass"
            cleanQuitAfterSave = [string]$first.capture.gameTermination -eq "engine-exited"
            coldReloadPhasePass = $second.status -eq "pass"
            bothStateManifestsRetained = (Test-Path -LiteralPath (Join-Path $saveRoot "real-save-state.json") -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $reloadRoot "real-save-state.json") -PathType Leaf)
        }
        artifacts = @($artifacts)
        error = $null
    }
}

function Invoke-OpenMWRealSaveC07PersistenceCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Fixture,
        [Parameter(Mandatory = $true)][string]$Worlds,
        [Parameter(Mandatory = $true)][string]$Runtime,
        [Parameter(Mandatory = $true)][pscustomobject]$Denominator
    )

    $firstRoot = Join-Path $Root "first-travel"
    $reloadRoot = Join-Path $Root "after-cold-reload"
    New-Item -ItemType Directory -Path $firstRoot, $reloadRoot | Out-Null

    $first = Invoke-OpenMWRealSaveCapture -Root $firstRoot -Fixture $Fixture -Worlds $Worlds -Runtime $Runtime `
        -Denominator $Denominator -PersistenceTelemetry -C07PersistenceFirst
    [IO.File]::WriteAllText(
        (Join-Path $firstRoot "real-save-capture-report.json"),
        ($first | ConvertTo-Json -Depth 20) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))

    if ($first.status -ne "pass" -or [string]$first.capture.gameTermination -ne "engine-exited") {
        throw "C07 first travel/save phase failed before a production save was emitted."
    }
    $firstLogPath = Join-Path $firstRoot "openmw.stdout.log"
    $firstLog = if (Test-Path -LiteralPath $firstLogPath -PathType Leaf) {
        Get-Content -Raw -LiteralPath $firstLogPath
    } else { "" }

    $campaignUserdata = [string]$first.source.campaignUserdata
    $saveCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($campaignUserdata) -and
        (Test-Path -LiteralPath $campaignUserdata -PathType Container)) {
        $saveCandidates = @(Get-ChildItem -LiteralPath $campaignUserdata -Recurse -File -Filter "*.omwsave" |
            Sort-Object FullName)
    }
    if ($saveCandidates.Count -ne 1) {
        throw "C07 expected exactly one production .omwsave under $campaignUserdata, found $($saveCandidates.Count)."
    }

    $generatedSavePath = Join-Path $Root "Save330-C07-travel-persistence.omwsave"
    if (Test-Path -LiteralPath $generatedSavePath) {
        throw "Refusing to overwrite generated C07 campaign save: $generatedSavePath"
    }
    Copy-Item -LiteralPath $saveCandidates[0].FullName -Destination $generatedSavePath -ErrorAction Stop
    $generatedSave = Get-Artifact $generatedSavePath
    if ($null -eq $generatedSave) {
        throw "C07 production campaign save copy is missing: $generatedSavePath"
    }
    $saveManifestPath = Join-Path $Root "save330-c07-production-save-manifest.json"
    if (Test-Path -LiteralPath $saveManifestPath) {
        throw "Refusing to overwrite generated C07 save manifest: $saveManifestPath"
    }
    $saveManifest = [ordered]@{
        schema = "nikami-fnv-real-save-c07-production-save/v1"
        sourceFixture = Get-Artifact $Fixture
        generatedSave = $generatedSave
        productionDescription = "Save330 C07 Travel Persistence"
        sourcePath = $saveCandidates[0].FullName
        sourceCampaignUserdata = $campaignUserdata
        cleanQuitObserved = [string]$first.capture.gameTermination -eq "engine-exited"
        firstPhaseReport = Get-Artifact (Join-Path $firstRoot "real-save-capture-report.json")
    }
    [IO.File]::WriteAllText(
        $saveManifestPath,
        ($saveManifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))

    $markerDenominatorPath = Join-Path $Worlds "run\fnv-real-save-campaign\save330-map-marker-denominator.json"
    if (-not (Test-Path -LiteralPath $markerDenominatorPath -PathType Leaf)) {
        throw "C07 cannot construct the persisted destination expectation without the C01 marker denominator."
    }
    $markerDenominator = Get-Content -Raw -LiteralPath $markerDenominatorPath | ConvertFrom-Json
    $marker = @($markerDenominator.markers | Where-Object { $_.formId -eq "0x03008885" })
    if ($marker.Count -ne 1) {
        throw "C07 expected exactly one canonical Southern Passage marker in the C01 denominator."
    }
    $destinationMatch = [regex]::Match(
        $firstLog,
        '(?s)FNV C07 persistence: phase=first-travel-arrived .*?worldspace=FormId:(?<worldspace>0x[0-9a-fA-F]+)\s+pos=\((?<px>[-+0-9.eE]+),(?<py>[-+0-9.eE]+),(?<pz>[-+0-9.eE]+)\)')
    if (-not $destinationMatch.Success) {
        throw "C07 could not parse the first production arrival transform from the retained log."
    }
    $destinationWorldspace = $destinationMatch.Groups["worldspace"].Value
    $destinationTelemetryMatch = [regex]::Match(
        $firstLog,
        '(?s)World viewer telemetry:.*?worldspace=FormId:' + [regex]::Escape($destinationWorldspace) +
            '.*?playerPos=\([-+0-9.eE]+,[-+0-9.eE]+,[-+0-9.eE]+\) playerRot=\((?<rx>[-+0-9.eE]+),(?<ry>[-+0-9.eE]+),(?<rz>[-+0-9.eE]+)\) cameraMode=(?<cameraMode>-?\d+)')
    if (-not $destinationTelemetryMatch.Success) {
        throw "C07 could not parse the persisted destination camera transform from the first retained log."
    }
    $expectedTransform = [pscustomobject]@{
        worldspace = "0x$destinationWorldspace".Replace("0x0x", "0x")
        position = @(
            [double]$destinationMatch.Groups["px"].Value,
            [double]$destinationMatch.Groups["py"].Value,
            [double]$destinationMatch.Groups["pz"].Value)
        rotation = @(
            [double]$destinationTelemetryMatch.Groups["rx"].Value,
            [double]$destinationTelemetryMatch.Groups["ry"].Value,
            [double]$destinationTelemetryMatch.Groups["rz"].Value)
    }

    $second = Invoke-OpenMWRealSaveCapture -Root $reloadRoot -Fixture $generatedSavePath -Worlds $Worlds `
        -Runtime $Runtime -Denominator $Denominator -AllowOpenMWSaveReload -PersistenceTelemetry `
        -C07PersistenceReload -ExpectedTransform $expectedTransform
    [IO.File]::WriteAllText(
        (Join-Path $reloadRoot "real-save-capture-report.json"),
        ($second | ConvertTo-Json -Depth 20) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))

    $artifacts = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($first.artifacts, $second.artifacts, $generatedSave,
            (Get-Artifact $saveManifestPath),
            (Get-Artifact (Join-Path $firstRoot "real-save-capture-report.json")),
            (Get-Artifact (Join-Path $reloadRoot "real-save-capture-report.json")))) {
        if ($null -ne $entry) {
            foreach ($artifact in @($entry)) {
                if ($null -ne $artifact -and -not [string]::IsNullOrWhiteSpace([string]$artifact.path)) {
                    $artifacts.Add($artifact)
                }
            }
        }
    }
    $reloadLogPath = Join-Path $reloadRoot "openmw.stdout.log"
    $reloadLog = if (Test-Path -LiteralPath $reloadLogPath -PathType Leaf) { Get-Content -Raw -LiteralPath $reloadLogPath } else { "" }
    $mapReopened = $reloadLog -match 'FNV C07 persistence: phase=reload-map-reopened .* path=production-map-reopen status=pass'
    $secondTravel = $reloadLog -match 'FNV C07 persistence: phase=second-travel-arrived .* path=production-persistence-travel status=pass'
    $passed = $first.status -eq "pass" -and $second.status -eq "pass" -and
        [string]$first.capture.gameTermination -eq "engine-exited" -and $mapReopened -and $secondTravel
    return [ordered]@{
        schema = "nikami-fnv-real-save-capture/v1"
        status = if ($passed) { "pass" } else { "fail" }
        target = "OpenMW"
        routeId = "save330-travel-persistence-v1"
        capture = [ordered]@{
            method = "ordinary OpenMW Save330 travel, production StateManager quick-save, clean quit, cold --load-savegame reload, MAP reopen, and second production travel"
            driver = "engine-owned bounded schedule only; no host keyboard or mouse input"
            windowsAppControlUsed = $false
            foregroundActivationUsed = $false
            foregroundInputInjected = $false
            capturesRanSequentially = $true
            userConfigurationRestored = $true
            cleanQuitObserved = [string]$first.capture.gameTermination -eq "engine-exited"
        }
        source = [ordered]@{
            binary = $second.source.binary
            resources = $second.source.resources
            saveFixture = Get-Artifact $Fixture
            normalizedDenominator = $Denominator.evidence
        }
        generatedSave = $generatedSave
        productionSaveManifest = Get-Artifact $saveManifestPath
        expectedReloadTransform = $expectedTransform
        phases = [ordered]@{
            firstTravelSave = $first
            coldReloadSecondTravel = $second
        }
        assertions = [ordered]@{
            productionSaveCreated = $null -ne $generatedSave
            firstTravelSavePhasePass = $first.status -eq "pass"
            cleanQuitAfterSave = [string]$first.capture.gameTermination -eq "engine-exited"
            coldReloadPhasePass = $second.status -eq "pass"
            mapReopenedAfterColdReload = $mapReopened
            secondTravelPass = $secondTravel
        }
        artifacts = @($artifacts)
        error = $null
    }
}

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$SavePath = [IO.Path]::GetFullPath($SavePath)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing RealSave capture: $OutputRoot"
}
if (-not (Test-Path -LiteralPath $SavePath -PathType Leaf)) {
    throw "Immutable Save330 fixture is missing: $SavePath"
}
if ($RouteId -notin @("save330-cold-load-settle-v1", "save330-reload-idempotence-v1", "save330-pipboy-map-selection-v1", "save330-pipboy-map-travel-v1", "save330-pipboy-rejection-matrix-v1", "save330-travel-persistence-v1", "save330-pipboy-inventory-v1", "save330-pipboy-weapon-selection-v1")) {
    throw "Unsupported RealSave route: $RouteId"
}
if ($RouteId -in @("save330-reload-idempotence-v1", "save330-pipboy-map-selection-v1", "save330-pipboy-map-travel-v1", "save330-pipboy-rejection-matrix-v1", "save330-travel-persistence-v1", "save330-pipboy-inventory-v1", "save330-pipboy-weapon-selection-v1") -and $Target -ne "OpenMW") {
    throw "The selected Save330 production route is OpenMW-only."
}
$saveFile = Get-Item -LiteralPath $SavePath
$saveHash = (Get-FileHash -LiteralPath $SavePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($saveFile.Length -ne 3395328L -or $saveHash -ne "07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f") {
    throw "Save330 fixture hash lock failed: bytes=$($saveFile.Length) sha256=$saveHash"
}
if ($InteractiveHandoff -and $Target -eq "Retail") {
    throw "Interactive handoff is restricted to OpenMW."
}
if ($Target -eq "OpenMW" -and [string]::IsNullOrWhiteSpace($BinaryRoot)) {
    . (Join-Path $WorldsRoot "scripts\WorldViewerPaths.ps1")
    $BinaryRoot = Resolve-NikamiOpenMWRuntimeRoot
}
if ($Target -eq "OpenMW") {
    $BinaryRoot = [IO.Path]::GetFullPath($BinaryRoot)
    if (-not (Test-Path -LiteralPath (Join-Path $BinaryRoot "openmw.exe") -PathType Leaf)) {
        throw "OpenMW RealSave binary is missing: $BinaryRoot"
    }
}
if ($Target -eq "Retail" -and (Get-Process -Name "FalloutNV" -ErrorAction SilentlyContinue)) {
    throw "Refusing to overlap a running FalloutNV process."
}
if ($Target -eq "OpenMW" -and (Get-Process -Name "openmw" -ErrorAction SilentlyContinue)) {
    throw "Refusing to overlap a running OpenMW process."
}

New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$denominator = Get-SourceDenominator -Root $WorldsRoot
$startedAt = [DateTime]::UtcNow
$result = $null
try {
    if ($Target -eq "Retail") {
        $result = Invoke-RetailRealSaveCapture -Root $OutputRoot -Fixture $SavePath -Worlds $WorldsRoot
    }
    else {
        if ($RouteId -eq "save330-reload-idempotence-v1") {
            $result = Invoke-OpenMWRealSaveReloadCapture -Root $OutputRoot -Fixture $SavePath -Worlds $WorldsRoot -Runtime $BinaryRoot -Denominator $denominator
        }
        elseif ($RouteId -eq "save330-travel-persistence-v1") {
            $result = Invoke-OpenMWRealSaveC07PersistenceCapture -Root $OutputRoot -Fixture $SavePath `
                -Worlds $WorldsRoot -Runtime $BinaryRoot -Denominator $denominator
        }
        else {
            $c04MapSelection = $RouteId -eq "save330-pipboy-map-selection-v1"
            $c05MapTravel = $RouteId -eq "save330-pipboy-map-travel-v1"
            $c06RejectionMatrix = $RouteId -eq "save330-pipboy-rejection-matrix-v1"
            $d01Inventory = $RouteId -eq "save330-pipboy-inventory-v1"
            $d02WeaponSelection = $RouteId -eq "save330-pipboy-weapon-selection-v1"
            $result = Invoke-OpenMWRealSaveCapture `
                -Root $OutputRoot `
                -Fixture $SavePath `
                -Worlds $WorldsRoot `
                -Runtime $BinaryRoot `
                -Denominator $denominator `
                -C04MapSelection:$c04MapSelection `
                -C05MapTravel:$c05MapTravel `
                -C06RejectionMatrix:$c06RejectionMatrix `
                -D01Inventory:$d01Inventory `
                -D02WeaponSelection:$d02WeaponSelection `
                -HandSkinningMode $HandSkinningMode `
                -HandPoseAudit:$HandPoseAudit
        }
    }
}
catch {
    $result = [ordered]@{
        schema = "nikami-fnv-real-save-capture/v1"
        status = "fail"
        target = $Target
        routeId = $RouteId
        capture = [ordered]@{
            method = "canonical RealSave runner"
            driver = "bounded engine-owned capture only"
            windowsAppControlUsed = $false
            foregroundActivationUsed = $false
            foregroundInputInjected = $false
            sourceFrameRetained = $false
            telemetryRetained = $false
            exactTitleVideoRetained = $false
            userConfigurationRestored = $true
        }
        source = [ordered]@{ saveFixture = Get-Artifact $SavePath; normalizedDenominator = $denominator.evidence }
        assertions = [ordered]@{ stateManifestPass = $false }
        artifacts = @()
        error = $_.Exception.Message
    }
}
$result.schema = "nikami-fnv-real-save-capture/v1"
$result.routeId = $RouteId
$result.startedAtUtc = $startedAt.ToString("o")
$result.completedAtUtc = [DateTime]::UtcNow.ToString("o")
$result.interactiveHandoffRequested = [bool]$InteractiveHandoff
$result.sourceSave = [ordered]@{
    path = $SavePath
    bytes = [long]$saveFile.Length
    sha256 = $saveHash
}
$resultPath = Join-Path $OutputRoot "real-save-capture-report.json"
[IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 18) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$result
if ($result.status -ne "pass") {
    throw "RealSave capture failed. See $resultPath"
}
