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
    [int]$TimeoutSeconds = 180,
    [switch]$WeaponWheel
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
$weaponCloseupVideoPath = Join-Path $proofRoot "OpenMW-VR-weapon-hand-closeup-proof.mp4"
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
$script:NativeFrameTelemetry = @()
$previousPointerCalibration = $env:OPENMW_FNV_VR_POINTER_CALIBRATION
$previousNativeWeaponDebugAxes = $env:OPENMW_FNV_VR_NATIVE_WEAPON_DEBUG_AXES
$previousNativeWeaponTelemetry = $env:OPENMW_FNV_VR_NATIVE_WEAPON_TELEMETRY
$framingHiddenPath = Join-Path $proofRoot "framing-hidden.bmp"
$framingLeftPath = Join-Path $proofRoot "framing-left-hand.bmp"
$framingRightPath = Join-Path $proofRoot "framing-right-hand.bmp"
$framingBothPath = Join-Path $proofRoot "framing-both-hands.bmp"
$framingLeftVisualDelta = 0.0
$framingRightVisualDelta = 0.0
$framingMathPassed = $false
$framingVisualPassed = $false
$script:ProofHeadPitch = -0.30

function Set-ProofHeadPose {
    & $headPoseScript `
        -SimulatorDataDirectory $simulatorRoot `
        -PosX 0 -PosY 1.7 -PosZ 0 `
        -Yaw 0 -Pitch $script:ProofHeadPitch -Roll 0 | Out-Null
}

function Set-RightController(
    [double]$X,
    [double]$Y,
    [double]$Z,
    [double]$Yaw,
    [double]$Pitch,
    [double]$Roll,
    [double]$Trigger,
    [double]$Grip,
    [int]$ButtonB = 0
) {
    & $controllerPoseScript `
        -SimulatorDataDirectory $simulatorRoot `
        -Hand right `
        -PosX $X -PosY $Y -PosZ $Z `
        -Yaw $Yaw -Pitch $Pitch -Roll $Roll `
        -Trigger $Trigger -Grip $Grip -ButtonB $ButtonB | Out-Null
}

function Set-LeftController([double]$ButtonA) {
    & $controllerPoseScript `
        -SimulatorDataDirectory $simulatorRoot `
        -Hand left `
        -PosX -0.20 -PosY -0.10 -PosZ -0.45 `
        -Yaw 0 -Pitch -0.05 -Roll 0 `
        -Trigger 0 -Grip 0 -ButtonA $ButtonA | Out-Null
}

function Set-SelectionRig {
    Set-ProofHeadPose
    & $controllerPoseScript `
        -SimulatorDataDirectory $simulatorRoot `
        -Hand left `
        -PosX -0.08 -PosY -0.10 -PosZ -0.10 `
        -Yaw 0 -Pitch -0.05 -Roll 0 `
        -Trigger 0 -Grip 0 -ButtonA 0 | Out-Null
}

function Set-InspectionRig {
    Set-ProofHeadPose
    Set-LeftController 0
}

function Save-NativeFrame {
    $script:NativeFrameNumber++
    $destination = Join-Path $nativeFrameRoot ('frame-{0:d4}.bmp' -f $script:NativeFrameNumber)
    # The first exterior transition can legitimately hold the render thread
    # while authored FNV cells and shaders finish loading. Keep the request
    # alive through that one-time transition instead of killing a healthy
    # OpenXR session at the old ten-second boundary.
    $nativeFrameResult = & $nativeFrameScript `
        -SimulatorDataDirectory $simulatorRoot `
        -DestinationPath $destination `
        -Eye both `
        -TimeoutSeconds 30
    $script:NativeFrameTelemetry += [pscustomobject][ordered]@{
        captureIndex = $script:NativeFrameNumber
        simulatorFrame = [int64]$nativeFrameResult.frame
        capturedAtUtc = [DateTime]::UtcNow.ToString('o')
        path = $destination
    }
}

function Save-HeldFrames([int]$Count) {
    for ($index = 0; $index -lt $Count; $index++) {
        Save-NativeFrame
    }
}

function Save-PacedFrames([int]$Count, [int]$DelayMilliseconds = 83) {
    for ($index = 0; $index -lt $Count; $index++) {
        Save-NativeFrame
        if ($index + 1 -lt $Count) {
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
}

function Set-HiddenController([ValidateSet('left', 'right')][string]$Hand) {
    & $controllerPoseScript `
        -SimulatorDataDirectory $simulatorRoot `
        -Hand $Hand `
        -PosX 0 -PosY 0 -PosZ 0.60 `
        -Yaw 0 -Pitch 0 -Roll 0 `
        -Trigger 0 -Grip 0 | Out-Null
}

function Save-FramingFrame([string]$Destination) {
    Start-Sleep -Milliseconds 150
    & $nativeFrameScript `
        -SimulatorDataDirectory $simulatorRoot `
        -DestinationPath $Destination `
        -Eye both `
        -TimeoutSeconds 30 | Out-Null
}

function Measure-FramingVisualDelta([string]$VisiblePath, [string]$HiddenPath) {
    # Measure actual changed pixels in the complete lower projection eye. This is independent
    # of scene-graph telemetry: a valid pose is insufficient when the hand is not recorded.
    $metadata = & $ffmpeg.Source `
        -hide_banner -loglevel info `
        -i $VisiblePath -i $HiddenPath `
        -filter_complex '[0:v][1:v]blend=all_mode=difference,crop=1120:700:80:700,signalstats,metadata=mode=print:file=-' `
        -frames:v 1 -f null NUL 2>&1 | Out-String
    $match = [regex]::Match($metadata, 'lavfi\.signalstats\.YAVG=(?<value>[-+0-9.eE]+)')
    if (-not $match.Success) {
        throw "Could not measure the native-eye framing delta for $VisiblePath."
    }
    return [double]$match.Groups['value'].Value
}

function Test-NaturalPoseProjection([double[]]$RightPose, [double]$Pitch) {
    # Controller offsets are head-local. Project both controller centers through the
    # simulator's declared 90-degree eye FOV before allowing a long proof sequence.
    $sinPitch = [math]::Sin($pitch)
    $cosPitch = [math]::Cos($pitch)
    $poses = @(
        [double[]]@(-0.20, -0.10, -0.45),
        [double[]]@($RightPose[0], $RightPose[1], $RightPose[2])
    )
    foreach ($pose in $poses) {
        $depth = ($pose[1] * $sinPitch) - ($pose[2] * $cosPitch)
        $viewUp = ($pose[1] * $cosPitch) + ($pose[2] * $sinPitch)
        if ($depth -le 0.10) {
            return $false
        }
        $ndcX = $pose[0] / $depth
        $ndcY = $viewUp / $depth
        if ([math]::Abs($ndcX) -gt 0.65 -or [math]::Abs($ndcY) -gt 0.65) {
            return $false
        }
    }
    return $true
}

function Move-RightController(
    [double[]]$From,
    [double[]]$To,
    [int]$Steps,
    [double]$Trigger,
    [double]$Grip,
    [int]$ButtonB = 0
) {
    for ($step = 1; $step -le $Steps; $step++) {
        $amount = $step / [double]$Steps
        $pose = @()
        for ($axis = 0; $axis -lt 6; $axis++) {
            $pose += $From[$axis] + (($To[$axis] - $From[$axis]) * $amount)
        }
        Set-RightController $pose[0] $pose[1] $pose[2] $pose[3] $pose[4] $pose[5] $Trigger $Grip $ButtonB
        Save-NativeFrame
    }
}

function Measure-PipBoyCursor([double[]]$Pose) {
    $pattern = 'OpenMW VR Pip-Boy focus .*cursor=\((?<x>\d+),(?<y>\d+)\)'
    $before = @(Select-String -LiteralPath $openMwLog -Pattern $pattern -ErrorAction SilentlyContinue).Count
    Set-RightController $Pose[0] $Pose[1] $Pose[2] $Pose[3] $Pose[4] $Pose[5] 0 1
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 25
        $matches = @(Select-String -LiteralPath $openMwLog -Pattern $pattern -ErrorAction SilentlyContinue)
        if ($matches.Count -gt $before) {
            $parsed = [regex]::Match($matches[-1].Line, $pattern)
            if ($parsed.Success) {
                return [pscustomobject]@{
                    X = [int]$parsed.Groups['x'].Value
                    Y = [int]$parsed.Groups['y'].Value
                }
            }
        }
    }
    return $null
}

function Find-PipBoyPointerPose([int]$TargetX, [int]$TargetY) {
    $pose = [double[]]@(0.10, -0.10, -0.03, 0.9193, 1.1875, 0.0)
    $sample = Measure-PipBoyCursor $pose
    if ($null -eq $sample) {
        throw "Pip-Boy pointer calibration could not acquire the physical screen at its seed pose."
    }

    for ($iteration = 0; $iteration -lt 24; $iteration++) {
        $errorX = $TargetX - $sample.X
        $errorY = $TargetY - $sample.Y
        if ([math]::Abs($errorX) -le 1 -and [math]::Abs($errorY) -le 1) {
            Write-Host "Calibrated Pip-Boy cursor target=($TargetX,$TargetY) actual=($($sample.X),$($sample.Y)) iterations=$iteration"
            return $pose
        }

        $step = 0.01
        $yawProbe = $null
        $yawDelta = 0.0
        foreach ($direction in @(1.0, -1.0)) {
            $candidate = [double[]]$pose.Clone()
            $candidate[3] += $direction * $step
            $candidateSample = Measure-PipBoyCursor $candidate
            if ($null -ne $candidateSample) {
                $yawProbe = $candidateSample
                $yawDelta = $direction * $step
                break
            }
        }
        $pitchProbe = $null
        $pitchDelta = 0.0
        foreach ($direction in @(1.0, -1.0)) {
            $candidate = [double[]]$pose.Clone()
            $candidate[4] += $direction * $step
            $candidateSample = Measure-PipBoyCursor $candidate
            if ($null -ne $candidateSample) {
                $pitchProbe = $candidateSample
                $pitchDelta = $direction * $step
                break
            }
        }
        if ($null -eq $yawProbe -or $null -eq $pitchProbe) {
            throw "Pip-Boy pointer calibration lost the physical screen while measuring its local cursor basis."
        }

        $j11 = ($yawProbe.X - $sample.X) / $yawDelta
        $j21 = ($yawProbe.Y - $sample.Y) / $yawDelta
        $j12 = ($pitchProbe.X - $sample.X) / $pitchDelta
        $j22 = ($pitchProbe.Y - $sample.Y) / $pitchDelta
        $determinant = ($j11 * $j22) - ($j12 * $j21)
        if ([math]::Abs($determinant) -lt 0.001) {
            throw "Pip-Boy pointer calibration produced a singular cursor basis."
        }

        $deltaYaw = (($errorX * $j22) - ($j12 * $errorY)) / $determinant
        $deltaPitch = (($j11 * $errorY) - ($errorX * $j21)) / $determinant
        $deltaYaw = [math]::Max(-0.06, [math]::Min(0.06, $deltaYaw))
        $deltaPitch = [math]::Max(-0.06, [math]::Min(0.06, $deltaPitch))

        $accepted = $false
        for ($backoff = 0; $backoff -lt 7; $backoff++) {
            $scale = [math]::Pow(0.5, $backoff)
            $candidate = [double[]]$pose.Clone()
            $candidate[3] += $deltaYaw * $scale
            $candidate[4] += $deltaPitch * $scale
            $candidateSample = Measure-PipBoyCursor $candidate
            if ($null -ne $candidateSample) {
                $pose = $candidate
                $sample = $candidateSample
                $accepted = $true
                break
            }
        }
        if (-not $accepted) {
            throw "Pip-Boy pointer calibration could not take a bounded step toward ($TargetX,$TargetY)."
        }
    }
    throw "Pip-Boy pointer calibration did not converge on ($TargetX,$TargetY); last=($($sample.X),$($sample.Y))."
}

function Measure-PipBoyPhysicalControl([double[]]$Pose, [string]$Control) {
    $number = '-?\d+(?:\.\d+)?(?:e[+-]?\d+)?'
    $pattern = "FNV Pip-Boy physical ray fixture: control=$([regex]::Escape($Control)) .*direction=\((?<dx>$number),(?<dy>$number),(?<dz>$number)\) targetDirection=\((?<tx>$number),(?<ty>$number),(?<tz>$number)\)"
    $before = @(Select-String -LiteralPath $openMwLog -Pattern $pattern -ErrorAction SilentlyContinue).Count
    Set-RightController $Pose[0] $Pose[1] $Pose[2] $Pose[3] $Pose[4] $Pose[5] 0 1
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 25
        $matches = @(Select-String -LiteralPath $openMwLog -Pattern $pattern -ErrorAction SilentlyContinue)
        if ($matches.Count -gt $before) {
            $parsed = [regex]::Match($matches[-1].Line, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($parsed.Success) {
                return [pscustomobject]@{
                    Direction = [double[]]@(
                        [double]$parsed.Groups['dx'].Value,
                        [double]$parsed.Groups['dy'].Value,
                        [double]$parsed.Groups['dz'].Value)
                    Target = [double[]]@(
                        [double]$parsed.Groups['tx'].Value,
                        [double]$parsed.Groups['ty'].Value,
                        [double]$parsed.Groups['tz'].Value)
                }
            }
        }
    }
    return $null
}

function Find-PipBoyPhysicalControlPose([string]$Control) {
    # Start at the proven screen-center ray and solve the two controller angles against
    # the exact world-space center of the named authored NIF drawable. The 3x2
    # Gauss-Newton step avoids screen-layout guesses and remains valid as the wrist moves.
    $pose = [double[]]@(0.10, -0.10, -0.03, 0.9193, 1.1875, 0.0)
    $sample = Measure-PipBoyPhysicalControl $pose $Control
    if ($null -eq $sample) {
        throw "Pip-Boy physical-control calibration did not receive fixture telemetry for $Control."
    }

    for ($iteration = 0; $iteration -lt 20; $iteration++) {
        $dot = 0.0
        for ($axis = 0; $axis -lt 3; $axis++) {
            $dot += $sample.Direction[$axis] * $sample.Target[$axis]
        }
        $dot = [math]::Max(-1.0, [math]::Min(1.0, $dot))
        $angle = [math]::Acos($dot)
        if ($angle -le 0.004) {
            Write-Host "Calibrated Pip-Boy physical control=$Control angleRad=$angle iterations=$iteration"
            return $pose
        }

        $step = 0.01
        $yawPose = [double[]]$pose.Clone()
        $yawPose[3] += $step
        $yawSample = Measure-PipBoyPhysicalControl $yawPose $Control
        $pitchPose = [double[]]$pose.Clone()
        $pitchPose[4] += $step
        $pitchSample = Measure-PipBoyPhysicalControl $pitchPose $Control
        if ($null -eq $yawSample -or $null -eq $pitchSample) {
            throw "Pip-Boy physical-control calibration lost fixture telemetry for $Control."
        }

        $jYaw = [double[]]@(0.0, 0.0, 0.0)
        $jPitch = [double[]]@(0.0, 0.0, 0.0)
        $error = [double[]]@(0.0, 0.0, 0.0)
        for ($axis = 0; $axis -lt 3; $axis++) {
            $jYaw[$axis] = ($yawSample.Direction[$axis] - $sample.Direction[$axis]) / $step
            $jPitch[$axis] = ($pitchSample.Direction[$axis] - $sample.Direction[$axis]) / $step
            $error[$axis] = $sample.Target[$axis] - $sample.Direction[$axis]
        }
        $a = 0.0; $b = 0.0; $c = 0.0; $r1 = 0.0; $r2 = 0.0
        for ($axis = 0; $axis -lt 3; $axis++) {
            $a += $jYaw[$axis] * $jYaw[$axis]
            $b += $jYaw[$axis] * $jPitch[$axis]
            $c += $jPitch[$axis] * $jPitch[$axis]
            $r1 += $jYaw[$axis] * $error[$axis]
            $r2 += $jPitch[$axis] * $error[$axis]
        }
        $determinant = ($a * $c) - ($b * $b)
        if ([math]::Abs($determinant) -lt 1e-8) {
            throw "Pip-Boy physical-control calibration produced a singular angular basis for $Control."
        }
        $deltaYaw = (($r1 * $c) - ($b * $r2)) / $determinant
        $deltaPitch = (($a * $r2) - ($b * $r1)) / $determinant
        $pose[3] += [math]::Max(-0.20, [math]::Min(0.20, $deltaYaw))
        $pose[4] += [math]::Max(-0.20, [math]::Min(0.20, $deltaPitch))
        $sample = Measure-PipBoyPhysicalControl $pose $Control
        if ($null -eq $sample) {
            throw "Pip-Boy physical-control calibration lost its accepted pose for $Control."
        }
    }
    throw "Pip-Boy physical-control calibration did not converge for $Control."
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
    $env:OPENMW_FNV_VR_POINTER_CALIBRATION = "1"
    if ($WeaponWheel) {
        # Weapon-wheel proof is also the signed attachment proof: show the native hand, Weapon bone, model origin,
        # actual production ray, and tracked Aim reference while logging the rigid invariant every rendered frame.
        $env:OPENMW_FNV_VR_NATIVE_WEAPON_DEBUG_AXES = "1"
        $env:OPENMW_FNV_VR_NATIVE_WEAPON_TELEMETRY = "1"
    }
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

    # Seed valid tracking immediately. The simulator may end an idle session
    # before the heavy exterior load completes if no head/controller state has
    # ever been published.
    # Controller translations below are head-local fixture coordinates. Head world height is
    # independent; adding it here would place the hands above the headset.
    # A neutral one-handed firing stance in front of the right shoulder.  The
    # 1.20-radian controller yaw presents the native weapon/hand frame obliquely
    # to the proof eye, so the grip, trigger finger, and barrel are visible instead
    # of collapsing into the previous edge-on silhouette.
    $natural = @(0.00, -0.19, -0.40, 1.20, 0.02, 0.0)
    Set-ProofHeadPose
    Set-LeftController 0
    Set-RightController @natural 0 0

    # Do not spend the native-frame request timeout inside the one-time FNV
    # exterior load. The engine publishes both conditions that make this proof
    # meaningful: the authored inventory was installed, the two hands plus
    # Pip-Boy are attached, and OpenMW's native weapon part owns the pistol.
    # Begin motion only after all three milestones.
    $rigReadyDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $nextTrackingHeartbeat = Get-Date
    $rigReady = $false
    do {
        $liveProofProcess = Get-Process -Name "openmw_vr" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Id -notin $existingProcessIds -and $_.StartTime -ge $launchCutoff
            } |
            Select-Object -First 1
        if ($null -eq $liveProofProcess) {
            throw "OpenMW VR exited before the live weapon rig became ready."
        }
        if (Test-Path -LiteralPath $openMwLog -PathType Leaf) {
            # Exterior/Pip-Boy setup emits several hundred renderer diagnostics between
            # these two one-shot milestones; keep both in the same bounded snapshot.
            $readyTail = Get-Content -LiteralPath $openMwLog -Tail 5000 -ErrorAction SilentlyContinue | Out-String
            $rigReady = $readyTail -match 'FNV Pip-Boy starter: live authored-data preparation=pass' -and
                $readyTail -match 'OpenMW VR player rig status=ready .*attachedSurfaces=3 requestedSurfaces=3' -and
                $readyTail -match 'OpenMW VR native equipped weapon: editor=WeapNV9mmPistol .*attach=Weapon .*duplicateSurface=0'
        }
        if (-not $rigReady) {
            if ((Get-Date) -ge $nextTrackingHeartbeat) {
                try {
                    Set-LeftController 0
                    Set-RightController @natural 0 0
                }
                catch {
                    # The render thread may not acknowledge commands while the
                    # initial exterior is synchronously loading. The command is
                    # still published; readiness telemetry remains authoritative.
                }
                $nextTrackingHeartbeat = (Get-Date).AddSeconds(2)
            }
            Start-Sleep -Milliseconds 250
        }
    } while (-not $rigReady -and (Get-Date) -lt $rigReadyDeadline)
    if (-not $rigReady) {
        throw "OpenMW VR did not publish the three hand/Pip-Boy surfaces plus native weapon part within $TimeoutSeconds seconds."
    }
    Start-Sleep -Milliseconds 500

    # Hard framing gate. Capture an empty projection-eye baseline, then each hand independently.
    # The long motion proof cannot begin unless both projection math and native-eye pixels prove
    # that the left and right hands are inside the recorded view.
    $framingCandidateIndex = 0
    # Start with the native-eye view that visibly contains both complete hands and
    # presents the weapon broadside; shallower candidates are fallbacks only.
    foreach ($candidatePitch in @(-0.70, -0.60, -0.50, -0.40, -0.35)) {
        $framingCandidateIndex++
        $script:ProofHeadPitch = $candidatePitch
        Set-ProofHeadPose
        $candidateHiddenPath = Join-Path $proofRoot ("framing-candidate-{0:d2}-hidden.bmp" -f $framingCandidateIndex)
        $candidateLeftPath = Join-Path $proofRoot ("framing-candidate-{0:d2}-left.bmp" -f $framingCandidateIndex)
        $candidateRightPath = Join-Path $proofRoot ("framing-candidate-{0:d2}-right.bmp" -f $framingCandidateIndex)
        Set-HiddenController left
        Set-HiddenController right
        Save-FramingFrame $candidateHiddenPath
        Set-LeftController 0
        Save-FramingFrame $candidateLeftPath
        Set-HiddenController left
        Set-RightController @natural 0 0
        Save-FramingFrame $candidateRightPath
        $candidateLeftDelta = Measure-FramingVisualDelta $candidateLeftPath $candidateHiddenPath
        $candidateRightDelta = Measure-FramingVisualDelta $candidateRightPath $candidateHiddenPath
        $candidateMathPassed = Test-NaturalPoseProjection $natural $candidatePitch
        Write-Host "VR framing candidate pitch=$candidatePitch math=$candidateMathPassed leftPixelDelta=$candidateLeftDelta rightPixelDelta=$candidateRightDelta"
        if ($candidateMathPassed -and $candidateLeftDelta -ge 0.20 -and $candidateRightDelta -ge 0.20) {
            $framingHiddenPath = $candidateHiddenPath
            $framingLeftPath = $candidateLeftPath
            $framingRightPath = $candidateRightPath
            $framingLeftVisualDelta = $candidateLeftDelta
            $framingRightVisualDelta = $candidateRightDelta
            $framingMathPassed = $true
            $framingVisualPassed = $true
            break
        }
    }
    Set-ProofHeadPose
    Set-LeftController 0
    Set-RightController @natural 0 0
    Save-FramingFrame $framingBothPath
    if (-not $framingMathPassed -or -not $framingVisualPassed) {
        throw "VR proof framing gate failed before the motion sequence: math=$framingMathPassed leftPixelDelta=$framingLeftVisualDelta rightPixelDelta=$framingRightVisualDelta."
    }
    Write-Host "VR proof framing gate passed: leftPixelDelta=$framingLeftVisualDelta rightPixelDelta=$framingRightVisualDelta"
    # Begin retained evidence on the accepted steady two-hand view.
    Save-HeldFrames 4

    Set-ProofHeadPose
    Set-LeftController 0

    # Prove that the same right-hand ray reaches and activates every authored
    # device control, not merely the LCD atlas. Solve each pose from the live
    # drawable center and restore ITEMS last so the subsequent row selections
    # continue through the production inventory pane.
    $pipBoyButton01 = Find-PipBoyPhysicalControlPose 'PipBoyButton01'
    $pipBoyButton02 = Find-PipBoyPhysicalControlPose 'PipBoyButton02'
    $pipBoyButton03 = Find-PipBoyPhysicalControlPose 'PipBoyButton03'
    $pipBoyTabKnob = Find-PipBoyPhysicalControlPose 'TabKnob'
    $pipBoyScrollKnob = Find-PipBoyPhysicalControlPose 'ScrollKnob'

    function Press-PipBoyPhysicalControl([string]$Control, [double[]]$Pose) {
        $focusPattern = "FNV Pip-Boy physical ray focus: control=$([regex]::Escape($Control))"
        $focusBefore = @(Select-String -LiteralPath $openMwLog -Pattern $focusPattern -ErrorAction SilentlyContinue).Count
        Set-RightController @Pose 0 1

        # Controller-pose commands and native-frame requests are independent
        # simulator channels. Wait until OpenMW has consumed this pose and its
        # production pointer owns the named control before raising the trigger;
        # otherwise the edge can race the previous pose and activate empty air.
        $focused = $false
        for ($attempt = 0; $attempt -lt 80; $attempt++) {
            Start-Sleep -Milliseconds 25
            $focusMatches = @(Select-String -LiteralPath $openMwLog -Pattern $focusPattern -ErrorAction SilentlyContinue)
            if ($focusMatches.Count -gt $focusBefore) {
                $focused = $true
                break
            }
        }
        if (-not $focused) {
            throw "Pip-Boy physical control $Control did not acquire production pointer focus before its trigger edge."
        }

        Save-PacedFrames 2 50
        $clickPattern = "FNV Pip-Boy physical ray click: control=$([regex]::Escape($Control)) .*handled=1"
        $clickBefore = @(Select-String -LiteralPath $openMwLog -Pattern $clickPattern -ErrorAction SilentlyContinue).Count
        Set-RightController @Pose 1 1
        $clicked = $false
        for ($attempt = 0; $attempt -lt 80; $attempt++) {
            Start-Sleep -Milliseconds 25
            $clickMatches = @(Select-String -LiteralPath $openMwLog -Pattern $clickPattern -ErrorAction SilentlyContinue)
            if ($clickMatches.Count -gt $clickBefore) {
                $clicked = $true
                break
            }
        }
        if (-not $clicked) {
            Set-RightController @Pose 0 1
            throw "Pip-Boy physical control $Control received focus but its trigger edge was not handled."
        }

        Save-PacedFrames 2 50
        Set-RightController @Pose 0 1
        Save-PacedFrames 2 50
    }

    Press-PipBoyPhysicalControl 'PipBoyButton01' $pipBoyButton01
    Press-PipBoyPhysicalControl 'PipBoyButton03' $pipBoyButton03
    Press-PipBoyPhysicalControl 'TabKnob' $pipBoyTabKnob
    Press-PipBoyPhysicalControl 'ScrollKnob' $pipBoyScrollKnob
    Press-PipBoyPhysicalControl 'PipBoyButton02' $pipBoyButton02

    if ($WeaponWheel) {
        # These targets are the inverse XR-space transform of the production wheel fixture centers measured
        # around the fixed left-grip anchor. Drive the ordinary OpenXR radial button and physically move the
        # selecting grip into each preview; no cursor or screen-space selection is involved.
        $wheelKnife = @(-0.1743, 0.2253, -0.6402, 0.0, 0.0, 0.0)
        $wheelRifle = @(-0.0714, 0.2253, -0.1058, 0.0, 0.0, 0.0)
        $wheelPistol = @(-0.3557, -0.1823, -0.3280, 0.0, 0.0, 0.0)
        $swingOne = @(0.18, -0.08, -0.08, 0.10, 0.20, 0.0)
        $swingTwo = @(0.35, 0.03, -0.14, -0.35, 0.35, 0.25)
        $swingThree = @(-0.02, 0.10, -0.20, -0.85, 0.55, 0.45)

        function Grab-WheelWeapon([double[]]$Target) {
            Set-RightController @natural 0 0 1
            Save-HeldFrames 14
            Move-RightController $natural $Target 8 0 0 1
            Set-RightController @Target 0 0 1
            Save-HeldFrames 3
            Set-RightController @Target 0 1 1
            Save-HeldFrames 4
            Set-RightController @Target 0 0 0
            Save-HeldFrames 3
            Move-RightController $Target $natural 8 0 0 0
            Set-RightController @natural 0 0 0
            Save-HeldFrames 5
        }

        Set-RightController @natural 0 0 0
        Save-HeldFrames 6

        Grab-WheelWeapon $wheelKnife
        Move-RightController $natural $swingOne 3 1 0
        Move-RightController $swingOne $swingTwo 4 1 0
        Move-RightController $swingTwo $swingThree 4 1 0
        Set-RightController @swingThree 0 0 0
        Save-HeldFrames 5

        Grab-WheelWeapon $wheelRifle
        Set-LeftController 1
        Save-NativeFrame
        Set-LeftController 0
        Save-PacedFrames 30
        Set-RightController @natural 1 0 0
        Save-PacedFrames 12
        Set-RightController @natural 0 0 0
        Save-PacedFrames 12

        Grab-WheelWeapon $wheelPistol
        Set-LeftController 1
        Save-NativeFrame
        Set-LeftController 0
        Save-PacedFrames 30
        Set-RightController @natural 1 0 0
        Save-PacedFrames 12
        Set-RightController @natural 0 0 0
        Save-PacedFrames 12
    }
    else {
    # These three calibrated RightHandAim poses hit distinct inventory rows on the production Pip-Boy
    # screen. Reusing a screen-center pose for every click leaves the starter pistol equipped throughout.
    $knifePointer = Find-PipBoyPointerPose 142 347
    $riflePointer = Find-PipBoyPointerPose 178 414
    $pistolPointer = Find-PipBoyPointerPose 126 315
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
    Save-PacedFrames 30
    Set-RightController @natural 1 0
    Save-PacedFrames 12
    Set-RightController @natural 0 0
    Save-PacedFrames 12
    # A fresh authored loadout may already have a full magazine, so guarantee
    # an observable production reload after the first shot creates capacity.
    Start-Sleep -Milliseconds 800
    Set-LeftController 1
    Save-NativeFrame
    Set-LeftController 0
    Save-PacedFrames 30

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
    Save-PacedFrames 30
    Set-RightController @natural 1 0
    Save-PacedFrames 12
    Set-RightController @natural 0 0
    Save-PacedFrames 12

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
    Save-PacedFrames 12
    Set-RightController @natural 0 0
    Save-PacedFrames 12
    }
}
catch {
    $captureFailure = $_
}
finally {
    if ($null -eq $previousPointerCalibration) {
        Remove-Item Env:OPENMW_FNV_VR_POINTER_CALIBRATION -ErrorAction SilentlyContinue
    } else {
        $env:OPENMW_FNV_VR_POINTER_CALIBRATION = $previousPointerCalibration
    }
    if ($null -eq $previousNativeWeaponDebugAxes) {
        Remove-Item Env:OPENMW_FNV_VR_NATIVE_WEAPON_DEBUG_AXES -ErrorAction SilentlyContinue
    } else {
        $env:OPENMW_FNV_VR_NATIVE_WEAPON_DEBUG_AXES = $previousNativeWeaponDebugAxes
    }
    if ($null -eq $previousNativeWeaponTelemetry) {
        Remove-Item Env:OPENMW_FNV_VR_NATIVE_WEAPON_TELEMETRY -ErrorAction SilentlyContinue
    } else {
        $env:OPENMW_FNV_VR_NATIVE_WEAPON_TELEMETRY = $previousNativeWeaponTelemetry
    }
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
$wheelFixtures = @([regex]::Matches($logText,
    'FNV VR weapon wheel fixture:.*centerError=(?<center>[-+0-9.eE]+).*planeDotNormalRight=(?<nr>[-+0-9.eE]+).*planeDotNormalUp=(?<nu>[-+0-9.eE]+).*planeDotRightUp=(?<ru>[-+0-9.eE]+).*maxRingRadiusError=(?<radius>[-+0-9.eE]+).*centered=1'))
$wheelFixtureMathPassed = $wheelFixtures.Count -ge 1
foreach ($fixture in $wheelFixtures) {
    $wheelFixtureMathPassed = $wheelFixtureMathPassed -and
        [math]::Abs([double]$fixture.Groups['center'].Value) -le 0.001 -and
        [math]::Abs([double]$fixture.Groups['nr'].Value) -le 0.001 -and
        [math]::Abs([double]$fixture.Groups['nu'].Value) -le 0.001 -and
        [math]::Abs([double]$fixture.Groups['ru'].Value) -le 0.001 -and
        [math]::Abs([double]$fixture.Groups['radius'].Value) -le 0.002
}
$requiredNativeModels = @(
    'meshes/weapons/1handpistol/9mm.nif',
    'meshes/weapons/1handmelee/rustyknife.nif',
    'meshes/weapons/2handrifle/varmintrifle.nif'
)
$nativeAttachmentPassed = $true
$nativeRigidPassed = $true
$nativeRenderPassed = $true
foreach ($model in $requiredNativeModels) {
    $escapedModel = [regex]::Escape($model)
    $nativeAttachmentPassed = $nativeAttachmentPassed -and
        $logText -match "OpenMW VR native weapon attachment bind: model=$escapedModel .*partParent=Weapon parentCount=1 modelAdapter=identity conversionCount=0 reparented=0 familyPoseSource=(?!first-person-skeleton-bind)\S+ status=pass"
    $nativeRigidPassed = $nativeRigidPassed -and
        $logText -match "OpenMW VR native weapon invariant:.*model=$escapedModel .*maxElementDelta=0(?:\.0+)? .*partInHandMaxDelta=0(?:\.0+)? .*rayInPartMaxDelta=0(?:\.0+)? .*renderedRayDot=1(?:\.0+)? .*parentCount=1 exactWeaponParent=1 .*callbackHead=1 competingWeaponKfWrites=0 writesThisFrame=1 .*status=pass"
    $nativeRenderPassed = $nativeRenderPassed -and
        $logText -match "OpenMW VR native weapon render invariant: model=$escapedModel .*drawables=[1-9]\d* .*authoredVisibleDrawables=[1-9]\d* .*texture2D=[1-9]\d* .*loadedTextureImages=[1-9]\d* .*invalidTextureImages=0 .*texturePassed=1 .*status=pass"
}
$nativeAttachmentPassed = $nativeAttachmentPassed -and
    $logText -notmatch 'OpenMW VR (?:native weapon attachment bind|native weapon invariant):.*status=fail' -and
    $logText -notmatch 'OpenMW VR Fallout native weapon attachment rejected' -and
    $logText -notmatch 'OpenMW VR native weapon family pose (?:fallback|load failed|rejected)' -and
    $logText -notmatch 'OpenMW VR native equipped weapon rejected'
$nativeRigidPassed = $nativeRigidPassed -and $nativeAttachmentPassed
$nativeRenderPassed = $nativeRenderPassed -and
    $logText -notmatch 'OpenMW VR native weapon render invariant:.*status=fail'
$nativeRayPassed =
    @([regex]::Matches($logText, 'OpenMW VR production ray ownership: origin=ProjectileNode direction=ProjectileNode\+Z-via-child\+Y parentPaths=1')).Count -ge 2 -and
    $logText -match 'OpenMW VR production ray ownership: origin=native-model direction=model\+Y parentPaths=1' -and
    $logText -notmatch 'FNV VR weapon ray fallback:'
$nativeDebugAxesPassed = -not $WeaponWheel -or
    @([regex]::Matches($logText, 'OpenMW VR native weapon debug axes: enabled=1 model=')).Count -ge 3
$aimFixtureMathPassed = $nativeRayPassed -and $nativeRigidPassed
$gripFixtureMathPassed = $nativeAttachmentPassed -and $nativeRigidPassed
$assertions = [ordered]@{
    handControllerProjectionCentered = $framingMathPassed
    leftHandVisibleInNativeEye = $framingLeftVisualDelta -ge 0.35
    rightHandVisibleInNativeEye = $framingRightVisualDelta -ge 0.35
    trackedRigReady = $logText -match 'OpenMW VR player rig status=ready'
    livePipBoyScreenBound = $logText -match 'FNV Pip-Boy VR physical: screenBinding=ready'
    pipBoyStatusButtonRayPassed = $logText -match 'FNV Pip-Boy physical ray click: control=PipBoyButton01 .*handled=1 pane=3'
    pipBoyItemsButtonRayPassed = $logText -match 'FNV Pip-Boy physical ray click: control=PipBoyButton02 .*handled=1 pane=1'
    pipBoyDataButtonRayPassed = $logText -match 'FNV Pip-Boy physical ray click: control=PipBoyButton03 .*handled=1 pane=2'
    pipBoyTabKnobRayPassed = $logText -match 'FNV Pip-Boy physical ray click: control=TabKnob .*handled=1 pane=0'
    pipBoyScrollKnobRayPassed = $logText -match 'FNV Pip-Boy physical ray click: control=ScrollKnob .*handled=1 pane=0'
    weaponWheelCentered = if ($WeaponWheel) { $wheelFixtureMathPassed } else { $true }
    knifeSelectedByWheel = if ($WeaponWheel) {
        $logText -match 'FNV VR weapon wheel: selected=.*editor=WeapKnife interaction=direct-grab'
    } else { $true }
    rifleSelectedByWheel = if ($WeaponWheel) {
        $logText -match 'FNV VR weapon wheel: selected=.*editor=WeapNVVarmintRifle interaction=direct-grab'
    } else { $true }
    pistolSelectedByWheel = if ($WeaponWheel) {
        $logText -match 'FNV VR weapon wheel: selected=.*editor=WeapNV9mmPistol interaction=direct-grab'
    } else { $true }
    weaponAimFixturesPassed = $aimFixtureMathPassed
    weaponGripFixturesPassed = $gripFixtureMathPassed
    nativeAttachmentRigidPassed = $nativeAttachmentPassed -and $nativeRigidPassed
    weaponTexturesPassed = $nativeRenderPassed
    weaponVisibilityPassed = $nativeRenderPassed
    actualProjectileRayPassed = $nativeRayPassed
    nativeWeaponDebugAxesPassed = $nativeDebugAxesPassed
    knifeSelectedByPointer = if (-not $WeaponWheel) {
        $logText -match 'FNV Pip-Boy pointer: control=inventory-row visibleRow=1 cursor=\(142,347\)' -and
            $logText -match 'FNV Pip-Boy selection:.*result="EQUIPPED Knife"'
    } else { $true }
    rifleSelectedByPointer = if (-not $WeaponWheel) {
        $logText -match 'FNV Pip-Boy pointer: control=inventory-row visibleRow=2 cursor=\(178,414\)' -and
            $logText -match 'FNV Pip-Boy selection:.*result="EQUIPPED Varmint Rifle"'
    } else { $true }
    pistolSelectedByPointer = if (-not $WeaponWheel) {
        $logText -match 'FNV Pip-Boy pointer: control=inventory-row visibleRow=0 cursor=\(126,315\)' -and
            $logText -match 'FNV Pip-Boy selection:.*result="EQUIPPED 9mm Pistol"'
    } else { $true }
    pistolSocketForward = $logText -match 'OpenMW VR native equipped weapon: editor=WeapNV9mmPistol model=meshes/weapons/1handpistol/9mm\.nif attach=Weapon .*boundIdentity=1 duplicateSurface=0'
    knifeSocketForward = $logText -match 'OpenMW VR native equipped weapon: editor=WeapKnife model=meshes/weapons/1handmelee/rustyknife\.nif attach=Weapon .*boundIdentity=1 duplicateSurface=0'
    rifleSocketForward = $logText -match 'OpenMW VR native equipped weapon: editor=WeapNVVarmintRifle model=meshes/weapons/2handrifle/varmintrifle\.nif attach=Weapon .*boundIdentity=1 duplicateSurface=0'
    pistolReloadPassed = $logText -match 'FNV reload:.*weapon=FormId:0x10e3778.*status=pass'
    rifleReloadPassed = $logText -match 'FNV reload:.*weapon=FormId:0x107ea24.*status=pass'
    pistolShotPassed = $logText -match 'FNV combat shot:.*weapon=FormId:0x10e3778.*originSource=vr-weapon-ProjectileNode.*status=pass'
    rifleShotPassed = $logText -match 'FNV combat shot:.*weapon=FormId:0x107ea24.*originSource=vr-weapon-ProjectileNode.*status=pass'
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
    -vf 'crop=1120:700:80:700,scale=960:600:flags=lanczos,format=yuv420p' `
    -c:v libx264 -preset medium -crf 18 -movflags +faststart `
    $videoPath
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $videoPath -PathType Leaf)) {
    throw "ffmpeg did not produce the OpenMW VR motion proof video."
}

& $ffmpeg.Source `
    -hide_banner -loglevel error -y `
    -framerate $FrameRate -start_number 1 `
    -i (Join-Path $nativeFrameRoot 'frame-%04d.bmp') `
    -vf 'crop=720:700:400:700,scale=720:700:flags=lanczos,format=yuv420p' `
    -c:v libx264 -preset medium -crf 18 -movflags +faststart `
    $weaponCloseupVideoPath
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $weaponCloseupVideoPath -PathType Leaf)) {
    throw "ffmpeg did not produce the OpenMW VR weapon-hand close-up proof video."
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

$manifestFrameIndex = 0
$frameEntries = @($nativeFrames | ForEach-Object {
    $capture = $script:NativeFrameTelemetry[$manifestFrameIndex]
    $manifestFrameIndex++
    [pscustomobject][ordered]@{
        captureIndex = $capture.captureIndex
        simulatorFrame = $capture.simulatorFrame
        capturedAtUtc = $capture.capturedAtUtc
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

$artifacts = @($videoPath, $weaponCloseupVideoPath, $contactSheetPath, $pipBoyRtt, $openMwLog, $frameManifestPath,
    $framingHiddenPath, $framingLeftPath, $framingRightPath, $framingBothPath) |
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
    [int]$videoStream.width -eq 960 -and
    [int]$videoStream.height -eq 600

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
        weaponCloseupVideoPath = $weaponCloseupVideoPath
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
