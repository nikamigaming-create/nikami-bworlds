[CmdletBinding()]
param(
    [string]$WorldsRoot = "",
    [Parameter(Mandatory)]
    [string]$BinaryRoot,
    [Parameter(Mandatory)]
    [string]$OutputRoot,
    [ValidateRange(8, 30)]
    [int]$FrameRate = 12,
    [ValidateRange(60, 300)]
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($WorldsRoot)) {
    $WorldsRoot = Split-Path -Parent $PSScriptRoot
}
$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$BinaryRoot = [IO.Path]::GetFullPath($BinaryRoot)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)

if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing OpenMW VR proof run: $OutputRoot"
}

$startScript = Join-Path $WorldsRoot "scripts\Start-FNVParityVRExisting.ps1"
$headPoseScript = Join-Path $WorldsRoot "scripts\Invoke-OpenXRSimulatorHeadPose.ps1"
$controllerPoseScript = Join-Path $WorldsRoot "scripts\Invoke-OpenXRSimulatorControllerPose.ps1"
$nativeFrameScript = Join-Path $WorldsRoot "scripts\Request-OpenXRSimulatorNativeEyeFrame.ps1"
$openMwVr = Join-Path $BinaryRoot "openmw_vr.exe"
$candidateManifest = Join-Path $BinaryRoot "candidate-runtime-manifest.json"
$releaseManifest = Join-Path $BinaryRoot "runtime-manifest.json"
$runtimeManifest = if (Test-Path -LiteralPath $candidateManifest -PathType Leaf) {
    $candidateManifest
} else {
    $releaseManifest
}

foreach ($requiredFile in @(
    $startScript,
    $headPoseScript,
    $controllerPoseScript,
    $nativeFrameScript,
    $openMwVr,
    $runtimeManifest
)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required OpenMW VR proof input is missing: $requiredFile"
    }
}

$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
$ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -eq $ffmpeg -or $null -eq $ffprobe -or $null -eq $pwsh) {
    throw "OpenMW VR proof requires pwsh, ffmpeg, and ffprobe on PATH."
}

$bridgeRoot = Join-Path $OutputRoot "bridge"
$simulatorRoot = Join-Path $OutputRoot "simulator"
$nativeFrameRoot = Join-Path $OutputRoot "native-frames"
$nativeRttRoot = Join-Path $OutputRoot "native-rtt"
$proofRoot = Join-Path $OutputRoot "proof"
$pipBoyRtt = Join-Path $nativeRttRoot "pipboy-rtt.png"
$openMwLog = Join-Path $bridgeRoot "openmw-config\openmw.log"
$videoPath = Join-Path $proofRoot "OpenMW-VR-PipBoy-weapons-motion-proof.mp4"
$contactSheetPath = Join-Path $proofRoot "OpenMW-VR-PipBoy-weapons-contact-sheet.png"
$frameManifestPath = Join-Path $OutputRoot "native-frame-manifest.json"
$reportPath = Join-Path $OutputRoot "vr-pipboy-interaction-report.json"

New-Item -ItemType Directory -Path $nativeFrameRoot -Force | Out-Null
New-Item -ItemType Directory -Path $nativeRttRoot -Force | Out-Null
New-Item -ItemType Directory -Path $proofRoot -Force | Out-Null

$startedAt = Get-Date
$launchCutoff = $startedAt.AddSeconds(-2)
$existingProcessIds = @(Get-Process -Name "openmw_vr" -ErrorAction SilentlyContinue | ForEach-Object Id)
$spawnedProcess = $null
$spawnedProcessIds = @()
$captureFailure = $null
$script:NativeFrameNumber = 0

function Set-RightController(
    [double]$X,
    [double]$Y,
    [double]$Z,
    [double]$Yaw,
    [double]$Pitch,
    [double]$Roll,
    [double]$Trigger,
    [double]$Grip
) {
    & $controllerPoseScript `
        -SimulatorDataDirectory $simulatorRoot `
        -Hand right `
        -PosX $X -PosY $Y -PosZ $Z `
        -Yaw $Yaw -Pitch $Pitch -Roll $Roll `
        -Trigger $Trigger -Grip $Grip | Out-Null
}

function Set-LeftController([double]$ButtonA) {
    & $controllerPoseScript `
        -SimulatorDataDirectory $simulatorRoot `
        -Hand left `
        -PosX -0.08 -PosY -0.10 -PosZ -0.10 `
        -Yaw 0 -Pitch -0.05 -Roll 0 `
        -Trigger 0 -Grip 0 -ButtonA $ButtonA | Out-Null
}

function Save-NativeFrame {
    $script:NativeFrameNumber++
    $destination = Join-Path $nativeFrameRoot ('frame-{0:d4}.bmp' -f $script:NativeFrameNumber)
    & $nativeFrameScript `
        -SimulatorDataDirectory $simulatorRoot `
        -DestinationPath $destination `
        -Eye both `
        -TimeoutSeconds 10 | Out-Null
}

function Save-HeldFrames([int]$Count) {
    for ($index = 0; $index -lt $Count; $index++) {
        Save-NativeFrame
    }
}

function Move-RightController(
    [double[]]$From,
    [double[]]$To,
    [int]$Steps,
    [double]$Trigger,
    [double]$Grip
) {
    for ($step = 1; $step -le $Steps; $step++) {
        $amount = $step / [double]$Steps
        $pose = @()
        for ($axis = 0; $axis -lt 6; $axis++) {
            $pose += $From[$axis] + (($To[$axis] - $From[$axis]) * $amount)
        }
        Set-RightController $pose[0] $pose[1] $pose[2] $pose[3] $pose[4] $pose[5] $Trigger $Grip
        Save-NativeFrame
    }
}

function Get-Sha256WithRetry([string]$Path) {
    $lastError = $null
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds 250
        }
    }
    throw $lastError
}

try {
    $launcherArguments = @(
        "-NoProfile",
        "-File", $startScript,
        "-BinaryRoot", $BinaryRoot,
        "-BridgeRoot", $bridgeRoot,
        "-SimulatorDataDirectory", $simulatorRoot,
        "-PipBoyRttCapturePath", $pipBoyRtt,
        "-AllowCandidateRuntime",
        "-DiagnosticCandidate",
        "-Background",
        "-DisableNavigationMesh",
        "-UseRepoOpenXRSimulator",
        "-StaticizedHandDiagnostics",
        "-InteractionProofLoadout",
        "-LogLevel", "VERBOSE"
    )
    & $pwsh.Source @launcherArguments
    if ($LASTEXITCODE -ne 0) {
        throw "OpenMW VR launcher failed with exit code $LASTEXITCODE."
    }

    $spawnDeadline = (Get-Date).AddSeconds(10)
    do {
        $spawnedProcess = Get-Process -Name "openmw_vr" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Id -notin $existingProcessIds -and $_.StartTime -ge $launchCutoff
            } |
            Sort-Object StartTime -Descending |
            Select-Object -First 1
        if ($null -eq $spawnedProcess) {
            Start-Sleep -Milliseconds 100
        }
    } while ($null -eq $spawnedProcess -and (Get-Date) -lt $spawnDeadline)
    if ($null -eq $spawnedProcess) {
        throw "The OpenMW VR proof process could not be identified after launch."
    }
    $spawnedProcessIds = @(Get-Process -Name "openmw_vr" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Id -notin $existingProcessIds -and $_.StartTime -ge $launchCutoff
        } |
        ForEach-Object Id)

    & $headPoseScript `
        -SimulatorDataDirectory $simulatorRoot `
        -PosX 0 -PosY 1.7 -PosZ 0 `
        -Yaw 0 -Pitch -0.8 -Roll 0 | Out-Null
    Set-LeftController 0

    $natural = @(0.20, -0.07, -0.10, 0.10, 0.20, 0.0)
    $knifePointer = @(0.10, -0.10, -0.03, 1.8544, 1.4793, 0.0)
    $riflePointer = @(0.10, -0.10, -0.03, 1.8544, 1.4859, 0.0)
    $pistolPointer = @(0.10, -0.10, -0.03, 1.8544, 1.4760, 0.0)
    $swingOne = @(0.18, -0.08, -0.08, 0.10, 0.20, 0.0)
    $swingTwo = @(0.35, 0.03, -0.14, -0.35, 0.35, 0.25)
    $swingThree = @(-0.02, 0.10, -0.20, -0.85, 0.55, 0.45)

    Set-RightController @natural 0 0
    Save-HeldFrames 6

    # The fresh proof loadout starts with an empty 9mm magazine. Exercise the
    # production reload edge, then retain the forward-barrel trigger action.
    Set-LeftController 1
    Save-NativeFrame
    Set-LeftController 0
    Start-Sleep -Milliseconds 2500
    Save-NativeFrame
    Set-RightController @natural 1 0
    Save-HeldFrames 6
    Set-RightController @natural 0 0
    Save-HeldFrames 4
    # A fresh authored loadout may already have a full magazine, so guarantee
    # an observable production reload after the first shot creates capacity.
    Start-Sleep -Milliseconds 800
    Set-LeftController 1
    Save-NativeFrame
    Set-LeftController 0
    Start-Sleep -Milliseconds 2500
    Save-NativeFrame

    # Native right-hand pointer -> Knife -> ordinary melee delivery.
    Move-RightController $natural $knifePointer 8 0 1
    Save-HeldFrames 2
    Set-RightController @knifePointer 1 1
    Save-HeldFrames 3
    Set-RightController @knifePointer 0 1
    Save-HeldFrames 3
    Move-RightController $knifePointer $natural 8 0 1
    Set-RightController @natural 0 0
    Save-HeldFrames 5
    Move-RightController $natural $swingOne 2 1 0
    Move-RightController $swingOne $swingTwo 4 1 0
    Move-RightController $swingTwo $swingThree 4 1 0
    Set-RightController @swingThree 0 0
    Save-HeldFrames 3

    # Native right-hand pointer -> Varmint Rifle -> reload -> fire.
    Move-RightController $swingThree $riflePointer 8 0 1
    Save-HeldFrames 2
    Set-RightController @riflePointer 1 1
    Save-HeldFrames 3
    Set-RightController @riflePointer 0 1
    Save-HeldFrames 3
    Move-RightController $riflePointer $natural 8 0 1
    Set-RightController @natural 0 0
    Save-HeldFrames 5
    Set-LeftController 1
    Save-NativeFrame
    Set-LeftController 0
    Start-Sleep -Milliseconds 2500
    Save-NativeFrame
    Set-RightController @natural 1 0
    Save-HeldFrames 6
    Set-RightController @natural 0 0
    Save-HeldFrames 4

    # Native right-hand pointer -> 9mm Pistol -> fire again.
    Move-RightController $natural $pistolPointer 8 0 1
    Save-HeldFrames 2
    Set-RightController @pistolPointer 1 1
    Save-HeldFrames 3
    Set-RightController @pistolPointer 0 1
    Save-HeldFrames 3
    Move-RightController $pistolPointer $natural 8 0 1
    Set-RightController @natural 0 0
    Save-HeldFrames 5
    Set-RightController @natural 1 0
    Save-HeldFrames 6
    Set-RightController @natural 0 0
    Save-HeldFrames 4
}
catch {
    $captureFailure = $_
}
finally {
    $spawnedProcessIds = @($spawnedProcessIds + @(
        Get-Process -Name "openmw_vr" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Id -notin $existingProcessIds -and $_.StartTime -ge $launchCutoff
            } |
            ForEach-Object Id
    ) | Sort-Object -Unique)
    foreach ($processId in $spawnedProcessIds) {
        if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $processId -Force -ErrorAction Stop
            Wait-Process -Id $processId -Timeout 10 -ErrorAction SilentlyContinue
            if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
                throw "OpenMW VR proof process $processId did not stop."
            }
        }
    }
    if ($spawnedProcessIds.Count -gt 0) {
        Write-Host "Stopped OpenMW VR proof process IDs: $($spawnedProcessIds -join ', ')."
        Start-Sleep -Milliseconds 500
    }
}

if ($null -ne $captureFailure) {
    throw $captureFailure
}
if (-not (Test-Path -LiteralPath $openMwLog -PathType Leaf)) {
    throw "OpenMW VR proof telemetry is missing: $openMwLog"
}

$logText = Get-Content -LiteralPath $openMwLog -Raw
$assertions = [ordered]@{
    trackedRigReady = $logText -match 'OpenMW VR player rig status=ready'
    livePipBoyScreenBound = $logText -match 'FNV Pip-Boy VR physical: screenBinding=ready'
    knifeSelectedByPointer = $logText -match 'FNV Pip-Boy pointer: control=inventory-row visibleRow=1 cursor=\(142,347\)' -and
        $logText -match 'FNV Pip-Boy selection:.*result="EQUIPPED Knife"'
    rifleSelectedByPointer = $logText -match 'FNV Pip-Boy pointer: control=inventory-row visibleRow=2 cursor=\(178,414\)' -and
        $logText -match 'FNV Pip-Boy selection:.*result="EQUIPPED Varmint Rifle"'
    pistolSelectedByPointer = $logText -match 'FNV Pip-Boy pointer: control=inventory-row visibleRow=0 cursor=\(126,315\)' -and
        $logText -match 'FNV Pip-Boy selection:.*result="EQUIPPED 9mm Pistol"'
    pistolSocketForward = $logText -match 'weapon socket model=meshes/weapons/1handpistol/9mm\.nif.*convention=firearm-forward-x defaultRotZ=90'
    knifeSocketForward = $logText -match 'weapon socket model=meshes/weapons/1handmelee/rustyknife\.nif.*convention=melee-forward-y defaultRotZ=0'
    rifleSocketForward = $logText -match 'weapon socket model=meshes/weapons/2handrifle/varmintrifle\.nif.*convention=firearm-forward-x defaultRotZ=90'
    pistolReloadPassed = $logText -match 'FNV reload:.*weapon=FormId:0x10e3778.*status=pass'
    rifleReloadPassed = $logText -match 'FNV reload:.*weapon=FormId:0x107ea24.*status=pass'
    pistolShotPassed = $logText -match 'FNV combat shot:.*weapon=FormId:0x10e3778.*status=pass'
    rifleShotPassed = $logText -match 'FNV combat shot:.*weapon=FormId:0x107ea24.*status=pass'
    knifeMeleePassed = $logText -match 'FNV combat melee:.*weapon=FormId:0x1004334.*exact=1 status=pass'
    knifeAuthoredHitPassed = $logText -match 'FNV combat authored attack delivery:.*weapon=FormId:0x1004334.*key=hit status=pass'
}

$failedAssertions = @($assertions.GetEnumerator() | Where-Object { -not [bool]$_.Value })
$nativeFrames = @(Get-ChildItem -LiteralPath $nativeFrameRoot -File -Filter 'frame-*.bmp' | Sort-Object Name)
if ($nativeFrames.Count -ne $script:NativeFrameNumber -or $nativeFrames.Count -lt 100) {
    throw "Native OpenXR frame sequence is incomplete: expected=$($script:NativeFrameNumber) actual=$($nativeFrames.Count)."
}

& $ffmpeg.Source `
    -hide_banner -loglevel error -y `
    -framerate $FrameRate -start_number 1 `
    -i (Join-Path $nativeFrameRoot 'frame-%04d.bmp') `
    -vf 'crop=620:620:520:760,scale=720:720:flags=lanczos,format=yuv420p' `
    -c:v libx264 -preset medium -crf 18 -movflags +faststart `
    $videoPath
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $videoPath -PathType Leaf)) {
    throw "ffmpeg did not produce the OpenMW VR motion proof video."
}

& $ffmpeg.Source `
    -hide_banner -loglevel error -y `
    -i $videoPath `
    -vf 'fps=1,scale=240:240,tile=4x4' `
    -frames:v 1 $contactSheetPath
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $contactSheetPath -PathType Leaf)) {
    throw "ffmpeg did not produce the OpenMW VR contact sheet."
}

$probe = & $ffprobe.Source `
    -v error `
    -show_entries format=duration,size `
    -show_entries stream=width,height,avg_frame_rate,nb_frames `
    -of json $videoPath | ConvertFrom-Json
$videoStream = @($probe.streams)[0]

$frameEntries = @($nativeFrames | ForEach-Object {
    [pscustomobject][ordered]@{
        path = $_.FullName
        bytes = $_.Length
        sha256 = Get-Sha256WithRetry $_.FullName
    }
})
$uniqueFrameHashes = @($frameEntries.sha256 | Sort-Object -Unique).Count
$frameManifest = [ordered]@{
    schema = 'nikami-openmw-vr-native-frame-manifest/v1'
    captureMethod = 'repo-local OpenXR simulator projection-eye native frame API'
    frameRate = $FrameRate
    frameCount = $frameEntries.Count
    uniqueFrameHashes = $uniqueFrameHashes
    frames = $frameEntries
}
[IO.File]::WriteAllText(
    $frameManifestPath,
    ($frameManifest | ConvertTo-Json -Depth 6),
    [Text.UTF8Encoding]::new($false))

$artifacts = @($videoPath, $contactSheetPath, $pipBoyRtt, $openMwLog, $frameManifestPath) |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    ForEach-Object {
        $file = Get-Item -LiteralPath $_
        [pscustomobject][ordered]@{
            path = $file.FullName
            bytes = $file.Length
            sha256 = Get-Sha256WithRetry $file.FullName
        }
    }

$passed = $failedAssertions.Count -eq 0 -and
    $uniqueFrameHashes -ge 20 -and
    [int]$videoStream.nb_frames -eq $nativeFrames.Count -and
    [int]$videoStream.width -eq 720 -and
    [int]$videoStream.height -eq 720

$report = [ordered]@{
    schema = 'nikami-openmw-vr-pipboy-interaction-proof/v1'
    status = if ($passed) { 'pass' } else { 'fail' }
    startedAt = $startedAt.ToString('o')
    completedAt = (Get-Date).ToString('o')
    launch = [ordered]@{
        target = 'OpenMW VR'
        executable = $openMwVr
        executableSha256 = Get-Sha256WithRetry $openMwVr
        runtimeManifest = $runtimeManifest
        isolatedProfile = $true
        repoLocalOpenXrSimulator = $true
        engineStopped = $true
    }
    capture = [ordered]@{
        captureMethod = 'repo-local OpenXR simulator projection-eye native frame API; ffmpeg encodes only retained native frames'
        driverMethod = 'OpenXR simulator command API drives head/controller poses, native fingertip ray clicks, reload, firearm trigger, and melee swing'
        selfDriven = $true
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        sourceFramesRetained = $true
        telemetryRetained = $true
        userConfigurationRestored = $true
        sourceFramePattern = (Join-Path $nativeFrameRoot 'frame-*.bmp')
        telemetryPath = $openMwLog
    }
    assertions = $assertions
    failedAssertions = @($failedAssertions | ForEach-Object Key)
    media = [ordered]@{
        videoPath = $videoPath
        width = [int]$videoStream.width
        height = [int]$videoStream.height
        frameRate = [string]$videoStream.avg_frame_rate
        frameCount = [int]$videoStream.nb_frames
        durationSeconds = [double]$probe.format.duration
        uniqueNativeFrameHashes = $uniqueFrameHashes
        nativeFrameCount = $nativeFrames.Count
    }
    artifacts = @($artifacts)
}
[IO.File]::WriteAllText(
    $reportPath,
    ($report | ConvertTo-Json -Depth 10),
    [Text.UTF8Encoding]::new($false))

$report | ConvertTo-Json -Depth 10
if (-not $passed) {
    throw "OpenMW VR Pip-Boy interaction proof failed: " +
        ((@($failedAssertions | ForEach-Object Key) +
            $(if ($uniqueFrameHashes -lt 20) { 'native-frame-motion' } else { @() })) -join ', ')
}
