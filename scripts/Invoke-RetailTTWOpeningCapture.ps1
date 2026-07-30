[CmdletBinding()]
param(
    [string]$WorldsRoot = 'D:\code\nikami-worlds',
    [string]$ParityRoot = 'D:\code\nikami-worlds-fnv-parity',
    [string]$RetailGameRoot = 'D:\SteamLibrary\steamapps\common\Fallout New Vegas',
    [string]$TtwDataRoot = 'D:\Modlists\fnv\mods\Tale of Two Wastelands - OpenMW',
    [string]$CompatibilityLayerManifest = '',
    [string]$OutputRoot = '',
    [ValidateRange(1, 12)]
    [int]$FrameStep = 4,
    [ValidateRange(30, 120)]
    [int]$TimelineFrameRate = 60,
    [ValidateRange(5, 120)]
    [int]$IntroSeconds = 20,
    [ValidateRange(3, 60)]
    [int]$NurserySeconds = 8,
    [ValidateRange(120, 1800)]
    [int]$MenuStartGameLoopFrame = 360,
    [ValidateRange(60, 900)]
    [int]$TimeoutSeconds = 360,
    [switch]$Diagnostic,
    [switch]$InputDiagnostic,
    [switch]$TitleGateDiagnostic,
    [switch]$TitleStateDiagnostic,
    [switch]$TitleInputDiagnostic,
    # A noncanonical, in-engine diagnostic. It uses retail's COC command only
    # to establish whether the disposable TTW runtime can load any world cell;
    # it cannot be used as fresh-opening evidence.
    [switch]$WorldLoadDiagnostic,
    # Title-state A/B diagnostic only. The canonical capture always enables
    # background polling, but this lets us prove whether changing a retail
    # DirectInput device's cooperative level prevents StartMenu's own title
    # transition from occurring.
    [switch]$SkipBackgroundInputPolling
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )

    [IO.File]::WriteAllLines($Path, $Lines, [Text.UTF8Encoding]::new($false))
}

function New-SourceHardLink {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (([IO.Path]::GetPathRoot($Source)).TrimEnd('\') -ine
        ([IO.Path]::GetPathRoot($Destination)).TrimEnd('\')) {
        throw "Hard-link source and destination must be on the same volume: $Source -> $Destination"
    }
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    New-Item -ItemType HardLink -Path $Destination -Target $Source | Out-Null
}

function Get-Artifact {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $file = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $file.FullName
        bytes = [long]$file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Restore-FileState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$Existed,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    if ($Existed) {
        [IO.File]::WriteAllBytes($Path, $Bytes)
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Test-FileState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$Existed,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    if (-not $Existed) {
        return -not (Test-Path -LiteralPath $Path -PathType Leaf)
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $restoredBytes = [IO.File]::ReadAllBytes($Path)
    if ($restoredBytes.Length -ne $Bytes.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        if ($restoredBytes[$index] -ne $Bytes[$index]) {
            return $false
        }
    }
    return $true
}

function Resolve-CompatibilityLayerFile {
    param(
        [Parameter(Mandatory = $true)][string]$LayerRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath) -or
        [regex]::IsMatch($RelativePath, '(^|[\\/])\.\.([\\/]|$)')) {
        throw "Compatibility-layer $Kind path must be a safe relative path: $RelativePath"
    }
    $root = [IO.Path]::GetFullPath($LayerRoot).TrimEnd('\', '/')
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Compatibility-layer $Kind path escapes its layer: $RelativePath"
    }
    return $candidate
}

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$ParityRoot = [IO.Path]::GetFullPath($ParityRoot)
$RetailGameRoot = [IO.Path]::GetFullPath($RetailGameRoot)
$TtwDataRoot = [IO.Path]::GetFullPath($TtwDataRoot)
$oracleScript = Join-Path $ParityRoot 'scripts\Invoke-FNVRetailOracle.ps1'
if ([string]::IsNullOrWhiteSpace($CompatibilityLayerManifest)) {
    $CompatibilityLayerManifest = Join-Path $WorldsRoot 'local\ttw-retail-compat\compatibility-layer.json'
}
$CompatibilityLayerManifest = [IO.Path]::GetFullPath($CompatibilityLayerManifest)
$compatibilityLayerRoot = Split-Path -Parent $CompatibilityLayerManifest

foreach ($required in @(
    $WorldsRoot,
    $ParityRoot,
    $RetailGameRoot,
    $TtwDataRoot,
    $oracleScript,
    (Join-Path $RetailGameRoot 'FalloutNV.exe'),
    (Join-Path $RetailGameRoot 'Data'),
    (Join-Path $TtwDataRoot 'FalloutNV.esm'),
    (Join-Path $TtwDataRoot 'Fallout3.esm'),
    (Join-Path $TtwDataRoot 'TaleOfTwoWastelands.esm'),
    (Join-Path $TtwDataRoot 'Video\Fallout INTRO Vsk.bik')
)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing retail TTW opening input: $required"
    }
}
foreach ($tool in @('ffmpeg', 'ffprobe')) {
    if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Missing required media tool: $tool"
    }
}
if (-not (Test-Path -LiteralPath $CompatibilityLayerManifest -PathType Leaf)) {
    throw "Missing TTW retail compatibility-layer manifest: $CompatibilityLayerManifest"
}
$compatibilityLayer = Get-Content -LiteralPath $CompatibilityLayerManifest -Raw | ConvertFrom-Json
if ([string]$compatibilityLayer.schema -ne 'opennv-ttw-retail-compat-layer/v1') {
    throw "Unsupported TTW retail compatibility-layer schema: $($compatibilityLayer.schema)"
}
if (@($compatibilityLayer.capabilities) -notcontains 'ttw-fresh-opening') {
    throw 'TTW retail compatibility layer does not declare the ttw-fresh-opening capability.'
}
$compatibilityPluginPaths = [Collections.Generic.List[string]]::new()
$compatibilityPluginArtifacts = [Collections.Generic.List[object]]::new()
$compatibilityPlugins = @($compatibilityLayer.plugins | Sort-Object loadOrder)
if ($compatibilityPlugins.Count -eq 0) {
    throw 'TTW retail compatibility layer declares no xNVSE plugins.'
}
foreach ($entry in $compatibilityPlugins) {
    $relativePath = [string]$entry.path
    $pluginPath = Resolve-CompatibilityLayerFile -LayerRoot $compatibilityLayerRoot `
        -RelativePath $relativePath -Kind 'plugin'
    if ([IO.Path]::GetExtension($pluginPath) -ine '.dll') {
        throw "Compatibility-layer plugin must remain inside its layer and be a DLL: $relativePath"
    }
    $artifact = Get-Artifact $pluginPath
    if ($artifact.sha256 -ne ([string]$entry.sha256).ToLowerInvariant()) {
        throw "Compatibility-layer plugin hash does not match its manifest: $pluginPath"
    }
    $compatibilityPluginPaths.Add($pluginPath)
    $compatibilityPluginArtifacts.Add([ordered]@{
        id = [string]$entry.id
        loadOrder = [int]$entry.loadOrder
        artifact = $artifact
    })
}
$compatibilitySupportFilePaths = [Collections.Generic.List[string]]::new()
$compatibilitySupportFileArtifacts = [Collections.Generic.List[object]]::new()
foreach ($entry in @($compatibilityLayer.supportFiles)) {
    $relativePath = [string]$entry.path
    $supportPath = Resolve-CompatibilityLayerFile -LayerRoot $compatibilityLayerRoot `
        -RelativePath $relativePath -Kind 'support-file'
    if ([IO.Path]::GetExtension($supportPath) -ieq '.dll') {
        throw "Compatibility-layer support file must be declared as a plugin instead: $relativePath"
    }
    $artifact = Get-Artifact $supportPath
    if ($artifact.sha256 -ne ([string]$entry.sha256).ToLowerInvariant()) {
        throw "Compatibility-layer support-file hash does not match its manifest: $supportPath"
    }
    $compatibilitySupportFilePaths.Add($supportPath)
    $compatibilitySupportFileArtifacts.Add([ordered]@{
        artifact = $artifact
    })
}

$running = @(Get-Process -Name @('FalloutNV', 'nvse_loader', 'openmw') -ErrorAction SilentlyContinue)
if ($running.Count -ne 0) {
    $runningDescription = ($running | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', '
    throw "Refusing to overlap the retail TTW opening oracle with a running engine: $runningDescription"
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $OutputRoot = Join-Path $WorldsRoot "run\retail-ttw-opening-$stamp"
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite existing retail TTW opening evidence: $OutputRoot"
}

if (@(@($Diagnostic, $InputDiagnostic, $TitleGateDiagnostic, $TitleStateDiagnostic, $TitleInputDiagnostic) | Where-Object { $_ }).Count -gt 1) {
    throw 'Choose one retail opening diagnostic route.'
}
$isDiagnostic = $Diagnostic -or $InputDiagnostic -or $TitleGateDiagnostic -or $TitleStateDiagnostic -or $TitleInputDiagnostic -or $WorldLoadDiagnostic
if ($isDiagnostic) {
    # Keep the fast proof small while honoring the capture contract's minimum
    # valid timeline duration.
    $IntroSeconds = 5
    $NurserySeconds = 3
    $FrameStep = [Math]::Max($FrameStep, 12)
}
$captureSeconds = $IntroSeconds + $NurserySeconds
$captureFrames = $captureSeconds * $TimelineFrameRate
$screenshotFrames = @(
    1..$captureFrames | Where-Object { (($_ - 1) % $FrameStep) -eq 0 }
)
if ($screenshotFrames[-1] -ne $captureFrames) {
    $screenshotFrames += $captureFrames
}

$shadowRoot = Join-Path $OutputRoot 'retail-game'
$shadowData = Join-Path $shadowRoot 'Data'
$baseDataRoot = Join-Path $RetailGameRoot 'Data'
$screens = Join-Path $OutputRoot 'screens'
$stateBackup = Join-Path $OutputRoot 'state-backup'
$oracleOutput = Join-Path $OutputRoot 'retail-opening.jsonl'
$reportPath = Join-Path $OutputRoot 'retail-opening-report.json'
$documentsFalloutRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\FalloutNV'
$isolatedSaveRelativePath = "Saves\OpenNVRetailOpening-$PID\"
$isolatedSaveDirectory = Join-Path $documentsFalloutRoot "Saves\OpenNVRetailOpening-$PID"
$videoPath = Join-Path $OutputRoot $(if ($isDiagnostic) {
    'Retail-TTW-fresh-start-native-diagnostic.mp4'
} else {
    'Retail-TTW-opening-20s-plus-nursery-native.mp4'
})
New-Item -ItemType Directory -Path $OutputRoot, $shadowRoot, $shadowData, $screens, $stateBackup | Out-Null

# The executable, original FNV data, and generated TTW data are immutable
# source files. TTW's installer produces a mod-manager overlay, not a complete
# replacement Data directory, so the shadow first links base FNV Data and then
# replaces only matching shadow files with the generated TTW overlay.
$rootFiles = @(
    'atimgpud.dll', 'binkw32.dll', 'Fallout_default.ini', 'FalloutNV.exe',
    'FalloutNV.ico', 'FalloutNVLauncher.exe', 'GDFFalloutNV.dll', 'high.ini',
    'libvorbis.dll', 'libvorbisfile.dll', 'low.ini', 'MainTitle.wav',
    'medium.ini', 'steam_api.dll', 'VeryHigh.ini'
)
foreach ($relative in $rootFiles) {
    $source = Join-Path $RetailGameRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Retail game root is missing required executable-side file: $source"
    }
    New-SourceHardLink -Source $source -Destination (Join-Path $shadowRoot $relative)
}

$baseDataFiles = @(Get-ChildItem -LiteralPath $baseDataRoot -Recurse -File)
foreach ($source in $baseDataFiles) {
    $relative = $source.FullName.Substring($baseDataRoot.Length).TrimStart('\', '/')
    New-SourceHardLink -Source $source.FullName -Destination (Join-Path $shadowData $relative)
}

$ttwFiles = @(Get-ChildItem -LiteralPath $TtwDataRoot -Recurse -File)
foreach ($source in $ttwFiles) {
    $relative = $source.FullName.Substring($TtwDataRoot.Length).TrimStart('\', '/')
    $destination = Join-Path $shadowData $relative
    if (Test-Path -LiteralPath $destination -PathType Container) {
        throw "TTW overlay destination unexpectedly resolves to a directory: $destination"
    }
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        # The destination exists only inside the fresh disposable shadow.
        Remove-Item -LiteralPath $destination -Force
    }
    New-SourceHardLink -Source $source.FullName -Destination $destination
}

$loadOrder = @(
    'FalloutNV.esm',
    'DeadMoney.esm',
    'HonestHearts.esm',
    'OldWorldBlues.esm',
    'LonesomeRoad.esm',
    'GunRunnersArsenal.esm',
    'Fallout3.esm',
    'Anchorage.esm',
    'ThePitt.esm',
    'BrokenSteel.esm',
    'PointLookout.esm',
    'Zeta.esm',
    'CaravanPack.esm',
    'ClassicPack.esm',
    'MercenaryPack.esm',
    'TribalPack.esm',
    'TaleOfTwoWastelands.esm',
    'YUPTTW.esm'
)
foreach ($plugin in $loadOrder) {
    if (-not (Test-Path -LiteralPath (Join-Path $shadowData $plugin) -PathType Leaf)) {
        throw "TTW shadow load order refers to a missing plugin: $plugin"
    }
}

$pluginsPath = Join-Path $env:LOCALAPPDATA 'FalloutNV\plugins.txt'
$prefsPath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\FalloutNV\FalloutPrefs.ini'
$pluginsExisted = Test-Path -LiteralPath $pluginsPath -PathType Leaf
$prefsExisted = Test-Path -LiteralPath $prefsPath -PathType Leaf
[byte[]]$pluginsBytes = [byte[]]::new(0)
[byte[]]$prefsBytes = [byte[]]::new(0)
if ($pluginsExisted) { $pluginsBytes = [IO.File]::ReadAllBytes($pluginsPath) }
if ($prefsExisted) { $prefsBytes = [IO.File]::ReadAllBytes($prefsPath) }
if ($pluginsExisted) { [IO.File]::WriteAllBytes((Join-Path $stateBackup 'plugins.txt'), $pluginsBytes) }
if ($prefsExisted) { [IO.File]::WriteAllBytes((Join-Path $stateBackup 'FalloutPrefs.ini'), $prefsBytes) }

if ($SkipBackgroundInputPolling -and -not $TitleStateDiagnostic) {
    throw '-SkipBackgroundInputPolling is restricted to the read-only -TitleStateDiagnostic route.'
}

$bootstrapCommands = @()
if (-not $SkipBackgroundInputPolling) {
    $bootstrapCommands += '180:EnableBackgroundInputPolling'
}
$bootstrapCommands += if ($WorldLoadDiagnostic) {
    "${MenuStartGameLoopFrame}:COC Goodsprings"
} else {
    "${MenuStartGameLoopFrame}:StartNewCharacter"
}
$startMenuDispatch = if ($TitleStateDiagnostic) {
    # Read-only retained telemetry.  This observes the live title fade and
    # StartMenu state without invoking a UI action or sending input.
    'title-state-diagnostic'
} elseif ($TitleInputDiagnostic) {
    # Diagnostic only: submit one existing xNVSE key press while retaining
    # raw retail input telemetry. This must prove the native title handoff
    # before it can be considered for canonical replay capture.
    'title-input-diagnostic'
} elseif ($TitleGateDiagnostic) {
    # Diagnostic only: ask the live StartMenu to handle its Enter character
    # once, then retain the state transition. This is intentionally not
    # eligible as canonical replay input.
    'start-menu-keyboard-diagnostic'
} elseif ($InputDiagnostic) {
    # This route intentionally uses only xNVSE's state-input commands against
    # retail's title screen. It tests the DirectInput API that the title menu
    # actually polls, without calling a menu handler or Option callback.
    'state-input-diagnostic'
} elseif ($Diagnostic) {
    # Diagnostic captures trace the native followup attached to the resolved
    # StartMenu New row. They are intentionally separate from the canonical
    # buffered DirectInput route.
    'callback-diagnostic'
} else {
    # The production path is a stateful xNVSE UI action: it resolves the
    # live New and Yes components and lets retail's own menu handler process
    # them.  No foreground or desktop input is involved.
    'xnvse-menu-api'
}
foreach ($bootstrapCommand in $bootstrapCommands) {
    if ($bootstrapCommand -notmatch '^[1-9][0-9]*:.+$') {
        throw "Retail TTW bootstrap command must use '<positive-frame>:<command>': $bootstrapCommand"
    }
}
$oracleResult = $null
$restorationError = $null
$startedAt = [DateTime]::UtcNow
try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $pluginsPath) -Force | Out-Null
    if (Test-Path -LiteralPath $isolatedSaveDirectory) {
        throw "Fresh-opening save namespace unexpectedly already exists: $isolatedSaveDirectory"
    }
    New-Item -ItemType Directory -Path $isolatedSaveDirectory | Out-Null
    Write-Utf8NoBom -Path $pluginsPath -Lines $loadOrder

    if (-not $prefsExisted) {
        throw "Fresh-opening capture requires an existing FalloutPrefs.ini so its exact bytes can be restored: $prefsPath"
    }
    $prefsText = [IO.File]::ReadAllText($prefsPath)
    $prefsText = $prefsText -replace '(?m)^bFull Screen=.*$', 'bFull Screen=0'
    $prefsText = $prefsText -replace '(?m)^iSize W=.*$', 'iSize W=1280'
    $prefsText = $prefsText -replace '(?m)^iSize H=.*$', 'iSize H=720'
    $prefsText = $prefsText -replace '(?m)^bGamepadEnable=.*$', 'bGamepadEnable=0'
    if ($prefsText -match '(?m)^SLocalSavePath=.*$') {
        $prefsText = $prefsText -replace '(?m)^SLocalSavePath=.*$', "SLocalSavePath=$isolatedSaveRelativePath"
    }
    else {
        $prefsText = $prefsText.TrimEnd() + [Environment]::NewLine +
            "SLocalSavePath=$isolatedSaveRelativePath" + [Environment]::NewLine
    }
    [IO.File]::WriteAllText($prefsPath, $prefsText, [Text.Encoding]::Default)

    $oracleResult = & $oracleScript `
        -GameRoot $shadowRoot `
        -OutputPath $oracleOutput `
        -AdditionalPluginDll $compatibilityPluginPaths.ToArray() `
        -AdditionalPluginFile $compatibilitySupportFilePaths.ToArray() `
        -AwaitNewGame `
        -StartMenuDispatch $startMenuDispatch `
        -BootstrapCommand $bootstrapCommands `
        -CaptureSession `
        -SampleEvery 15 `
        -BeforeFrame 1 `
        -CommandFrame 2 `
        -AfterFrame $captureFrames `
        -ScreenshotFrame $screenshotFrames `
        -ScreenshotDirectory $screens `
        -MaxFrames $captureFrames `
        -TimeoutSeconds $TimeoutSeconds `
        -VisibleGame
}
finally {
    try {
        Restore-FileState -Path $pluginsPath -Existed $pluginsExisted -Bytes $pluginsBytes
        Restore-FileState -Path $prefsPath -Existed $prefsExisted -Bytes $prefsBytes
        if (-not (Test-FileState -Path $pluginsPath -Existed $pluginsExisted -Bytes $pluginsBytes) -or
            -not (Test-FileState -Path $prefsPath -Existed $prefsExisted -Bytes $prefsBytes)) {
            throw 'Retail TTW opening oracle restored a user configuration path with different bytes.'
        }
    }
    catch {
        $restorationError = $_.Exception.Message
    }
}
if ($null -ne $restorationError) {
    throw "Retail TTW opening oracle could not restore the user's configuration: $restorationError"
}
if ($null -eq $oracleResult -or $oracleResult.validation.status -ne 'passed') {
    throw 'Retail TTW opening oracle did not return a passing fresh-game validation result.'
}

$events = @(Get-Content -LiteralPath $oracleOutput | ForEach-Object { $_ | ConvertFrom-Json })
$bootstrapEvents = @($events | Where-Object { $_.event -eq 'bootstrap-console-command' })
$newGameEvents = @($events | Where-Object { $_.event -eq 'new-game-observed' })
$backbufferEvents = @($events | Where-Object { $_.event -eq 'scheduled-backbuffer-capture' })
$sessionEvents = @($events | Where-Object { $_.event -eq 'combat-session-snapshot' })
$backgroundInputEvents = @($events | Where-Object { $_.event -eq 'background-input-polling' })
$backgroundInput = if ($backgroundInputEvents.Count -eq 1) { $backgroundInputEvents[0] } else { $null }
$keyboardDevices = @($(if ($null -ne $backgroundInput) {
    $backgroundInput.devices | Where-Object { [bool]$_.selected -and [bool]$_.reconfigured }
}))
$otherDevicesReconfigured = @($(if ($null -ne $backgroundInput) {
    $backgroundInput.devices | Where-Object { -not [bool]$_.selected -and [bool]$_.reconfigured }
}))
$nativeFrames = @(Get-ChildItem -LiteralPath $screens -File -Filter 'frame-*.bmp' |
    ForEach-Object {
        $match = [regex]::Match($_.BaseName, '^frame-(?<frame>[0-9]+)$')
        if ($match.Success) {
            [pscustomobject]@{ frame = [int]$match.Groups['frame'].Value; file = $_ }
        }
    } | Sort-Object frame)

$nativeFrameVideo = $null
if ($nativeFrames.Count -eq $screenshotFrames.Count) {
    $concatPath = Join-Path $OutputRoot 'retail-native-frames.ffconcat'
    $concatLines = [Collections.Generic.List[string]]::new()
    $concatLines.Add('ffconcat version 1.0')
    for ($index = 0; $index -lt $nativeFrames.Count; $index++) {
        $escapedPath = $nativeFrames[$index].file.FullName.Replace("'", "'\\''")
        $concatLines.Add("file '$escapedPath'")
        $frameDuration = if ($index + 1 -lt $nativeFrames.Count) {
            $nativeFrames[$index + 1].frame - $nativeFrames[$index].frame
        } else {
            $FrameStep
        }
        $duration = [double]$frameDuration / [double]$TimelineFrameRate
        $concatLines.Add('duration ' + $duration.ToString('0.000000000', [Globalization.CultureInfo]::InvariantCulture))
    }
    $concatLines.Add("file '$($nativeFrames[-1].file.FullName.Replace("'", "'\\''"))'")
    [IO.File]::WriteAllLines($concatPath, $concatLines, [Text.UTF8Encoding]::new($false))

    & ffmpeg -hide_banner -loglevel warning -y `
        -f concat -safe 0 -i $concatPath `
        -vf "fps=$TimelineFrameRate,scale=1280:720:flags=lanczos" `
        -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -movflags +faststart $videoPath
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $videoPath -PathType Leaf)) {
        $probe = & ffprobe -v error -show_entries format=duration,size `
            -show_entries stream=codec_type,width,height,avg_frame_rate,nb_frames `
            -of json $videoPath | ConvertFrom-Json
        $nativeFrameVideo = [ordered]@{
            captureMethod = 'retail-d3d9-backbuffer-bmp-sequence'
            path = $videoPath
            sha256 = (Get-FileHash -LiteralPath $videoPath -Algorithm SHA256).Hash.ToLowerInvariant()
            bytes = [long]$probe.format.size
            durationSeconds = [double]::Parse([string]$probe.format.duration, [Globalization.CultureInfo]::InvariantCulture)
            sourceFrames = $nativeFrames.Count
            sourceFrameStep = $FrameStep
            timelineFrameRate = $TimelineFrameRate
            videoStreamCount = @($probe.streams | Where-Object { $_.codec_type -eq 'video' }).Count
            audioStreamCount = @($probe.streams | Where-Object { $_.codec_type -eq 'audio' }).Count
        }
    }
}

$backgroundInputPassed = $null -ne $backgroundInput -and [bool]$backgroundInput.accepted -and
    $keyboardDevices.Count -eq 1 -and $otherDevicesReconfigured.Count -eq 0
$passed = $oracleResult.validation.status -eq 'passed' -and
    $bootstrapEvents.Count -eq $bootstrapCommands.Count -and
    @($bootstrapEvents | Where-Object { -not [bool]$_.accepted }).Count -eq 0 -and
    $newGameEvents.Count -eq 1 -and [bool]$newGameEvents[0].awaiting -and
    -not [bool]$newGameEvents[0].duplicate -and
    $backgroundInputPassed -and
    $backbufferEvents.Count -eq $screenshotFrames.Count -and
    @($backbufferEvents | Where-Object { -not [bool]$_.accepted }).Count -eq 0 -and
    $nativeFrames.Count -eq $screenshotFrames.Count -and
    $sessionEvents.Count -gt 0 -and
    $null -ne $nativeFrameVideo -and
    $nativeFrameVideo.videoStreamCount -eq 1 -and
    $nativeFrameVideo.durationSeconds -ge ($captureSeconds - 1.0)

$report = [ordered]@{
    schema = 'retail-ttw-fresh-opening-capture/v1'
    status = if ($passed) { 'pass' } else { 'fail' }
    diagnostic = [bool]$isDiagnostic
    diagnosticMode = if ($TitleStateDiagnostic) { 'title-state' } elseif ($TitleInputDiagnostic) { 'title-input' } elseif ($TitleGateDiagnostic) { 'start-menu-keyboard' } elseif ($InputDiagnostic) { 'state-input' } elseif ($Diagnostic) { 'callback' } else { $null }
    startedAtUtc = $startedAt.ToString('o')
    completedAtUtc = [DateTime]::UtcNow.ToString('o')
    capture = [ordered]@{
        method = 'native StartMenu readiness-gated retail New Game menu dispatch plus native Direct3D 9 backbuffer frames'
        driver = 'in-process xNVSE bootstrap schedule; authored StartMenu readiness; the named engine action uses retail buffered menu input, verifies the live Yes tile, then issues one xNVSE MenuTapKey Enter event; native NVSE NewGame message gate'
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        sourceAssetsUnmodified = $true
        userConfigurationRestored = $true
        audioCaptured = $false
        audioNote = 'The fresh-game visual and telemetry oracle is established first; final synchronized audio is captured after the retail scene state is measured.'
    }
    content = [ordered]@{
        shadowRoot = $shadowRoot
        baseDataRoot = $baseDataRoot
        ttwDataRoot = $TtwDataRoot
        baseDataFileCount = $baseDataFiles.Count
        ttwOverlayFileCount = $ttwFiles.Count
        isolatedSaveDirectory = $isolatedSaveDirectory
        isolatedSavePathSetting = $isolatedSaveRelativePath
        compatibilityLayerManifest = Get-Artifact $CompatibilityLayerManifest
        compatibilityPlugins = @($compatibilityPluginArtifacts)
        compatibilitySupportFiles = @($compatibilitySupportFileArtifacts)
        loadOrder = $loadOrder
        keyAssets = @(
            Get-Artifact (Join-Path $TtwDataRoot 'FalloutNV.esm'),
            Get-Artifact (Join-Path $TtwDataRoot 'Fallout3.esm'),
            Get-Artifact (Join-Path $TtwDataRoot 'TaleOfTwoWastelands.esm'),
            Get-Artifact (Join-Path $TtwDataRoot 'YUPTTW.esm'),
            Get-Artifact (Join-Path $TtwDataRoot 'Video\Fallout INTRO Vsk.bik')
        )
    }
    oracle = [ordered]@{
        output = Get-Artifact $oracleOutput
        manifest = Get-Artifact ($oracleOutput + '.manifest.json')
        bootstrapCommands = $bootstrapCommands
        bootstrapEvents = $bootstrapEvents.Count
        newGameEvents = $newGameEvents.Count
        sessionSamples = $sessionEvents.Count
        validation = $oracleResult.validation
    }
    nativeFrames = [ordered]@{
        expected = $screenshotFrames.Count
        captured = $nativeFrames.Count
        events = $backbufferEvents.Count
        frameStep = $FrameStep
        timelineFrameRate = $TimelineFrameRate
        directory = $screens
    }
    backgroundInput = [ordered]@{
        passed = $backgroundInputPassed
        keyboardDevicesReconfigured = $keyboardDevices.Count
        nonKeyboardDevicesReconfigured = $otherDevicesReconfigured.Count
    }
    video = $nativeFrameVideo
    artifacts = @(
        Get-Artifact $reportPath,
        Get-Artifact $oracleOutput,
        Get-Artifact ($oracleOutput + '.manifest.json'),
        Get-Artifact $videoPath
    ) | Where-Object { $null -ne $_ }
}
[IO.File]::WriteAllText(
    $reportPath,
    (($report | ConvertTo-Json -Depth 14) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false))

$report
if (-not $passed) {
    throw "Retail TTW fresh-opening capture failed. See $reportPath"
}
