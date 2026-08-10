[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$BinaryRoot = "D:\code\nikami-worlds\local\openmw-ttw-compat",
    [string]$TtwRoot = "D:\Modlists\fnv\mods\Tale of Two Wastelands - OpenMW",
    [string]$Fallout3Data = "D:\SteamLibrary\steamapps\common\Fallout 3 goty\Data",
    [string]$FalloutNewVegasData = "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data",
    [ValidateSet("TTW", "NewVegas")]
    [string]$Campaign = "TTW",
    [string]$ExpectedVideoAsset = "",
    [string]$AudioDevice = "Stereo Mix (Realtek(R) Audio)",
    [ValidateRange(5, 120)]
    [int]$VideoSeconds = 20,
    [ValidateRange(3, 180)]
    [int]$SceneSeconds = 8,
    # Drives an authored message box through the engine's own default-button
    # callback. This is capture-only automation, never desktop input.
    [ValidateRange(0, 60)]
    [double]$DefaultChoiceDelaySeconds = 1,
    [ValidateRange(100, 5000)]
    [int]$CaptureLeadMilliseconds = 750,
    # Engine-native frame sampling backs visual proof when Windows cannot read
    # an OpenGL-composed window through GDI. It remains input-free and writes
    # only into this disposable capture profile before the runner copies the
    # retained source frames into its unique evidence directory.
    [ValidateRange(50, 1000)]
    [int]$NativeFrameIntervalMilliseconds = 250,
    [ValidateRange(30, 300)]
    [int]$TimeoutSeconds = 90,
    # Optional engine-internal, manifest-declared route to reach a named
    # authored scene checkpoint while the normal opening capture is running.
    # This is deliberately not desktop input or a campaign-specific script.
    [string]$AuthoredRoutePath = "",
    [string]$OutputRoot = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Quote-OpenNVArgument {
    param([Parameter(Mandatory=$true)][string]$Argument)

    if ($Argument -match '[\s"]') {
        return '"' + ($Argument -replace '"', '\"') + '"'
    }
    return $Argument
}

function Wait-ForCaptureFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory=$true)][DateTime]$Deadline,
        [Parameter(Mandatory=$true)][string]$Description
    )

    while ([DateTime]::UtcNow -lt $Deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return
        }
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "OpenNV exited before it created the $Description."
        }
        Start-Sleep -Milliseconds 50
    }
    throw "Timed out waiting for OpenNV to create the $Description."
}

function Wait-ForNativePostVideoFrames {
    param(
        [Parameter(Mandatory=$true)][string]$LogPath,
        [Parameter(Mandatory=$true)][string]$FrameDirectory,
        [Parameter(Mandatory=$true)][string]$ExpectedVideoAsset,
        [Parameter(Mandatory=$true)][int]$SceneSeconds,
        [Parameter(Mandatory=$true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory=$true)][DateTime]$Deadline
    )

    # Screen capture is deliberately asynchronous.  Do not terminate the
    # owned engine merely because the exact-title recorder reached its end:
    # the PNG worker may still be writing the post-video frames that prove the
    # authored hand-off rendered correctly.
    # Match the visual gate: after the engine has attested completion, eight
    # actually-persisted post-video frames are sufficient to analyze the whole
    # retained sequence without using elapsed wall-clock time as fake evidence.
    $minimumSceneFrames = 8
    $videoFrameCount = 0
    $frameCount = 0
    $emptyFrameCount = 0
    $completed = $false
    $stableReadyPolls = 0
    $previousReadyFrameSignature = $null
    while ([DateTime]::UtcNow -lt $Deadline) {
        if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
            $logText = Get-Content -LiteralPath $LogPath -Raw
            $match = [regex]::Match(
                $logText,
                'OpenNV capture: queued native source frames asset="' +
                    [regex]::Escape($ExpectedVideoAsset) +
                    '" count=(?<count>\d+) intervalMilliseconds=\d+')
            if ($match.Success) {
                $videoFrameCount = [int]$match.Groups['count'].Value
            }
            $completed = $logText -match [regex]::Escape(
                'OpenNV capture: post-video native scene frames complete')
        }
        if (Test-Path -LiteralPath $FrameDirectory -PathType Container) {
            $frameFiles = @(
                Get-ChildItem -LiteralPath $FrameDirectory -File |
                    Where-Object { $_.Extension -in @('.jpg', '.jpeg', '.png') }
            )
            $frameCount = $frameFiles.Count
            $emptyFrameCount = @($frameFiles | Where-Object { $_.Length -le 0 }).Count
            # A screenshot file appears before its asynchronous PNG write has
            # completed.  Require a stable non-empty file set across several
            # polls rather than accepting a mere directory entry and then
            # terminating the writer underneath it.
            $frameSignature = @($frameFiles |
                Sort-Object Name |
                ForEach-Object { "$($_.Name):$($_.Length):$($_.LastWriteTimeUtc.Ticks)" }) -join '|'
        }
        else {
            $frameSignature = ''
        }
        if ($completed -and $videoFrameCount -gt 0 -and
            $frameCount -ge ($videoFrameCount + $minimumSceneFrames) -and $emptyFrameCount -eq 0) {
            if ($frameSignature -eq $previousReadyFrameSignature) {
                ++$stableReadyPolls
            }
            else {
                $previousReadyFrameSignature = $frameSignature
                $stableReadyPolls = 1
            }
            if ($stableReadyPolls -ge 3) {
                return [ordered]@{
                    completed = $true
                    timedOut = $false
                    videoFrameCount = $videoFrameCount
                    requiredSceneFrames = $minimumSceneFrames
                    savedFrameCount = $frameCount
                    emptyFrameCount = $emptyFrameCount
                    stableReadyPolls = $stableReadyPolls
                }
            }
        }
        else {
            $stableReadyPolls = 0
            $previousReadyFrameSignature = $null
        }
        $Process.Refresh()
        if ($Process.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 100
    }
    return [ordered]@{
        completed = $false
        timedOut = $true
        videoFrameCount = $videoFrameCount
        requiredSceneFrames = $minimumSceneFrames
        savedFrameCount = $frameCount
        emptyFrameCount = $emptyFrameCount
        stableReadyPolls = $stableReadyPolls
    }
}

function Get-DirectShowDeviceText {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        return ((& ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1) | Out-String)
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Save-AsyncProcessStreams {
    param(
        [Parameter(Mandatory=$true)][System.Threading.Tasks.Task[string]]$StandardOutputTask,
        [Parameter(Mandatory=$true)][System.Threading.Tasks.Task[string]]$StandardErrorTask,
        [Parameter(Mandatory=$true)][string]$StandardOutputPath,
        [Parameter(Mandatory=$true)][string]$StandardErrorPath
    )

    $stdout = $StandardOutputTask.GetAwaiter().GetResult()
    $stderr = $StandardErrorTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText($StandardOutputPath, $stdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($StandardErrorPath, $stderr, [Text.UTF8Encoding]::new($false))
}

function Get-Artifact {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

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

function Get-VideoVisualEvidence {
    param([Parameter(Mandatory=$true)][string]$Path)

    # A syntactically valid gdigrab MP4 can still consist of a frozen or black
    # surface when the target window was minimized. Sample the retained native
    # title capture at one frame per second, after normalising it to a compact
    # grayscale image, so codec metadata cannot turn a blank recording into a
    # passing proof.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $frameMd5Lines = @(
            & ffmpeg -hide_banner -loglevel error -i $Path -an `
                -vf "fps=1,scale=64:36:flags=area,format=gray" -f framemd5 - 2>$null
        )
        $frameMd5ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($frameMd5ExitCode -ne 0) {
        throw "Unable to sample visual frames from the retained opening video (ffmpeg exit code $frameMd5ExitCode)."
    }

    $hashes = [Collections.Generic.List[string]]::new()
    foreach ($line in $frameMd5Lines) {
        $match = [regex]::Match(
            [string]$line,
            '^\s*\d+,\s*-?\d+,\s*-?\d+,\s*\d+,\s*\d+,\s*(?<hash>[0-9a-fA-F]{32})\s*$')
        if ($match.Success) {
            $hashes.Add($match.Groups["hash"].Value.ToLowerInvariant())
        }
    }
    $uniqueHashes = @($hashes | Sort-Object -Unique)
    $hasChangingVisibleFrames = $hashes.Count -ge 5 -and $uniqueHashes.Count -ge 5
    return [ordered]@{
        sampleMethod = "ffmpeg framemd5 at 1 fps after 64x36 grayscale normalisation"
        sampledFrameCount = $hashes.Count
        uniqueFrameHashes = $uniqueHashes.Count
        firstSampleHash = if ($hashes.Count -gt 0) { $hashes[0] } else { $null }
        lastSampleHash = if ($hashes.Count -gt 0) { $hashes[$hashes.Count - 1] } else { $null }
        changingVisibleFrames = $hasChangingVisibleFrames
    }
}

function Get-NativeSourceFrameNumber {
    param([Parameter(Mandatory=$true)][System.IO.FileInfo]$File)

    $match = [regex]::Match($File.BaseName, '^screenshot(?<number>\d+)$')
    if (-not $match.Success) {
        return -1
    }
    return [int]$match.Groups["number"].Value
}

function Get-NativeSceneFrameHealth {
    param(
        [Parameter(Mandatory=$true)][System.IO.FileInfo[]]$Frames,
        [Parameter(Mandatory=$true)][int]$FirstFrameNumber,
        [Parameter(Mandatory=$true)][int]$VideoNativeFrameCount,
        [Parameter(Mandatory=$true)][int]$SceneSeconds,
        # A scripted image-space transition is only tolerated when the engine
        # telemetry attests one and the retained native frames subsequently
        # recover to a sustained healthy scene.  This never hides a persistent
        # black, brown, magenta, or monochrome room.
        [bool]$AuthoredInitialFadeObserved = $false,
        # A later, source-attested Fade* IMAD can legitimately bridge two
        # authored opening segments. Each entry is a frame-count ceiling
        # derived from that modifier's declared duration.
        [int[]]$AuthoredTransientFadeMaximumFrameCounts = @(),
        # The engine writes this only after its wall-clock post-video capture
        # window ends. PNG encoding can make a few requested samples miss the
        # nominal one-per-second cadence, so an attested completion permits a
        # narrow retained-frame tolerance while all visual fault checks remain
        # fail-closed.
        [bool]$PostVideoNativeSceneFramesCompleted = $false
    )

    # The exact-title recorder is retained for transport/audibility, but the
    # engine-native screenshots are the visual authority. Sample the post-video
    # part of that sequence directly and fail closed on the known invalid
    # surfaces (brown void, magenta missing assets, black, or monochrome room).
    # The boundary must come from the engine's queued-video-frame telemetry,
    # not an idealized timer calculation: screenshot encoding can make the
    # observed cadence slower than the requested capture interval.
    if ($VideoNativeFrameCount -lt 1) {
        return [ordered]@{
            sampleMethod = "32x18 RGB grid over retained native post-video frames"
            boundarySource = "OpenNV queued native video frame telemetry"
            videoNativeFrameCount = $VideoNativeFrameCount
            sceneStartFrameNumber = $null
            sampledFrameCount = 0
            requiredMinimumFrameCount = [Math]::Max(8, [int][Math]::Ceiling($SceneSeconds))
            passed = $false
            reason = "missing-native-video-frame-boundary-telemetry"
            badFrameCount = 0
            badFrames = @()
        }
    }
    # A compact grid is intentional: a full-frame failure is detectable without
    # making proof capture dependent on an external image-processing install.
    $sceneStartFrameNumber = $FirstFrameNumber + $VideoNativeFrameCount
    $sceneFrames = @($Frames | Where-Object {
        (Get-NativeSourceFrameNumber -File $_) -ge $sceneStartFrameNumber
    })
    # The engine attests completion of the requested scene duration.  A modal
    # authored transition can legitimately defer its first capture callback,
    # so frame count must not be derived from wall-clock duration.  Require a
    # hard minimum of eight persisted frames and inspect every retained frame;
    # that preserves fail-closed visual checking without rejecting a completed
    # capture merely because the async screenshot queue missed a cadence.
    $minimumSceneFrameCount = 8
    $effectiveMinimumSceneFrameCount = if ($PostVideoNativeSceneFramesCompleted) {
        $minimumSceneFrameCount
    } else {
        [Math]::Max($minimumSceneFrameCount, [int][Math]::Ceiling($SceneSeconds))
    }
    if ($sceneFrames.Count -lt $effectiveMinimumSceneFrameCount) {
        return [ordered]@{
            sampleMethod = "32x18 RGB grid over retained native post-video frames"
            boundarySource = "OpenNV queued native video frame telemetry"
            videoNativeFrameCount = $VideoNativeFrameCount
            sceneStartFrameNumber = $sceneStartFrameNumber
            sampledFrameCount = $sceneFrames.Count
            requiredMinimumFrameCount = $minimumSceneFrameCount
            effectiveMinimumFrameCount = $effectiveMinimumSceneFrameCount
            postVideoNativeSceneFramesCompleted = $PostVideoNativeSceneFramesCompleted
            passed = $false
            reason = "insufficient-post-video-native-frames"
            badFrameCount = 0
            badFrames = @()
        }
    }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    }
    catch {
        return [ordered]@{
            sampleMethod = "32x18 RGB grid over retained native post-video frames"
            boundarySource = "OpenNV queued native video frame telemetry"
            videoNativeFrameCount = $VideoNativeFrameCount
            sceneStartFrameNumber = $sceneStartFrameNumber
            sampledFrameCount = $sceneFrames.Count
            requiredMinimumFrameCount = $minimumSceneFrameCount
            passed = $false
            reason = "native-frame-health-analyzer-unavailable"
            analyzerError = $_.Exception.Message
            badFrameCount = 0
            badFrames = @()
        }
    }

    $sampleWidth = 32
    $sampleHeight = 18
    $sampleCount = $sampleWidth * $sampleHeight
    $badFrames = [System.Collections.Generic.List[object]]::new()
    $decodeFailures = [System.Collections.Generic.List[object]]::new()
    $frameFaultStates = [System.Collections.Generic.List[object]]::new()

    foreach ($frame in $sceneFrames) {
        $bitmap = $null
        try {
            $bitmap = [System.Drawing.Bitmap]::new($frame.FullName)
            $redSum = 0.0
            $greenSum = 0.0
            $blueSum = 0.0
            $lumaSum = 0.0
            $lumaSquareSum = 0.0
            $blackPixels = 0
            $magentaPixels = 0
            $brownPixels = 0
            $monochromePixels = 0

            for ($sampleY = 0; $sampleY -lt $sampleHeight; ++$sampleY) {
                $pixelY = [Math]::Min($bitmap.Height - 1, [int](($sampleY + 0.5) * $bitmap.Height / $sampleHeight))
                for ($sampleX = 0; $sampleX -lt $sampleWidth; ++$sampleX) {
                    $pixelX = [Math]::Min($bitmap.Width - 1, [int](($sampleX + 0.5) * $bitmap.Width / $sampleWidth))
                    $pixel = $bitmap.GetPixel($pixelX, $pixelY)
                    $red = [double]$pixel.R
                    $green = [double]$pixel.G
                    $blue = [double]$pixel.B
                    $luma = (0.2126 * $red) + (0.7152 * $green) + (0.0722 * $blue)
                    $redSum += $red
                    $greenSum += $green
                    $blueSum += $blue
                    $lumaSum += $luma
                    $lumaSquareSum += ($luma * $luma)

                    if ([Math]::Max($red, [Math]::Max($green, $blue)) -lt 12) { ++$blackPixels }
                    if ($red -gt 180 -and $blue -gt 120 -and $green -lt 140) { ++$magentaPixels }
                    if ($red -ge 30 -and $red -le 140 -and $green -ge 20 -and $green -le 110 -and
                        $blue -le 80 -and ($red - $green) -ge 5 -and ($green - $blue) -ge 5) {
                        ++$brownPixels
                    }
                    if (([Math]::Max($red, [Math]::Max($green, $blue)) - [Math]::Min($red, [Math]::Min($green, $blue))) -le 8) {
                        ++$monochromePixels
                    }
                }
            }

            $meanRed = $redSum / $sampleCount
            $meanGreen = $greenSum / $sampleCount
            $meanBlue = $blueSum / $sampleCount
            $meanLuma = $lumaSum / $sampleCount
            $lumaStandardDeviation = [Math]::Sqrt([Math]::Max(0.0, ($lumaSquareSum / $sampleCount) - ($meanLuma * $meanLuma)))
            $blackRatio = $blackPixels / $sampleCount
            $magentaRatio = $magentaPixels / $sampleCount
            $brownRatio = $brownPixels / $sampleCount
            $monochromeRatio = $monochromePixels / $sampleCount
            $faults = [System.Collections.Generic.List[string]]::new()
            if ($blackRatio -ge 0.98 -and $meanLuma -lt 12.0) { $faults.Add("black") }
            if ($magentaRatio -ge 0.95) { $faults.Add("magenta") }
            if ($brownRatio -ge 0.95 -and $lumaStandardDeviation -le 15.0) { $faults.Add("brown") }
            if ($monochromeRatio -ge 0.98) { $faults.Add("monochrome") }
            if ($lumaStandardDeviation -le 1.0) { $faults.Add("flat-color") }

            if ($faults.Count -gt 0) {
                $badFrames.Add([ordered]@{
                    file = $frame.Name
                    frameNumber = Get-NativeSourceFrameNumber -File $frame
                    faults = @($faults.ToArray())
                    meanRgb = @(
                        [Math]::Round($meanRed, 2),
                        [Math]::Round($meanGreen, 2),
                        [Math]::Round($meanBlue, 2))
                    lumaStandardDeviation = [Math]::Round($lumaStandardDeviation, 2)
                    blackRatio = [Math]::Round($blackRatio, 4)
                    magentaRatio = [Math]::Round($magentaRatio, 4)
                    brownRatio = [Math]::Round($brownRatio, 4)
                    monochromeRatio = [Math]::Round($monochromeRatio, 4)
                })
            }
            $frameFaultStates.Add([ordered]@{
                frameNumber = Get-NativeSourceFrameNumber -File $frame
                bad = ($faults.Count -gt 0)
            })
        }
        catch {
            $decodeFailures.Add([ordered]@{
                file = $frame.Name
                frameNumber = Get-NativeSourceFrameNumber -File $frame
                error = $_.Exception.Message
            })
        }
        finally {
            if ($null -ne $bitmap) { $bitmap.Dispose() }
        }
    }

    # Treat source-attested image-space fades as transitions only when they
    # are bounded, recover to healthy frames, and contain no magenta or brown
    # missing-content surface. A persistent black/white room still fails.
    $badFramesByNumber = @{}
    foreach ($badFrame in $badFrames) {
        $badFramesByNumber[[int]$badFrame.frameNumber] = $badFrame
    }
    $leadingBadFrameCount = 0
    $badFramesAfterRecovery = 0
    $recoveredToHealthyFrame = $false
    $lateBadSegments = [System.Collections.Generic.List[object]]::new()
    $currentLateBadSegment = $null
    foreach ($frameState in $frameFaultStates) {
        if (-not [bool]$frameState.bad) {
            if ($null -ne $currentLateBadSegment) {
                $currentLateBadSegment.endedInHealthyFrame = $true
                $lateBadSegments.Add($currentLateBadSegment)
                $currentLateBadSegment = $null
            }
            $recoveredToHealthyFrame = $true
            continue
        }
        if ($recoveredToHealthyFrame) {
            ++$badFramesAfterRecovery
            $frameNumber = [int]$frameState.frameNumber
            if ($null -eq $currentLateBadSegment) {
                $currentLateBadSegment = [pscustomobject]@{
                    startFrameNumber = $frameNumber
                    endFrameNumber = $frameNumber
                    frameCount = 0
                    faults = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    endedInHealthyFrame = $false
                }
            }
            $currentLateBadSegment.endFrameNumber = $frameNumber
            ++$currentLateBadSegment.frameCount
            foreach ($fault in @($badFramesByNumber[$frameNumber].faults)) {
                [void]$currentLateBadSegment.faults.Add([string]$fault)
            }
        }
        else {
            ++$leadingBadFrameCount
        }
    }
    if ($null -ne $currentLateBadSegment) {
        $lateBadSegments.Add($currentLateBadSegment)
    }
    $verifiedHealthyFrameCount = $frameFaultStates.Count - $badFrames.Count
    $requiredRecoveredHealthyFrameCount = [Math]::Max(8, [int][Math]::Ceiling($SceneSeconds * 0.5))
    $maximumInitialTransientBadFrameCount = [Math]::Max(8, [int][Math]::Floor($sceneFrames.Count * 0.35))
    $recoveredAuthoredInitialFade = $AuthoredInitialFadeObserved -and $leadingBadFrameCount -gt 0 -and
        $leadingBadFrameCount -le $maximumInitialTransientBadFrameCount -and
        $verifiedHealthyFrameCount -ge $requiredRecoveredHealthyFrameCount
    $initialFaultsAccepted = $leadingBadFrameCount -eq 0 -or $recoveredAuthoredInitialFade

    $recoveredAuthoredTransientFades = $true
    if ($lateBadSegments.Count -gt $AuthoredTransientFadeMaximumFrameCounts.Count) {
        $recoveredAuthoredTransientFades = $false
    }
    else {
        for ($index = 0; $index -lt $lateBadSegments.Count; ++$index) {
            $segment = $lateBadSegments[$index]
            $allowedFaults = @($segment.faults | Where-Object { $_ -in @('black', 'monochrome', 'flat-color') })
            if ($segment.frameCount -gt $AuthoredTransientFadeMaximumFrameCounts[$index] -or
                -not $segment.endedInHealthyFrame -or $allowedFaults.Count -ne $segment.faults.Count) {
                $recoveredAuthoredTransientFades = $false
                break
            }
        }
    }
    $recoveredAuthoredFades = $initialFaultsAccepted -and $recoveredAuthoredTransientFades -and
        $verifiedHealthyFrameCount -ge $requiredRecoveredHealthyFrameCount
    $passed = $decodeFailures.Count -eq 0 -and ($badFrames.Count -eq 0 -or $recoveredAuthoredFades)

    return [ordered]@{
        sampleMethod = "32x18 RGB grid over retained native post-video frames"
        boundarySource = "OpenNV queued native video frame telemetry"
        videoNativeFrameCount = $VideoNativeFrameCount
        sceneStartFrameNumber = $sceneStartFrameNumber
        sampledFrameCount = $sceneFrames.Count
        requiredMinimumFrameCount = $minimumSceneFrameCount
        effectiveMinimumFrameCount = $effectiveMinimumSceneFrameCount
        postVideoNativeSceneFramesCompleted = $PostVideoNativeSceneFramesCompleted
        passed = $passed
        reason = if ($decodeFailures.Count -gt 0) { "native-scene-frame-decode-failed" } elseif ($badFrames.Count -eq 0) { "ok" } elseif ($recoveredAuthoredFades) { "authored-transient-fades-recovered" } else { "invalid-scene-frame-detected" }
        authoredInitialFadeObserved = $AuthoredInitialFadeObserved
        authoredTransientFadeMaximumFrameCounts = @($AuthoredTransientFadeMaximumFrameCounts)
        initialTransientBadFrameCount = $leadingBadFrameCount
        maximumInitialTransientBadFrameCount = $maximumInitialTransientBadFrameCount
        badFramesAfterRecovery = $badFramesAfterRecovery
        verifiedHealthyFrameCount = $verifiedHealthyFrameCount
        requiredRecoveredHealthyFrameCount = $requiredRecoveredHealthyFrameCount
        recoveredAuthoredInitialFade = $recoveredAuthoredInitialFade
        recoveredAuthoredTransientFades = $recoveredAuthoredTransientFades
        recoveredAuthoredFades = $recoveredAuthoredFades
        transientFadeSegments = @($lateBadSegments | ForEach-Object {
            [ordered]@{
                startFrameNumber = $_.startFrameNumber
                endFrameNumber = $_.endFrameNumber
                frameCount = $_.frameCount
                faults = @($_.faults | Sort-Object)
                endedInHealthyFrame = $_.endedInHealthyFrame
            }
        })
        badFrameCount = $badFrames.Count
        badFrames = @($badFrames.ToArray())
        decodeFailureCount = $decodeFailures.Count
        decodeFailures = @($decodeFailures.ToArray())
    }
}

function Set-CaptureProfileSetting {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Section,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Value
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
        $updated = $false
        for ($index = $sectionStart + 1; $index -lt $sectionEnd; ++$index) {
            if ($lines[$index] -match $keyPattern) {
                $lines[$index] = "$Key = $Value"
                $updated = $true
                break
            }
        }
        if (-not $updated) {
            $lines.Insert($sectionEnd, "$Key = $Value")
        }
    }

    [IO.File]::WriteAllText(
        $Path,
        (($lines -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false))
}

function Assert-OpenNVTtwLayerContract {
    param(
        [Parameter(Mandatory=$true)][string]$ProfileManifestPath,
        [Parameter(Mandatory=$true)][string]$OpenMwConfigPath
    )

    if (-not (Test-Path -LiteralPath $ProfileManifestPath -PathType Leaf)) {
        throw "The generated TTW profile manifest is missing: $ProfileManifestPath"
    }
    $manifest = Get-Content -LiteralPath $ProfileManifestPath -Raw | ConvertFrom-Json
    if ([string]$manifest.schema -ne "nikami-ttw-compatibility-profile/v1") {
        throw "The generated TTW profile manifest has an unsupported schema: $($manifest.schema)"
    }
    if ([string]$manifest.dataLayerPolicy.order -ne "low-to-high precedence") {
        throw "The generated TTW profile does not declare the required low-to-high layer order."
    }

    $layers = @($manifest.dataLayers | Sort-Object { [int]$_.priority })
    if ($layers.Count -lt 4) {
        throw "The generated TTW profile has too few data layers: $($layers.Count)"
    }
    $lastLayer = $layers[$layers.Count - 1]
    if ([string]$lastLayer.id -ne "ttw-generated-overlay") {
        throw "The TTW generated overlay must be the highest-priority layer for this no-JAM opening capture; found '$($lastLayer.id)'."
    }

    $configDataRoots = @(
        Get-Content -LiteralPath $OpenMwConfigPath |
            Where-Object { $_ -match '^data=' } |
            ForEach-Object { $_.Substring(5) }
    )
    $manifestDataRoots = @($layers | ForEach-Object { [string]$_.path })
    $normalisePath = {
        param([string]$Path)
        $normalised = ([IO.Path]::GetFullPath($Path) -replace '\\', '/')
        return $normalised.TrimEnd([char[]]@('/')).ToLowerInvariant()
    }
    $configMatchesManifest = $configDataRoots.Count -eq $manifestDataRoots.Count
    if ($configMatchesManifest) {
        for ($index = 0; $index -lt $configDataRoots.Count; ++$index) {
            if ((& $normalisePath $configDataRoots[$index]) -ne (& $normalisePath $manifestDataRoots[$index])) {
                $configMatchesManifest = $false
                break
            }
        }
    }
    if (-not $configMatchesManifest) {
        throw "The generated openmw.cfg data= order does not match the declared TTW compatibility layers."
    }

    $assets = @($manifest.resolvedLayeredAssets)
    $missingAssets = @($assets | Where-Object {
        -not (Test-Path -LiteralPath ([string]$_.providerPath) -PathType Leaf)
    })
    if ($missingAssets.Count -gt 0) {
        throw "The TTW layer contract has missing resolved assets: $($missingAssets.id -join ', ')."
    }
    $wrongOverlayAssets = @($assets | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.expectedProviderLayerId) -and
        [string]$_.providerLayerId -ne [string]$_.expectedProviderLayerId
    })
    if ($wrongOverlayAssets.Count -gt 0) {
        throw "The TTW layer contract resolved an authored asset from the wrong provider: $($wrongOverlayAssets.id -join ', ')."
    }

    return [pscustomobject][ordered]@{
        schema = [string]$manifest.schema
        dataLayerIds = @($layers | ForEach-Object { [string]$_.id })
        dataLayerPaths = @($manifestDataRoots)
        resolvedAssetCount = $assets.Count
        ttwOwnedAssetCount = @($assets | Where-Object {
            [string]$_.expectedProviderLayerId -eq "ttw-generated-overlay"
        }).Count
        baseFallbackAssetCount = @($assets | Where-Object {
            [string]::IsNullOrWhiteSpace([string]$_.expectedProviderLayerId)
        }).Count
        configMatchesManifest = $configMatchesManifest
    }
}

function Restore-Environment {
    param([Parameter(Mandatory=$true)][hashtable]$Values)

    foreach ($entry in $Values.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
    }
}

function Save-And-ClearOpenNVTestEnvironment {
    $previous = @{}
    $keys = @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })
    foreach ($name in $keys) {
        if ($name.StartsWith("OPENMW_WORLD_VIEWER_", [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith("OPENMW_PROOF_", [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith("OPENMW_FNV_", [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith("OPENMW_PLAYABLE_SESSION_", [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith("OPENMW_COMPAT_TELEMETRY_", [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith("OPENMW_COMPAT_ROUTE_", [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith("OPENMW_CAPTURE_VIDEO_", [StringComparison]::OrdinalIgnoreCase) -or
            $name.Equals("OPENMW_AUTHORED_START_TELEMETRY", [StringComparison]::OrdinalIgnoreCase) -or
            $name.Equals("OPENMW_AUTHORED_DEFAULT_CHOICE_DELAY_SECONDS", [StringComparison]::OrdinalIgnoreCase) -or
            $name.Equals("OPENMW_STARTUP_SCRIPT", [StringComparison]::OrdinalIgnoreCase) -or
            $name.Equals("OPENMW_DEBUG_LEVEL", [StringComparison]::OrdinalIgnoreCase)) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
    if (-not $previous.ContainsKey("OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG")) {
        $previous["OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG"] = [Environment]::GetEnvironmentVariable("OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG", $null, "Process")
    }
    return $previous
}

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$BinaryRoot = [IO.Path]::GetFullPath($BinaryRoot)
$TtwRoot = [IO.Path]::GetFullPath($TtwRoot)
$Fallout3Data = [IO.Path]::GetFullPath($Fallout3Data)
$FalloutNewVegasData = [IO.Path]::GetFullPath($FalloutNewVegasData)
if ([string]::IsNullOrWhiteSpace($ExpectedVideoAsset)) {
    $ExpectedVideoAsset = if ($Campaign -eq "TTW") { "Fallout INTRO Vsk.bik" } else { "FNVIntro.bik" }
}

$requiredDirectories = [Collections.Generic.List[string]]::new()
foreach ($requiredDirectory in @($WorldsRoot, $BinaryRoot, $FalloutNewVegasData)) {
    $requiredDirectories.Add($requiredDirectory)
}
if ($Campaign -eq "TTW") {
    $requiredDirectories.Add($TtwRoot)
    $requiredDirectories.Add($Fallout3Data)
}
foreach ($requiredDirectory in $requiredDirectories) {
    if (-not (Test-Path -LiteralPath $requiredDirectory -PathType Container)) {
        throw "Missing required opening-capture directory: $requiredDirectory"
    }
}

$binary = Join-Path $BinaryRoot "openmw.exe"
$resources = Join-Path $BinaryRoot "resources"
$initializer = Join-Path $WorldsRoot $(if ($Campaign -eq "TTW") {
    "scripts\Initialize-TTWCompatibilityProfile.ps1"
} else {
    "scripts\Initialize-OpenNVBaseProfile.ps1"
})
$videoAssetRoot = if ($Campaign -eq "TTW") { $TtwRoot } else { $FalloutNewVegasData }
$videoAssetPath = Join-Path (Join-Path $videoAssetRoot "Video") $ExpectedVideoAsset
foreach ($requiredFile in @($binary, $initializer, $videoAssetPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Missing required opening-capture file: $requiredFile"
    }
}
if (-not (Test-Path -LiteralPath $resources -PathType Container)) {
    throw "Missing deployed OpenNV resources: $resources"
}

$running = @(Get-Process -Name "openmw" -ErrorAction SilentlyContinue)
if ($running.Count -ne 0) {
    throw "Refusing to overlap opening capture with an existing OpenMW process: $($running.Id -join ', ')"
}

$deviceText = Get-DirectShowDeviceText
if ($deviceText -notmatch [regex]::Escape('"' + $AudioDevice + '" (audio)')) {
    throw "The requested DirectShow loopback device was not found: $AudioDevice"
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $campaignSlug = if ($Campaign -eq "TTW") { "ttw" } else { "newvegas" }
    $OutputRoot = Join-Path $WorldsRoot "run\opennv-$campaignSlug-opening-capture-$stamp"
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing opening-capture run: $OutputRoot"
}
$AuthoredRoutePath = if ([string]::IsNullOrWhiteSpace($AuthoredRoutePath)) {
    ""
} else {
    [IO.Path]::GetFullPath($AuthoredRoutePath)
}
if (-not [string]::IsNullOrWhiteSpace($AuthoredRoutePath) -and
    -not (Test-Path -LiteralPath $AuthoredRoutePath -PathType Leaf)) {
    throw "The declared authored route does not exist: $AuthoredRoutePath"
}

$stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$campaignSlug = if ($Campaign -eq "TTW") { "ttw" } else { "newvegas" }
$profileDirectory = Join-Path $WorldsRoot "profiles\_verification\$campaignSlug-opening-capture-$stamp"
$campaignUserdata = Join-Path $WorldsRoot "profiles\_verification\_campaigns\$campaignSlug-opening-capture-$stamp\userdata"
$signalsDirectory = Join-Path $OutputRoot "signals"
$readyPath = Join-Path $signalsDirectory "video-ready.txt"
$goPath = Join-Path $signalsDirectory "video-go.txt"
$stopPath = Join-Path $signalsDirectory "video-stop.txt"
$stdoutPath = Join-Path $OutputRoot "openmw.stdout.log"
$stderrPath = Join-Path $OutputRoot "openmw.stderr.log"
$captureStdoutPath = Join-Path $OutputRoot "ffmpeg.stdout.log"
$captureStderrPath = Join-Path $OutputRoot "ffmpeg.stderr.log"
$rawVideoPath = Join-Path $OutputRoot $(if ($Campaign -eq "TTW") {
    "OpenNV-TTW-authored-opening-raw-with-audio.mp4"
} else {
    "OpenNV-NewVegas-authored-opening-raw-with-audio.mp4"
})
$videoPath = Join-Path $OutputRoot $(if ($Campaign -eq "TTW") {
    "OpenNV-TTW-authored-opening-20s-plus-nursery-with-audio.mp4"
} elseif (-not [string]::IsNullOrWhiteSpace($AuthoredRoutePath)) {
    "OpenNV-NewVegas-authored-opening-20s-plus-doc-mitchell-vigor-with-audio.mp4"
} else {
    "OpenNV-NewVegas-authored-opening-20s-plus-doc-mitchell-with-audio.mp4"
})
$reportPath = Join-Path $OutputRoot "opening-capture-report.json"
$nativeSourceFramesDirectory = Join-Path $OutputRoot "native-source-frames"
$nativeSourceFramesManifestPath = Join-Path $OutputRoot "native-source-frames-manifest.json"
$authoredRouteReportPath = if ([string]::IsNullOrWhiteSpace($AuthoredRoutePath)) {
    ""
} else {
    Join-Path $OutputRoot "authored-route-report.json"
}

New-Item -ItemType Directory -Path $OutputRoot, $signalsDirectory | Out-Null

$profile = if ($Campaign -eq "TTW") {
    & $initializer `
        -TtwRoot $TtwRoot `
        -Fallout3Data $Fallout3Data `
        -FalloutNewVegasData $FalloutNewVegasData `
        -ProfileDirectory $profileDirectory `
        -CampaignUserdataDirectory $campaignUserdata `
        -BinaryRoot $BinaryRoot `
        -Force
} else {
    & $initializer `
        -FalloutNewVegasData $FalloutNewVegasData `
        -ProfileDirectory $profileDirectory `
        -CampaignUserdataDirectory $campaignUserdata `
        -BinaryRoot $BinaryRoot `
        -Force
}
if (-not [bool]$profile.launchable) {
    throw "The isolated $Campaign profile is not launchable: $($profile.installReasons -join '; ')"
}
$captureSettingsPath = Join-Path ([string]$profile.profileDirectory) "settings.cfg"
$captureSettingsText = Get-Content -LiteralPath $captureSettingsPath -Raw
Set-CaptureProfileSetting -Path $captureSettingsPath -Section "General" -Key "screenshot format" -Value "png"
Set-CaptureProfileSetting -Path $captureSettingsPath -Section "General" -Key "notify on saved screenshot" -Value "false"
$captureSettingsText = Get-Content -LiteralPath $captureSettingsPath -Raw
$captureWindowRemainsVisible = $captureSettingsText -match '(?im)^\s*minimize on focus loss\s*=\s*false\s*$'
if (-not $captureWindowRemainsVisible) {
    throw "The isolated $Campaign opening profile must set 'minimize on focus loss = false' for no-foreground exact-title capture."
}
$captureSourceFramesUsePng = $captureSettingsText -match '(?im)^\s*screenshot format\s*=\s*png\s*$'
if (-not $captureSourceFramesUsePng) {
    throw "The isolated $Campaign opening profile must use PNG native source frames."
}
$layerContract = if ($Campaign -eq "TTW") {
    Assert-OpenNVTtwLayerContract `
        -ProfileManifestPath ([string]$profile.manifestPath) `
        -OpenMwConfigPath ([string]$profile.openmwConfigPath)
} else {
    $null
}

$sourceArtifact = Get-Artifact $videoAssetPath
# Keep the exact-title recorder alive briefly after the requested presentation
# interval.  The engine's final native frame and completion attestation are
# emitted on the next update boundary; stopping precisely at the wall-clock
# deadline can terminate the owned process just before that boundary.  The
# presentation is still trimmed to VideoSeconds + SceneSeconds below.
$sceneCompletionGraceSeconds = 2
$captureSeconds = $VideoSeconds + $SceneSeconds + ([Math]::Ceiling($CaptureLeadMilliseconds / 1000.0)) + $sceneCompletionGraceSeconds
$nativeFrameSourceDirectory = Join-Path $campaignUserdata "screenshots"
$profileLogPath = Join-Path $profile.profileDirectory "openmw.log"
$startedAt = [DateTime]::UtcNow
$previousEnvironment = Save-And-ClearOpenNVTestEnvironment
$game = $null
$ffmpeg = $null
$ffmpegStdoutTask = $null
$ffmpegStderrTask = $null
$ffmpegStreamsPersisted = $false
$ffmpegExitCode = $null
$gateOpenedAt = $null
$gameTermination = "not-started"
$nativePostVideoFlush = [ordered]@{
    completed = $false
    timedOut = $false
    videoFrameCount = 0
    requiredSceneFrames = 8
    savedFrameCount = 0
}

try {
    [Environment]::SetEnvironmentVariable("OPENMW_DEBUG_LEVEL", "INFO", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG", "1", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_CAPTURE_VIDEO_MATCH", $ExpectedVideoAsset, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_CAPTURE_VIDEO_MAX_SECONDS", [string]$VideoSeconds, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_CAPTURE_VIDEO_POST_SCENE_SECONDS", [string]$SceneSeconds, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_CAPTURE_VIDEO_READY_PATH", $readyPath, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_CAPTURE_VIDEO_GO_PATH", $goPath, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_CAPTURE_VIDEO_STOP_PATH", $stopPath, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_CAPTURE_VIDEO_GATE_TIMEOUT_SECONDS", "45", "Process")
    [Environment]::SetEnvironmentVariable(
        "OPENMW_CAPTURE_VIDEO_NATIVE_FRAME_INTERVAL_MS", [string]$NativeFrameIntervalMilliseconds, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_AUTHORED_START_TELEMETRY", "1", "Process")
    [Environment]::SetEnvironmentVariable(
        "OPENMW_AUTHORED_DEFAULT_CHOICE_DELAY_SECONDS",
        $DefaultChoiceDelaySeconds.ToString("0.###", [Globalization.CultureInfo]::InvariantCulture),
        "Process")
    if (-not [string]::IsNullOrWhiteSpace($AuthoredRoutePath)) {
        # The engine owns the route execution and report.  Leave the exit
        # flag unset so capture duration, not route completion, controls the
        # owned process lifetime.
        [Environment]::SetEnvironmentVariable("OPENMW_COMPAT_ROUTE_PATH", $AuthoredRoutePath, "Process")
        [Environment]::SetEnvironmentVariable(
            "OPENMW_COMPAT_ROUTE_REPORT_PATH", $authoredRouteReportPath, "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_COMPAT_ROUTE_EXIT_AFTER_WRITE", $null, "Process")
    }

    $arguments = @(
        "--replace", "config",
        "--config", [string]$profile.profileDirectory,
        "--resources", [string]$profile.resourcesRoot,
        "--skip-menu", "--new-game"
    )
    $argumentLine = ($arguments | ForEach-Object { Quote-OpenNVArgument $_ }) -join " "
    $game = Start-Process -FilePath $binary -ArgumentList $argumentLine `
        -WorkingDirectory (Split-Path -Parent $binary) -WindowStyle Normal `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Wait-ForCaptureFile -Path $readyPath -Process $game -Deadline $deadline -Description "authored video-ready marker"

    $ffmpegArgs = @(
        "-hide_banner", "-loglevel", "warning", "-y",
        "-f", "gdigrab", "-framerate", "60", "-draw_mouse", "0", "-i", "title=OpenMW",
        "-thread_queue_size", "1024", "-f", "dshow", "-i", "audio=$AudioDevice",
        "-t", ([string]$captureSeconds),
        "-map", "0:v:0", "-map", "1:a:0",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", $rawVideoPath
    )
    $ffmpegArgumentLine = ($ffmpegArgs | ForEach-Object { Quote-OpenNVArgument $_ }) -join " "
    # Start-Process exposes a blank ExitCode on this Windows PowerShell host
    # even after WaitForExit. Use ProcessStartInfo directly so the recorder's
    # exit status remains auditable instead of treating a healthy MP4 as a
    # failed transport solely because its host wrapper discarded that status.
    $ffmpegStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $ffmpegStartInfo.FileName = (Get-Command ffmpeg -ErrorAction Stop).Source
    $ffmpegStartInfo.Arguments = $ffmpegArgumentLine
    $ffmpegStartInfo.WorkingDirectory = $WorldsRoot
    $ffmpegStartInfo.UseShellExecute = $false
    $ffmpegStartInfo.CreateNoWindow = $true
    $ffmpegStartInfo.RedirectStandardOutput = $true
    $ffmpegStartInfo.RedirectStandardError = $true
    $ffmpeg = [System.Diagnostics.Process]::new()
    $ffmpeg.StartInfo = $ffmpegStartInfo
    if (-not $ffmpeg.Start()) {
        throw "Unable to start the exact-title/audio recorder."
    }
    $ffmpegStdoutTask = $ffmpeg.StandardOutput.ReadToEndAsync()
    $ffmpegStderrTask = $ffmpeg.StandardError.ReadToEndAsync()
    Start-Sleep -Milliseconds $CaptureLeadMilliseconds
    $ffmpeg.Refresh()
    if ($ffmpeg.HasExited) {
        throw "The exact-title/audio recorder exited before the authored video gate could open."
    }

    [IO.File]::WriteAllText(
        $goPath,
        "openedAtUtc=$([DateTime]::UtcNow.ToString('o'))$([Environment]::NewLine)",
        [Text.UTF8Encoding]::new($false))
    $gateOpenedAt = [DateTime]::UtcNow
    $ffmpeg.WaitForExit()
    $ffmpeg.Refresh()
    $ffmpegExitCode = $ffmpeg.ExitCode
    Save-AsyncProcessStreams `
        -StandardOutputTask $ffmpegStdoutTask `
        -StandardErrorTask $ffmpegStderrTask `
        -StandardOutputPath $captureStdoutPath `
        -StandardErrorPath $captureStderrPath
    $ffmpegStreamsPersisted = $true
    if ($null -ne $ffmpegExitCode -and $ffmpegExitCode -ne 0) {
        throw "The exact-title/audio recorder failed with exit code $ffmpegExitCode."
    }
    $nativeFlushSeconds = [Math]::Max(15, [Math]::Min(60, [int][Math]::Ceiling($SceneSeconds * 2.0)))
    $nativePostVideoFlush = Wait-ForNativePostVideoFrames `
        -LogPath $profileLogPath `
        -FrameDirectory $nativeFrameSourceDirectory `
        -ExpectedVideoAsset $ExpectedVideoAsset `
        -SceneSeconds $SceneSeconds `
        -Process $game `
        -Deadline ([DateTime]::UtcNow.AddSeconds($nativeFlushSeconds))
}
finally {
    if ($null -ne $ffmpeg) {
        $ffmpeg.Refresh()
        if (-not $ffmpeg.HasExited) {
            $ffmpeg.Kill()
            $ffmpeg.WaitForExit()
        }
        if ($null -eq $ffmpegExitCode -and $ffmpeg.HasExited) {
            $ffmpegExitCode = $ffmpeg.ExitCode
        }
        if (-not $ffmpegStreamsPersisted -and
            $null -ne $ffmpegStdoutTask -and $null -ne $ffmpegStderrTask) {
            Save-AsyncProcessStreams `
                -StandardOutputTask $ffmpegStdoutTask `
                -StandardErrorTask $ffmpegStderrTask `
                -StandardOutputPath $captureStdoutPath `
                -StandardErrorPath $captureStderrPath
            $ffmpegStreamsPersisted = $true
        }
    }
    if ($null -ne $game) {
        $game.Refresh()
        if (-not $game.HasExited) {
            [IO.File]::WriteAllText(
                $stopPath,
                "stoppedAtUtc=$([DateTime]::UtcNow.ToString('o'))$([Environment]::NewLine)",
                [Text.UTF8Encoding]::new($false))
            # Let the profile-local asynchronous screenshot writer finish its
            # last native frame before the owned game process is terminated.
            Start-Sleep -Milliseconds 1500
            $game.Refresh()
        }
        if (-not $game.HasExited) {
            Stop-Process -Id $game.Id -Force
            $gameTermination = "owned-process-terminated-after-recorder-finished"
        }
        else {
            $gameTermination = "engine-exited"
        }
    }
    Restore-Environment -Values $previousEnvironment
}

$nativeSourceFrameFiles = @()
if (Test-Path -LiteralPath $nativeFrameSourceDirectory -PathType Container) {
    $sourceFrames = @(
        Get-ChildItem -LiteralPath $nativeFrameSourceDirectory -File |
            Where-Object { $_.Extension -in @(".jpg", ".jpeg", ".png") } |
            Sort-Object @{ Expression = { Get-NativeSourceFrameNumber -File $_ } }, Name
    )
    if ($sourceFrames.Count -gt 0) {
        New-Item -ItemType Directory -Path $nativeSourceFramesDirectory -ErrorAction Stop | Out-Null
        foreach ($frame in $sourceFrames) {
            Copy-Item -LiteralPath $frame.FullName -Destination (Join-Path $nativeSourceFramesDirectory $frame.Name) -ErrorAction Stop
        }
        $nativeSourceFrameFiles = @(
            Get-ChildItem -LiteralPath $nativeSourceFramesDirectory -File |
                Where-Object { $_.Extension -in @(".jpg", ".jpeg", ".png") } |
                Sort-Object @{ Expression = { Get-NativeSourceFrameNumber -File $_ } }, Name
        )
    }
}
$nativeSourceFramesManifest = [ordered]@{
    schema = "opennv-native-source-frames/v1"
    campaign = $Campaign
    intervalMilliseconds = $NativeFrameIntervalMilliseconds
    sourceDirectory = $nativeFrameSourceDirectory
    retainedDirectory = $nativeSourceFramesDirectory
    frameCount = $nativeSourceFrameFiles.Count
    frames = @($nativeSourceFrameFiles | ForEach-Object { Get-Artifact $_.FullName })
}
[IO.File]::WriteAllText(
    $nativeSourceFramesManifestPath,
    (($nativeSourceFramesManifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false))

$logText = @(
    $(if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -Raw -LiteralPath $stdoutPath }),
    $(if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -Raw -LiteralPath $stderrPath }),
    $(if (Test-Path -LiteralPath (Join-Path $profile.profileDirectory "openmw.log") -PathType Leaf) {
        Get-Content -Raw -LiteralPath (Join-Path $profile.profileDirectory "openmw.log")
    })
) -join [Environment]::NewLine

$specialSelectionMatch = [regex]::Match(
    $logText,
    'FNV/ESM4 behavior: ShowLoveTesterMenuParams default selection total=(?<total>\d+) values=(?<values>\d+(?:,\d+){6}) capability=character-special')
$authoredDefaultSpecialTotal = if ($specialSelectionMatch.Success) {
    [int]$specialSelectionMatch.Groups["total"].Value
} else {
    $null
}
$authoredDefaultSpecialValues = if ($specialSelectionMatch.Success) {
    @($specialSelectionMatch.Groups["values"].Value -split ',' | ForEach-Object { [int]$_ })
} else {
    @()
}
$authoredDefaultSpecialSelection = $specialSelectionMatch.Success -and
    $authoredDefaultSpecialTotal -eq 40 -and
    ((@($authoredDefaultSpecialValues) -join ',') -eq '6,6,6,6,6,5,5')
$nativeVideoFrameMatch = [regex]::Match(
    $logText,
    'OpenNV capture: queued native source frames asset="' + [regex]::Escape($ExpectedVideoAsset) +
        '" count=(?<count>\d+) intervalMilliseconds=\d+')
[int]$nativeVideoFrameCount = if ($nativeVideoFrameMatch.Success) {
    [int]$nativeVideoFrameMatch.Groups["count"].Value
} else {
    0
}
$postVideoNativeSceneFramesCompleted = $logText -match [regex]::Escape(
    "OpenNV capture: post-video native scene frames complete")

$events = [ordered]@{
    videoReady = Test-Path -LiteralPath $readyPath -PathType Leaf
    videoGateOpened = $logText -match [regex]::Escape("OpenNV capture: video gate opened asset=`"$ExpectedVideoAsset`"")
    videoLimited = $logText -match [regex]::Escape("OpenNV capture: limiting authored video asset=`"$ExpectedVideoAsset`"")
    playBinkCompleted = $logText -match [regex]::Escape("FNV/ESM4 behavior: PlayBink completed asset='$ExpectedVideoAsset'")
    nativeVideoFrameBoundaryRecorded = $nativeVideoFrameMatch.Success -and $nativeVideoFrameCount -gt 0
    nativeVideoFrameCount = $nativeVideoFrameCount
    postVideoNativeSceneFramesCompleted = $postVideoNativeSceneFramesCompleted
    charGenOverlaySuppressed = $logText -match [regex]::Escape("OpenNV UI: gameplay overlay suppression=1")
    authoredDefaultMessageChoiceSelected = $logText -match [regex]::Escape("OpenNV authored automation: selected default interactive message button")
    ttwGeneProjectorMapped = $logText -match [regex]::Escape("OpenNV compatibility: authored command=ttw_showgeneprojector capability=character-appearance handled=1")
    authoredCharacterAppearanceOpened = $logText -match [regex]::Escape("FNV/ESM4 behavior: ShowRaceMenu opened authored character appearance menu")
    authoredDefaultCharacterAppearanceSelected = $logText -match [regex]::Escape("OpenNV authored automation: accepted default character appearance")
    authoredNameMenuOpened = $logText -match [regex]::Escape("FNV/ESM4 behavior: GetPlayerName opened authored name menu")
    authoredDefaultNameSelected = $logText -match [regex]::Escape("OpenNV authored automation: accepted default player name")
    newVegasOpeningStageExecuted = $logText -match "FNV/ESM4 behavior: SetStage quest=VCG00.+stage=0"
    courierPlacedAtDocMitchell = $logText -match [regex]::Escape("FNV/ESM4 behavior: MoveTo actor=player marker=VCG01PlayerStartMarkerREF")
    docMitchellOpeningStarted = $logText -match [regex]::Escape("FNV/ESM4 behavior: SetQuestVariable quest=VCG01 variable=ftimer")
    authoredVigorTesterTriggerEntered = $logText -match "FNV/ESM4 behavior: SetStage quest=VCG01 .*stage=60"
    authoredVigorTesterActivated = $logText -match [regex]::Escape("FNV/ESM4 behavior: reference-script event reference=VCG01VigorTesterREF event=onactivate argument=player")
    authoredDefaultSpecialSelected = $authoredDefaultSpecialSelection
    authoredDefaultSpecialTotal = $authoredDefaultSpecialTotal
    authoredDefaultSpecialValues = @($authoredDefaultSpecialValues)
    authoredDefaultChoiceSelected = ($logText -match [regex]::Escape("OpenNV authored automation: selected default interactive message button")) -or
        ($logText -match [regex]::Escape("OpenNV authored automation: accepted default character appearance")) -or
        ($logText -match [regex]::Escape("OpenNV authored automation: accepted default player name"))
}

$rawArtifact = Get-Artifact $rawVideoPath
$videoArtifact = $null
$probe = $null
$audioMaximumDb = $null
$visualEvidence = $null
$exactTitleRecorderVisualEvidence = $null
$nativeSourceFrameRate = $null
$nativeSourceFramePattern = $null
$nativeSourceFrameSequenceValid = $false
$firstNativeSourceFrameNumber = $null
$nativeSceneFrameHealth = $null
$presentationVisualSource = $null
$authoredInitialFadeObserved = $logText -match 'FNV/ESM4 behavior: ApplyImageSpaceModifier id=.*animatable=1'
$authoredTransientFadeIds = [System.Collections.Generic.List[string]]::new()
$authoredTransientFadeMaximumFrameCounts = [System.Collections.Generic.List[int]]::new()
foreach ($fadeMatch in [regex]::Matches(
    $logText,
    '(?im)^.*FNV/ESM4 behavior: ApplyImageSpaceModifier id=(?<id>\S*fade\S*)\s+form=.*?\s+animatable=1\s+duration=(?<duration>\d+(?:\.\d+)?)')) {
    $durationSeconds = [double]$fadeMatch.Groups['duration'].Value
    if ($durationSeconds -le 0.0) {
        continue
    }
    $authoredTransientFadeIds.Add($fadeMatch.Groups['id'].Value)
    # Keep a four-frame slack for the asynchronous image writer, while the
    # captured segment still has to recover to a healthy native frame.
    $authoredTransientFadeMaximumFrameCounts.Add([Math]::Max(4,
        [int][Math]::Ceiling(($durationSeconds * 1000.0) / $NativeFrameIntervalMilliseconds) + 4))
}
$presentationDurationSeconds = [double]($VideoSeconds + $SceneSeconds)
# Native screenshots are sampled asynchronously and the authored opening can
# suspend their cadence in a modal transition.  The evidence contract is the
# recorded video boundary plus a visually inspected post-video sequence, not a
# fictional one-frame-per-second wall-clock rate.  Require the complete video
# boundary and at least eight persisted post-video frames; the scene-health
# gate below still analyzes every one of those frames fail-closed.
$minimumNativeSourceFrameCount = [Math]::Max(40, $nativeVideoFrameCount + 8)
if ($nativeSourceFrameFiles.Count -gt 0) {
    $emptyNativeSourceFrames = @($nativeSourceFrameFiles | Where-Object { $_.Length -le 0 })
    if ($emptyNativeSourceFrames.Count -gt 0) {
        throw "The retained native source frame sequence contains empty files: $($emptyNativeSourceFrames[0].Name)"
    }
    $extensions = @($nativeSourceFrameFiles | ForEach-Object { $_.Extension.ToLowerInvariant() } | Select-Object -Unique)
    if ($extensions.Count -ne 1) {
        throw "The retained native source frame sequence mixes file formats: $($extensions -join ', ')."
    }
    $firstFrameMatch = [regex]::Match($nativeSourceFrameFiles[0].BaseName, '^screenshot(?<number>\d+)$')
    if (-not $firstFrameMatch.Success) {
        throw "The first retained native source frame is not a numbered OpenMW screenshot: $($nativeSourceFrameFiles[0].Name)"
    }
    $firstFrameNumber = [int]$firstFrameMatch.Groups["number"].Value
    $firstNativeSourceFrameNumber = $firstFrameNumber
    for ($index = 0; $index -lt $nativeSourceFrameFiles.Count; ++$index) {
        $frameMatch = [regex]::Match($nativeSourceFrameFiles[$index].BaseName, '^screenshot(?<number>\d+)$')
        if (-not $frameMatch.Success -or [int]$frameMatch.Groups["number"].Value -ne ($firstFrameNumber + $index)) {
            throw "The retained native source frames are not a contiguous OpenMW screenshot sequence."
        }
    }
    if ($nativeSourceFrameFiles.Count -lt $minimumNativeSourceFrameCount) {
        throw "The retained native source frame sequence is too short for the opening proof: $($nativeSourceFrameFiles.Count) frames; expected at least $minimumNativeSourceFrameCount."
    }
    $nativeSourceFrameRate = ($nativeSourceFrameFiles.Count / $presentationDurationSeconds).ToString(
        "0.######", [Globalization.CultureInfo]::InvariantCulture)
    $nativeSourceFramePattern = Join-Path $nativeSourceFramesDirectory ("screenshot%03d" + $extensions[0])
    $nativeSourceFrameSequenceValid = $true
    $nativeSceneFrameHealth = Get-NativeSceneFrameHealth `
        -Frames $nativeSourceFrameFiles `
        -FirstFrameNumber $firstNativeSourceFrameNumber `
        -VideoNativeFrameCount $nativeVideoFrameCount `
        -SceneSeconds $SceneSeconds `
        -AuthoredInitialFadeObserved $authoredInitialFadeObserved `
        -AuthoredTransientFadeMaximumFrameCounts @($authoredTransientFadeMaximumFrameCounts.ToArray()) `
        -PostVideoNativeSceneFramesCompleted $postVideoNativeSceneFramesCompleted
}
$captureStderrText = if (Test-Path -LiteralPath $captureStderrPath -PathType Leaf) {
    Get-Content -Raw -LiteralPath $captureStderrPath
} else {
    ""
}
# Exact-title gdigrab may retain a syntactically valid MP4 after the window
# capture backend has stopped delivering frames.  Treat those transport errors
# as evidence failure even if ffmpeg itself later exits successfully; a valid
# opening proof must have a healthy native recorder from the video gate through
# the handoff.
$captureTransportFailurePatterns = @(
    "Failed to capture image",
    "Error during demuxing",
    "I/O error"
)
$captureTransportFailures = @(
    foreach ($pattern in $captureTransportFailurePatterns) {
        if ($captureStderrText -match [regex]::Escape($pattern)) {
            $pattern
        }
    }
)
$captureTransportHealthy = ($null -ne $ffmpegExitCode) -and $ffmpegExitCode -eq 0 -and
    $captureTransportFailures.Count -eq 0
if ($null -ne $rawArtifact) {
    # Retain the exact-title recording as the engine-title/audio transport
    # artifact. On this GPU-backed unattended desktop, GDI can return a black
    # client surface, so the presentation video is built from OpenMW's native
    # framebuffer frames instead of treating a black window recording as proof.
    $exactTitleRecorderVisualEvidence = Get-VideoVisualEvidence -Path $rawVideoPath
    if (-not $nativeSourceFrameSequenceValid) {
        throw "Cannot construct the opening presentation video without a valid retained native source frame sequence."
    }
    $presentationDuration = [string]($VideoSeconds + $SceneSeconds)
    $leadSeconds = ([double]$CaptureLeadMilliseconds / 1000.0).ToString("0.000", [Globalization.CultureInfo]::InvariantCulture)
    $presentationArguments = @(
        "-hide_banner", "-loglevel", "warning", "-y",
        "-framerate", $nativeSourceFrameRate, "-start_number", [string]$firstFrameNumber,
        "-i", $nativeSourceFramePattern,
        "-ss", $leadSeconds, "-i", $rawVideoPath,
        "-t", $presentationDuration,
        "-map", "0:v:0", "-map", "1:a:0",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", $videoPath
    )
    $presentationArgumentLine = ($presentationArguments | ForEach-Object { Quote-OpenNVArgument $_ }) -join " "
    $presentation = Start-Process -FilePath "ffmpeg" -ArgumentList $presentationArgumentLine `
        -WindowStyle Hidden -Wait -PassThru
    if ($presentation.ExitCode -ne 0) {
        throw "Unable to create the native-frame opening presentation video."
    }
    $videoArtifact = Get-Artifact $videoPath
    $visualEvidence = Get-VideoVisualEvidence -Path $videoPath
    $presentationVisualSource = "openmw-native-screencapture-frames"
    $probe = (& ffprobe -v error -show_entries format=duration,size `
        -show_entries stream=codec_type,codec_name,width,height,channels,sample_rate `
        -of json $videoPath | ConvertFrom-Json)
    # FFmpeg writes normal probe information to stderr.  Capture it as evidence
    # without letting PowerShell's native-command error preference mistake that
    # successful diagnostic output for a failed opening capture.
    # Windows PowerShell does not expose this PowerShell 7 preference variable.
    # Detect it rather than reading an unset strict-mode variable.
    $hasNativeErrorPreference = Test-Path -LiteralPath 'Variable:PSNativeCommandUseErrorActionPreference'
    $priorNativeErrorPreference = if ($hasNativeErrorPreference) {
        Get-Variable -Name PSNativeCommandUseErrorActionPreference -ValueOnly
    } else {
        $null
    }
    $priorErrorActionPreference = $ErrorActionPreference
    try {
        # On Windows PowerShell, native stderr is still surfaced as an error
        # record when the script-wide preference is Stop, even when it is
        # explicitly redirected into the diagnostic transcript below.
        $ErrorActionPreference = "Continue"
        if ($hasNativeErrorPreference) {
            Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false
        }
        $audioText = ((& ffmpeg -hide_banner -i $videoPath -map "0:a:0" -af volumedetect -f null - 2>&1) | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect the presentation audio stream (ffmpeg exit code $LASTEXITCODE)."
        }
    }
    finally {
        $ErrorActionPreference = $priorErrorActionPreference
        if ($hasNativeErrorPreference) {
            Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $priorNativeErrorPreference
        }
    }
    $maximumMatch = [regex]::Match($audioText, 'max_volume:\s*(?<db>-?(?:\d+(?:\.\d+)?|inf)) dB')
    if ($maximumMatch.Success -and $maximumMatch.Groups["db"].Value -ne "-inf") {
        $audioMaximumDb = [double]::Parse($maximumMatch.Groups["db"].Value, [Globalization.CultureInfo]::InvariantCulture)
    }
}

$videoStreams = @($(if ($null -ne $probe) { $probe.streams | Where-Object { $_.codec_type -eq "video" } }))
$audioStreams = @($(if ($null -ne $probe) { $probe.streams | Where-Object { $_.codec_type -eq "audio" } }))
$durationSeconds = if ($null -ne $probe) {
    [double]::Parse([string]$probe.format.duration, [Globalization.CultureInfo]::InvariantCulture)
} else { 0.0 }
$authoredRoute = $null
$authoredRoutePassed = [string]::IsNullOrWhiteSpace($AuthoredRoutePath)
if (-not $authoredRoutePassed -and (Test-Path -LiteralPath $authoredRouteReportPath -PathType Leaf)) {
    $authoredRoute = Get-Content -Raw -LiteralPath $authoredRouteReportPath | ConvertFrom-Json
    $authoredRoutePassed = [string]$authoredRoute.status -eq "pass"
}
$requiresDefaultCharacterAppearance = $DefaultChoiceDelaySeconds -gt 0
$requiresNewVegasVigorProof = $Campaign -eq "NewVegas" -and -not [string]::IsNullOrWhiteSpace($AuthoredRoutePath)
$campaignOpeningEventsPassed = if ($Campaign -eq "TTW") {
    $events.ttwGeneProjectorMapped -and $events.authoredCharacterAppearanceOpened -and
        (-not $requiresDefaultCharacterAppearance -or $events.authoredDefaultCharacterAppearanceSelected)
} else {
    $events.newVegasOpeningStageExecuted -and $events.courierPlacedAtDocMitchell -and
    $events.docMitchellOpeningStarted -and $events.authoredNameMenuOpened -and
        (-not $requiresDefaultCharacterAppearance -or $events.authoredDefaultNameSelected) -and
        (-not $requiresNewVegasVigorProof -or
            ($events.authoredVigorTesterTriggerEntered -and $events.authoredVigorTesterActivated -and
                $events.authoredDefaultSpecialSelected))
}
$passed = $captureTransportHealthy -and $events.videoReady -and $events.videoGateOpened -and $events.videoLimited -and
    $events.playBinkCompleted -and $events.nativeVideoFrameBoundaryRecorded -and
    $events.postVideoNativeSceneFramesCompleted -and $events.charGenOverlaySuppressed -and $campaignOpeningEventsPassed -and
    $null -ne $videoArtifact -and $videoStreams.Count -eq 1 -and $audioStreams.Count -eq 1 -and
    $durationSeconds -ge (($VideoSeconds + $SceneSeconds) - 1.0) -and
    $null -ne $audioMaximumDb -and $audioMaximumDb -gt -80.0 -and
    $nativeSourceFrameSequenceValid -and $null -ne $visualEvidence -and
    [bool]$visualEvidence.changingVisibleFrames -and $null -ne $nativeSceneFrameHealth -and
    [bool]$nativeSceneFrameHealth.passed -and $authoredRoutePassed

$report = [ordered]@{
    schema = if ($Campaign -eq "TTW") {
        "opennv-ttw-authored-opening-capture/v1"
    } else {
        "opennv-newvegas-authored-opening-capture/v1"
    }
    status = if ($passed) { "pass" } else { "fail" }
    campaign = $Campaign
    startedAtUtc = $startedAt.ToString("o")
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
    capture = [ordered]@{
        method = "openmw-authored-start-video-gate-native-screencapture-frames-plus-exact-title-directshow-audio"
        driver = "authored PlayBink source command; generic time-limited capture gate; engine-native framebuffer frames"
        windowTitle = "OpenMW"
        audioDevice = $AudioDevice
        videoSeconds = $VideoSeconds
        sceneSeconds = $SceneSeconds
        defaultChoiceDelaySeconds = $DefaultChoiceDelaySeconds
        authoredRoutePath = $AuthoredRoutePath
        authoredRouteReportPath = $authoredRouteReportPath
        authoredRoutePassed = $authoredRoutePassed
        captureLeadMilliseconds = $CaptureLeadMilliseconds
        nativeSourceFrameIntervalMilliseconds = $NativeFrameIntervalMilliseconds
        nativePostVideoCaptureSeconds = $SceneSeconds
        sceneCompletionGraceSeconds = $sceneCompletionGraceSeconds
        nativeVideoFrameBoundaryRecorded = $events.nativeVideoFrameBoundaryRecorded
        nativeVideoFrameCount = $nativeVideoFrameCount
        postVideoNativeSceneFramesCompleted = $events.postVideoNativeSceneFramesCompleted
        nativePostVideoFrameFlush = $nativePostVideoFlush
        nativeSourceFrameSequenceValid = $nativeSourceFrameSequenceValid
        nativeSceneFrameHealthPassed = if ($null -ne $nativeSceneFrameHealth) { [bool]$nativeSceneFrameHealth.passed } else { $false }
        presentationVisualSource = $presentationVisualSource
        profilePreventsFocusLossMinimize = $captureWindowRemainsVisible
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        gameTermination = $gameTermination
        recorderExitCode = $ffmpegExitCode
        transportHealthy = $captureTransportHealthy
        transportFailures = $captureTransportFailures
        stopMarker = $stopPath
    }
    source = [ordered]@{
        videoAsset = $sourceArtifact
        ttwRoot = $TtwRoot
        falloutNewVegasData = $FalloutNewVegasData
        profileDirectory = $profile.profileDirectory
        profileManifest = $profile.manifestPath
        content = @($profile.content)
        dataLayerContract = $layerContract
    }
    events = $events
    authoredRoute = $authoredRoute
    media = [ordered]@{
        durationSeconds = $durationSeconds
        videoStreamCount = $videoStreams.Count
        audioStreamCount = $audioStreams.Count
        audioMaximumDb = $audioMaximumDb
        nativeSourceFrameCount = $nativeSourceFrameFiles.Count
        nativeSourceFramesManifest = $nativeSourceFramesManifestPath
        nativeSourceFrameRate = $nativeSourceFrameRate
        presentationVisualSource = $presentationVisualSource
        visualEvidence = $visualEvidence
        sceneFrameHealth = $nativeSceneFrameHealth
        exactTitleRecorderVisualEvidence = $exactTitleRecorderVisualEvidence
        gateOpenedAtUtc = if ($null -ne $gateOpenedAt) { $gateOpenedAt.ToString("o") } else { $null }
        captureTransportHealthy = $captureTransportHealthy
        captureTransportFailures = $captureTransportFailures
    }
    artifacts = @(
        $sourceArtifact,
        (Get-Artifact $readyPath),
        (Get-Artifact $goPath),
        (Get-Artifact $stopPath),
        (Get-Artifact $stdoutPath),
        (Get-Artifact $stderrPath),
        (Get-Artifact (Join-Path $profile.profileDirectory "openmw.log")),
        (Get-Artifact $captureStdoutPath),
        (Get-Artifact $captureStderrPath),
        (Get-Artifact $authoredRouteReportPath),
        (Get-Artifact $nativeSourceFramesManifestPath),
        $rawArtifact,
        $videoArtifact
    ) | Where-Object { $null -ne $_ }
}
[IO.File]::WriteAllText(
    $reportPath,
    (($report | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false))

$report
if (-not $passed) {
    throw "OpenNV $Campaign opening capture did not meet its movie, authored handoff, Vigor/SPECIAL (when routed), audible-audio, changing-visible-frame, or native scene-frame integrity acceptance checks. See $reportPath"
}
